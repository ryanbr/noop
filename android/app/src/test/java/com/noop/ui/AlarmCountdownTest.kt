package com.noop.ui

import com.noop.alarm.SmartAlarmScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * The Alarms hero countdown ("Alarm in 17 hours 47 minutes", with the date beneath it).
 *
 * Twin of the Apple `AlarmWakeTimeLabellingTests` countdown cases. The invariant on both platforms is the
 * same: the readout resolves through the SAME pure function the scheduler arms from, takes the per-day
 * overrides, and is not shown at all when nothing will actually fire. A countdown is a promise.
 */
class AlarmCountdownTest {

    /**
     * An override day counts down to ITS deadline, not the default one.
     *
     * This is the behaviour behind the display: a day whose wake was moved has a different deadline, and a
     * countdown resolved from the default would be wrong on exactly the days someone took the trouble to
     * change. `nextDeadline` is pure but for the clock, so it pins without an AlarmManager.
     */
    @Test fun anOverrideDayCountsDownToItsOwnDeadline() {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        // Wednesday 2026-09-16, 09:00 UTC. Saturday only, base 06:30 + 30m window = 07:00,
        // but Saturday's wake is overridden to 20:00, so its deadline is 20:30.
        cal.set(2026, Calendar.SEPTEMBER, 16, 9, 0, 0)
        cal.set(Calendar.MILLISECOND, 0)
        val next = SmartAlarmScheduler.nextDeadline(
            now = cal,
            weekdays = setOf(Calendar.SATURDAY),
            windowMinutes = 30,
            targetForDay = { dow -> if (dow == Calendar.SATURDAY) 20 * 60 else 6 * 60 + 30 },
        )
        assertNotNull("a reachable Saturday must resolve", next)
        assertEquals(Calendar.SATURDAY, next!!.get(Calendar.DAY_OF_WEEK))
        assertEquals(20, next.get(Calendar.HOUR_OF_DAY))
        assertEquals(30, next.get(Calendar.MINUTE))
    }

    /** Without an override the deadline is the default wake plus the window, which is what the card promises. */
    @Test fun anUntouchedDayUsesTheDefaultWakePlusTheWindow() {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.set(2026, Calendar.SEPTEMBER, 16, 9, 0, 0)
        cal.set(Calendar.MILLISECOND, 0)
        val next = SmartAlarmScheduler.nextDeadline(
            now = cal,
            weekdays = emptySet(),
            windowMinutes = 30,
            targetForDay = { 6 * 60 + 30 },
        )
        assertNotNull(next)
        assertEquals(7, next!!.get(Calendar.HOUR_OF_DAY))
        assertEquals(0, next.get(Calendar.MINUTE))
    }

    /**
     * The countdown must come from the scheduler's own resolver, take the overrides, and carry the gate.
     *
     * Source-asserted because a Composable reading `LocalContext` and a live clock has no unit seam, the
     * same reason `ChargingAndReleaseTest` reads source.
     *
     * The gate is the part worth pinning. Without the exact-alarm permission the OS alarm is never
     * scheduled, and the card already carries a warning saying so. A countdown rendered above that warning
     * would promise a wake that cannot happen, which is the same defect the Apple twin hit with a 5/MG
     * that arms nothing.
     */
    @Test fun theCountdownResolvesThroughTheSchedulerAndIsGatedOnTheAlarmBeingReal() {
        val src = screenSource()
        val start = src.indexOf("private fun alarmCountdown(")
        if (start < 0) throw AssertionError("alarmCountdown not found in SmartAlarmScreen.kt")
        val body = src.substring(start, src.indexOf("\n}", start))
        assertTrue(
            "the countdown must use the scheduler's own next-deadline resolver:\n$body",
            body.contains("SmartAlarmScheduler.nextDeadline("),
        )
        assertTrue(
            "the per-day overrides must reach it, or override days count to the wrong time",
            src.contains("targetForDay = { phoneAlarmDayOverrides[it] ?: targetMinutes }"),
        )
        assertTrue(
            "no countdown without the exact-alarm permission: the OS alarm is not scheduled at all",
            src.contains("armed = enabled && canSchedule"),
        )
        assertTrue(
            "an unarmed alarm must produce no readout rather than a wrong one",
            body.contains("if (!armed) return null"),
        )
    }

    /**
     * The card's window figures and its countdown must resolve from ONE clock.
     *
     * `nextWindowStartMinutes` was keyed only on the settings, so it read the clock once and stayed pinned
     * to the instant the screen opened while the countdown moved with the tick. Left open across the fire
     * time, the hero then read "06:30 -> 07:00" for today above a countdown already naming tomorrow. Two
     * readouts of one fact that can disagree is the defect this whole screen has been fixing.
     */
    @Test fun theWindowFiguresAndTheCountdownShareOneClock() {
        val src = screenSource()
        assertTrue(
            "the window figures must re-resolve on the tick, not stay pinned to the opening instant",
            src.contains("nowMs, targetMinutes, windowMinutes, phoneAlarmWeekdays, phoneAlarmDayOverrides,"),
        )
        assertTrue(
            "and they must resolve FROM that tick, not from a fresh Calendar.getInstance()",
            src.contains("now = java.util.Calendar.getInstance().apply { timeInMillis = nowMs },"),
        )
    }

    /**
     * The countdown has to tick. Computed once at composition it would freeze at whatever it read when the
     * screen opened, which is the single failure mode a countdown has.
     */
    @Test fun theCountdownIsDrivenByAClockRatherThanComposedOnce() {
        val src = screenSource()
        assertTrue(
            "the hero needs a minute ticker feeding the countdown",
            src.contains("produceState(initialValue = System.currentTimeMillis())"),
        )
        assertTrue("the tick interval must be a minute", src.contains("delay(60_000L)"))
    }

    /**
     * The stamp adds the DATE and does not repeat the deadline time.
     *
     * That time is already on this card twice, in the figures row and in the "a backup alarm is set for
     * ..." sentence, so a third copy is noise. The day is the only thing the stamp needs to add, and it is
     * the half that settles "tonight or tomorrow". The Apple twin had the mirror of this: its alarm figure
     * was dropped from the hero row once the stamp carried the same time.
     */
    @Test fun theStampAddsTheDateWithoutRepeatingTheTime() {
        val src = screenSource()
        val start = src.indexOf("private fun alarmCountdown(")
        val body = src.substring(start, src.indexOf("\n}", start))
        assertTrue(
            "the stamp must carry the weekday and date",
            body.contains("SimpleDateFormat(\"EEE d MMM\""),
        )
        assertFalse(
            "the stamp must not repeat a time the card already shows twice",
            body.contains("ClockFormat.hourMinutePattern"),
        )
    }

    private fun screenSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ui/SmartAlarmScreen.kt")
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        throw IllegalStateException("SmartAlarmScreen.kt not found from ${System.getProperty("user.dir")}")
    }
}
