package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import com.noop.analytics.ClockFormat
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** "Wed 4 Jun · 22:50–06:48" style trailing label from the session clock, when available. */
internal fun shortDayLabel(day: String): String =
    runCatching {
        LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }.getOrDefault(day)

internal fun clockLabel(latest: DailyMetric, session: SleepSession?, is24h: Boolean): String {
    if (session != null) return sessionClockLabel(session, is24h)
    // Fall back to the daily metric's day string, which is the night's WAKE day: sleep rows are keyed
    // by `dayString(endTs)`, "the day its night ENDS on". Subtract a day so this names the night the
    // same way [clockLabelFor] does on the branch above (#2199).
    //
    // Both branches fill ONE slot, so a night with stages and the same night without must not print
    // dates a day apart. They did before this: the session branch showed the onset and this one the
    // wake day, which agreed only for a night that began after midnight. That is the two-paths-one-
    // night shape of #2201, and it is worth keeping the two ends together rather than only the case
    // that was reported.
    //
    // `LocalDate` rather than the old SimpleDateFormat pair: that parsed the key at UTC midnight and
    // formatted it in the DEVICE zone, so west of UTC it already printed the previous day. A plain
    // calendar date has no instant to misplace.
    return runCatching {
        LocalDate.parse(latest.day).minusDays(1)
            .format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.US))
    }.getOrNull() ?: latest.day
}

/** "Wed 4 Jun · 22:50–06:48" — the night-nav header's date · onset–wake line. (#160) */
internal fun sessionClockLabel(session: SleepSession, is24h: Boolean): String =
    clockLabelFor(session.effectiveStartTs, session.endTs, is24h) // EFFECTIVE onset so an edited bedtime shows (PR #395)

/**
 * Same date · onset–wake line from explicit unix-second bounds (the #736 group-aligned bedtime).
 *
 * The DATE names the night by the EVENING IT BELONGS TO, derived as its wake day minus one, not by
 * the calendar date the sleep happened to begin on. Those agree for an ordinary night that crosses
 * midnight, and they differ for one that begins after it (#2199).
 *
 * The onset is the wrong anchor here because the carousel groups nights by `localDayString(endTs)`,
 * so each row IS one wake date. A night beginning at 00:30 has its onset on its own wake date, so
 * it printed the same date as the row above while counting correctly one row further back. Two
 * rows naming the same night is what @bartmuskala reported three times; the first two explanations,
 * including a borrowed-date defect that was real but separate (#2201), did not account for it.
 *
 * Deriving the date from the same `endTs` the row is keyed by makes a repeat impossible rather than
 * unlikely: distinct rows have distinct wake dates, so they have distinct labels.
 *
 * The times stay the true onset and wake. A night that began at 00:30 therefore reads
 * "Sat 12 Sep · 00:30 - 07:00", naming the night of Saturday-into-Sunday in the ordinary sense
 * while reporting exactly when it started and ended.
 */
internal fun clockLabelFor(onsetTs: Long, wakeTs: Long, is24h: Boolean): String {
    val timeFmt = SimpleDateFormat(ClockFormat.hourMinutePattern(is24h), Locale.US)
    val onset = Date(onsetTs * 1000L)
    val wake = Date(wakeTs * 1000L)
    // minusDays(1) on the zoned date, NOT wakeTs - 86_400: across a DST boundary the day is 23 or
    // 25 hours long and the arithmetic form lands on the wrong calendar date.
    val zone = TimeZone.getDefault().toZoneId()
    val nightDay = Instant.ofEpochSecond(wakeTs).atZone(zone).toLocalDate().minusDays(1)
    val nightDate = nightDay.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.US))
    return "$nightDate · ${timeFmt.format(onset)} - ${timeFmt.format(wake)}"
}

/** Unix seconds → "YYYY-MM-DD" in the DEVICE timezone (vs AnalyticsEngine.dayString = UTC). */
internal fun localDayString(ts: Long): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(ts * 1000L))

/**
 * Unix seconds → a local wall-clock time, in the reader's chosen clock (#1821). [is24h] comes from
 * `ClockPrefs.uses24Hour(context)` at the call site, keeping this pure and unit-testable - the same
 * shape [axisEdgeLabel] already used.
 */
internal fun clockTimeLabel(ts: Long, is24h: Boolean): String =
    SimpleDateFormat(ClockFormat.hourMinutePattern(is24h), Locale.US).format(Date(ts * 1000L))

/**
 * Hypnogram-axis EDGE label (onset / wake) at minute precision, honouring the device 12/24h setting:
 * "23:28" when the clock is 24h, "11:28 PM" when it's 12h. The [is24h] flag comes from
 * `DateFormat.is24HourFormat(context)` at the call site so this stays pure/unit-testable.
 */
internal fun axisEdgeLabel(ts: Long, is24h: Boolean): String =
    SimpleDateFormat(ClockFormat.hourMinutePattern(is24h), Locale.US).format(Date(ts * 1000L))

/**
 * Hypnogram-axis INTERIOR round-hour mark — the label is always on the hour, so it drops the minutes and
 * reads shorter than an edge label ("06:00" in 24h, "6 AM" in 12h). The narrower label lets a phone fit an
 * extra mark in the same width. Locale 12/24h via [is24h], same source as [axisEdgeLabel].
 */
internal fun axisHourLabel(ts: Long, is24h: Boolean): String =
    SimpleDateFormat(if (is24h) "HH:00" else "h a", Locale.US).format(Date(ts * 1000L))
