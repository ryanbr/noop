package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EcgResearchStatsTest {

    private fun rec(ms: Long, ch: String, payload: ByteArray, type: Int? = null, recognized: Boolean = true) =
        EcgResearchStats.RxRecord(ms, ch, payload, type, recognized)

    @Test
    fun zeroByteFractionCountsZerosInWindow() {
        val p = byteArrayOf(0, 0, 1, 2, 0, 0)
        assertEquals(4.0 / 6.0, EcgResearchStats.zeroByteFraction(p), 1e-9)
        assertEquals(1.0, EcgResearchStats.zeroByteFraction(byteArrayOf(0, 0, 0)), 1e-9)
        assertEquals(0.0, EcgResearchStats.zeroByteFraction(byteArrayOf(1, 2, 3)), 1e-9)
        // windowed
        assertEquals(1.0, EcgResearchStats.zeroByteFraction(p, 0, 2), 1e-9)
        assertEquals(0.0, EcgResearchStats.zeroByteFraction(p, 2, 4), 1e-9)
        // empty / out of range
        assertEquals(0.0, EcgResearchStats.zeroByteFraction(ByteArray(0)), 1e-9)
    }

    @Test
    fun isAllZeroDetectsEmptyRegions() {
        assertTrue(EcgResearchStats.isAllZero(ByteArray(1584)))
        assertTrue(EcgResearchStats.isAllZero(byteArrayOf(1, 0, 0, 0, 2), 1, 4))
        assertFalse(EcgResearchStats.isAllZero(byteArrayOf(0, 0, 1)))
        // an empty window is not "all zero"
        assertFalse(EcgResearchStats.isAllZero(ByteArray(0)))
    }

    @Test
    fun changingBytePositionsFindsCounterLikeFields() {
        val a = byteArrayOf(0x10, 0x00, 0x05, 0x00)
        val b = byteArrayOf(0x11, 0x00, 0x05, 0x00)   // only byte 0 moved
        assertEquals(listOf(0), EcgResearchStats.changingBytePositions(a, b))

        val c = byteArrayOf(0x12, 0x00, 0x06, 0x00)   // bytes 0 and 2 moved vs b
        assertEquals(listOf(0, 2), EcgResearchStats.changingPositionsAcross(listOf(a, b, c)))
    }

    @Test
    fun packetsPerSecondByCharacteristic() {
        // char "0003": 3 packets across 2000ms span => 1.5/s. char "0005": single packet => raw count 1.
        val records = listOf(
            rec(0, "0003", ByteArray(20)),
            rec(1000, "0003", ByteArray(20)),
            rec(2000, "0003", ByteArray(20)),
            rec(500, "0005", ByteArray(8)),
        )
        val pps = EcgResearchStats.packetsPerSecondByCharacteristic(records)
        assertEquals(1.5, pps["0003"]!!, 1e-9)
        assertEquals(1.0, pps["0005"]!!, 1e-9)
    }

    @Test
    fun payloadSizeHistogramAndLargestAndRepeatedRecordCount() {
        val records = listOf(
            rec(0, "a", ByteArray(1584)),
            rec(1, "a", ByteArray(1584)),
            rec(2, "a", ByteArray(1584)),
            rec(3, "a", ByteArray(20)),
        )
        assertEquals(mapOf(20 to 1, 1584 to 3), EcgResearchStats.payloadSizeHistogram(records))
        assertEquals(listOf(1584, 20), EcgResearchStats.largestPayloadSizes(records))
        assertEquals(3, EcgResearchStats.countOfSize(records, 1584))
    }

    @Test
    fun packetTypeCountsAndUnrecognized() {
        val records = listOf(
            rec(0, "a", ByteArray(4), type = 40, recognized = true),
            rec(1, "a", ByteArray(4), type = 40, recognized = true),
            rec(2, "a", ByteArray(4), type = null, recognized = false),
        )
        assertEquals(2, EcgResearchStats.packetTypeCounts(records)[40])
        assertEquals(1, EcgResearchStats.packetTypeCounts(records)[null])
        assertEquals(1, EcgResearchStats.unrecognizedCount(records))
    }

    @Test
    fun typeDeltaAroundAStartBoundary() {
        val records = listOf(
            rec(0, "a", ByteArray(4), type = 40),      // before
            rec(100, "a", ByteArray(4), type = 40),    // before
            rec(200, "a", ByteArray(4), type = 40),    // after (still 40)
            rec(250, "a", ByteArray(1584), type = 41), // after only — candidate "appeared after Start"
        )
        val delta = EcgResearchStats.typeDeltaAround(records, afterMs = 150)
        assertEquals(listOf<Int?>(41), delta.appearedAfter)
        assertTrue(delta.disappearedAfter.isEmpty())
    }

    @Test
    fun estimateBpmFindsAKnownRateAndRejectsNoise() {
        // Synthetic 72 bpm at 100 Hz over 6 s: period = 100*60/72 ≈ 83.3 samples.
        val fs = 100
        val n = fs * 6
        val periodSamples = 60.0 * fs / 72.0
        val beat = IntArray(n) { (1000 * Math.sin(2 * Math.PI * it / periodSamples)).toInt() }
        val bpm = EcgResearchStats.estimateBpm(beat, fs, excludeLag = null)
        assertNotNull(bpm)
        assertTrue("expected ~72, got $bpm", bpm!! in 68..76)

        // Flat/near-zero -> no confident rhythm -> null (never a fabricated number).
        assertNull(EcgResearchStats.estimateBpm(IntArray(fs * 3) { 0 }, fs, excludeLag = null))
        // Too short -> null.
        assertNull(EcgResearchStats.estimateBpm(IntArray(fs / 2) { it }, fs, excludeLag = null))
    }

    @Test
    fun maxZeroFractionOfLargeRecords() {
        val records = listOf(
            rec(0, "a", ByteArray(1584)),               // all zero, big
            rec(1, "a", byteArrayOf(1, 2, 3)),          // small — ignored by minSize
        )
        assertEquals(1.0, EcgResearchStats.maxZeroFractionOfLargeRecords(records, 64)!!, 1e-9)
        assertNull(EcgResearchStats.maxZeroFractionOfLargeRecords(listOf(rec(0, "a", ByteArray(4))), 64))
    }
}
