package com.noop.ui

import com.noop.analytics.SleepEditGuard
import java.time.ZoneId
import java.util.Calendar
import java.util.TimeZone

/**
 * The two endpoints edited by Android's sleep-time dialog (#515).
 *
 * Bed and wake changes stay in this draft until [validatedWindow] is saved, so changing one picker
 * can never persist an intermediate window against the session's stale opposite endpoint.
 */
internal data class SleepTimeEditDraft(
    val startTs: Long,
    val endTs: Long,
) {
    fun withBedCandidate(
        candidateBedTs: Long,
        nowTs: Long,
        zone: ZoneId = ZoneId.systemDefault(),
    ): SleepTimeEditDraft = copy(
        startTs = SleepEditGuard.autoCorrectedBed(
            previousBedTs = startTs,
            candidateBedTs = candidateBedTs,
            originalWakeTs = endTs,
            nowTs = nowTs,
            zone = zone,
        ),
    )

    /** Store a complete user-selected wake instant without deriving or shifting its calendar date. */
    fun withWakeCandidate(candidateWakeTs: Long): SleepTimeEditDraft =
        copy(endTs = candidateWakeTs)


    fun validatedWindow(
        nowTs: Long,
        slackSec: Long = 300L,
    ): Pair<Long, Long>? = SleepEditGuard.clampedEditWindow(startTs, endTs, nowTs, slackSec)
}

/**
 * The epoch second for an endpoint the user picked as a DATE and then a TIME.
 *
 * Both sleep endpoints are chosen date-first in the Android editor, and this is the one line of
 * arithmetic that turns those two choices into a timestamp: take [baseTs] for the fields nobody picked
 * (the zone's own offset rules), overwrite the calendar date, overwrite the time, and zero the rest.
 *
 * It exists as a named function rather than inline in two dialog callbacks because of what #2470 was.
 * The bedtime control used to replace only hour and minute on the DETECTED start, so correcting a 23:00
 * onset to 04:00 produced 04:00 on the previous day: a 28-hour draft, rejected by the 24-hour edit limit,
 * surfacing as a Save button that silently would not work. The fix is that the selected date is used, and
 * that is worth having somewhere a test can reach rather than only inside a `DatePickerDialog` callback.
 *
 * Seconds and milliseconds are zeroed so two edits that pick the same minute produce the same timestamp,
 * which the draft's equality and the 24-hour guard both compare on.
 */
internal fun sleepEndpointTs(
    baseTs: Long,
    year: Int,
    month: Int,
    dayOfMonth: Int,
    hour: Int,
    minute: Int,
    timeZone: TimeZone = TimeZone.getDefault(),
): Long {
    val cal = Calendar.getInstance(timeZone).apply {
        timeInMillis = baseTs * 1000L
        set(Calendar.YEAR, year)
        set(Calendar.MONTH, month)
        set(Calendar.DAY_OF_MONTH, dayOfMonth)
        set(Calendar.HOUR_OF_DAY, hour)
        set(Calendar.MINUTE, minute)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }
    return cal.timeInMillis / 1000L
}
