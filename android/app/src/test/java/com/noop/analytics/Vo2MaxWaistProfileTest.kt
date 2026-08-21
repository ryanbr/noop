package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * #1493: VO₂max jumped between two values with nothing to explain it — "always around 50, all of a sudden
 * it is 64", then 51 again the same day.
 *
 * A missing waist does not blank VO₂max, it silently swaps the estimator. `FitnessAgeEngine.compute`
 * returns the waist-based Nes value only when a waist is supplied, and `fitnessAgeRows` otherwise falls
 * back to the Uth HR-ratio formula — writing THAT under the same "vo2max_est" key, with the card labelling
 * both simply "Estimated".
 *
 * Two passes built their own `UserProfile` longhand and one of them omitted `waistCm`, so the post-offload
 * pass scored with Uth while the 15-minute pass scored with Nes, and the card showed whichever ran last.
 * Both now build through `ProfileStore.toUserProfile()`.
 *
 * These tests pin the mechanism rather than the plumbing, because it is what makes the bug invisible: the
 * two estimators disagree by a wide margin for exactly the population that sets a waist in the first place.
 */
class Vo2MaxWaistProfileTest {

    private val computedId = "my-whoop-noop"
    private val satKey = "2026-08-15"

    /** Seven nights of wear, comfortably past the 4-day coverage floor, with a fit user's resting HR. */
    private fun week(restingHr: Int = 43) = (1..7).map { i ->
        DailyMetric(
            deviceId = computedId, day = "2026-08-0$i",
            restingHr = restingHr, strain = 120.0,
        )
    }

    private fun profile(waistCm: Double) = UserProfile(
        weightKg = 78.0, heightCm = 182.0, age = 40.0, sex = "male", waistCm = waistCm,
    )

    private fun vo2(rows: List<com.noop.data.MetricSeriesRow>): Double? =
        rows.firstOrNull { it.key == "vo2max_est" }?.value

    /**
     * The regression, stated as the thing the user actually saw: the same nights, the same person, and the
     * only difference is whether the pass knew the waist — yet the number moves by more than a real year of
     * training would. That is two estimators, not one changing its mind.
     */
    @Test fun losingTheWaistSilentlyChangesTheEstimatorAndTheNumber() {
        val withWaist = vo2(IntelligenceEngine.fitnessAgeRows(week(), profile(92.0), computedId, satKey))
        val without = vo2(IntelligenceEngine.fitnessAgeRows(week(), profile(0.0), computedId, satKey))
        assertNotNull("a waist-based pass must still produce a value", withWaist)
        assertNotNull("a waist-free pass must still produce a value (that is #1391)", without)
        assertTrue(
            "the two estimators should disagree enough to be visible as a jump: $withWaist vs $without",
            abs(without!! - withWaist!!) > 5.0,
        )
    }

    /**
     * ...and names which estimator the waist-free pass used, so a future change to either formula fails
     * here loudly instead of quietly moving one branch of a value the card presents as a single number.
     */
    @Test fun theWaistFreeValueIsTheUthHrRatio() {
        val without = vo2(IntelligenceEngine.fitnessAgeRows(week(), profile(0.0), computedId, satKey))
        val hrmax = StrainScorer.estimateHRmax(emptyList(), 40.0).first
        assertEquals(Calories.vo2maxFor(hrmax, 43.0)!!, without!!, 0.001)
    }

    /**
     * The fix's actual contract: a profile that carries the waist takes the Nes branch. Pinned by value so
     * "carries the waist" cannot degrade into "happens to produce something".
     */
    @Test fun aProfileCarryingTheWaistTakesTheNesBranch() {
        val withWaist = vo2(IntelligenceEngine.fitnessAgeRows(week(), profile(92.0), computedId, satKey))
        val nes = FitnessAgeEngine.compute(
            age = 40.0, sex = "male", restingHR = 43.0,
            paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(7, 120.0),
            waistCm = 92.0,
        )?.vo2max
        assertNotNull(nes)
        assertEquals(nes!!, withWaist!!, 0.001)
    }
}
