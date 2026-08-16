package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Byte-twin of the Swift `TodayVitalCardTests` respiratory cases (#1331). Pins `lastRespRow` — the
 * STALENESS-BOUNDED resolver the classic Today dashboard's Respiratory card now reads, instead of the
 * unbounded whole-row vitals carry that printed one CSV import's last value for a fortnight.
 */
class LastRespRowTest {

    private fun day(d: String, resp: Double? = null) =
        DailyMetric(deviceId = "my-whoop", day = d, restingHr = 60, avgHrv = 45.0, respRateBpm = resp)

    /** The reported regression: a WHOOP CSV import ending 2026-07-30, viewed on 2026-08-13, with
     * thirteen live nights after it that recorded pulse and HRV but no respiration. The only
     * respiratory value anywhere is a fortnight old; the bounded selector refuses it, so the card
     * reads "No Data". */
    @Test
    fun fortnightOldImportNoLongerCarries() {
        val days = listOf(day("2026-07-29", 16.2), day("2026-07-30", 15.6)) +
            (1..13).map { day("2026-08-%02d".format(it)) }

        assertEquals(
            "the fixture reproduces the report: the newest respiratory value IS the old import",
            "2026-07-30", days.lastOrNull { it.respRateBpm != null }?.day,
        )
        assertNull(lastRespRow(days, todayKey = "2026-08-13"))
    }

    /** The carry still earns its keep: one missed night must not blank the card. */
    @Test
    fun aRecentNightStillCarries() {
        val days = listOf(day("2026-08-11", 14.1), day("2026-08-12"))
        assertEquals(14.1, lastRespRow(days, todayKey = "2026-08-13")?.respRateBpm)
    }

    /** Today's own row is never "carried": the bound looks strictly backwards, so a still-forming
     * today cannot be picked up as its own prior night. */
    @Test
    fun todayIsNotItsOwnCarry() {
        val days = listOf(day("2026-08-13", 15.0))
        assertNull(lastRespRow(days, todayKey = "2026-08-13"))
    }
}
