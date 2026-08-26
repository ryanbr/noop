package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The nightly absolute (#1636) must survive every path that REBUILDS a `DailyMetric`.
 *
 * The column is written once, on the scoring pass, and then carried by three separate merges before it
 * reaches a screen. Each of those spells its fields out by name, so a new column is silently dropped by
 * omission rather than by a compile error — the failure mode is a value that persists correctly and then
 * disappears on the way to being read, which no migration test would catch.
 *
 * Twin of the Swift `DailySkinTempAbsoluteCarryTests`.
 */
class DailySkinTempAbsoluteCarryTest {

    private fun row(
        id: String = "my-whoop",
        day: String = "2026-08-25",
        skinTempC: Double? = null,
        skinTempDevC: Double? = null,
        avgHrv: Double? = null,
    ) = DailyMetric(deviceId = id, day = day, skinTempC = skinTempC,
        skinTempDevC = skinTempDevC, avgHrv = avgHrv)

    /** An imported winner carries no absolute, so the computed filler's must survive the coalesce. */
    @Test
    fun coalesceTakesTheStrapAbsoluteWhenTheWinnerHasNone() {
        val winner = row(skinTempDevC = 0.2, avgHrv = 44.0)          // an import: deviation only
        val filler = row(skinTempC = 34.6, skinTempDevC = 0.2)       // the strap's own scored night
        assertEquals(34.6, WhoopRepository.coalesceDay(winner, filler).skinTempC!!, 0.0)
    }

    /** A winner that HAS one keeps it — the filler must never overwrite a measured value. */
    @Test
    fun coalesceKeepsTheWinnersOwnAbsolute() {
        val winner = row(skinTempC = 34.6)
        val filler = row(skinTempC = 30.1)
        assertEquals(34.6, WhoopRepository.coalesceDay(winner, filler).skinTempC!!, 0.0)
    }

    @Test
    fun coalesceLeavesItNullWhenNeitherSideMeasuredOne() {
        assertNull(WhoopRepository.coalesceDay(row(), row()).skinTempC)
    }

    /**
     * Cross-bucket: imports win the row, but the absolute is on-device only, so the computed value has to
     * come through or a user with any WHOOP-export history would never see one.
     */
    @Test
    fun mergeFillsTheAbsoluteFromTheComputedRow() {
        val imported = listOf(row(id = "my-whoop", skinTempDevC = 0.2))
        val computed = listOf(row(id = "my-whoop-noop", skinTempC = 34.6, skinTempDevC = 0.2))
        val merged = WhoopRepository.mergeDaily(imported = imported, computed = computed)
        assertEquals(1, merged.size)
        assertEquals(34.6, merged.single().skinTempC!!, 0.0)
        // And the deviation every downstream gate reads is untouched by carrying the absolute.
        assertEquals(0.2, merged.single().skinTempDevC!!, 1e-12)
    }
}
