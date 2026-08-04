package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #950, second defect — a rescored workout must be scored against the wearer's MEASURED resting HR
 * when one exists, not the hardcoded 60 the day total never uses.
 *
 * The day's Effort passes the measured resting into the %HRR denominator; the workout rescore always
 * took the default. For a fit wearer (resting well under 60) that widens the true heart-rate reserve,
 * so every sample sits LOWER in the zone table than it should — the workout under-scores relative to
 * the very day it sits in, which is the incomparability #950 reports.
 *
 * Twin of Swift `ManualWorkoutRescoreRestingHrTests` — same fixtures, same expectations.
 */
class ManualWorkoutRescoreRestingHrTest {

    private val profile = UserProfile(weightKg = 70.0, heightCm = 175.0, age = 35.0, sex = "male")
    private val hrMax = 190.0

    /** An hour at 148 bpm, 30 s cadence — chosen because the Edwards zone FLIPS with the reserve: */
    private fun window(): List<HrSample> =
        (0 until 120).map { HrSample(deviceId = "t", ts = it * 30L, bpm = 148) }

    /** A measured resting of 45 must score the same window strictly higher than the default 60:
     *  148 bpm is 71.0% of a 45-resting reserve (zone 3) but 67.7% of a 60-resting one (zone 2). */
    @Test
    fun measuredRestingScoresHigherThanTheDefaultForAFitWearer() {
        val default = ManualWorkoutRescore.scored(window(), profile, hrMax)
        val measured = ManualWorkoutRescore.scored(window(), profile, hrMax, restingHR = 45.0)
        assertNotNull(default?.strain); assertNotNull(measured?.strain)
        assertTrue(
            "resting 45 (${measured!!.strain}) must out-score the default 60 (${default!!.strain})",
            measured.strain!! > default.strain!!,
        )
    }

    /** null keeps the old behaviour byte-for-byte — the cold-start path with no measured resting yet. */
    @Test
    fun nullRestingIsByteIdenticalToTheOldCall() {
        val old = ManualWorkoutRescore.scored(window(), profile, hrMax)
        val explicit = ManualWorkoutRescore.scored(window(), profile, hrMax, restingHR = null)
        assertEquals(old, explicit)
    }

    /** The resting HR reaches the calories model too — but there it sets the ACTIVE THRESHOLD
     *  (resting + 30% HRR), not the burn rate, so it only moves kcal when samples straddle the two
     *  thresholds. 95 bpm does: active under a 45-resting threshold (88.5) and resting-rate under a
     *  60-resting one (99). The first version of this test used an all-hard window and failed on both
     *  platforms with IDENTICAL kcal — asserting a mechanism the model doesn't have. */
    @Test
    fun caloriesSeeTheMeasuredRestingThroughTheActiveThreshold() {
        val warmup = (0 until 40).map { HrSample(deviceId = "t", ts = it * 30L, bpm = 95) }
        val mixed = warmup + (40 until 160).map { HrSample(deviceId = "t", ts = it * 30L, bpm = 148) }
        val default = ManualWorkoutRescore.scored(mixed, profile, hrMax)!!
        val measured = ManualWorkoutRescore.scored(mixed, profile, hrMax, restingHR = 45.0)!!
        assertTrue(
            "the 95 bpm warm-up is active under resting 45 but not 60, so kcal must differ " +
                "(${default.kcal} vs ${measured.kcal})",
            default.kcal != measured.kcal,
        )
    }
}
