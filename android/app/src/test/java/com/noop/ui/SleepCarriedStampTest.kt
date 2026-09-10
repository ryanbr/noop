package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** #1946: a carried prior-night metric value must be stamped with its day so it is not passed off
 *  as tonight's read. The [Metric] data class now carries `latestDay` alongside `latest`, and
 *  [Metric.carriedMetricCaption] returns a [DisplayText.Resource] when the value is from a prior
 *  day, so the string lives in `strings.xml` where the i18n audit and the locale files can see it.
 *  Byte-parity twin of Swift `SleepCarriedStampTests`. */
class SleepCarriedStampTest {

    private fun day(d: String, resp: Double? = null, eff: Double? = null): DailyMetric =
        DailyMetric(
            deviceId = "test", day = d, totalSleepMin = 420.0, efficiency = eff,
            deepMin = 80.0, remMin = 90.0, lightMin = 200.0, disturbances = null,
            restingHr = null, avgHrv = null, recovery = null, strain = null,
            exerciseCount = null, spo2Pct = null, skinTempDevC = null, respRateBpm = resp,
        )

    private fun metric(
        days: List<DailyMetric>,
        todayKey: String,
        transform: (DailyMetric) -> Double?,
    ): Metric {
        val points = days.mapNotNull { d ->
            transform(d)?.takeIf { it.isFinite() }?.let { d.day to it }
        }
        val series = points.map { it.second }
        val fresh = com.noop.analytics.Baselines.freshestCarried(points, todayKey)
        val latestDay = if (fresh != null && fresh.first != todayKey) fresh.first else null
        return Metric(fresh?.second, latestDay, if (series.isEmpty()) null else series.average(), series)
    }

    /** Resolve a DisplayText to its raw string for assertions. */
    private fun DisplayText?.asString(): String? = when (this) {
        is DisplayText.Resource -> {
            // The test runs under JVM unit tests without Android resources, so resolve the
            // format string manually. The resource is "Carried · %1$s".
            "Carried · ${args.joinToString("")}"
        }
        is DisplayText.Dynamic -> value
        null -> null
    }

    /** A value from TODAY's own day is NOT carried — `latestDay` is null, no stamp. */
    @Test fun todayValueIsNotCarried() {
        val days = listOf(day("2026-08-13", resp = 15.6))
        val resp = metric(days, "2026-08-13") { it.respRateBpm }
        assertEquals(15.6, resp.latest!!, 1e-9)
        assertNull("today's own value must not be marked as carried", resp.latestDay)
        assertNull(Metric.carriedMetricCaption(resp.latestDay, resp.latest))
    }

    /** A value from a PRIOR day within the carry window IS carried — `latestDay` is set, and the
     *  caption stamps it as a DisplayText.Resource pointing at the string resource. */
    @Test fun priorDayValueIsCarriedAndStamped() {
        val days = listOf(day("2026-08-11", resp = 14.1), day("2026-08-12"))
        val resp = metric(days, "2026-08-13") { it.respRateBpm }
        assertEquals(14.1, resp.latest!!, 1e-9)
        assertEquals("the carried value's source day is tracked", "2026-08-11", resp.latestDay)
        val caption = Metric.carriedMetricCaption(resp.latestDay, resp.latest)
        assertNotNull("a carried value must produce a stamp caption", caption)
        assertTrue("caption must be a Resource", caption is DisplayText.Resource)
        val resolved = caption.asString()
        assertTrue("caption must contain 'Carried': $resolved", resolved!!.contains("Carried"))
    }

    /** A nil latest has no stamp — the tile falls through to "vs typical" or "—". */
    @Test fun noValueHasNoStamp() {
        assertNull(Metric.carriedMetricCaption("2026-08-11", null))
        assertNull(Metric.carriedMetricCaption(null, 15.6))
        assertNull(Metric.carriedMetricCaption(null, null))
    }

    /** A stale value (outside the carry window) has no latest and no stamp. */
    @Test fun staleValueHasNoLatestAndNoStamp() {
        val days = mutableListOf(day("2026-07-29", resp = 16.2), day("2026-07-30", resp = 15.6))
        for (i in 1..13) days.add(day(String.format("2026-08-%02d", i)))
        val resp = metric(days, "2026-08-13") { it.respRateBpm }
        assertNull(resp.latest)
        assertNull(resp.latestDay)
        assertNull(Metric.carriedMetricCaption(resp.latestDay, resp.latest))
    }

    /** A fresh sibling metric (efficiency, present every night) is NOT carried when today has a value. */
    @Test fun freshSiblingIsNotCarried() {
        val days = listOf(day("2026-08-12", eff = 90.0), day("2026-08-13", eff = 88.0))
        val eff = metric(days, "2026-08-13") { it.efficiency }
        assertEquals(88.0, eff.latest!!, 1e-9)
        assertNull("today's own efficiency is not carried", eff.latestDay)
    }
}
