package com.noop.protocol

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #891/#1100 + the #194 lesson: [EcgResearchStats.estimateBpm].
 *
 * The repo's rule for deriving a physiological signal from raw sensor data is that a single match proves
 * nothing — the method has to track a VARYING input, and for a synthetic test that means recovering SEVERAL
 * injected values rather than one. The previous test injected one rate. This injects a spread, and then
 * attacks the estimator with the specific artefact that got the earlier PPG->HR estimate withdrawn: the
 * strap's records carry a fixed 101 samples, so a seam between records is periodic at ~59 bpm all by itself.
 */
class EcgBpmEstimatorTest {

    private val fs = 100

    /** A clean sinusoid at [bpm], [seconds] long, at [fs] Hz. */
    private fun beats(bpm: Int, seconds: Double = 8.0, amplitude: Int = 1000): IntArray {
        val n = (fs * seconds).toInt()
        val f = bpm / 60.0
        return IntArray(n) { (amplitude * sin(2 * PI * f * it / fs)).toInt() }
    }

    @Test
    fun recoversSeveralDifferentInjectedRates() {
        // One match is a coincidence; the method has to move with the input.
        for (bpm in intArrayOf(45, 52, 70, 88, 110, 132, 150, 170)) {
            val got = EcgResearchStats.estimateBpm(beats(bpm), fs)
            assertNotNull("no estimate at $bpm bpm", got)
            // Lag quantisation at 100 Hz coarsens with rate, so allow a proportional tolerance.
            val tolerance = maxOf(3.0, bpm * 0.06)
            assertTrue(
                "expected ~$bpm bpm, got $got",
                abs(got!! - bpm) <= tolerance,
            )
        }
    }

    @Test
    fun theEstimateRisesAndFallsWithTheInput() {
        // Monotonicity across the band: the ordering of the estimates must match the ordering of the truth.
        val truth = intArrayOf(50, 75, 100, 125, 150)
        val got = truth.map { EcgResearchStats.estimateBpm(beats(it), fs)!! }
        assertTrue("estimates not monotonic with input: $got", got.zipWithNext().all { (a, b) -> a < b })
    }

    /**
     * THE regression that matters. A buffer assembled by tiling the SAME record content over and over has no
     * cardiac information in it at all — its only periodicity is the record length. At 101 samples and 100 Hz
     * that is lag 101 == ~59 bpm: inside the search band, and a thoroughly plausible resting heart rate.
     *
     * This is the shape that got the earlier PPG->HR estimate withdrawn, so it is pinned twice: that the
     * artefact really is detectable (or the test proves nothing), and that the guarded call refuses it.
     */
    @Test
    fun aPureRecordSeamArtefactIsRefusedRatherThanReportedAsFiftyNineBpm() {
        val period = Whoop5Ecg.SAMPLES_PER_RAW_RECORD
        // One record's worth of arbitrary but fixed content, tiled — exactly what a repeated block looks like.
        var seed = 987654321L
        val block = IntArray(period) {
            seed = (seed * 6364136223846793005L + 1442695040888963407L)
            ((seed shr 33).toInt() % 500)
        }
        val tiled = IntArray(period * 8) { block[it % period] }

        // Unguarded, the artefact is reported with confidence, and it lands on a resting heart rate.
        val unguarded = EcgResearchStats.estimateBpm(tiled, fs, excludeLag = null)
        assertNotNull("the artefact should be detectable at all, or this test proves nothing", unguarded)
        assertTrue(
            "the artefact was expected near 60*100/101 = 59 bpm, got $unguarded",
            abs(unguarded!! - 59) <= 4,
        )

        // Guarded — the way the live view calls it — it declines rather than manufacturing physiology.
        assertNull(EcgResearchStats.estimateBpm(tiled, fs, excludeLag = period))
    }

    @Test
    fun excludingTheRecordPeriodStillFindsRatesEitherSideOfIt() {
        // The guard must be a narrow notch, not a hole that swallows the resting band.
        val period = Whoop5Ecg.SAMPLES_PER_RAW_RECORD
        for (bpm in intArrayOf(45, 52, 70, 80)) {
            val got = EcgResearchStats.estimateBpm(beats(bpm), fs, excludeLag = period)
            assertNotNull("the notch swallowed $bpm bpm", got)
            assertTrue("expected ~$bpm bpm, got $got", abs(got!! - bpm) <= maxOf(3.0, bpm * 0.06))
        }
    }

    @Test
    fun theCostOfTheGuardIsStatedNotHidden() {
        // A genuine rate that lands ON the artefact lag is indistinguishable from the artefact, so the method
        // declines. Note the notch ALONE would not do this — it would just report the peak's shoulder as a
        // slightly different number; it is the dominance check that makes the refusal real. Pinned so the
        // documented cost cannot quietly regress into a confident false reading.
        val onTheNotch = 60 * fs / Whoop5Ecg.SAMPLES_PER_RAW_RECORD   // 59 bpm
        assertNotNull(EcgResearchStats.estimateBpm(beats(onTheNotch), fs, excludeLag = null))
        assertNull(
            "a rate on the artefact lag must be declined, not reported",
            EcgResearchStats.estimateBpm(beats(onTheNotch), fs, excludeLag = Whoop5Ecg.SAMPLES_PER_RAW_RECORD),
        )
    }

    @Test
    fun noiseAndFlatlineAndTooShortAllReturnNull() {
        assertNull(EcgResearchStats.estimateBpm(IntArray(0), fs))
        assertNull("a buffer under one second cannot be judged", EcgResearchStats.estimateBpm(IntArray(fs - 1) { it }, fs))
        assertNull("a flat trace has no variance", EcgResearchStats.estimateBpm(IntArray(400) { 0 }, fs))
        // Deterministic pseudo-noise: no dominant period should clear the strength floor.
        var seed = 12345L
        val noise = IntArray(800) {
            seed = (seed * 6364136223846793005L + 1442695040888963407L)
            ((seed shr 33).toInt() % 200)
        }
        assertNull("pseudo-noise should not yield a confident rate", EcgResearchStats.estimateBpm(noise, fs))
    }

    @Test
    fun theSearchIsNotBiasedTowardHighRatesByOverlapLength() {
        // The lag score is a mean over the overlap, not a raw sum: an unnormalised sum shrinks with lag and
        // pulls the winner toward short lags (high BPM). A slow rate in a short-ish buffer is where that
        // bias showed, so pin it.
        val got = EcgResearchStats.estimateBpm(beats(46, seconds = 4.0), fs)
        assertNotNull(got)
        assertTrue("a slow rate was pulled high (got $got)", abs(got!! - 46) <= 5)
    }
}
