package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #761: byte-parity twin of the Swift `FeatureFlagProbeTests` — same synthetic fixtures, same
 * expectations — for the read-only feature-flag enumeration probe. Fixtures are SYNTHETIC (built here
 * with real CRCs) because the layout is reverse-engineered and not yet answered by a strap in this
 * project's hands; they pin the decode/report contract, including every failure path.
 */
class FeatureFlagProbeTest {

    /** WHOOP 4.0 COMMAND_RESPONSE: [0xAA][len u16 LE][crc8(len)][type=36][seq][cmd][payload…][crc32 LE]. */
    private fun whoop4Response(cmd: Int, payload: ByteArray, seq: Int = 1): ByteArray {
        val inner = byteArrayOf(36, seq.toByte(), cmd.toByte()) + payload
        val length = inner.size + 4
        val lenBytes = byteArrayOf((length and 0xFF).toByte(), ((length shr 8) and 0xFF).toByte())
        val c = Crc.crc32(inner)
        return byteArrayOf(0xAA.toByte()) + lenBytes + byteArrayOf(Crc.crc8(lenBytes).toByte()) + inner +
            byteArrayOf(
                (c and 0xFFL).toByte(), ((c shr 8) and 0xFFL).toByte(),
                ((c shr 16) and 0xFFL).toByte(), ((c shr 24) and 0xFFL).toByte(),
            )
    }

    /** WHOOP 5/MG COMMAND_RESPONSE in the puffin envelope: type @8, seq @9, cmd @10, record from @11. */
    private fun whoop5Response(cmd: Int, payload: ByteArray, seq: Int = 1): ByteArray {
        var inner = byteArrayOf(36, seq.toByte(), cmd.toByte()) + payload
        val pad = (4 - inner.size % 4) % 4
        if (pad > 0) inner += ByteArray(pad)
        val declLen = inner.size + 4
        val head = byteArrayOf(
            0xAA.toByte(), 0x01, (declLen and 0xFF).toByte(), ((declLen shr 8) and 0xFF).toByte(),
            0x00, 0x01,
        )
        val c16 = Crc.crc16Modbus(head)
        val c32 = Crc.crc32(inner)
        return head + byteArrayOf((c16 and 0xFF).toByte(), ((c16 shr 8) and 0xFF).toByte()) + inner +
            byteArrayOf(
                (c32 and 0xFFL).toByte(), ((c32 shr 8) and 0xFFL).toByte(),
                ((c32 shr 16) and 0xFFL).toByte(), ((c32 shr 24) and 0xFFL).toByte(),
            )
    }

    /** The 2-byte response header every COMMAND_RESPONSE carries, then the record. */
    private fun payload(result: Int, record: ByteArray): ByteArray =
        byteArrayOf(0x0A, result.toByte()) + record

    private fun keyBytes(s: String, pad: Int = 8): ByteArray =
        s.toByteArray(Charsets.US_ASCII) + byteArrayOf(0) + ByteArray(pad)

    @Test fun opcodesAreTheEnumeratePairOnly() {
        assertEquals(117, FeatureFlagProbe.START_KEY_EXCHANGE_CMD)
        assertEquals(118, FeatureFlagProbe.SEND_NEXT_FLAG_CMD)
        assertEquals(1, FeatureFlagProbe.REQUEST_BODY.size)
        assertEquals(1, FeatureFlagProbe.REQUEST_BODY[0].toInt())
    }

    @Test fun startDecodesRevisionAndCountOnWhoop4() {
        val frame = whoop4Response(117, payload(1, byteArrayOf(0x01, 0x0B, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(1, r.revision)
        assertEquals(11, r.count)
        assertNull(r.resultCode)
        assertTrue(r.countIsPlausible)
    }

    @Test fun startDecodesOnWhoop5AndSurfacesTheResultCode() {
        val frame = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x10, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(16, r.count)
        assertEquals(1, r.resultCode)
    }

    @Test fun startWithUnsupportedResultIsStillDecodedAndVerdictSaysRejected() {
        val frame = whoop5Response(117, payload(3, byteArrayOf(0x00, 0x00, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(3, r.resultCode)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(r)
        assertTrue(report.verdict.contains("REJECTED by firmware (UNSUPPORTED)"))
        assertTrue(report.render().contains("opcode 117 REJECTED"))
    }

    @Test fun implausibleCountIsFlaggedNotTrusted() {
        val frame = whoop4Response(117, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0xFF.toByte())))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(65535, r.count)
        assertFalse(r.countIsPlausible)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(r)
        assertTrue(report.render().contains("count outside 1…128"))
    }

    @Test fun nextDecodesTheKeyName() {
        val record = byteArrayOf(0x01, 0x00, 0x01) + keyBytes("enable_r22_packets")
        val frame = whoop4Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(0, r.index)
        assertTrue(r.validKey)
        assertEquals("enable_r22_packets", r.key)
        assertFalse(r.isExhausted)
    }

    @Test fun nextDecodesOnWhoop5Too() {
        val record = byteArrayOf(0x01, 0x03, 0x01) + keyBytes("sigproc_wear_detect")
        val frame = whoop5Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(3, r.index)
        assertEquals("sigproc_wear_detect", r.key)
        assertEquals(1, r.resultCode)
    }

    @Test fun exhaustedCursorIsTheEndMarker() {
        val frame = whoop4Response(118, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0x00, 0x00)))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(0xFF, r.index)
        assertTrue(r.isExhausted)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        assertFalse(report.noteNext(r))
        assertEquals("cursor exhausted (index 0xFF)", report.stopReason)
    }

    @Test fun validKeyFalseStopsTheWalkEvenWithBytesAfterIt() {
        val record = byteArrayOf(0x01, 0x04, 0x00) + keyBytes("stale_buffer_leftover")
        val frame = whoop4Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertFalse(r.validKey)
        assertTrue(r.isExhausted)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        assertFalse(report.noteNext(r))
        assertEquals("firmware reported validKey=false", report.stopReason)
        assertTrue(report.keys.isEmpty())
    }

    @Test fun nonPrintableNameIsNotReportedAsAKey() {
        val record = byteArrayOf(0x01, 0x02, 0x01, 0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte())
        val frame = whoop4Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertNull(r.key)
        // Our decode declining a name is NOT the strap saying stop: the firmware still flagged this entry
        // valid, so the walk steps over it instead of throwing away everything after it.
        assertFalse(r.isExhausted)
        assertTrue(r.isSkippable)
    }

    /**
     * The regression this split exists for: one undecodable entry used to end the enumeration, so a list
     * with a bad byte in the middle reported only the keys BEFORE it. The first real capture is the
     * expensive one to obtain, and it is exactly the run that must not be truncated by our own strictness.
     */
    @Test fun anUndecodableEntryDoesNotHideTheKeysAfterIt() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 4))
        fun next(index: Int, key: String?) = FeatureFlagProbe.NextResponse(1, 1, index, true, key)

        assertTrue(report.noteNext(next(0, "enable_r22_packets")))
        assertTrue("a bad name must not stop the walk", report.noteNext(next(1, null)))
        assertTrue(report.noteNext(next(2, "sigproc_wear_detect")))
        assertFalse(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0xFF, false, null)))

        assertEquals(listOf("enable_r22_packets", "sigproc_wear_detect"), report.keys)
        assertEquals(1, report.skipped)
        assertEquals("cursor exhausted (index 0xFF)", report.stopReason)
        assertTrue(report.render().contains("1 name(s) did not decode and were skipped"))
    }

    /**
     * `validKey = 0` is trusted as an end marker, but the other reading — an EMPTY SLOT with the list
     * continuing past it — is not ruled out by anything observed so far. Stopping well short of the
     * announced count is the evidence that would settle it, so the report has to say so loudly rather
     * than reporting a confident short list.
     */
    @Test fun stoppingOnValidKeyFalseShortOfTheAnnouncedCountIsFlagged() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 40))
        assertTrue(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0, true, "enable_r22_packets")))
        assertFalse(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 1, false, null)))

        val why = report.stopReason!!
        assertTrue(why, why.contains("2 of 40 announced entries"))
        assertTrue(why, why.contains("the remainder was NOT walked"))
    }

    /** …and when the count was fully walked, the plain reason stands — no false alarm. */
    @Test fun validKeyFalseAtTheAnnouncedEndIsNotFlagged() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 1))
        assertFalse(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0, false, null)))
        assertEquals("firmware reported validKey=false", report.stopReason)
    }

    /**
     * The verdict must never blame the strap for our own decode. A firmware whose names all fail our
     * printable-ASCII/length filter DID name them; reporting "named none" points at the strap and is the
     * sentence someone would paste into #103.
     */
    @Test fun verdictBlamesOurParserNotTheStrapWhenEveryNameFails() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 3))
        for (i in 0 until 3) {
            report.noteNext(FeatureFlagProbe.NextResponse(1, 1, i, true, null))
        }
        assertTrue(report.keys.isEmpty())
        assertEquals(3, report.skipped)
        val v = report.verdict
        assertTrue(v, v.contains("strap named 3 flag(s)"))
        assertTrue(v, v.contains("our parser rejecting them"))
        assertFalse("must not report our limitation as the strap's behaviour", v.contains("named none"))
    }

    /** A partial success says so in the headline too, not only in the flag-count line. */
    @Test fun verdictReportsSkippedAlongsideTheKeysItDidGet() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 3))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0, true, "enable_r22_packets"))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 1, true, null))
        assertEquals(
            "enumerated 1 feature-flag key name(s); 1 further name(s) did not decode",
            report.verdict,
        )
    }

    /**
     * The skip cannot become an unbounded walk: [FeatureFlagProbe.MAX_FLAGS] still terminates a firmware
     * that answers forever with entries whose names never decode.
     */
    @Test fun everyReplyUndecodableStillStopsAtTheSafetyCap() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        var sent = 0
        while (report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0, true, null))) {
            sent += 1
            assertTrue("walk must not run away", sent < FeatureFlagProbe.MAX_FLAGS + 2)
        }
        assertEquals(FeatureFlagProbe.MAX_FLAGS, report.steps)
        assertEquals(FeatureFlagProbe.MAX_FLAGS, report.skipped)
        assertEquals("safety cap of ${FeatureFlagProbe.MAX_FLAGS} replies reached", report.stopReason)
        assertTrue(report.keys.isEmpty())
    }

    @Test fun keyLongerThanTheSetSideFieldIsRejected() {
        val long = "a".repeat(FeatureFlagProbe.MAX_KEY_LENGTH + 1)
        assertNull(FeatureFlagProbe.asciiKey(long.toByteArray(Charsets.US_ASCII) + byteArrayOf(0)))
        assertEquals("ok_key", FeatureFlagProbe.asciiKey("ok_key".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0x41)))
    }

    @Test fun badCrcIsRejected() {
        val frame = whoop4Response(117, payload(1, byteArrayOf(0x01, 0x0B, 0x00)))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).failure)

        val five = whoop5Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("x")))
        five[7] = (five[7].toInt() xor 0xFF).toByte()
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseNext(five, DeviceFamily.WHOOP5).failure)
    }

    @Test fun corruptPayloadBytesFailCrcBeforeAnyFieldIsRead() {
        val frame = whoop4Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("enable_r22_packets")))
        frame[10] = (frame[10].toInt() xor 0x01).toByte()
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).failure)
    }

    @Test fun wrongCommandIsRejected() {
        val frame = whoop4Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("x")))
        assertEquals(
            FeatureFlagProbe.ParseFailure.WRONG_COMMAND,
            FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).failure,
        )
    }

    @Test fun nonCommandResponseTypeIsRejected() {
        // Same bytes, but packet type COMMAND (35) rather than COMMAND_RESPONSE (36).
        val inner = byteArrayOf(35, 1, 117) + payload(1, byteArrayOf(0x01, 0x0B, 0x00))
        val length = inner.size + 4
        val lenBytes = byteArrayOf((length and 0xFF).toByte(), ((length shr 8) and 0xFF).toByte())
        val c = Crc.crc32(inner)
        val frame = byteArrayOf(0xAA.toByte()) + lenBytes + byteArrayOf(Crc.crc8(lenBytes).toByte()) + inner +
            byteArrayOf(
                (c and 0xFFL).toByte(), ((c shr 8) and 0xFFL).toByte(),
                ((c shr 16) and 0xFFL).toByte(), ((c shr 24) and 0xFFL).toByte(),
            )
        assertEquals(FeatureFlagProbe.ParseFailure.ENVELOPE, FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).failure)
    }

    @Test fun truncatedRecordsAreRejected() {
        val short = whoop4Response(117, payload(1, byteArrayOf(0x01)))
        assertEquals(FeatureFlagProbe.ParseFailure.TRUNCATED, FeatureFlagProbe.parseStart(short, DeviceFamily.WHOOP4).failure)
        val header = whoop4Response(118, byteArrayOf(0x0A, 0x01))
        assertEquals(FeatureFlagProbe.ParseFailure.TRUNCATED, FeatureFlagProbe.parseNext(header, DeviceFamily.WHOOP4).failure)
        val full = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x02, 0x00)))
        assertEquals(
            FeatureFlagProbe.ParseFailure.CRC,
            FeatureFlagProbe.parseStart(full.copyOfRange(0, 9), DeviceFamily.WHOOP5).failure,
        )
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseStart(ByteArray(0), DeviceFamily.WHOOP4).failure)
    }

    @Test fun fullWalkRendersEveryKeyAndStopsOnTheAnnouncedCount() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x03, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        val names = listOf("enable_r22_packets", "hr_ch_switching", "wear_detect_bias")
        names.forEachIndexed { i, name ->
            val record = byteArrayOf(0x01, i.toByte(), 0x01) + keyBytes(name)
            val frame = whoop5Response(118, payload(1, record))
            val n = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP5).value!!
            assertEquals(i < names.size - 1, report.noteNext(n))
        }
        assertEquals(names, report.keys)
        val text = report.render()
        assertTrue(text.contains("#761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG"))
        assertTrue(text.contains("Read-only"))
        assertTrue(text.contains("enumerated 3 feature-flag key name(s)"))
        assertTrue(text.contains("Flags reported by the strap (3 of 3 announced)"))
        assertTrue(text.contains("   1. enable_r22_packets"))
        assertTrue(text.contains("   3. wear_detect_bias"))
        assertTrue(text.contains("walked the 3 entries the strap announced"))
        assertTrue(text.contains("START_FF_KEY_EXCHANGE(117) → revision=1 count=3 result=SUCCESS(1)"))
        assertTrue(text.contains("SEND_NEXT_FF(118) → index=0 validKey=true key=\"enable_r22_packets\""))
    }

    @Test fun repeatedKeysCannotDriveAnUnboundedWalk() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        val record = byteArrayOf(0x01, 0x00, 0x01) + keyBytes("stuck_cursor")
        val frame = whoop4Response(118, payload(1, record))
        val n = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        var steps = 0
        while (report.noteNext(n)) {
            steps += 1
            assertTrue("the walk must terminate", steps < FeatureFlagProbe.MAX_FLAGS + 2)
        }
        assertEquals(listOf("stuck_cursor"), report.keys)
        assertEquals(FeatureFlagProbe.MAX_FLAGS, report.steps)
        assertEquals("safety cap of 128 replies reached", report.stopReason)
    }

    @Test fun timeoutAndFailureAreReportedNotSwallowed() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteTimeout(117, 8)
        val text = report.render()
        assertTrue(text.contains("no COMMAND_RESPONSE for opcode 117 within 8s"))
        assertTrue(text.contains("no usable reply — the enumerate path is unconfirmed"))
        assertTrue(text.contains("(none)"))

        val other = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        other.noteFailure(FeatureFlagProbe.ParseFailure.CRC, 118)
        assertTrue(other.render().contains("CRC failed — frame rejected (never decoded)"))
    }

    /**
     * GOLDEN: the exact rendered report, byte-for-byte. Its Swift twin
     * (`FeatureFlagProbeTests.testGoldenReportIsByteIdenticalAcrossPlatforms`) asserts the SAME literal,
     * so a strap log reads identically on either platform — that is the parity contract, and a whitespace
     * or wording drift on one side fails here rather than in a user's log.
     */
    @Test fun goldenReportIsByteIdenticalAcrossPlatforms() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x02, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        val first = whoop5Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("enable_r22_packets")))
        assertTrue(report.noteNext(FeatureFlagProbe.parseNext(first, DeviceFamily.WHOOP5).value!!))
        val end = whoop5Response(118, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0x00, 0x00)))
        assertFalse(report.noteNext(FeatureFlagProbe.parseNext(end, DeviceFamily.WHOOP5).value!!))

        val golden = """
            #761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG
            Read-only: START_FF_KEY_EXCHANGE(117) + SEND_NEXT_FF(118). No value is written; SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.

            Verdict: enumerated 1 feature-flag key name(s)
            Stopped: cursor exhausted (index 0xFF)

            Flags reported by the strap (1 of 2 announced):
               1. enable_r22_packets

            Exchange:
              START_FF_KEY_EXCHANGE(117) → revision=1 count=2 result=SUCCESS(1)
              SEND_NEXT_FF(118) → index=0 validKey=true key="enable_r22_packets" result=SUCCESS(1)
              SEND_NEXT_FF(118) → index=255 validKey=false result=SUCCESS(1)

        """.trimIndent()
        assertEquals(golden, report.render())
    }

    /**
     * The 117 answer landed and then nothing did: `probeFeatureFlags()` sends 118, the 8s timer fires,
     * and the report renders with zero SEND_NEXT replies. "Named none" would be a claim about the
     * strap's key list that this run's own inputs cannot support — the list was never read. Same class
     * as the `skipped > 0` branch beside it: never report our limitation as the strap's behaviour.
     */
    @Test fun announcedCountWithNo118ReplyIsInconclusiveNotBlamedOnTheStrap() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x05, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        report.noteTimeout(118, 8)

        assertEquals("no SEND_NEXT reply was decoded", 0, report.steps)
        val v = report.verdict
        assertEquals(
            "strap announced 5 flag(s); no SEND_NEXT_FF(118) reply was decoded — " +
                "the key list was never read (inconclusive)",
            v
        )
        assertFalse("must not report our own timeout as the strap serving no names", v.contains("named none"))
    }

    /**
     * A 118 reply that DID land and carried no name is the opposite case: the strap walked its own
     * cursor straight to the end marker, so "named none" is a fact about the strap and is said plainly.
     */
    @Test fun announcedCountWithARealEmptyWalkIsSaidPlainly() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x05, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        assertFalse(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0xFF, false, null)))

        assertEquals(1, report.steps)
        assertTrue(report.keys.isEmpty())
        assertEquals(0, report.skipped)
        assertEquals("strap announced 5 flag(s) but named none", report.verdict)
    }

    /**
     * The count itself is the strap's claim, not a measurement. [FeatureFlagProbeReport.noteStart]
     * already marks an implausible one in the trace; the verdict is the line that gets pasted into an
     * issue, so it carries the doubt too rather than restating the number as bare fact.
     */
    @Test fun implausibleAnnouncedCountIsNotRestatedAsFactInTheVerdict() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 9999))
        report.noteTimeout(118, 8)

        val v = report.verdict
        assertTrue(v, v.contains("an implausible 9999 flag(s)"))
        assertTrue(v, v.contains("(inconclusive)"))
    }
}
