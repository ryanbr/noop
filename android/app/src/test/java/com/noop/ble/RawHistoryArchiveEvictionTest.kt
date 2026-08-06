package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #344: per-version retention floor for the reject archive. Before this fix a full archive simply
 * stopped accepting frames, so a rare never-seen layout version (WHOOP 4 v19, WHOOP 5 v20/v21)
 * arriving when the archive was full of the common version was lost — the exact frames the archive
 * exists to study. The fix gives every distinct hist_version a retention FLOOR: when over cap we evict
 * oldest surplus from the most-populous versions first, never below `perVersionFloor` newest lines of
 * any version, so the rare version always survives. These exercise the PURE [RawHistoryArchive.evictLines]
 * core (no Context, JVM-runnable) and mirror the macOS RawHistoryArchiveEvictionTests.
 */
class RawHistoryArchiveEvictionTest {

    /** A JSONL line whose stored frame has type@4 = 0x2F (47) and hist_version@5 = [version]. */
    private fun jsonl(version: Int, family: String = "whoop4", filler: String = "00"): String {
        val hex = "aa0100002f" + "%02x".format(version) + filler
        return """{"capturedAtMs":1,"trim":1,"family":"$family","frameHex":"$hex"}""" + "\n"
    }

    @Test fun keepsRareVersionUnderAFloodOfCommonFrames() {
        // Two rare v19 lines land FIRST (oldest), then a flood of the common v18 version.
        val lines = ArrayList<String>()
        lines.add(jsonl(19, filler = "a1"))
        lines.add(jsonl(19, filler = "b2"))
        for (i in 0 until 400) lines.add(jsonl(18, filler = "%02x".format(i and 0xFF)))

        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 4_096, floor = 2)

        val bytes = kept.sumOf { it.toByteArray(Charsets.UTF_8).size }
        assertTrue("eviction must bring the archive within the cap", bytes <= 4_096)
        assertTrue("rare v19 #1 must survive", kept.any { it.contains("2f13a1") })  // 0x13 = 19
        assertTrue("rare v19 #2 must survive", kept.any { it.contains("2f13b2") })
        assertTrue("common v18 still represented", kept.any { it.contains("2f12") })  // 0x12 = 18
    }

    @Test fun eachDistinctVersionGetsItsOwnFloor() {
        val lines = ArrayList<String>()
        lines.add(jsonl(19))   // rare
        lines.add(jsonl(21))   // rare
        for (i in 0 until 400) lines.add(jsonl(18, filler = "%02x".format(i and 0xFF)))

        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 6_144, floor = 2)
        assertTrue("v19 must keep its floor", kept.any { it.contains("2f13") })  // 0x13 = 19
        assertTrue("v21 must keep its floor", kept.any { it.contains("2f15") })  // 0x15 = 21
    }

    @Test fun noOpUnderCap() {
        val lines = (0 until 10).map { jsonl(18, filler = "%02x".format(it)) }
        assertEquals(lines, RawHistoryArchive.evictLines(lines, maxBytes = 1_000_000, floor = 2))
    }

    // MARK: - zero-payload frames lose retention priority

    /**
     * A synthetic WHOOP 5/MG type-47 record: a non-zero 21-byte header (type @8 = 47, hist_version @9),
     * then [payloadBytes] of payload, then a 4-byte CRC trailer.
     *
     * [payloadByte] = 0 reproduces the measured empty record — a 5/MG banks one per second with every
     * byte from offset 21 to the CRC trailer zero. [marker] writes a single distinguishing byte into the
     * payload, which is also what makes a frame informative.
     */
    private fun whoop5Frame(
        version: Int,
        payloadByte: Int,
        payloadBytes: Int = 64,
        marker: Int? = null,
    ): ByteArray {
        val f = ByteArray(21) { 0x11 }                 // non-zero header (seq/ts/const bytes)
        f[0] = 0xAA.toByte(); f[8] = 47; f[9] = version.toByte()
        val payload = ByteArray(payloadBytes) { payloadByte.toByte() }
        if (marker != null) payload[0] = marker.toByte()
        return f + payload + byteArrayOf(0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte())
    }

    /** One archived JSONL line for [frame], in the exact shape `append` writes. */
    private fun archiveLine(frame: ByteArray, family: String = "whoop5"): String {
        val hex = frame.joinToString("") { "%02x".format(it) }
        return """{"capturedAtMs":1,"trim":1,"family":"$family","frameHex":"$hex"}""" + "\n"
    }

    /** The strict test: entirely-zero payload region -> yes; ONE non-zero byte anywhere -> no. */
    @Test fun zeroPayloadDetectionIsStrictAndHeaderAware() {
        val empty = whoop5Frame(22, payloadByte = 0)
        assertTrue(
            "the header and CRC bytes are non-zero but the PAYLOAD region is all zero",
            RawHistoryArchive.hasZeroPayload(empty, com.noop.protocol.DeviceFamily.WHOOP5),
        )
        // A single populated byte in an otherwise-empty buffer is exactly what this archive is for.
        val oneByte = empty.copyOf().also { it[21 + 40] = 1 }
        assertFalse(
            "'mostly zero' must NOT count as empty — one non-zero byte makes it informative",
            RawHistoryArchive.hasZeroPayload(oneByte, com.noop.protocol.DeviceFamily.WHOOP5),
        )
        // The last payload byte, immediately before the CRC trailer, is inside the region.
        val lastByte = empty.copyOf().also { it[it.size - 5] = 1 }
        assertFalse(RawHistoryArchive.hasZeroPayload(lastByte, com.noop.protocol.DeviceFamily.WHOOP5))
        // A payload region too short to judge is never called empty.
        assertFalse(RawHistoryArchive.hasZeroPayload(
            whoop5Frame(22, payloadByte = 0, payloadBytes = 8), com.noop.protocol.DeviceFamily.WHOOP5))
        assertFalse(RawHistoryArchive.hasZeroPayload(
            byteArrayOf(0xAA.toByte(), 1), com.noop.protocol.DeviceFamily.WHOOP5))
        // The header length is family-aware: the puffin envelope is 4 bytes longer.
        assertEquals(21, RawHistoryArchive.payloadStart(com.noop.protocol.DeviceFamily.WHOOP5))
        assertEquals(17, RawHistoryArchive.payloadStart(com.noop.protocol.DeviceFamily.WHOOP4))
    }

    /**
     * THE DEFECT. A 5/MG has been measured banking one all-zero record per second, so a purely
     * age-ordered archive evicts everything informative within ~21 minutes. An informative frame must
     * outrank an all-zero one of the SAME layout version, even when it is the OLDEST line in the file and
     * the empties are the newest — so no floor can be what saves it.
     */
    @Test fun evictLinesEvictsZeroPayloadBeforeInformative() {
        val informative = archiveLine(whoop5Frame(22, payloadByte = 0, marker = 0xE7))
        val lines = ArrayList<String>()
        lines.add(informative)
        repeat(200) { lines.add(archiveLine(whoop5Frame(22, payloadByte = 0))) }

        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 4_096, floor = 2, zeroFloor = 2)
        assertTrue(kept.sumOf { it.toByteArray(Charsets.UTF_8).size } <= 4_096)
        assertTrue(
            "the one informative line must survive a flood of all-zero-payload lines",
            kept.contains(informative),
        )
        assertTrue("the zero-payload surplus must actually have been evicted", kept.size < 200)
    }

    /**
     * A version whose records are ALL empty still keeps [zeroFloor] dated samples — enough to prove the
     * artefact exists without letting it own the archive.
     */
    @Test fun allZeroVersionKeepsItsSmallFloor() {
        val lines = ArrayList<String>()
        repeat(200) { lines.add(archiveLine(whoop5Frame(22, payloadByte = 0))) }
        repeat(200) { i -> lines.add(archiveLine(whoop5Frame(18, payloadByte = 0, marker = (i and 0xFF).coerceAtLeast(1)))) }

        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 4_096, floor = 2, zeroFloor = 2)
        val keptZeroVersion = kept.count { it.contains("2f16") }   // 0x2f = type 47, 0x16 = v22
        assertTrue(
            "an all-empty version must keep its small floor, not vanish (kept $keptZeroVersion)",
            keptZeroVersion >= 2,
        )
    }

    /** The eviction target is a low-water mark below the cap, not the cap itself — see LOW_WATER_DIVISOR. */
    @Test fun evictionLeavesHeadroomSoAOneHzStreamDoesNotRewriteEveryRecord() {
        val lines = (0 until 400).map { jsonl(18, filler = "%02x".format(it and 0xFF)) }
        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 4_096, floor = 2)
        val bytes = kept.sumOf { it.toByteArray(Charsets.UTF_8).size }
        assertTrue("must fit the cap", bytes <= 4_096)
        assertTrue(
            "must evict PAST the cap to 7/8 of it, or every subsequent batch rewrites the whole file",
            bytes <= 4_096 - 4_096 / RawHistoryArchive.LOW_WATER_DIVISOR,
        )
    }

    /** The shipped floors are the documented ones, and the zero floor is far smaller than the real one. */
    @Test fun shippedFloors() {
        assertEquals(64, RawHistoryArchive.PER_VERSION_FLOOR)
        assertEquals(8, RawHistoryArchive.ZERO_PAYLOAD_FLOOR)
        assertTrue(RawHistoryArchive.ZERO_PAYLOAD_FLOOR < RawHistoryArchive.PER_VERSION_FLOOR)
        assertEquals(5L * 1024 * 1024, RawHistoryArchive.REJECTED_ARCHIVE_MAX_BYTES)
    }

    @Test fun versionByteReadsTheRightIndexPerFamily() {
        // WHOOP 4 = frame[5]; WHOOP 5 = frame[9] (puffin envelope 4 B longer).
        val w4 = byteArrayOf(0xAA.toByte(), 1, 0, 0, 47, 19, 0, 0)
        assertEquals(19, RawHistoryArchive.versionByte(w4, com.noop.protocol.DeviceFamily.WHOOP4))
        val w5 = byteArrayOf(0xAA.toByte(), 1, 0, 0, 0, 0, 0, 0, 47, 20, 0)
        assertEquals(20, RawHistoryArchive.versionByte(w5, com.noop.protocol.DeviceFamily.WHOOP5))
        // Too short → sentinel bucket, never crashes.
        assertEquals(-1, RawHistoryArchive.versionByte(byteArrayOf(0xAA.toByte(), 1), com.noop.protocol.DeviceFamily.WHOOP4))
    }
}
