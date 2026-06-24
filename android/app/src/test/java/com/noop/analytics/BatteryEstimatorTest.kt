package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Mirror of the Swift BatteryEstimatorTests — same fixtures, same expectations (#713). */
class BatteryEstimatorTest {

    private val h = 3600L

    @Test fun nullWhenNoReadings() {
        assertNull(BatteryEstimator.estimate(emptyList(), BatteryEstimator.ratedLifeHoursWhoop5))
    }

    @Test fun measuredRateFromCleanDischarge() {
        // 100% → 90% over 10 h = 1 %/h; at 90% → 90 h left, from the user's OWN discharge.
        val e = BatteryEstimator.estimate(listOf(0L to 100.0, 10 * h to 90.0),
            BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(90.0, e.remainingHours, 1e-6)
        assertEquals(90.0, e.currentSoc, 1e-6)
    }

    @Test fun ratedFallbackWhenSpanTooShort() {
        // One reading (no span) → rated: 50 / (100/108) = 54 h.
        val e = BatteryEstimator.estimate(listOf(0L to 50.0), BatteryEstimator.ratedLifeHoursWhoop4)!!
        assertEquals(BatteryEstimator.Source.RATED, e.source)
        assertEquals(54.0, e.remainingHours, 1e-6)
    }

    @Test fun chargeRestartsTheDischargeRun() {
        // discharge 100→70, then a CHARGE back to 100, then 100→88 over 6 h. The rate is fit on the
        // post-charge segment (2 %/h), NOT across the charge — proving we never fit through a charge.
        val r = listOf(0L to 100.0, 4 * h to 70.0, 5 * h to 100.0, 11 * h to 88.0)
        val e = BatteryEstimator.estimate(r, BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(44.0, e.remainingHours, 1e-6)   // 88 / 2
    }

    @Test fun ratedFallbackWhenDropTooSmall() {
        // 100→99 over 10 h: 1% drop < minDropPct(2) → rated, not a wild ~1000 h.
        val e = BatteryEstimator.estimate(listOf(0L to 100.0, 10 * h to 99.0),
            BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.RATED, e.source)
        assertEquals(285.12, e.remainingHours, 1e-6)   // 99 / (100/288) — anchored to the latest SoC
    }

    @Test fun labelSwitchesHoursToDaysAt48h() {
        assertEquals("~14 h", BatteryEstimator.label(14.0))
        assertEquals("~4.5 days", BatteryEstimator.label(108.0))
    }
}
