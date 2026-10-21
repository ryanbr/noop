package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors StrandAnalyticsTests/WeeklyPlanTests.swift - same fixtures, same expected outputs. */
class WeeklyPlanTest {

    // 2026-10-21 is a Wednesday, so its week runs Mon 2026-10-19 ... Sun 2026-10-25.
    private val today = "2026-10-21"


    @Test fun weekdayIndexIsMondayFirst() {
        assertEquals(0, WeeklyPlan.weekdayIndex(Baselines.isoEpochDay("2026-10-19")!!))
        assertEquals(6, WeeklyPlan.weekdayIndex(Baselines.isoEpochDay("2026-10-25")!!))
        assertEquals(3, WeeklyPlan.weekdayIndex(0))   // 1970-01-01, a Thursday
    }

    @Test fun weekCountsOnlyThisWeekAndPlausibleValues() {
        val days = listOf(
            WeeklyPlan.Day("2026-10-18", sleepMin = 500.0, strain = 15.0, steps = 12_000.0),   // last Sunday
            WeeklyPlan.Day("2026-10-19", sleepMin = 430.0, strain = 9.9, steps = 8_000.0),
            WeeklyPlan.Day("2026-10-20", sleepMin = 30.0, strain = 25.0, steps = 200_000.0),    // implausible
            WeeklyPlan.Day("2026-10-21", sleepMin = 419.0, strain = 10.0, steps = 9_000.0),
        )
        val w = WeeklyPlan.week(days, today, WeeklyPlan.defaultGoals())!!
        assertEquals(2, w.todayIndex)
        assertEquals(Baselines.isoEpochDay("2026-10-19"), w.mondayEpochDay)
        val (sleep, effort, steps) = w.progress
        assertEquals(listOf(0), sleep.hitWeekdays)
        assertEquals(5, sleep.daysLeft)
        assertTrue(sleep.onTrack)
        assertEquals(listOf(2), effort.hitWeekdays)
        assertEquals(4, effort.daysLeft)
        assertEquals(listOf(0, 2), steps.hitWeekdays)
        assertFalse(steps.met)
    }

    @Test fun offGoalsAreDroppedAndOffTrackIsReported() {
        val goals = listOf(
            WeeklyPlan.Goal(WeeklyPlanKind.SLEEP, 420.0, 7),
            WeeklyPlan.Goal(WeeklyPlanKind.STEPS, 8_000.0, 0),
        )
        val w = WeeklyPlan.week(emptyList(), today, goals)!!
        assertEquals(1, w.progress.size)
        assertFalse(w.progress[0].onTrack)
        assertNull(WeeklyPlan.week(emptyList(), "bad", goals))
    }
}
