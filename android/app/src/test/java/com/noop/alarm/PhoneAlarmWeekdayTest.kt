package com.noop.alarm

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Calendar

/**
 * Per-day scheduling for the PHONE smart alarm (distinct from com.noop.ui.SmartAlarmWeekdayTest,
 * which covers the STRAP alarm): the Mon…Sun circles that let a day be switched off
 * without disabling the alarm and having to remember to switch it back on.
 *
 * Covers [SmartAlarmScheduler.advanceToEnabledDay], which is the whole of the day-selection logic —
 * `arm` wraps it around an AlarmManager call that a JVM test cannot exercise, so the decision is
 * factored out and pinned here instead. Fixtures use a fixed date so a Sunday case stays a Sunday case
 * whatever day the suite runs on.
 */
class PhoneAlarmWeekdayTest {

    /** 2026-08-24 is a Monday. Calendar.DAY_OF_WEEK: 1=Sun … 7=Sat. */
    private fun mondayAt(hour: Int = 7): Calendar = Calendar.getInstance().apply {
        set(2026, Calendar.AUGUST, 24, hour, 0, 0)
        set(Calendar.MILLISECOND, 0)
    }

    /** The fixture must actually be the day the tests below assume. */
    @Test fun fixtureIsAMonday() {
        assertEquals(Calendar.MONDAY, mondayAt().get(Calendar.DAY_OF_WEEK))
    }

    /**
     * EMPTY = every day. This is the backward-compatible default: every existing install has no weekday
     * key set, so an empty set must leave the day exactly as computed or the feature would silently
     * re-schedule everyone's alarm on upgrade.
     */
    @Test fun emptySetMeansEveryDayAndDoesNotMoveTheDay() {
        val cal = mondayAt()
        SmartAlarmScheduler.advanceToEnabledDay(cal, emptySet())
        assertEquals(Calendar.MONDAY, cal.get(Calendar.DAY_OF_WEEK))
        assertEquals(24, cal.get(Calendar.DAY_OF_MONTH))
    }

    /** A day that IS selected is left alone — no gratuitous shifting. */
    @Test fun anEnabledDayIsNotMoved() {
        val cal = mondayAt()
        SmartAlarmScheduler.advanceToEnabledDay(cal, setOf(Calendar.MONDAY, Calendar.FRIDAY))
        assertEquals(Calendar.MONDAY, cal.get(Calendar.DAY_OF_WEEK))
        assertEquals(24, cal.get(Calendar.DAY_OF_MONTH))
    }

    /** A disabled day rolls forward to the next selected one, and to the NEAREST such day. */
    @Test fun aDisabledDayAdvancesToTheNextSelectedDay() {
        val cal = mondayAt()
        SmartAlarmScheduler.advanceToEnabledDay(cal, setOf(Calendar.WEDNESDAY, Calendar.SATURDAY))
        assertEquals(Calendar.WEDNESDAY, cal.get(Calendar.DAY_OF_WEEK))
        assertEquals(26, cal.get(Calendar.DAY_OF_MONTH))   // Mon 24 → Wed 26, not Sat
    }

    /** Wrapping the week end: from Monday, a Sunday-only alarm lands six days out, not never. */
    @Test fun itWrapsAroundTheWeekEnd() {
        val cal = mondayAt()
        SmartAlarmScheduler.advanceToEnabledDay(cal, setOf(Calendar.SUNDAY))
        assertEquals(Calendar.SUNDAY, cal.get(Calendar.DAY_OF_WEEK))
        assertEquals(30, cal.get(Calendar.DAY_OF_MONTH))   // Mon 24 → Sun 30
    }

    /** The time of day survives a day shift — only the DATE moves. */
    @Test fun advancingPreservesTheWakeTime() {
        val cal = mondayAt(hour = 6).apply { set(Calendar.MINUTE, 45) }
        SmartAlarmScheduler.advanceToEnabledDay(cal, setOf(Calendar.THURSDAY))
        assertEquals(Calendar.THURSDAY, cal.get(Calendar.DAY_OF_WEEK))
        assertEquals(6, cal.get(Calendar.HOUR_OF_DAY))
        assertEquals(45, cal.get(Calendar.MINUTE))
    }

    /**
     * An unreachable set returns the unshifted day rather than spinning. [SmartAlarmStore.weekdays]
     * filters to 1..7 so this is unreachable through the store, but the guard is on the
     * safety-critical scheduling path: a wrong-day alarm is recoverable, a hung scheduler is not.
     */
    @Test fun anUnreachableSetTerminatesInsteadOfSpinning() {
        val cal = mondayAt()
        SmartAlarmScheduler.advanceToEnabledDay(cal, setOf(99))
        assertEquals(24 + 7, cal.get(Calendar.DAY_OF_MONTH))   // bounded at 7 hops, then gives up
    }
}
