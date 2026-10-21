package com.noop.analytics

import com.noop.data.V18AuxRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #112 / #103 — the nightly windowed SpO2 from the 5/MG @82 byte (wearable5.0 FINDINGS §13).
 *
 * Byte-parity twin of the Swift `Spo2CandidateNightlyTests`: same fixtures, same expected values.
 */
class Spo2CandidateNightlyTest {

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun aux(ts: Long, v: Long?) = V18AuxRow(ts = ts, auxByte82 = v)

    private fun window(start: Long, values: List<Int?>) = values.mapIndexed { i, v -> aux(start + i, v?.toLong()) }

    @Test fun oneWindowYieldsItsMedian() {
        val r = AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 3600)), window(1100, listOf(94, 95, 96, 96, 96, 97, 97, 97, 98, 97)))
        assertEquals(97, r?.first)
        assertEquals(10, r?.second)
    }

    @Test fun nightIsTheMeanOfWindowMedians() {
        val a = window(1100, listOf(96, 96, 96, 96, 96)) + window(2300, listOf(99, 99, 99, 99, 99, 99, 99))
        val r = AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 3600)), a)
        assertEquals(98, r?.first)
        assertEquals(12, r?.second)
    }

    @Test fun codesAndThinWindowsDoNotCount() {
        val full = window(1100, listOf(160, 95, 128, 95, 95, 32, 96, 95))
        val thin = window(2300, listOf(78, 160, 128, 16))
        val r = AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 3600)), full + thin)
        assertEquals(95, r?.first)
        assertEquals(5, r?.second)
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 3600)), thin))
    }

    @Test fun gapSplitsWindows() {
        val a = window(1100, listOf(95, 95, 95)) + window(1106, listOf(95, 95, 95))
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 3600)), a))
    }

    @Test fun outsideSessionZeroAndMissingAreSkipped() {
        val a = window(500, listOf(99, 99, 99, 99, 99)) + window(1100, listOf(94, null, 94, 94, 94, 94))
        val r = AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 600)), a)
        assertEquals(94, r?.first)
        assertEquals(5, r?.second)
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(emptyList(), a))
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 600)), emptyList()))
    }

    @Test fun bandBoundariesMatchTheDecoderGate() {
        assertEquals(5, AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), window(1100, listOf(70, 70, 100, 100, 100)))?.second)
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), window(1100, listOf(69, 69, 101, 101, 101))))
    }
}
