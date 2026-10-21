package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors StrandAnalyticsTests/AchievementsTests.swift - same fixtures, same expected outputs. */
class AchievementsTest {

    private fun key(epoch: Int): String = java.time.LocalDate.ofEpochDay(epoch.toLong()).toString()

    @Test fun streakAndThresholdMilestones() {
        val start = Baselines.isoEpochDay("2026-09-01")!!
        val days = (0 until 8).map { Achievements.Day(key(start + it), recovery = 50.0) }.toMutableList()
        days += Achievements.Day(key(start + 10), recovery = 95.0, strain = 18.2, sleepMin = 481.0, steps = 10_000.0)
        days += Achievements.Day(key(start + 11), strain = 30.0, sleepMin = 2_000.0)   // implausible, no score
        val a = Achievements.evaluate(days.shuffled(), key(start + 12)).associateBy { it.id }
        assertEquals("2026-09-01", a[Achievements.Id.FIRST_SCORE]?.unlockedDay)
        assertEquals("2026-09-07", a[Achievements.Id.STREAK_7]?.unlockedDay)
        assertNull(a[Achievements.Id.STREAK_30]?.unlockedDay)
        assertNull(a[Achievements.Id.SCORED_100]?.unlockedDay)
        assertEquals("2026-09-11", a[Achievements.Id.CHARGE_90]?.unlockedDay)
        assertEquals("2026-09-11", a[Achievements.Id.SLEEP_8H]?.unlockedDay)
        assertEquals("2026-09-11", a[Achievements.Id.EFFORT_18]?.unlockedDay)
        assertEquals("2026-09-11", a[Achievements.Id.STEPS_10K]?.unlockedDay)
        assertTrue(a[Achievements.Id.CHARGE_90]!!.isNew)
        assertFalse(a[Achievements.Id.FIRST_SCORE]!!.isNew)
        assertEquals(Achievements.Id.entries.size, Achievements.evaluate(emptyList(), "x").size)
    }

    @Test fun duplicateDayCountsOnceInStreak() {
        val start = Baselines.isoEpochDay("2026-01-01")!!
        val days = (0 until 6).map { Achievements.Day(key(start + it), recovery = 40.0) } +
            Achievements.Day(key(start + 5), recovery = 41.0)
        val a = Achievements.evaluate(days, key(start + 5))
        assertNull(a.first { it.id == Achievements.Id.STREAK_7 }.unlockedDay)
    }
}
