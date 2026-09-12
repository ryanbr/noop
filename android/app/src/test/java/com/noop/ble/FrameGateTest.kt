package com.noop.ble

import com.noop.protocol.Crc
import com.noop.protocol.DeviceFamily
import com.noop.protocol.FrameRejectReason
import com.noop.protocol.Framing
import com.noop.protocol.HistoricalMeta
import com.noop.protocol.classifyHistoricalMeta
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Scenario "Zustandstreibende Tore fordern das volle Urteil", Kotlin side — the app-layer half that
 * `com.noop.protocol.FrameIntegrityTest` cannot cover, plus the ONE exemption from the payload bound.
 *
 * Every fixture is a protocol-correct HISTORY_END at the 25-byte size a real one has, broken in exactly
 * ONE way, and each test asserts up front that the frame still DECODES as a HISTORY_END. Without that
 * precondition a passing test would only prove that unreadable bytes are unreadable.
 */
class FrameGateTest {

    private fun putU32LE(b: ByteArray, off: Int, v: Long) {
        b[off] = (v and 0xFF).toByte()
        b[off + 1] = ((v shr 8) and 0xFF).toByte()
        b[off + 2] = ((v shr 16) and 0xFF).toByte()
        b[off + 3] = ((v shr 24) and 0xFF).toByte()
    }

    private fun le32(v: Long): ByteArray {
        val b = ByteArray(4); putU32LE(b, 0, v); return b
    }

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

    /** A protocol-correct WHOOP 4.0 HISTORY_END (METADATA 49, meta_type 2) carrying unix + trim cursor. */
    private fun historyEndFrame(unix: Long = 1_700_000_000L, trim: Long = 70_476L): ByteArray =
        whoop4Frame(byteArrayOf(49, 0, 2) + le32(unix) + byteArrayOf(0, 0) + le32(0) + le32(trim))

    private fun stillDecodesAsHistoryEnd(frame: ByteArray) {
        val p = Framing.parseFrame(frame, DeviceFamily.WHOOP4)
        assertEquals("precondition: it still decodes as METADATA", "METADATA", p.typeName)
        assertTrue(
            "precondition: it still decodes as a HISTORY_END",
            (p.parsed["meta_type"] as String).startsWith("HISTORY_END"),
        )
    }

    // MARK: - the history-metadata classifier (3b.4: the offload drain against the changed classification)

    /** Control: an intact HISTORY_END still closes a chunk and still yields its trim cursor. */
    @Test
    fun anIntactHistoryEndStillClassifiesAsAnEnd() {
        val meta = classifyHistoricalMeta(Framing.parseFrame(historyEndFrame(), DeviceFamily.WHOOP4))
        assertTrue(meta is HistoricalMeta.End)
        assertEquals(70_476L, (meta as HistoricalMeta.End).trim)
    }

    /**
     * A HISTORY_END with a broken header checksum must NOT advance the trim. The stake is the whole
     * change: an END the app acts on acknowledges the strap, which frees the records it just sent.
     */
    @Test
    fun aHistoryEndWithABrokenHeaderChecksumClassifiesAsNothing() {
        val frame = historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }
        stillDecodesAsHistoryEnd(frame)
        val p = Framing.parseFrame(frame, DeviceFamily.WHOOP4)
        assertEquals(FrameRejectReason.HEADER_CHECKSUM_MISMATCH, p.rejectReason)
        assertEquals(HistoricalMeta.Other, classifyHistoricalMeta(p))
    }

    /** The same for trailing bytes and for a cut-off CRC32 trailer: both are envelope damage. */
    @Test
    fun aHistoryEndWithTrailingOrMissingBytesClassifiesAsNothing() {
        val trailing = historyEndFrame() + byteArrayOf(0)
        stillDecodesAsHistoryEnd(trailing)
        assertEquals(
            HistoricalMeta.Other,
            classifyHistoricalMeta(Framing.parseFrame(trailing, DeviceFamily.WHOOP4)),
        )

        val truncated = historyEndFrame().copyOf(24)
        stillDecodesAsHistoryEnd(truncated)
        assertEquals(
            HistoricalMeta.Other,
            classifyHistoricalMeta(Framing.parseFrame(truncated, DeviceFamily.WHOOP4)),
        )
    }

    /**
     * A rejected END falls into the SAME classification bucket a plain record does, so the offload keeps
     * accumulating it into the open chunk rather than dropping it — the evidence-preserving direction
     * (D8). What it must not do is close the chunk or acknowledge.
     */
    @Test
    fun aRejectedEndIsAccumulatedRatherThanActedOn() {
        val frame = historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }
        val meta = classifyHistoricalMeta(Framing.parseFrame(frame, DeviceFamily.WHOOP4))
        assertFalse("it must not close a chunk", meta is HistoricalMeta.End)
        assertFalse("nor end the session", meta is HistoricalMeta.Complete)
        assertEquals(HistoricalMeta.Other, meta)
    }

    // MARK: - the acknowledgement block is EXEMPT from the payload bound (D7, decision 4)

    /**
     * The eight bytes the trim acknowledgement mirrors back to the strap reach INTO the CRC32 trailer by
     * design: on the real 25-byte HISTORY_END the trailer starts at 21 and the block runs 17…25. It is an
     * opaque echo, not a decoded field, so the payload bound that now clamps every named field must not
     * touch it.
     *
     * Clamped to the trailer it would yield four bytes, and the strap would be acknowledged with a block
     * it never sent — either it refuses the acknowledgement and the offload stops, or it trims on an
     * altered block. Both are the permanent data loss this whole change exists to prevent, arriving
     * through the fix rather than the bug. Twin of the Swift `BackfillMetaForgeryTests` pair.
     */
    @Test
    fun theWhoop4AcknowledgementBlockIsEightBytesAndReachesIntoTheTrailer() {
        val frame = historyEndFrame()
        assertEquals("precondition: the real HISTORY_END size the exemption is about", 25, frame.size)
        val declared = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        assertEquals("precondition: the CRC32 trailer starts at 21", 21, declared)

        val endData = Backfiller.endData(frame, DeviceFamily.WHOOP4)
        assertEquals("eight bytes, not the four a trailer clamp would leave", 8, endData?.size)
        assertArrayEquals(
            "…and exactly the bytes at 17…25, unaltered",
            frame.copyOfRange(17, 25), endData,
        )
        assertNotEquals(
            "a clamped-then-padded block is not the same echo",
            (frame.copyOfRange(17, 21) + ByteArray(4)).toList(), endData!!.toList(),
        )
    }

    /** The 5/MG twin of the same slice, so a later tidy-up cannot narrow one family and not the other. */
    @Test
    fun theWhoop5AcknowledgementBlockIsAlsoEightBytes() {
        val frame = ByteArray(30) { (it + 1).toByte() }
        val endData = Backfiller.endData(frame, DeviceFamily.WHOOP5)
        assertEquals(8, endData?.size)
        assertArrayEquals(frame.copyOfRange(21, 29), endData)
    }

    /**
     * The guard the exemption does keep: a frame too short to hold the block yields null rather than a
     * short read. Not-enough-bytes is a different answer from four-bytes-because-we-clamped.
     */
    @Test
    fun aFrameTooShortForTheBlockYieldsNullRatherThanAShortRead() {
        assertNull(Backfiller.endData(whoop4Frame(byteArrayOf(49, 0, 2)), DeviceFamily.WHOOP4))
    }

    // MARK: - the unbonded-offload probe (3b.3)

    /** Control: an intact COMMAND_RESPONSE is still the strongest evidence the probe can collect. */
    @Test
    fun anIntactCommandResponseIsStillProof() {
        assertEquals(
            UnbondedProbeEvidence.ANSWERS_COMMANDS,
            unbondedProbeEvidenceOf(ok = true, crcOk = true, typeName = "COMMAND_RESPONSE"),
        )
        assertEquals(
            UnbondedProbeEvidence.SERVES_NOTIFICATIONS,
            unbondedProbeEvidenceOf(ok = true, crcOk = true, typeName = "REALTIME_DATA"),
        )
    }

    /**
     * The changed evidence effect, pinned. Before the verdict widened, `ok` meant only "the envelope was
     * well-formed", so a frame with a broken header checksum but a verifying payload CRC32 satisfied both
     * conditions and counted as proof that the strap serves this link unbonded. It no longer does — and
     * that is the direction the probe wants, because its output is a claim about the STRAP, while that
     * frame class is exactly what a confused or foreign transmitter on a shared channel produces.
     */
    @Test
    fun aFrameWithAVerifyingPayloadButABrokenEnvelopeIsNoLongerProof() {
        val frame = historyEndFrame().also { it[3] = (it[3].toInt() xor 0xFF).toByte() }
        val p = Framing.parseFrame(frame, DeviceFamily.WHOOP4)
        assertEquals("precondition: its payload CRC32 verifies", true, p.crcOk)
        assertFalse("precondition: but the full verdict is negative", p.ok)
        assertEquals(
            UnbondedProbeEvidence.NONE,
            unbondedProbeEvidenceOf(ok = p.ok, crcOk = p.crcOk, typeName = p.typeName),
        )
    }

    /** An unverifiable CRC32 was never a pass and still is not. */
    @Test
    fun anUnverifiableChecksumIsNotProof() {
        assertEquals(
            UnbondedProbeEvidence.NONE,
            unbondedProbeEvidenceOf(ok = true, crcOk = null, typeName = "COMMAND_RESPONSE"),
        )
    }

    // MARK: - the live-realtime filter

    /**
     * The batch anchor the live path stamps every HR sample against comes from the NEWEST realtime frame,
     * so a frame admitted here misdates a whole batch. The filter used to read `ok && crcOk != false`,
     * whose second half passed a frame whose CRC32 could not be computed at all; `ok` alone is now the
     * stronger statement. Pinned on the predicate the client applies, so a later edit that loosens it
     * back to the tri-state fails here.
     */
    @Test
    fun onlyIntactRealtimeFramesCanAnchorALiveBatch() {
        val realtime = whoop4Frame(byteArrayOf(40, 0, 0) + le32(1_700_000_000L) + byteArrayOf(0, 61, 0))
        val intact = Framing.parseFrame(realtime, DeviceFamily.WHOOP4)
        assertEquals("precondition: it decodes as live data", "REALTIME_DATA", intact.typeName)
        assertTrue(intact.ok && intact.typeName == "REALTIME_DATA")

        val broken = Framing.parseFrame(
            realtime.copyOf().also { it[3] = (it[3].toInt() xor 0xFF).toByte() },
            DeviceFamily.WHOOP4,
        )
        assertEquals("precondition: still a decoded live frame", "REALTIME_DATA", broken.typeName)
        assertEquals("precondition: and its payload CRC32 verifies", true, broken.crcOk)
        assertFalse("the widened verdict is what excludes it", broken.ok && broken.typeName == "REALTIME_DATA")
    }
}
