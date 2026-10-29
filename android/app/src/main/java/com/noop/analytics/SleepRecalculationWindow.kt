package com.noop.analytics

import java.time.LocalDate
import java.time.ZoneId

/** A completed local wake day, with calendar midnights and the scorer's neighboring context. */
data class SleepRecalculationWindow private constructor(
    val day: String,
    val start: Long,
    val end: Long,
    val offsetSeconds: Long,
) {
    val readStart: Long get() = start - StreamReadCap.LOOKBACK_SECONDS

    /** Swift twin: `SleepRecalculationWindow.contains`. */
    fun contains(timestamp: Long): Boolean = timestamp >= start && timestamp < end

    companion object {
        /** Swift twin: `SleepRecalculationWindow.make`. */
        fun make(day: String, timeZone: ZoneId, now: Long): SleepRecalculationWindow? = runCatching {
            val date = LocalDate.parse(day)
            require(date.toString() == day && day.length == 10 && date.year > 0)
            val midnight = date.atStartOfDay(timeZone)
            val start = midnight.toEpochSecond()
            val end = date.plusDays(1).atStartOfDay(timeZone).toEpochSecond()
            require(start < end && end <= now)
            SleepRecalculationWindow(day, start, end, midnight.offset.totalSeconds.toLong())
        }.getOrNull()
    }
}
