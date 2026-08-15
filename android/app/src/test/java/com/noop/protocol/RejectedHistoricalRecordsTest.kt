package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [rejectedHistoricalRecords] — the genuinely-undecodable type-47 record frames the Backfiller must
 * archive BEFORE acking the trim (#77 / #91). The strap frees acked history, so anything this misses
 * (false negative) is permanently lost; anything it over-counts (false positive) wastes the archive
 * and the honest "could not decode" status.
 *
 * The two hard requirements from the bug: a CONSOLE (type-50) frame decodes to zero rows BY DESIGN
 * and must NOT be flagged, while a real record frame that fails to decode MUST be flagged.
 */
class RejectedHistoricalRecordsTest {

    // Real on-wrist WHOOP 4.0 v24 record (HR 109) — the same hardware frame HistoricalFallbackTest uses.
    private val realV24Hex =
        "aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff00" +
        "85593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03" +
        "640229014009010c020c00000000000f0001c4020000000000008fdeb278"

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    /** Recompute the body CRC32 (over inner bytes frame[4 until length]) and write it LE into the
     *  trailer so a frame mutated in the test still validates. */
    private fun repairCrc32(frame: ByteArray) {
        val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        val crc = Crc.crc32(frame.copyOfRange(4, length))
        frame[length] = (crc and 0xFF).toByte()
        frame[length + 1] = ((crc shr 8) and 0xFF).toByte()
        frame[length + 2] = ((crc shr 16) and 0xFF).toByte()
        frame[length + 3] = ((crc shr 24) and 0xFF).toByte()
    }

    @Test
    fun goodRecordIsNotRejected() {
        // Sanity / control: a record that decodes fine must never be flagged as rejected.
        val good = bytes(realV24Hex)
        assertEquals(emptyList<ByteArray>(), rejectedHistoricalRecords(listOf(good), DeviceFamily.WHOOP4))
    }

    @Test
    fun consoleTypeFrameIsExcluded() {
        // A type-50 (0x32) CONSOLE_LOGS frame: the strap's own diagnostics text. It decodes to zero
        // rows by design and must NOT count as a rejected record (frame[4] = 0x32, not 0x2F/47).
        val console = bytes(realV24Hex)
        console[4] = 0x32             // packet type byte → CONSOLE_LOGS (50)
        repairCrc32(console)         // keep the envelope valid so only the type guard excludes it
        assertEquals(
            "type-50 console frame must not be counted as a lost record",
            emptyList<ByteArray>(),
            rejectedHistoricalRecords(listOf(console), DeviceFamily.WHOOP4),
        )
    }

    @Test
    fun crcFailedRecordIsRejected() {
        // A genuine type-47 record whose body is corrupted so its CRC fails — undecodable, and its
        // bytes would be silently dropped. It MUST be flagged for archiving.
        val bad = bytes(realV24Hex)
        bad[21] = (bad[21].toInt() xor 0xFF).toByte() // flip HR byte, leave the CRC trailer stale → CRC mismatch
        val rejected = rejectedHistoricalRecords(listOf(bad), DeviceFamily.WHOOP4)
        assertEquals(1, rejected.size)
        assertTrue(rejected[0].contentEquals(bad))
    }

    @Test
    fun unmappedNonPhysicalRecordIsRejected() {
        // A CRC-valid type-47 record on an UNMAPPED firmware version whose v24-fallback decode yields
        // non-physical data (gravity zeroed) — the plausibility gate drops it, so it is genuinely lost
        // and must be flagged. Exercises the decode-returns-null branch (not just the CRC branch).
        val bad = bytes(realV24Hex)
        bad[5] = 99.toByte()                  // unmapped version
        for (i in 40 until 52) bad[i] = 0     // zero gravity x/y/z → |g| = 0, fails the gate
        repairCrc32(bad)
        val rejected = rejectedHistoricalRecords(listOf(bad), DeviceFamily.WHOOP4)
        assertEquals(1, rejected.size)
        assertTrue(rejected[0].contentEquals(bad))
    }

    @Test
    fun mixedChunkFlagsOnlyTheUndecodableRecord() {
        // The case the old chunk-level isEmpty check missed: one good row hiding a loss. Only the bad
        // record (not the good one, not the console frame) must be returned.
        val good = bytes(realV24Hex)
        val console = bytes(realV24Hex).also { it[4] = 0x32; repairCrc32(it) }
        val bad = bytes(realV24Hex).also { it[21] = (it[21].toInt() xor 0xFF).toByte() } // CRC now stale → fails
        val rejected = rejectedHistoricalRecords(listOf(good, console, bad), DeviceFamily.WHOOP4)
        assertEquals(1, rejected.size)
        assertTrue(rejected[0].contentEquals(bad))
    }

    @Test
    fun isEmptyRecordFrame_flagsAllZeroPayloadOnly() {
        // A 104 B frame with header + CRC bytes set but the record payload (21..end-4) all zero -> empty.
        val empty = ByteArray(104).also { it[0] = 0xAA.toByte(); it[103] = 0x78 }
        assertTrue(isEmptyRecordFrame(empty))
        // One non-zero byte inside the payload -> not empty.
        assertTrue(!isEmptyRecordFrame(empty.copyOf().also { it[50] = 0x01 }))
        // A runt frame (no room for a payload past header+CRC) is never treated as empty.
        assertTrue(!isEmptyRecordFrame(ByteArray(20)))
    }
}
