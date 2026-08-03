package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #983 — the resting HR a workout is scored with is not cosmetic; it moves every zone boundary.
 *
 * %HRR is `(bpm - resting) / (max - resting)`, so scoring someone whose real resting is 50 as if it were
 * the hardcoded default of 60 both shrinks the reserve and raises the floor. At 136 bpm that is exactly
 * the difference between zone 1 and zone 2 — the same session, two different Efforts.
 *
 * This is why the saved-workout path threading the measured value matters: Today's Effort and the
 * manual rescore (#972) already did, so a stored workout used to disagree with its own re-score.
 *
 * Twin of `StrainScorerTests.testRestingHrChangesTheZoneASampleLandsIn`.
 */
class StrainRestingHrTest {

    @Test
    fun restingHrChangesTheZoneASampleLandsIn() {
        // 136 bpm straddles the zone-1/zone-2 boundary depending only on the resting HR used.
        assertEquals(1, StrainScorer.zoneWeight(136.0, 60.0, 130.0))
        assertEquals(2, StrainScorer.zoneWeight(136.0, 50.0, 140.0))

        // ...and it carries through to the score, not just the zone.
        val window = (0 until 1200).map { HrSample(deviceId = "d", ts = 1_700_000_000L + it, bpm = 136) }
        val asDefault = StrainScorer.strain(window, maxHR = 190.0, restingHR = 60.0)!!
        val asMeasured = StrainScorer.strain(window, maxHR = 190.0, restingHR = 50.0)!!
        assertTrue(
            "a lower measured resting puts the same HR in a higher zone, so Effort rises",
            asMeasured > asDefault,
        )
    }
}
