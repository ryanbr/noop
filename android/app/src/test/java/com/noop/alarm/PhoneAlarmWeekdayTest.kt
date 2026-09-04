package com.noop.alarm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Calendar

/**
 * Day and time selection for the PHONE smart alarm (distinct from com.noop.ui.SmartAlarmWeekdayTest,
 * which covers the STRAP alarm).
 *
 * Covers [SmartAlarmScheduler.nextDeadline], which is the whole of the scheduling decision — `arm` wraps
 * it around an AlarmManager call a JVM test cannot exercise, so the decision is factored out and pinned
 * here. Repinned from `advanceToEnabledDay` when #1858 made the deadline minute per-day: the day can no
 * longer be chosen first and the time applied afterwards, because the time is a property OF the day.
 *
 * Fixtures use a fixed date so a Sunday case stays a Sunday case whatever day the suite runs on.
 */
class PhoneAlarmWeekdayTest {

    /** 2026-08-24 is a Monday. Calendar.DAY_OF_WEEK: 1=Sun … 7=Sat. */
    private fun mondayAt(hour: Int = 5): Calendar = Calendar.getInstance().apply {
        set(2026, Calendar.AUGUST, 24, hour, 0, 0)
        set(Calendar.MILLISECOND, 0)
    }

    /** 06:30 earliest + 30 min window = a 07:00 deadline, the shipped defaults. */
    private fun deadline(
        now: Calendar,
        weekdays: Set<Int> = emptySet(),
        target: Int = 6 * 60 + 30,
        window: Int = 30,
        afterFire: Boolean = false,
        perDay: Map<Int, Int> = emptyMap(),
    ): Calendar? = SmartAlarmScheduler.nextDeadline(now, weekdays, window, afterFire) {
        perDay[it] ?: target
    }

    /** The fixture must actually be the day the tests below assume. */
    @Test fun fixtureIsAMonday() {
        assertEquals(Calendar.MONDAY, mondayAt().get(Calendar.DAY_OF_WEEK))
    }

    /**
     * EMPTY = every day, the backward-compatible default: every existing install has no weekday key set,
     * so an empty set must schedule today's own deadline rather than shifting anyone on upgrade.
     */
    @Test fun emptySetMeansEveryDay() {
        val d = deadline(mondayAt())!!
        assertEquals(Calendar.MONDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(24, d.get(Calendar.DAY_OF_MONTH))
        assertEquals(7, d.get(Calendar.HOUR_OF_DAY))
        assertEquals(0, d.get(Calendar.MINUTE))
    }

    /** A day that IS selected is used as-is — no gratuitous shifting. */
    @Test fun anEnabledDayIsNotMoved() {
        val d = deadline(mondayAt(), weekdays = setOf(Calendar.MONDAY, Calendar.FRIDAY))!!
        assertEquals(Calendar.MONDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(24, d.get(Calendar.DAY_OF_MONTH))
    }

    /** A disabled day rolls forward to the NEAREST selected one. */
    @Test fun aDisabledDayAdvancesToTheNextSelectedDay() {
        val d = deadline(mondayAt(), weekdays = setOf(Calendar.WEDNESDAY, Calendar.SATURDAY))!!
        assertEquals(Calendar.WEDNESDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(26, d.get(Calendar.DAY_OF_MONTH))   // Mon 24 → Wed 26, not Sat
    }

    /** Wrapping the week end: from Monday, a Sunday-only alarm lands six days out, not never. */
    @Test fun itWrapsAroundTheWeekEnd() {
        val d = deadline(mondayAt(), weekdays = setOf(Calendar.SUNDAY))!!
        assertEquals(Calendar.SUNDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(30, d.get(Calendar.DAY_OF_MONTH))   // Mon 24 → Sun 30
    }

    /** Today's deadline already gone ⇒ tomorrow, not a wake in the past. */
    @Test fun aPastDeadlineRollsToTheNextDay() {
        val d = deadline(mondayAt(hour = 9))!!   // 07:00 already behind us
        assertEquals(25, d.get(Calendar.DAY_OF_MONTH))
    }

    // MARK: #1858 — a different wake time on different days

    /**
     * The reported shape: 04:45 on three days, 03:30 on two others — impossible to express before, since
     * one target applied to every selected day.
     *
     * Each day's deadline is its OWN target plus the window, so Tuesday here wakes at 03:30 while the
     * default days wake at 04:45.
     */
    @Test fun aDayWithAnOverrideUsesItsOwnTime() {
        val d = deadline(
            mondayAt(),
            weekdays = setOf(Calendar.TUESDAY),
            target = 4 * 60 + 15,                                   // default 04:15 + 30 = 04:45
            perDay = mapOf(Calendar.TUESDAY to 3 * 60),             // Tue 03:00 + 30 = 03:30
        )!!
        assertEquals(Calendar.TUESDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(3, d.get(Calendar.HOUR_OF_DAY))
        assertEquals(30, d.get(Calendar.MINUTE))
    }

    /** A day with no override falls back to the single target, so setting one day never moves another. */
    @Test fun daysWithoutAnOverrideKeepTheDefault() {
        val d = deadline(
            mondayAt(),
            weekdays = setOf(Calendar.MONDAY),
            target = 4 * 60 + 15,
            perDay = mapOf(Calendar.TUESDAY to 3 * 60),   // an override for a DIFFERENT day
        )!!
        assertEquals(Calendar.MONDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(4, d.get(Calendar.HOUR_OF_DAY))
        assertEquals(45, d.get(Calendar.MINUTE))
    }

    /**
     * The nearest day wins on TIME, not on day order alone: with per-day targets an earlier day can now
     * hold a later deadline, so "next" has to be decided by the instant.
     */
    @Test fun theNearestDeadlineWinsAcrossDifferentPerDayTimes() {
        val d = deadline(
            mondayAt(hour = 5),                                   // Monday 05:00; Monday's own 04:45 is gone
            weekdays = setOf(Calendar.MONDAY, Calendar.TUESDAY),
            target = 4 * 60 + 15,
            perDay = mapOf(Calendar.TUESDAY to 3 * 60),
        )!!
        assertEquals(Calendar.TUESDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(25, d.get(Calendar.DAY_OF_MONTH))
        assertEquals(3, d.get(Calendar.HOUR_OF_DAY))
    }

    // MARK: re-arming and edges

    /**
     * After an EARLY fire the same morning's deadline is still ahead — re-arming onto it would wake the
     * user a second time. `afterFire` skips today, and because the skip happens inside the day loop it
     * can never land on a day the alarm is switched off.
     */
    @Test fun afterFiringEarlyTheNextWakeIsNotToday() {
        val d = deadline(mondayAt(hour = 4), afterFire = true)!!   // 07:00 today still ahead
        assertEquals(25, d.get(Calendar.DAY_OF_MONTH))
    }

    /** …and the skip respects the weekday set rather than blindly taking tomorrow. */
    @Test fun afterFiringTheSkipStillHonoursTheEnabledDays() {
        val d = deadline(
            mondayAt(hour = 4), weekdays = setOf(Calendar.MONDAY, Calendar.THURSDAY), afterFire = true,
        )!!
        assertEquals(Calendar.THURSDAY, d.get(Calendar.DAY_OF_WEEK))
    }

    /**
     * `target + window` can roll past midnight. The deadline stays on the ENABLED day and the window
     * opens the previous evening — the same relationship the single-time version produced.
     */
    @Test fun aWindowCrossingMidnightKeepsTheDeadlineOnTheEnabledDay() {
        val d = deadline(mondayAt(), weekdays = setOf(Calendar.MONDAY), target = 23 * 60 + 50, window = 30)!!
        assertEquals(Calendar.MONDAY, d.get(Calendar.DAY_OF_WEEK))
        assertEquals(0, d.get(Calendar.HOUR_OF_DAY))
        assertEquals(20, d.get(Calendar.MINUTE))
    }

    /** An unreachable set yields null rather than spinning — a missed alarm is recoverable, a hung
     *  scheduler on the safety-critical path is not. The store's 1..7 filter makes this unreachable in
     *  practice; the guard is for the day a caller forgets that. */
    @Test fun anUnreachableSetYieldsNothingInsteadOfSpinning() {
        assertNull(deadline(mondayAt(), weekdays = setOf(99)))
    }

    // MARK: what the guarantee card shows

    /**
     * The card names a specific time, so it must name the NEXT one. Derived from the same
     * [SmartAlarmScheduler.nextDeadline] the alarm uses, so the promise on screen and the alarm that
     * actually fires cannot drift apart — two independent time computations going stale is the failure
     * this change had to fix in the Buzz-WHOOP companion as well.
     */
    @Test fun theCardShowsTheNextWindowNotTheDefault() {
        val start = SmartAlarmScheduler.nextWindowStartMinutes(
            now = mondayAt(),
            weekdays = setOf(Calendar.TUESDAY),
            windowMinutes = 30,
            defaultTarget = 4 * 60 + 15,
        ) { mapOf(Calendar.TUESDAY to 3 * 60)[it] ?: (4 * 60 + 15) }
        assertEquals(3 * 60, start)   // Tuesday's own 03:00, not the 04:15 default
    }

    /** With no overrides it is the default, so the card is unchanged for every existing install. */
    @Test fun theCardKeepsTheDefaultWhenNothingIsOverridden() {
        val start = SmartAlarmScheduler.nextWindowStartMinutes(
            now = mondayAt(), weekdays = emptySet(), windowMinutes = 30, defaultTarget = 6 * 60 + 30,
        ) { 6 * 60 + 30 }
        assertEquals(6 * 60 + 30, start)
    }

    /** A window opening the previous evening still reports its own start, not a negative minute. */
    @Test fun theCardHandlesAWindowThatOpensBeforeMidnight() {
        val start = SmartAlarmScheduler.nextWindowStartMinutes(
            now = mondayAt(), weekdays = setOf(Calendar.MONDAY), windowMinutes = 30,
            defaultTarget = 23 * 60 + 50,
        ) { 23 * 60 + 50 }
        assertEquals(23 * 60 + 50, start)
    }

    /** Nothing schedulable degrades to the default rather than blanking the promise. */
    @Test fun theCardFallsBackWhenNoDayIsReachable() {
        val start = SmartAlarmScheduler.nextWindowStartMinutes(
            now = mondayAt(), weekdays = setOf(99), windowMinutes = 30, defaultTarget = 5 * 60,
        ) { 5 * 60 }
        assertEquals(5 * 60, start)
    }


    // MARK: wind-down fan-out (Apple parity — WindDownNudge has done this since #554)

    /** The weekly anchor lands on the requested weekday at the requested minute. */
    @Test fun theWeeklyNudgeAnchorLandsOnItsWeekday() {
        val at = WindDownScheduler.nextWeeklyOccurrence(21 * 60 + 15, Calendar.THURSDAY, mondayAt())
        assertEquals(Calendar.THURSDAY, at.get(Calendar.DAY_OF_WEEK))
        assertEquals(21, at.get(Calendar.HOUR_OF_DAY))
        assertEquals(15, at.get(Calendar.MINUTE))
        assertEquals(27, at.get(Calendar.DAY_OF_MONTH))   // Mon 24 → Thu 27
    }

    /** Today counts only while its minute is still ahead. */
    @Test fun todayCountsWhenItsMinuteHasNotPassed() {
        val at = WindDownScheduler.nextWeeklyOccurrence(21 * 60, Calendar.MONDAY, mondayAt(hour = 5))
        assertEquals(24, at.get(Calendar.DAY_OF_MONTH))
    }

    /** …and rolls a full week once it has, rather than scheduling a nudge in the past. */
    @Test fun aPassedMinuteRollsAWholeWeek() {
        val at = WindDownScheduler.nextWeeklyOccurrence(4 * 60, Calendar.MONDAY, mondayAt(hour = 9))
        assertEquals(31, at.get(Calendar.DAY_OF_MONTH))   // Mon 24 → Mon 31
    }


    /**
     * An EARLY wake puts its wind-down on the previous EVENING, so the nudge must be pinned to that day —
     * not to the day you wake on.
     *
     * The reported schedule is exactly this shape: a 03:30 wake with an 8 h need and a 30 min lead puts
     * the nudge at 19:00 the night before. Pinning it to the wake's own weekday would fire it eight hours
     * AFTER the wake it exists to precede, pointing at the next day's wake — which per-day times mean may
     * be a different hour entirely.
     *
     * Only reachable once the nudge is weekday-pinned: the single daily schedule fires at a minute-of-day
     * every day, so which day owns it was never a question.
     */
    @Test fun anEarlyWakePinsTheNudgeToThePreviousEvening() {
        val need = WindDownStore.DEFAULT_SLEEP_NEED   // 8 h
        val lead = WindDownStore.DEFAULT_LEAD         // 30 min
        // 03:30 wake ⇒ 19:00 the previous evening.
        assertEquals(-1, WindDownStore.nudgeDayShift(3 * 60 + 30, need, lead))
        // A late-morning wake keeps its nudge on the same day.
        assertEquals(0, WindDownStore.nudgeDayShift(21 * 60, need, lead))
    }

    /** Shifting a weekday wraps through the week end in both directions. */
    @Test fun theWeekdayShiftWrapsAtBothEnds() {
        assertEquals(Calendar.SATURDAY, WindDownScheduler.shiftWeekday(Calendar.SUNDAY, -1))
        assertEquals(Calendar.SUNDAY, WindDownScheduler.shiftWeekday(Calendar.MONDAY, -1))
        assertEquals(Calendar.MONDAY, WindDownScheduler.shiftWeekday(Calendar.MONDAY, 0))
        assertEquals(Calendar.SUNDAY, WindDownScheduler.shiftWeekday(Calendar.SATURDAY, 1))
    }

}
