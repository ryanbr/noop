package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Tests the closed-window binning of the SHIPPED per-session HR/HRV path,
 * SleepStager.sessionRestingHR and SleepStager.sessionHrvWindows.
 *
 * Both prefilter ts ∈ [start, end] but binned as [t, t+300) with a loop stopping at `end`, so a
 * sample sitting exactly on an ALIGNED end was admitted and then belonged to no window. The final
 * bin now closes on `end` — the same rule RecoveryScorer already carries. Each case is paired with
 * a non-aligned twin that was always correct.
 *
 * Parity: the expected values are the verbatim stdout of a standalone Swift oracle built from the
 * fixed Swift binning (CLAUDE.md's byte-identical-by-oracle rule), not values read off this Kotlin
 * implementation. SleepStagerTests.swift pins the same scenarios on the Swift side.
 */
class SleepStagerWindowEndpointTest {

    private val dev = "test"

    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)

    private fun rr(ts: Long, rrMs: Int) = RrInterval(deviceId = dev, ts = ts, rrMs = rrMs)

    @Test
    fun alignedEndpointSampleReachesABin() {
        // Minimal case: start = 0, end = 300 (one window wide), five samples on the endpoint.
        // Already returned 60 before the fix, but only via the all-sample fallback.
        val samples = (0 until 5).map { hr(300L, 60) }
        assertEquals(
            "a sample exactly on an aligned end must belong to the final bin",
            60, SleepStager.sessionRestingHR(0L, 300L, samples)
        )
    }

    @Test
    fun nonAlignedEndpointSampleReachesABin() {
        // Paired non-aligned case: end = 450 falls mid-window, so the endpoint sample was always
        // inside the trailing partial bin. Same answer, before and after.
        val samples = (0 until 5).map { hr(450L, 60) }
        assertEquals(
            "a sample on a non-aligned end stays in the trailing partial bin",
            60, SleepStager.sessionRestingHR(0L, 450L, samples)
        )
    }

    @Test
    fun endpointSampleLandsInFinalBinOnly() {
        // Where the fallback cannot hide the dropped sample: a dense 70 bpm first bin plus five
        // endpoint beats at 40 makes the floor 40. Before the fix the shipped resting HR read 70.
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 70))
        for (i in 0 until 5) samples.add(hr(600L, 40))
        assertEquals(
            "the endpoint sample belongs to the final bin only",
            40, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun degenerateZeroLengthWindow() {
        // start == end: the single instant is one closed bin — the same number the all-sample
        // fallback produced before.
        val samples = (0 until 5).map { hr(1000L, 58) }
        assertEquals(58, SleepStager.sessionRestingHR(1000L, 1000L, samples))
    }

    @Test
    fun sessionRestingHrEndpointSweepMatchesSwiftOracle() {
        // `end` walks a whole window width and beyond in 25 s steps against a dense 70 bpm opening
        // bin plus five endpoint beats at 60. Verbatim Swift oracle stdout — the check that catches
        // drift the eye does not, including end = 300 where the single closed bin holds BOTH groups.
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
                "sessionRestingHR.end=$endTs", expected[i], SleepStager.sessionRestingHR(0L, endTs, samples)
            )
            i++
            endTs += 25L
        }
    }

    @Test
    fun alignedEndpointBeatsFillTheFinalHrvWindow() {
        // 120 beats in the opening window plus three beats exactly on an aligned end = 600. The
        // second window is the final one, so it closes on `end` and holds those three beats; before
        // the fix it was emitted empty and its RMSSD was null. Constant 900 ms RR keeps the RMSSD
        // analytically 0.0 on both platforms — this pins the BINNING, not the RMSSD math.
        val beats = ArrayList<RrInterval>()
        for (i in 0 until 120) beats.add(rr(i.toLong(), 900))
        for (i in 0 until 3) beats.add(rr(600L, 900))
        val wins = SleepStager.sessionHrvWindows(0L, 600L, beats, emptyList())
        assertEquals(listOf(0L, 300L), wins.map { it.startTs })
        assertEquals(
            "the endpoint beats must fill the final window",
            listOf(120, 3), wins.map { it.cleanBeats }
        )
        assertEquals(listOf(0.0, 0.0), wins.map { it.rmssd })
    }

    @Test
    fun nonAlignedEndpointHrvWindowUnchanged() {
        // Paired non-aligned case: end = 450 sits mid-window, so the endpoint beats were already
        // inside the trailing partial window. Same shape, before and after.
        val beats = ArrayList<RrInterval>()
        for (i in 0 until 120) beats.add(rr(i.toLong(), 900))
        for (i in 0 until 3) beats.add(rr(450L, 900))
        val wins = SleepStager.sessionHrvWindows(0L, 450L, beats, emptyList())
        assertEquals(listOf(0L, 300L), wins.map { it.startTs })
        assertEquals(listOf(120, 3), wins.map { it.cleanBeats })
    }

    @Test
    fun sessionAvgHrvZeroLengthWindowUsesTheEndpointBeats() {
        // The value-level consequence: a zero-length window (start == end) is one closed bin, so
        // beats admitted by the prefilter produce a number instead of null.
        val beats = (0 until 3).map { rr(1000L, 900) }
        assertEquals(0.0, SleepStager.sessionAvgHRV(1000L, 1000L, beats)!!, 1e-9)
    }
}
