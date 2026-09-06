package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Tests the closed-window binning of RecoveryScorer.restingHR and RecoveryScorer.recoveryIndexSlope
 * Both prefilter ts ∈ [start, end] but binned as [t, t+300) up to `end`, so a sample sitting
 * exactly on an ALIGNED end was admitted and then belonged to no bin. The final bin now closes on
 * `end`.
 *
 * Parity: the expected values are the verbatim stdout of the standalone Swift oracle built from the
 * fixed Swift source (CLAUDE.md's byte-identical-by-oracle rule), not values read off this Kotlin
 * implementation. RecoveryScorerTests.swift pins the same scenarios on the Swift side.
 */
class RecoveryScorerWindowEndpointTest {

    private val dev = "test"

    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)

    @Test
    fun alignedEndpointSampleReachesABin() {
        // The minimal case: start = 0, end = 300 (exactly one bin wide), five samples on
        // the endpoint. This already returned 60 before the fix, but only because NO bin held
        // anything and the all-sample fallback stepped in; it now flows through the bin path.
        val samples = (0 until 5).map { hr(300L, 60) }
        assertEquals(
            "a sample exactly on an aligned end must belong to the final bin",
            60, RecoveryScorer.restingHR(samples, 0L, 300L)
        )
    }

    @Test
    fun nonAlignedEndpointSampleReachesABin() {
        // Paired non-aligned case: end = 450 falls mid-bin, so the endpoint sample was always
        // inside the trailing partial bin. Same answer, before and after the fix.
        val samples = (0 until 5).map { hr(450L, 60) }
        assertEquals(
            "a sample on a non-aligned end stays in the trailing partial bin",
            60, RecoveryScorer.restingHR(samples, 0L, 450L)
        )
    }

    @Test
    fun endpointSampleLandsInFinalBinOnly() {
        // The endpoint must join the LAST bin, not leak into earlier ones: a dense 70 bpm first bin
        // plus five endpoint beats at 40 gives a floor of 40, while the 70 bpm bin is untouched.
        // Before the fix the endpoint beats vanished and the floor read 70.
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 70))
        for (i in 0 until 5) samples.add(hr(600L, 40))
        assertEquals(
            "the endpoint sample belongs to the final bin only",
            40, RecoveryScorer.restingHR(samples, 0L, 600L)
        )
    }

    @Test
    fun degenerateZeroLengthWindow() {
        // start == end: the single instant is one closed bin, and its mean is the same number the
        // all-sample fallback produced before.
        val samples = (0 until 5).map { hr(1000L, 58) }
        assertEquals(58, RecoveryScorer.restingHR(samples, 1000L, 1000L))
    }

    @Test
    fun restingHrEndpointSweepMatchesSwiftOracle() {
        // `end` walks a whole bin width and beyond, in 25 s steps, against a dense 70 bpm opening
        // bin plus five endpoint beats at 60. Verbatim Swift oracle stdout — this is the check that
        // catches drift the eye does not, including the aligned end = 300 case where the single
        // closed bin holds BOTH groups (mean 69.8 → 70).
        val expected = listOf(
            62, 68, 69, 69, 70, 70, 70, 70, 70, 70, 70, 70, 70,
            60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60,
            60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60
        )
        var i = 0
        var endTs = 0L
        while (endTs <= 900L) {
            val samples = ArrayList<HrSample>()
            for (s in 0 until 300) samples.add(hr(s.toLong(), 70))
            for (s in 0 until 5) samples.add(hr(endTs, 60))
            assertEquals(
                "restingHR.end=$endTs", expected[i], RecoveryScorer.restingHR(samples, 0L, endTs)
            )
            i++
            endTs += 25L
        }
    }

    @Test
    fun restingHrNullWithoutSamples() {
        assertNull(RecoveryScorer.restingHR(emptyList(), 0L, 1000L))
    }

    @Test
    fun recoveryIndexSlopeAlignedEndpointCompletesTheBinGate() {
        // The bin-gate case: six samples over an aligned 30-minute window, the last exactly
        // on `end`. Dropping it left five bins — one short of recoveryIndexMinBins — so the gate
        // turned a complete window into null.
        val samples = listOf(
            hr(0L, 66), hr(300L, 64), hr(600L, 62), hr(900L, 60), hr(1200L, 58), hr(1800L, 54)
        )
        val slope = RecoveryScorer.recoveryIndexSlope(samples, 0L, 1800L)
        assertNotNull("an admitted endpoint sample must count toward the bin gate", slope)
        assertEquals(-27.428571428571423, slope!!, 1e-9)
    }

    @Test
    fun recoveryIndexSlopeStillNullWithOnlyFiveBins() {
        // The gate itself is unchanged: the same window without the endpoint sample has five bins
        // and must stay null. Closing the final bin adds no bin where there is no sample.
        val samples = listOf(hr(0L, 66), hr(300L, 64), hr(600L, 62), hr(900L, 60), hr(1200L, 58))
        assertNull(RecoveryScorer.recoveryIndexSlope(samples, 0L, 1800L))
    }

    @Test
    fun recoveryIndexSlopeNonAlignedEndpointCompletesTheBinGate() {
        // Paired non-aligned case: end = 1750 sits mid-bin, so the endpoint sample was already in
        // the trailing partial bin. Same slope as the aligned case (identical bin midpoints).
        val samples = listOf(
            hr(0L, 66), hr(300L, 64), hr(600L, 62), hr(900L, 60), hr(1200L, 58), hr(1750L, 54)
        )
        val slope = RecoveryScorer.recoveryIndexSlope(samples, 0L, 1750L)
        assertNotNull(slope)
        assertEquals(-27.428571428571423, slope!!, 1e-9)
    }

    @Test
    fun recoveryIndexSlopeFullNightUnchanged() {
        // A full 6 h night has no sample on `end`, so the endpoint rule must not move it: the
        // oracle's slope for a −2 bpm/hour synthetic night, to the last digit.
        val samples = ArrayList<HrSample>()
        var s = 0L
        while (s < 6 * 3600L) {
            samples.add(hr(s, Math.round(62.0 - 2.0 * s.toDouble() / 3600.0).toInt()))
            s += 30L
        }
        val slope = RecoveryScorer.recoveryIndexSlope(samples, 0L, 6 * 3600L)
        assertNotNull(slope)
        assertEquals(-2.0071001350569166, slope!!, 1e-9)
    }
}
