package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1842: per-field HRV / resting-HR carries, the twins of [lastSpo2Row] and [lastSkinTempRow].
 *
 * [lastVitalsRow]'s predicate is an OR across HRV / resting-HR / respiratory, so it selects the freshest
 * row having ANY of them — which can be a row whose `avgHrv` is null. The HRV card then read null and
 * printed "No data" while the Key Metrics tile, carrying a different row, showed a value on the same
 * screen. Same failure the SpO₂ and skin-temp twins were split out to fix.
 */
class LastHrvRowTest {

    private fun day(d: String, hrv: Double? = null, rhr: Int? = null, resp: Double? = null) =
        DailyMetric(deviceId = "my-whoop", day = d, restingHr = rhr, avgHrv = hrv, respRateBpm = resp)

    /** The reported shape: the freshest row has respiratory only, so the shared predicate picks it and
     *  its null avgHrv becomes "No data" — while a real HRV sits one row back. */
    @Test
    fun sharedPredicatePicksARowWithNoHrv() {
        val days = listOf(day("2026-09-01", hrv = 35.0, rhr = 58), day("2026-09-02", resp = 14.2))

        // The bug, pinned: lastVitalsRow selects the respiratory-only row and yields no HRV.
        assertEquals("2026-09-02", lastVitalsRow(days, todayKey = "2026-09-03")?.day)
        assertNull(lastVitalsRow(days, todayKey = "2026-09-03")?.avgHrv)

        // The per-field resolvers find the row that actually holds each value.
        assertEquals(35.0, lastHrvRow(days, todayKey = "2026-09-03")?.avgHrv)
        assertEquals(58, lastRestingHrRow(days, todayKey = "2026-09-03")?.restingHr)
    }

    /** Freshest wins when several rows carry the field. */
    @Test
    fun theFreshestRowWithTheFieldIsChosen() {
        val days = listOf(day("2026-09-01", hrv = 30.0), day("2026-09-02", hrv = 41.0))
        assertEquals(41.0, lastHrvRow(days, todayKey = "2026-09-03")?.avgHrv)
    }

    /** Same future-clock guard as its siblings: strictly prior to today's key, never today or later. */
    @Test
    fun todayAndLaterRowsAreNeverCarried() {
        val days = listOf(day("2026-09-03", hrv = 44.0), day("2026-09-04", hrv = 45.0))
        assertNull(lastHrvRow(days, todayKey = "2026-09-03"))
        assertNull(lastRestingHrRow(days, todayKey = "2026-09-03"))
    }

    /** Nothing anywhere stays "No data" — the carry must never invent a value. */
    @Test
    fun noRowWithTheFieldCarriesNothing() {
        val days = listOf(day("2026-09-01", resp = 15.0), day("2026-09-02", resp = 14.0))
        assertNull(lastHrvRow(days, todayKey = "2026-09-03"))
        assertNull(lastRestingHrRow(days, todayKey = "2026-09-03"))
    }
}
