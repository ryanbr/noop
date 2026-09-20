package com.noop.ble

import com.noop.protocol.CommandNames
import com.noop.protocol.CommandNumber
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2338: the read-only GET_ADVERTISING_NAME(141) probe.
 *
 * Nothing has ever sent 140 or 141 to a strap, so these pin the two things that can be checked without
 * one: that the decode reads the 5/MG envelope rather than the 4.0 one, and that the WRITE side is not
 * expressible at all.
 */
class AdvertisingNameProbeTest {

    /** SOF, len(LE u16), crc8, then the 5/MG inner block; payload starts at 13. */
    private fun whoop5Response(payload: ByteArray): ByteArray {
        val head = ByteArray(13)
        val length = 13 + payload.size
        head[0] = 0xAA.toByte()
        head[1] = (length and 0xFF).toByte()
        head[2] = ((length shr 8) and 0xFF).toByte()
        return head + payload
    }

    @Test fun decodesAPrintableNameFromTheFiveMgEnvelope() {
        val frame = whoop5Response("Whoop von Beispiel".toByteArray(Charsets.UTF_8))
        assertEquals("Whoop von Beispiel", advertisingNameFromWhoop5Response(frame))
    }

    @Test fun stripsNonPrintableBytesAndTrims() {
        // A NUL-terminated, space-padded name is the 4.0 payload shape; if the 5/MG echoes anything
        // similar the decode must not carry the padding into a device name.
        val frame = whoop5Response(byteArrayOf(0, 0) + "  WHOOP 4.0  ".toByteArray() + byteArrayOf(0))
        assertEquals("WHOOP 4.0", advertisingNameFromWhoop5Response(frame))
    }

    @Test fun aPayloadWithNoPrintableBytesIsNotAName() {
        // The answer to "the strap replied with something that is not a name". An empty string here
        // would read as "the strap says its name is blank", which this cannot support.
        assertNull(advertisingNameFromWhoop5Response(whoop5Response(byteArrayOf(0, 1, 2, 3))))
    }

    @Test fun aTooShortFrameIsNull() {
        assertNull(advertisingNameFromWhoop5Response(byteArrayOf()))
        assertNull(advertisingNameFromWhoop5Response(byteArrayOf(0xAA.toByte(), 2)))
        // Length pointing at or before the payload start carries nothing.
        assertNull(advertisingNameFromWhoop5Response(byteArrayOf(0xAA.toByte(), 13, 0) + ByteArray(20)))
    }

    /**
     * The decode must read the 5/MG envelope, NOT the 4.0 one. Reading a 5/MG frame with the 4.0 helper
     * does not fail, it returns four bytes of envelope dressed as payload, which is exactly the mistake
     * bhelm/noop#4 was. A frame whose envelope bytes are printable would decode differently under each.
     */
    @Test fun readsTheFiveMgOffsetNotTheFourPointZeroOne() {
        val frame = whoop5Response("NAME".toByteArray())
        // Bytes 9..12 are envelope on a 5/MG and would be payload under the 4.0 helper. Make them
        // printable so the two offsets cannot agree by accident.
        frame[9] = 'X'.code.toByte(); frame[10] = 'X'.code.toByte()
        frame[11] = 'X'.code.toByte(); frame[12] = 'X'.code.toByte()
        assertEquals("NAME", advertisingNameFromWhoop5Response(frame))
        assertEquals("XXXXNAME", String(whoop4CommandResponsePayload(frame)!!, Charsets.UTF_8))
    }

    @Test fun theReadOpcodeIsKnownAndLabelled() {
        assertEquals(141, CommandNumber.GET_ADVERTISING_NAME.rawValue)
        assertEquals("GET_ADVERTISING_NAME(141)", CommandNames.label(141))
    }

    /**
     * The WRITE side (140) exists, and is admitted by the 5/MG allow-list ONLY while a user-confirmed
     * rename is in flight.
     *
     * That guard is the whole safety story for an opcode no strap has ever been sent, so it is pinned
     * against the SOURCE: `renameStrap` needs a bonded link and has no unit seam, the same reason
     * `ChargingAndReleaseTest` reads source. Losing the `advertisingNameWriteArmed` conjunct would leave
     * a default install able to form these bytes, and nothing else in the suite would notice.
     */
    @Test fun theWriteIsAdmittedOnlyWhileAConfirmedRenameIsInFlight() {
        assertTrue(
            "SET_ADVERTISING_NAME_5MG(140) should exist once the write path ships (#2338)",
            CommandNumber.entries.any { it.rawValue == 140 },
        )
        val src = clientSource()
        val clause = src.lines().firstOrNull {
            it.contains("cmd == CommandNumber.SET_ADVERTISING_NAME_5MG")
        } ?: throw AssertionError("the 140 allow-list clause was not found")
        assertTrue(
            "opcode 140 must be gated on a write actually being in flight: $clause",
            clause.contains("advertisingNameWriteArmed") ||
                src.lines().dropWhile { it != clause }.take(2).any { it.contains("advertisingNameWriteArmed") },
        )
        // And the arming must happen BEFORE the send, or the gate drops our own write.
        val armIdx = src.indexOf("advertisingNameWriteArmed = true")
        val sendIdx = src.indexOf("send(CommandNumber.SET_ADVERTISING_NAME_5MG")
        assertTrue("the write-arm site was not found", armIdx > 0)
        assertTrue("the 140 send site was not found", sendIdx > 0)
        assertTrue("the allow-list must be armed before the send, not after", armIdx < sendIdx)
    }

    /**
     * The probe must clear `renameStatus` before it runs, and must be 5/MG-only.
     *
     * The first is not cosmetic. A 5/MG rename leaves "use Check current name to see whether it took",
     * the Settings section renders `renameStatus ?: advertisingNameProbe`, and without the clear that
     * line sits there hiding the answer to the question it just asked — the one affordance that makes an
     * unconfirmed write checkable at all. The second keeps opcode 141 off a 4.0, which has no send
     * allow-list to stop it and reads its name on 76 anyway.
     *
     * Source-asserted because `probeAdvertisingName` needs a live link and has no unit seam, the same
     * reason `ChargingAndReleaseTest` reads source.
     */
    @Test fun theProbeClearsTheRenameStatusAndIsFiveMgOnly() {
        val src = clientSource()
        val start = src.indexOf("fun probeAdvertisingName()")
        if (start < 0) throw AssertionError("probeAdvertisingName not found")
        val end = src.indexOf("\n    }", start)
        val body = src.substring(start, end)
        assertTrue(
            "the probe must clear renameStatus, or its own answer stays hidden behind it:\n$body",
            body.contains("renameStatus = null"),
        )
        assertTrue(
            "the probe must refuse a non-5/MG family in the client, not only in the UI:\n$body",
            body.contains("connectedFamily != DeviceFamily.WHOOP5"),
        )
        // And the clear has to happen BEFORE the send, not after the reply, or the stale status is
        // on screen for the whole 8s the probe is in flight.
        val clearIdx = body.indexOf("renameStatus = null")
        val sendIdx = body.indexOf("send(CommandNumber.GET_ADVERTISING_NAME")
        assertTrue("the send site was not found", sendIdx > 0)
        assertTrue("renameStatus must be cleared before the probe is sent", clearIdx in 1 until sendIdx)
    }

    /**
     * The 5/MG strap-name SECTION must render for any connected 5/MG; only its CONTROLS may sit behind
     * Test Centre.
     *
     * This regressed once already, inside this same change: gating the whole section put it back to
     * invisible on a default install, which is the exact state that had #2338 reported as "you cannot
     * change it" rather than "not supported yet". Nothing caught it — the give-away was a translated
     * explainer string left rendered nowhere, and `lintVitalFullRelease` does not flag unused resources.
     * So the two conditions are pinned apart here.
     */
    @Test fun theFiveMgSectionIsNotItselfTestCentreGated() {
        val src = settingsSource()
        val outer = src.lines().firstOrNull {
            it.contains("live.connected && live.whoop5Detected")
        } ?: throw AssertionError("the 5/MG strap-name section guard was not found")
        assertFalse(
            "the SECTION must not be gated on Test Centre, only its controls: $outer",
            outer.contains("fiveMgRenameUnlocked"),
        )
        assertTrue(
            "the controls must still be gated on Test Centre somewhere inside the section",
            src.contains("if (fiveMgRenameUnlocked) {"),
        )
        // Both explainers must be reachable: one for the gated state, one for the unlocked state. An
        // orphaned string is how the regression announced itself last time.
        assertTrue(
            "the not-supported explainer must still be rendered",
            src.contains("l10n_settings_screen_renaming_is_not_supported_on_a_02f7af2c"),
        )
        assertTrue(
            "the experimental explainer must still be rendered",
            src.contains("l10n_settings_screen_experimental_on_a_whoop_5_0_711d5341"),
        )
    }

    private fun settingsSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ui/SettingsScreen.kt")
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        throw IllegalStateException("SettingsScreen.kt not found from ${System.getProperty("user.dir")}")
    }

    @Test fun theHarvardSetKeepsItsOwnIdentity() {
        // 77 is the HARVARD set, WHOOP 4.0 only, and keeps its own name in the log.
        assertTrue(CommandNumber.entries.any { it.rawValue == 77 })
        assertEquals("SET_ADVERTISING_NAME_HARVARD(77)", CommandNames.label(77))
    }

    private fun clientSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt")
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        throw IllegalStateException("WhoopBleClient.kt not found from ${System.getProperty("user.dir")}")
    }
}
