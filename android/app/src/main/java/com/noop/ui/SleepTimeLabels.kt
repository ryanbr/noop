package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import java.text.SimpleDateFormat
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

internal fun clockLabel(latest: DailyMetric, session: SleepSession?): String {
    if (session != null) return sessionClockLabel(session)
    // Fall back to the daily metric's day string (YYYY-MM-DD), formatted to "EEE d MMM".
    val dateFmt = SimpleDateFormat("EEE d MMM", Locale.US)
    return runCatching {
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        parser.parse(latest.day)?.let { dateFmt.format(it) }
    }.getOrNull() ?: latest.day
}

/** "Wed 4 Jun · 22:50–06:48" — the night-nav header's date · onset–wake line. (#160) */
internal fun sessionClockLabel(session: SleepSession): String =
    clockLabelFor(session.effectiveStartTs, session.endTs) // EFFECTIVE onset so an edited bedtime shows (PR #395)

/** Same date · onset–wake line from explicit unix-second bounds (the #736 group-aligned bedtime). */
internal fun clockLabelFor(onsetTs: Long, wakeTs: Long): String {
    val timeFmt = SimpleDateFormat("HH:mm", Locale.US)
    val dateFmt = SimpleDateFormat("EEE d MMM", Locale.US)
    val onset = Date(onsetTs * 1000L)
    val wake = Date(wakeTs * 1000L)
    return "${dateFmt.format(onset)} · ${timeFmt.format(onset)} - ${timeFmt.format(wake)}"
}

/** Unix seconds → "YYYY-MM-DD" in the DEVICE timezone (vs AnalyticsEngine.dayString = UTC). */
internal fun localDayString(ts: Long): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(ts * 1000L))

/** Unix seconds → a local wall-clock "HH:mm" (same 24h formatting the nav-header span uses). */
internal fun clockTimeLabel(ts: Long): String =
    SimpleDateFormat("HH:mm", Locale.US).format(Date(ts * 1000L))

/**
 * Hypnogram-axis EDGE label (onset / wake) at minute precision, honouring the device 12/24h setting:
 * "23:28" when the clock is 24h, "11:28 PM" when it's 12h. The [is24h] flag comes from
 * `DateFormat.is24HourFormat(context)` at the call site so this stays pure/unit-testable.
 */
internal fun axisEdgeLabel(ts: Long, is24h: Boolean): String =
    SimpleDateFormat(if (is24h) "HH:mm" else "h:mm a", Locale.US).format(Date(ts * 1000L))

/**
 * Hypnogram-axis INTERIOR round-hour mark — the label is always on the hour, so it drops the minutes and
 * reads shorter than an edge label ("06:00" in 24h, "6 AM" in 12h). The narrower label lets a phone fit an
 * extra mark in the same width. Locale 12/24h via [is24h], same source as [axisEdgeLabel].
 */
internal fun axisHourLabel(ts: Long, is24h: Boolean): String =
    SimpleDateFormat(if (is24h) "HH:00" else "h a", Locale.US).format(Date(ts * 1000L))
