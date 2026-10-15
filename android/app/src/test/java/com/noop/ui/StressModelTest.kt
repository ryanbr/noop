package com.noop.ui

import com.noop.analytics.DaytimeStress
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * StressModel.build carry (#543). The Today "Stress" metric derives against a 30-day RHR/HRV baseline.
 * Today's own daily row is often vitals-less until the overnight is analyzed (especially right after an
 * app update relaunches and re-runs the analyze pass), and every OTHER Today vital carries last night's
 * value — Stress used to be the one card that didn't, so it dropped to "Calibrating" while the rest showed
 * numbers. These pin the carry: score the newest day that actually has RHR/HRV. Twin of the Swift
 * StressModelCarryTests.
 */
class StressModelTest {

    private fun day(d: String, rhr: Int?, hrv: Double?) =
        DailyMetric(deviceId = "my-whoop", day = d, restingHr = rhr, avgHrv = hrv)

    // 31 days that all carry RHR + HRV: a full 30-day baseline plus one more scorable day.
    private val baseline = (1..30).map { day("2026-06-%02d".format(it), rhr = 55, hrv = 60.0) } +
        day("2026-07-01", rhr = 55, hrv = 60.0)

    @Test
    fun vitalsLessTodayCarriesInsteadOfCalibrating() {
        // Control: today HAS vitals -> builds (unchanged behaviour).
        assertNotNull(StressModel.build(baseline + day("2026-07-02", rhr = 58, hrv = 45.0), emptyMap()))
        // The fix: today has NO RHR/HRV yet (the post-update window) but a prior day does -> carries, not null.
        assertNotNull(
            "a vitals-less today must carry the last day with RHR/HRV, not calibrate",
            StressModel.build(baseline + day("2026-07-02", rhr = null, hrv = null), emptyMap()),
        )
    }

    @Test
    fun noVitalsAnywhereStillCalibrates() {
        // Genuine cold start: no day has RHR/HRV and nothing stored -> honestly calibrating (null).
        val days = (1..5).map { day("2026-07-0$it", rhr = null, hrv = null) }
        assertNull(StressModel.build(days, emptyMap()))
    }

    @Test
    fun firstNightWithoutBaselineStillShowsTodaysTimeline() {
        val night = day("2026-07-01", rhr = 55, hrv = 60.0).copy(totalSleepMin = 420.0)
        val daily = StressModel.build(listOf(night), emptyMap())
        assertNull("one night cannot establish the daily stress baseline", daily)
        val hr = (0 until DaytimeStress.minHourHrSamples).map {
            HrSample(deviceId = "t", ts = 7 * 3_600L + it, bpm = 65)
        }
        val daytime = DaytimeStress.analyze(hr, emptyList())
        assertFalse(daytime.scored.isEmpty())
        assertEquals(StressDaytimeState.Timeline, StressDaytimeState.resolve(daytime, daily != null, false))
    }

    @Test
    fun intradayLoadingAndEmptyStatesRespectIndependentReadouts() {
        for (hasDaily in listOf(false, true)) {
            for (hasAdvanced in listOf(false, true)) {
                assertEquals(StressDaytimeState.Loading, StressDaytimeState.resolve(null, hasDaily, hasAdvanced))
                assertEquals(
                    if (hasDaily || hasAdvanced) StressDaytimeState.Hidden else StressDaytimeState.Empty,
                    StressDaytimeState.resolve(DaytimeStress.Result.EMPTY, hasDaily, hasAdvanced),
                )
            }
        }
    }

    @Test
    fun storedStressOnLatestVitalsLessDayIsUsedNotSkipped() {
        // An imported latest day carries a STORED stress value but no RHR/HRV (e.g. a Xiaomi / Garmin /
        // WHOOP export). The original gate honoured it; the carry must NOT skip it back to an older vitals
        // day. The stored 2.5 must win over any derived carry.
        val days = baseline + day("2026-07-02", rhr = null, hrv = null)
        val model = StressModel.build(days, mapOf("2026-07-02" to 2.5))
        assertNotNull(model)
        assertEquals("the latest day's stored stress must win over a carry", 2.5, model!!.score, 0.001)
    }
}
