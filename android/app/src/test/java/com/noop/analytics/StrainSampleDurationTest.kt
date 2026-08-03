package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * #950 — TRIMP must weight each HR reading by its OWN gap, not by one factor guessed from the window's
 * first two timestamps.
 *
 * The report: a hard ride showed Effort 6.9 while the day around it showed 14, and the two are computed
 * from the same samples. The old code inferred ONE per-sample duration from `hr[1].ts - hr[0].ts` and
 * multiplied the whole zone-weight sum by it. NOOP's stream is not uniformly spaced — live Bluetooth ~1 s,
 * banked 5/MG history ~30 s, dropouts larger — so whichever gap came first set the scale for the entire
 * window, and the workout window and the day window (different first samples) got different scales.
 *
 * Twin of Swift `StrainSampleDurationTests` — same fixtures, same expected values.
 */
class StrainSampleDurationTest {

    private val rest = 60.0
    private val max = 190.0
    private val reserve = max - rest

    /** A bpm solidly in Edwards zone 4 (85% HRR). */
    private val hard = (rest + 0.85 * reserve).toInt()

    private fun series(vararg ts: Long): List<HrSample> =
        ts.map { HrSample(deviceId = "t", ts = it, bpm = hard) }

    private fun uniform(n: Int, stepS: Long): List<HrSample> =
        (0 until n).map { HrSample(deviceId = "t", ts = it * stepS, bpm = hard) }

    // --- the invariant that keeps every pre-existing strain test green ---

    /** Uniform spacing: per-sample gaps all equal the first gap, so TRIMP is byte-identical to the old
     *  single-factor code. This is why the fix moves no existing assertion. */
    @Test
    fun uniformSeriesIsByteIdenticalToTheOldComputation() {
        val hr = uniform(120, 30)
        val oldTrimp = run {
            var w = 0
            for (s in hr) w += StrainScorer.zoneWeight(s.bpm.toDouble(), rest, reserve)
            w.toDouble() * StrainScorer.sampleDurationMinutes(hr)
        }
        val newTrimp = StrainScorer.edwardsTRIMP(hr, rest, reserve, StrainScorer.sampleDurationsMinutes(hr))
        assertEquals(oldTrimp, newTrimp, 1e-9)
        assertEquals(240.0, newTrimp, 1e-9)   // 120 samples x zone-4 weight x 0.5 min
    }

    // --- the reported defect ---

    /** The #950 shape: a few 1 s live samples, then 30 s banked history. The old code scaled the whole
     *  hour by the 1 s first gap and lost ~96% of the effort; per-sample gaps recover it. */
    @Test
    fun mixedCadenceNoLongerCollapsesTheWindow() {
        val live = (0 until 10).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = hard) }
        val banked = (0 until 120).map { HrSample(deviceId = "t", ts = 60L + it * 30L, bpm = hard) }
        val hr = live + banked
        val trimp = StrainScorer.edwardsTRIMP(hr, rest, reserve, StrainScorer.sampleDurationsMinutes(hr))
        // Old: (10+120) x 4 x (1/60) = 8.67. New: the banked hour carries its real half-minute weights.
        assertTrue("expected the banked hour to be counted (got $trimp)", trimp > 230.0)
    }

    /** The workout window and the day containing it must agree: appending low-HR context around a hard
     *  window may only ADD effort, never shrink what the window alone scores. Under the old code the day
     *  could score a fraction of its own workout purely from a different first gap. */
    @Test
    fun addingContextAroundAWindowNeverShrinksItsTrimp() {
        val workout = (0 until 120).map { HrSample(deviceId = "t", ts = 1000L + it * 30L, bpm = hard) }
        val idleBefore = (0 until 60).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = 55) }
        val day = idleBefore + workout
        val w = StrainScorer.edwardsTRIMP(workout, rest, reserve, StrainScorer.sampleDurationsMinutes(workout))
        val d = StrainScorer.edwardsTRIMP(day, rest, reserve, StrainScorer.sampleDurationsMinutes(day))
        assertTrue("day ($d) must be >= its own workout ($w)", d >= w - 1e-9)
    }

    // --- the clamp ---

    /** A dropout gap is capped: one reading before a 3 h hole may carry at most [maxSampleGapMin], not
     *  the whole hole — otherwise a single zone-5 sample invents hours of effort. */
    @Test
    fun dropoutGapIsClampedNotCredited() {
        val hr = series(0, 3 * 3600)
        val durations = StrainScorer.sampleDurationsMinutes(hr)
        assertEquals(listOf(StrainScorer.maxSampleGapMin, StrainScorer.maxSampleGapMin), durations)
    }

    /** No genuine cadence is truncated: the clamp sits at 4x the sparsest real cadence (~30 s). */
    @Test
    fun thirtySecondCadenceIsNotClamped() {
        val durations = StrainScorer.sampleDurationsMinutes(uniform(3, 30))
        assertEquals(listOf(0.5, 0.5, 0.5), durations)
    }

    // --- edges ---

    @Test
    fun edgesMatchTheOldFallbacks() {
        assertEquals(emptyList<Double>(), StrainScorer.sampleDurationsMinutes(emptyList()))
        assertEquals(listOf(StrainScorer.fallbackSampleMin), StrainScorer.sampleDurationsMinutes(series(5)))
        // Coincident timestamps keep the 1 s fallback rather than a zero-duration sample.
        val co = StrainScorer.sampleDurationsMinutes(series(7, 7))
        assertTrue(co.all { abs(it - StrainScorer.fallbackSampleMin) < 1e-9 })
    }
}
