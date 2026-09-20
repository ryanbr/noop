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

    @Test fun theHarvardSetKeepsItsOwnIdentity() {
        // 77 is the HARVARD set, WHOOP 4.0 only, and keeps its own name in the log.
        assertTrue(CommandNumber.entries.any { it.rawValue == 77 })
        assertEquals("SET_ADVERTISING_NAME_HARVARD(77)", CommandNames.label(77))
    }

    /**
     * The probe must clear `renameStatus` before it runs, and must be 5/MG-only.
     *
     * The family guard is the one that bites: a WHOOP 4.0 has NO send allow-list, so without it the
     * frame would actually reach the wire there, and 141 is the wrong opcode for that family anyway
     * since a 4.0 reads its name on 76. The clear keeps a standing 4.0 rename status from sitting on
     * top of this probe's answer, because the Settings line prefers `renameStatus`.
     *
     * Source-asserted because `probeAdvertisingName` needs a live link and has no unit seam, the same
     * reason `ChargingAndReleaseTest` reads source.
     */
    @Test fun theProbeClearsTheRenameStatusAndIsFiveMgOnly() {
        val src = clientSource()
        val start = src.indexOf("fun probeAdvertisingName()")
        if (start < 0) throw AssertionError("probeAdvertisingName not found")
        val body = src.substring(start, src.indexOf("\n    }", start))
        assertTrue(
            "the probe must refuse a non-5/MG family in the client, not only in the UI:\n$body",
            body.contains("connectedFamily != DeviceFamily.WHOOP5"),
        )
        assertTrue(
            "the probe must clear renameStatus, or a standing status hides its answer:\n$body",
            body.contains("renameStatus = null"),
        )
        val clearIdx = body.indexOf("renameStatus = null")
        val sendIdx = body.indexOf("send(CommandNumber.GET_ADVERTISING_NAME")
        assertTrue("the send site was not found", sendIdx > 0)
        assertTrue("renameStatus must be cleared before the probe is sent", clearIdx in 1 until sendIdx)
    }

    /**
     * The 5/MG strap-name SECTION must render for any connected 5/MG; only the read-only CHECK may sit
     * behind Test Centre.
     *
     * This regressed once already: gating the whole section put it back to invisible on a default
     * install, which is the exact state that had #2338 reported as "you cannot change it" rather than
     * "not supported yet". Nothing caught it — the give-away was a translated explainer left rendered
     * nowhere, and `lintVitalFullRelease` does not flag unused resources.
     */
    @Test fun theFiveMgSectionIsNotItselfTestCentreGated() {
        val src = settingsSource()
        val outer = src.lines().firstOrNull { it.contains("live.connected && live.whoop5Detected") }
            ?: throw AssertionError("the 5/MG strap-name section guard was not found")
        assertFalse(
            "the SECTION must not be gated on Test Centre, only the check inside it: $outer",
            outer.contains("fiveMgProbeUnlocked"),
        )
        assertTrue(
            "the read-only check must still be gated on Test Centre inside the section",
            src.contains("if (fiveMgProbeUnlocked) {"),
        )
        assertTrue(
            "the not-supported explainer must still be rendered",
            src.contains("l10n_settings_screen_renaming_is_not_supported_on_a_02f7af2c"),
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
