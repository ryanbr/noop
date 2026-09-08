package com.noop.ui

import com.noop.analytics.ScoreConfidence
import com.noop.analytics.ChargeDriverLabel
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the Today "What shaped it" wiring: [recoveryChargeDrivers] (folds the visible history
 * into baselines, then defers to RecoveryDrivers.chargeDrivers) and [chargeConfidenceTier] (surfaces the
 * existing ScoreConfidence). Pure JVM, no Robolectric. Mirrors the iOS chargeDrivers wiring tests.
 */
class RecoveryDriversUiTest {

    private fun day(
        d: String,
        hrv: Double? = 55.0,
        rhr: Int? = 55,
        resp: Double? = 15.0,
        recovery: Double? = null,
        efficiency: Double? = 0.9,
        sleepMin: Double? = 450.0,
        skinTempDevC: Double? = null,
    ) = DailyMetric(
        deviceId = "my-whoop-noop", day = d, avgHrv = hrv, restingHr = rhr, respRateBpm = resp,
        recovery = recovery, efficiency = efficiency, totalSleepMin = sleepMin, skinTempDevC = skinTempDevC,
    )

    /** A history long enough to make the HRV baseline usable, plus a scored "today". */
    private fun scoredHistory(): List<DailyMetric> {
        val past = (1..10).map { day("2026-01-%02d".format(it), hrv = 50.0 + (it % 3)) }
        val today = day("2026-01-20", hrv = 62.0, rhr = 51, resp = 15.0, recovery = 64.0, skinTempDevC = 0.2)
        return past + today
    }

    @Test fun scoredDayProducesDriverRows() {
        val days = scoredHistory()
        val drivers = recoveryChargeDrivers(days, days.last())
        assertTrue("a usable baseline should yield driver rows", drivers.isNotEmpty())
        val labels = drivers.map { it.label }
        assertTrue(labels.contains(ChargeDriverLabel.HEART_RATE_VARIABILITY))
        assertTrue(labels.contains(ChargeDriverLabel.RESTING_HEART_RATE))
        // Skin-temp was supplied on the scored day, so its row is present.
        assertTrue(labels.contains(ChargeDriverLabel.SKIN_TEMPERATURE))
    }

    @Test fun coldStartHistoryProducesNoRows() {
        // Two nights only: the HRV baseline is not usable yet, so there are no honest drivers.
        val days = listOf(
            day("2026-01-01", hrv = 55.0),
            day("2026-01-02", hrv = 58.0, recovery = null),
        )
        assertTrue(recoveryChargeDrivers(days, days.last()).isEmpty())
    }

    @Test fun confidenceTierIsSurfaced() {
        val days = scoredHistory()
        // A scored day on a now-usable baseline surfaces a non-calibrating tier.
        val tier = chargeConfidenceTier(days, days.last())
        assertTrue(tier == ScoreConfidence.BUILDING || tier == ScoreConfidence.SOLID)
        // A day with no recovery number surfaces CALIBRATING.
        assertEquals(ScoreConfidence.CALIBRATING, chargeConfidenceTier(days, day("2026-01-21", recovery = null)))
    }

    @Test fun nullDayProducesNoRows() {
        assertTrue(recoveryChargeDrivers(scoredHistory(), null).isEmpty())
    }

    // ---- #1988: the RHR row needs a USABLE resting-HR baseline ----------------------------------

    /**
     * A history with no banked resting HR folds to `foldHistory`'s synthetic midpoint (about 75 bpm),
     * which is nobody's resting HR. Scoring the RHR row against it moves a bar on a baseline the user
     * has never had, so the row must be absent. The HRV row still stands, since that baseline is real.
     *
     * The display day itself carries a reading, so this is specifically the BASELINE being unusable,
     * not the reading being missing.
     *
     * The gate is NOT in this file: `recoveryChargeDrivers` passes its fold on ungated and
     * `RecoveryDrivers.chargeDrivers` applies it (#1990). This pins the end of that path, the surface a
     * user actually sees, which nothing else covers. `scoredDayProducesDriverRows` above is the usable
     * -baseline half of the pair: it asserts the row IS present on a history that banks resting HR, so
     * the two together show the gate is not a blanket off. Deliberately not restated here.
     */
    @Test fun rhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable() {
        val history = (1..6).map { day("2026-01-0$it", rhr = null) }
        val today = day("2026-01-07", rhr = 55)
        val drivers = recoveryChargeDrivers(history + today, today)
        val labels = drivers.map { it.label }
        assertTrue("the HRV baseline is real, so its row must still be there",
            labels.contains(ChargeDriverLabel.HEART_RATE_VARIABILITY))
        assertFalse("no usable resting-HR baseline, so no RHR row: got $labels",
            labels.contains(ChargeDriverLabel.RESTING_HEART_RATE))
    }
}
