package com.noop.ui

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * Pins the pure scheduling arithmetic of the daily debug export (#510): the initial delay from "now" to
 * the next wall-clock occurrence of the chosen time-of-day. WorkManager itself isn't exercised here (it
 * needs an instrumented context); this guards the one piece of logic that decides WHEN the worker first
 * runs, which is the part a bug would silently break.
 */
class DebugExportSchedulerTest {

    private lateinit var savedZone: TimeZone

    @Before fun pinUtc() {
        savedZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    @After fun restoreZone() { TimeZone.setDefault(savedZone) }

    private fun localTime(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0): Long =
        Calendar.getInstance().apply {
            clear()
            set(year, month, day, hour, minute)
        }.timeInMillis

    /** Fixed UTC midnight for the flat-hour assertions. */
    private fun midnight(): Long = localTime(2026, Calendar.JANUARY, 15, 0)

    @Test
    fun targetLaterTodayDelaysWithinTheSameDay() {
        val midnight = midnight()
        // now = 06:00, target = 07:00 → 1h ahead, today.
        val now = midnight + 6 * 60 * 60 * 1000L
        val delay = DebugExportScheduler.delayToNextOccurrenceMs(minuteOfDay = 7 * 60, nowMs = now)
        assertEquals(60L * 60L * 1000L, delay)
    }

    @Test
    fun targetEarlierTodayRollsToTomorrow() {
        val midnight = midnight()
        // now = 09:00, target = 07:00 → already passed → tomorrow 07:00 = 22h ahead.
        val now = midnight + 9 * 60 * 60 * 1000L
        val delay = DebugExportScheduler.delayToNextOccurrenceMs(minuteOfDay = 7 * 60, nowMs = now)
        assertEquals(22L * 60L * 60L * 1000L, delay)
    }

    @Test
    fun targetEqualToNowRollsToTomorrow() {
        val midnight = midnight()
        // now == target (07:00 exactly) → "<=" rolls forward a full day so we never fire instantly.
        val now = midnight + 7 * 60 * 60 * 1000L
        val delay = DebugExportScheduler.delayToNextOccurrenceMs(minuteOfDay = 7 * 60, nowMs = now)
        assertEquals(24L * 60L * 60L * 1000L, delay)
    }

    @Test
    fun delayIsAlwaysPositiveAndWithinADayInUtc() {
        val midnight = midnight()
        // In UTC, any time-of-day sampled across the day yields a delay in (0, 24h].
        for (minute in intArrayOf(0, 1, 6 * 60, 12 * 60, 23 * 60 + 59)) {
            for (hourNow in 0..23) {
                val now = midnight + hourNow * 60 * 60 * 1000L + 137L // odd offset to avoid exact ties
                val delay = DebugExportScheduler.delayToNextOccurrenceMs(minute, now)
                assertTrue("delay must be > 0", delay > 0L)
                assertTrue("delay must be <= 24h", delay <= 24L * 60L * 60L * 1000L)
            }
        }
    }

    @Test
    fun springForwardShortensTheElapsedDelay() {
        TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Auckland"))
        val now = localTime(2026, Calendar.SEPTEMBER, 26, 7)
        val delay = DebugExportScheduler.delayToNextOccurrenceMs(7 * 60, now)
        assertEquals(23L * 60L * 60L * 1000L, delay)
    }

    @Test
    fun fallBackCanMakeTheElapsedDelayLongerThanADay() {
        TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Auckland"))
        val now = localTime(2026, Calendar.APRIL, 4, 7)
        val delay = DebugExportScheduler.delayToNextOccurrenceMs(7 * 60, now)
        assertEquals(25L * 60L * 60L * 1000L, delay)
    }

    @Test
    fun settingsClampTimeToValidMinuteOfDay() {
        // The store clamps out-of-range minutes; mirror SmartAlarmStore's defensive coercion shape.
        // (No SharedPreferences here — assert the bound constants are internally consistent.)
        assertEquals(24 * 60, DebugExportSettings.MINUTES_PER_DAY)
        assertTrue(DebugExportSettings.DEFAULT_TIME in 0 until DebugExportSettings.MINUTES_PER_DAY)
    }
}
