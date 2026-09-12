package com.noop.ble

import com.noop.protocol.BackfillCaptureJsonl
import com.noop.protocol.BackfillCaptureRecord
import com.noop.protocol.BackfillCaptureSummary
import com.noop.protocol.Crc
import com.noop.protocol.DeviceFamily
import com.noop.protocol.FrameRejectReason
import com.noop.protocol.Framing
import com.noop.protocol.ParsedFrame
import com.noop.protocol.Reassembler
import com.noop.protocol.wireName
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Scenario "Diagnose behält Parsbarkeit und Ablehnungsgrund", Kotlin side — the twin of the Swift
 * `FrameDiagnosticsTests`.
 *
 * The property under test is the one that goes quiet unnoticed: after the gate widened, a rejected
 * frame must still be COUNTED, must still name WHY, and must still carry the packet type the decoder
 * read out of it. A capture that blanks the type of a corrupted frame throws away exactly the evidence
 * it exists to collect, and a gate that drops frames without a counter reports a clean link.
 *
 * Every fixture is a protocol-correct frame broken in exactly ONE way, and each test asserts up front
 * that the break is the one intended — otherwise a passing test would only prove that unreadable bytes
 * are unreadable.
 */
class FrameRejectDiagnosticsTest {

    // MARK: - frame builders (real checksums, never a placeholder)

    private fun putU32LE(b: ByteArray, off: Int, v: Long) {
        b[off] = (v and 0xFF).toByte()
        b[off + 1] = ((v shr 8) and 0xFF).toByte()
        b[off + 2] = ((v shr 16) and 0xFF).toByte()
        b[off + 3] = ((v shr 24) and 0xFF).toByte()
    }

    private fun le32(v: Long): ByteArray {
        val b = ByteArray(4); putU32LE(b, 0, v); return b
    }

    /** `[0xAA][len u16 LE][crc8(len)][inner…][crc32(inner) u32 LE]`, `len = inner.size + 4`. */
    private fun whoop4Frame(inner: ByteArray): ByteArray {
        val length = inner.size + 4
        val out = ByteArray(inner.size + 8)
        out[0] = 0xAA.toByte()
        out[1] = (length and 0xFF).toByte()
        out[2] = ((length shr 8) and 0xFF).toByte()
        out[3] = Crc.crc8(byteArrayOf(out[1], out[2])).toByte()
        inner.copyInto(out, 4)
        putU32LE(out, length, Crc.crc32(inner))
        return out
    }

    /**
     * A protocol-correct WHOOP 4.0 HISTORY_END (METADATA type 49, meta_type 2) at the 25-byte size a real
     * one has: `meta_type@6`, `unix@7`, `subsec@11`, `unk0@13`, `trim_cursor@17`.
     */
    private fun historyEndFrame(unix: Long = 1_700_000_000L, trim: Long = 70_476L): ByteArray =
        whoop4Frame(byteArrayOf(49, 0, 2) + le32(unix) + byteArrayOf(0, 0) + le32(0) + le32(trim))

    private fun parsed(frame: ByteArray): ParsedFrame = Framing.parseFrame(frame, DeviceFamily.WHOOP4)

    // MARK: - the fixtures break exactly one rule each

    @Test
    fun theFixturesBreakTheRuleTheyClaimTo() {
        assertEquals(25, historyEndFrame().size)
        assertEquals(FrameRejectReason.NONE, parsed(historyEndFrame()).rejectReason)

        val header = historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }
        assertEquals(FrameRejectReason.HEADER_CHECKSUM_MISMATCH, parsed(header).rejectReason)

        val trailing = historyEndFrame() + byteArrayOf(0)
        assertEquals(FrameRejectReason.LENGTH_MISMATCH, parsed(trailing).rejectReason)

        val payload = historyEndFrame().also { it[8] = (it[8].toInt() xor 0xFF).toByte() }
        assertEquals(FrameRejectReason.PAYLOAD_CRC_MISMATCH, parsed(payload).rejectReason)
    }

    // MARK: - parseability is not integrity

    /**
     * The core of the requirement: a REJECTED frame keeps its decoded packet type. Blanking it would cost
     * the capture the one thing the decoder did learn about a frame nobody can otherwise read.
     */
    @Test
    fun aRejectedFrameKeepsItsPacketTypeAndIsStillParsable() {
        val header = historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }
        val p = parsed(header)
        assertFalse("precondition: the verdict is negative", p.ok)
        assertEquals("METADATA", p.typeName)
        assertTrue("a rejected frame is still PARSABLE — a different question from intact", p.isParsable)
        assertTrue(
            "…and it still decoded its inner fields",
            (p.parsed["meta_type"] as String).startsWith("HISTORY_END"),
        )
    }

    /** Only a byte run that produced no type at all is unparsable. */
    @Test
    fun aByteRunWithNoStartOfFrameIsNotParsable() {
        val p = parsed(byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B))
        assertEquals(FrameRejectReason.NO_START_OF_FRAME, p.rejectReason)
        assertEquals(UNPARSABLE_TYPE_NAME, p.typeName)
        assertFalse(p.isParsable)
    }

    // MARK: - the named counter for the class that used to pass

    /**
     * The class the change closes, read as ONE number: the payload CRC32 verified while the envelope did
     * not. No single reason bucket can express that conjunction — the length bucket in particular also
     * collects the harmless resyncs after a lost notification — which is why it is counted separately.
     */
    @Test
    fun theClassThatUsedToPassIsCountedSeparately() {
        val header = historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }
        val p = parsed(header)
        assertEquals("precondition: its payload CRC32 DID verify", true, p.crcOk)
        assertTrue(p.payloadCrcOkButEnvelopeRejected)

        val tally = FrameRejectTally()
        tally.note(p)
        assertEquals(1, tally.payloadCrcOkButEnvelopeRejected)
        assertEquals(1, tally.count(FrameRejectReason.HEADER_CHECKSUM_MISMATCH))
    }

    /** A trailing byte is the same class through a different reason — the conjunction, not the bucket. */
    @Test
    fun aTrailingByteAlsoCountsInTheNamedClass() {
        val p = parsed(historyEndFrame() + byteArrayOf(0))
        assertEquals(FrameRejectReason.LENGTH_MISMATCH, p.rejectReason)
        assertEquals(true, p.crcOk)
        val tally = FrameRejectTally()
        tally.note(p)
        assertEquals(1, tally.payloadCrcOkButEnvelopeRejected)
    }

    /** A broken payload is NOT that class: the envelope is fine, the CRC32 is the thing that disagreed. */
    @Test
    fun aBrokenPayloadIsNotTheNamedClass() {
        val p = parsed(historyEndFrame().also { it[8] = (it[8].toInt() xor 0xFF).toByte() })
        val tally = FrameRejectTally()
        tally.note(p)
        assertEquals(1, tally.count(FrameRejectReason.PAYLOAD_CRC_MISMATCH))
        assertEquals(0, tally.payloadCrcOkButEnvelopeRejected)
    }

    // MARK: - "could not be checked" is not "was wrong"

    /**
     * A truncated frame's CRC32 cannot be computed at all. The tally must not turn that silence into the
     * stronger claim that the checksum disagreed — a diagnostic may only assert what it observed.
     */
    @Test
    fun anUncomputableChecksumIsNeverReportedAsAMismatch() {
        val truncated = historyEndFrame().copyOf(24)
        val p = parsed(truncated)
        assertNull("precondition: there were not enough bytes to check", p.crcOk)
        val tally = FrameRejectTally()
        tally.note(p)
        assertEquals(0, tally.count(FrameRejectReason.PAYLOAD_CRC_MISMATCH))
        assertEquals(1, tally.count(FrameRejectReason.LENGTH_MISMATCH))
        assertFalse("…and it is not the named class either", p.payloadCrcOkButEnvelopeRejected)
    }

    // MARK: - the tally itself

    @Test
    fun intactFramesAreNotCounted() {
        val tally = FrameRejectTally()
        assertEquals(FrameRejectReason.NONE, tally.note(parsed(historyEndFrame())))
        assertEquals(0, tally.totalRejected)
        assertNull("nothing rejected ⇒ no line at all, not a '0 rejections' line", tally.summaryLine())
    }

    /**
     * A byte run dropped INSIDE the reassembler never reaches a parser, so its monotonic count is folded
     * in. The fold takes only the growth since the last call, so a per-notification caller cannot
     * double-count.
     */
    @Test
    fun reassemblerDropsAreFoldedInOnceEach() {
        val reassembler = Reassembler(DeviceFamily.WHOOP4)
        // A declared total of 2 + 4 = 6, below the 11-byte WHOOP 4.0 minimum: dropped, never emitted.
        assertTrue(reassembler.feed(byteArrayOf(0xAA.toByte(), 0x02, 0x00, 0x00, 0x00)).isEmpty())
        assertEquals(1, reassembler.belowMinimumLengthDrops)

        val tally = FrameRejectTally()
        tally.absorbReassemblerDrops(reassembler.belowMinimumLengthDrops)
        tally.absorbReassemblerDrops(reassembler.belowMinimumLengthDrops)   // idempotent
        assertEquals(1, tally.count(FrameRejectReason.BELOW_MINIMUM_LENGTH))

        assertTrue(reassembler.feed(byteArrayOf(0xAA.toByte(), 0x02, 0x00, 0x00, 0x00)).isEmpty())
        tally.absorbReassemblerDrops(reassembler.belowMinimumLengthDrops)
        assertEquals(2, tally.count(FrameRejectReason.BELOW_MINIMUM_LENGTH))
        assertEquals(2, tally.totalRejected)
    }

    /** The readout names every reason that occurred, in the Swift spelling, plus the named class. */
    @Test
    fun theSummaryLineNamesEveryReasonInTheSwiftSpelling() {
        val tally = FrameRejectTally()
        tally.note(parsed(historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }))
        tally.note(parsed(historyEndFrame().also { it[8] = (it[8].toInt() xor 0xFF).toByte() }))
        assertEquals(
            "frameReject total=2 headerChecksumMismatch=1 payloadCRCMismatch=1 " +
                "payloadCRCOKButEnvelopeRejected=1",
            tally.summaryLine(),
        )
    }

    @Test
    fun resetClearsEverything() {
        val tally = FrameRejectTally()
        tally.note(parsed(historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }))
        tally.absorbReassemblerDrops(3)
        tally.reset()
        assertEquals(0, tally.totalRejected)
        assertEquals(0, tally.payloadCrcOkButEnvelopeRejected)
        assertNull(tally.summaryLine())
        // A fold after reset starts from zero again, so the next link's first drop is not swallowed.
        tally.absorbReassemblerDrops(1)
        assertEquals(1, tally.count(FrameRejectReason.BELOW_MINIMUM_LENGTH))
    }

    /** The wire spellings are the Swift `rawValue`s, so two field reports read alike. */
    @Test
    fun everyReasonHasTheSwiftWireSpelling() {
        assertEquals(
            listOf(
                "none", "noStartOfFrame", "belowMinimumLength", "lengthMismatch",
                "headerChecksumMismatch", "payloadCRCMismatch", "payloadCRCUnverifiable",
            ),
            FrameRejectReason.entries.map { it.wireName },
        )
    }

    // MARK: - the capture export

    /**
     * The capture record keeps the packet type of a rejected frame AND gains the reason. Additive: every
     * key the old format carried is still there, in the same place.
     */
    @Test
    fun theCaptureRecordKeepsTheTypeAndAddsTheReason() {
        val p = parsed(historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() })
        val line = BackfillCaptureJsonl.encode(
            BackfillCaptureRecord(
                capturedAtMs = 1L, sessionId = "s", characteristic = "c",
                typeName = p.typeName, crcOk = p.crcOk, offload = false, size = 25,
                parsed = emptyMap(), hex = "aa", rejectReason = p.rejectReason,
            ),
        )
        assertTrue("the packet type survives the rejection", line.contains("\"type_name\":\"METADATA\""))
        assertTrue(line.contains("\"reject_reason\":\"headerChecksumMismatch\""))
        assertTrue("…and the old keys are untouched", line.contains("\"crc_ok\":true"))
    }

    /**
     * An INTACT frame's line is byte-identical to the previous format: no reason, no key. That is what
     * makes the field additive rather than a format change — every pinned golden line and every existing
     * reader keeps working, and "key absent ⇒ none" is exactly what the Swift decoder does with it.
     */
    @Test
    fun anIntactFrameAddsNoKeyAtAll() {
        val line = BackfillCaptureJsonl.encode(
            BackfillCaptureRecord(
                capturedAtMs = 1L, sessionId = "s", characteristic = "c", typeName = "EVENT",
                crcOk = true, offload = false, size = 11, parsed = emptyMap(), hex = "aa",
            ),
        )
        assertFalse(line.contains("reject_reason"))
        assertTrue("…and the record still ends where it did", line.endsWith("\"hex\":\"aa\"}"))
    }

    /**
     * The unknown-type samples are what a mapper reads first, and "an unmappable type" and "a corrupted
     * copy of a type we know" are indistinguishable from the hex alone.
     */
    @Test
    fun theCaptureSummarySampleNamesTheReason() {
        val summary = BackfillCaptureSummary()
        summary.record("type99", false, 30, "fd4b0003", "aabb", FrameRejectReason.PAYLOAD_CRC_MISMATCH)
        val text = summary.unknownSamplesText()
        assertTrue(text.contains("type99"))
        assertTrue(text.contains("reject=payloadCRCMismatch"))
        assertEquals("type99=1", summary.countsText())
    }
}
