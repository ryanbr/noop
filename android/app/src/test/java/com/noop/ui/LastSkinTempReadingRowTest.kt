package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** #1844: the carry must find a night holding EITHER skin-temp number, and read both off that ONE row. */
class LastSkinTempReadingRowTest {

    private fun day(d: String, abs: Double? = null, dev: Double? = null) =
        DailyMetric(deviceId = "my-whoop", day = d, skinTempC = abs, skinTempDevC = dev)

    /** The calibrating night the deviation-only selector skipped: real temperature, no deviation yet. */
    @Test
    fun findsANightWithOnlyAnAbsolute() {
        val days = listOf(day("2026-09-01", dev = -0.3), day("2026-09-02", abs = 34.1))
        assertEquals("2026-09-02", lastSkinTempReadingRow(days, todayKey = "2026-09-03")?.day)
        // The old deviation-only row would reach back past it to the older night.
        assertEquals("2026-09-01", lastSkinTempRow(days, todayKey = "2026-09-03")?.day)
    }

    /** Both numbers come off the SAME row, so an absolute is never paired with another night's deviation. */
    @Test
    fun bothNumbersComeFromOneNight() {
        val days = listOf(day("2026-09-01", abs = 33.0, dev = -0.9), day("2026-09-02", abs = 34.1, dev = 0.2))
        val row = lastSkinTempReadingRow(days, todayKey = "2026-09-03")!!
        assertEquals(34.1, row.skinTempC!!, 1e-9)
        assertEquals(0.2, row.skinTempDevC!!, 1e-9)
    }

    /** Same future-clock bound as every sibling carry. */
    @Test
    fun neverCarriesTodayOrLater() {
        val days = listOf(day("2026-09-03", abs = 34.0), day("2026-09-04", abs = 34.2))
        assertNull(lastSkinTempReadingRow(days, todayKey = "2026-09-03"))
    }

    /** A row with neither number is not a reading. */
    @Test
    fun rowsWithNeitherNumberAreSkipped() {
        val days = listOf(day("2026-09-01", abs = 33.5), day("2026-09-02"))
        assertEquals("2026-09-01", lastSkinTempReadingRow(days, todayKey = "2026-09-03")?.day)
    }
}
