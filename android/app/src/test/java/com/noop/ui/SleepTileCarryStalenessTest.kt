package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The Night detail tiles must not present a stale value as this night's reading.
 *
 * The regression, reported 2026-08-13: the Sleep tab's Respiratory tile read "15.6" every day for a
 * fortnight — the last value of a WHOOP CSV import that ended 2026-07-30 — because the tile's `latest`
 * was `series.lastOrNull()` with no age bound, and this card shows no date beside the number at all.
 * Twin of the Swift `SleepModelStaleCarryTests`.
 */
class SleepTileCarryStalenessTest {

    private fun day(d: String, resp: Double? = null) = DailyMetric(
        deviceId = "my-whoop", day = d, totalSleepMin = 420.0,
        deepMin = 80.0, remMin = 90.0, lightMin = 200.0, efficiency = 90.0,
        respRateBpm = resp,
    )

    /** The reported case: last respiratory value 2026-07-30, viewed on 2026-08-13. */
    @Test
    fun staleRespiratoryRateDoesNotReachTheTile() {
        val days = listOf(
            day("2026-07-29", resp = 16.2),
            day("2026-07-30", resp = 15.6),
        ) + (1..13).map { day("2026-08-%02d".format(it)) }   // live nights, no respiratory value

        val m = buildSleepModel(days, session = null, todayKey = "2026-08-13")!!
        assertNull(m.respiratory.latest)
        // The trend line is HISTORICAL and survives — only the headline claims to be current.
        assertEquals(2, m.respiratory.series.size)
        // Sleep-derived siblings are unaffected: they have fresh values every night.
        assertNotNull(m.efficiency.latest)
        assertNotNull(m.restorative.latest)
    }

    /** The carry still does its job: a value inside the window is a legitimate "latest". */
    @Test
    fun recentRespiratoryRateStillReachesTheTile() {
        val days = listOf(day("2026-08-11", resp = 14.1), day("2026-08-12"))
        val m = buildSleepModel(days, session = null, todayKey = "2026-08-13")!!
        assertEquals(14.1, m.respiratory.latest!!, 1e-9)
    }
}
