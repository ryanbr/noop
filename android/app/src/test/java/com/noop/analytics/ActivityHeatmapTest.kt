package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the ActivityHeatmap grid builder + its calendar arithmetic. The Swift twin
 * (`ActivityHeatmapTests`) asserts the same shape, so the two platforms bucket days into identical
 * week-columns / weekday-rows / intensity levels.
 */
class ActivityHeatmapTest {

    private val today = "2026-08-11" // a Tuesday (Monday-first weekday 1)

    @Test fun gridShapeAndTodayPlacement() {
        val values = mapOf("2026-08-11" to 400.0, "2026-08-10" to 100.0, "2026-08-09" to 200.0)
        val g = ActivityHeatmap.build(values, today, weeks = 13)
        assertEquals(13, g.weeks)
        assertEquals(13, g.columns.size)
        assertTrue(g.columns.all { it.size == 7 })
        assertEquals(400.0, g.maxValue, 0.0)

        // The rightmost column is the current week; today sits at weekday row 1, Monday at row 0.
        val last = g.columns[12]
        assertEquals("2026-08-11", last[1].day)
        assertEquals(400.0, last[1].value)
        assertEquals(4, last[1].level)          // max → level 4
        assertEquals("2026-08-10", last[0].day)
        assertEquals(1, last[0].level)          // 100/400 → level 1
        // Future days in the current week are empty pad cells.
        assertNull(last[2].day)
        assertEquals(0, last[2].level)

        // The first column starts 13 weeks back on a Monday; no value → no-data cell.
        assertEquals("2026-05-18", g.columns[0][0].day)
        assertEquals(0, g.columns[0][0].level)
    }

    @Test fun levelBuckets() {
        assertEquals(0, ActivityHeatmap.levelFor(null, 400.0))   // no data
        assertEquals(1, ActivityHeatmap.levelFor(0.0, 400.0))    // present but zero → 1
        assertEquals(1, ActivityHeatmap.levelFor(100.0, 400.0))  // 25%
        assertEquals(2, ActivityHeatmap.levelFor(200.0, 400.0))  // 50%
        assertEquals(3, ActivityHeatmap.levelFor(300.0, 400.0))  // 75%
        assertEquals(4, ActivityHeatmap.levelFor(400.0, 400.0))  // max
        assertEquals(1, ActivityHeatmap.levelFor(50.0, 0.0))     // no max → 1
    }

    @Test fun calendarArithmeticMatchesTheProlepticGregorian() {
        assertEquals(20676L, ActivityHeatmap.epochDay("2026-08-11"))
        assertEquals(0L, ActivityHeatmap.epochDay("1970-01-01"))
        assertEquals("2026-08-11", ActivityHeatmap.civilDay(20676L))
        assertEquals("1970-01-01", ActivityHeatmap.civilDay(0L))
        assertEquals(1, ActivityHeatmap.mondayFirstWeekday(20676L)) // Tue
        assertEquals(3, ActivityHeatmap.mondayFirstWeekday(0L))     // 1970-01-01 = Thu
        assertNull(ActivityHeatmap.epochDay("not-a-date"))
        assertNull(ActivityHeatmap.epochDay("2026-13-40"))
    }

    @Test fun emptyValuesGivesAllNoData() {
        val g = ActivityHeatmap.build(emptyMap(), today, weeks = 13)
        assertTrue(g.isEmpty)
        assertEquals(0.0, g.maxValue, 0.0)
        assertTrue(g.columns.flatten().all { it.level == 0 })
    }
}
