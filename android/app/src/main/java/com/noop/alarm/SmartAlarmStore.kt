package com.noop.alarm

import android.content.Context
import android.content.SharedPreferences

/**
 * Persisted state for the PHONE-based smart alarm (#207).
 *
 * This is deliberately SEPARATE from the strap's firmware buzz-alarm (NoopPrefs.smartAlarm*, which
 * arms the WHOOP itself). This one is a guaranteed phone alarm: a hard OS alarm is scheduled at the
 * LATEST edge of the wake window via AlarmManager, and the overnight sleep watcher may only move it
 * EARLIER inside the window when it detects light sleep — it can never cancel the fallback. So the
 * user is woken even if Bluetooth drops, no light sleep is found, or the app is killed.
 *
 * Times are stored as minutes since local midnight. The "target" is the EARLIEST the user wants to
 * be woken; [windowMinutes] is how much later the hard deadline sits (e.g. target 06:30 + 30 min
 * window = guaranteed wake by 07:00, with the smart logic allowed to fire any time from 06:30).
 *
 * Single-user, on-device. Mirrors the macOS UserDefaults pattern; nothing is ever sent off-device.
 */
class SmartAlarmStore(private val prefs: SharedPreferences) {

    /** Master enable. Default OFF (every automation in NOOP is opt-in). */
    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(v) = prefs.edit().putBoolean(KEY_ENABLED, v).apply()

    /** Earliest acceptable wake time, minutes since midnight. Default 06:30. */
    var targetMinutes: Int
        get() = prefs.getInt(KEY_TARGET, DEFAULT_TARGET).coerceIn(0, MINUTES_PER_DAY - 1)
        set(v) = prefs.edit().putInt(KEY_TARGET, v.coerceIn(0, MINUTES_PER_DAY - 1)).apply()

    /** Window length in minutes — how long after [targetMinutes] the guaranteed hard deadline sits.
     *  Clamped 5..60; default 30. A 0 window would collapse smart + fallback into one exact alarm,
     *  so we keep a floor that leaves the watcher room to find a lighter phase. */
    var windowMinutes: Int
        get() = prefs.getInt(KEY_WINDOW, DEFAULT_WINDOW).coerceIn(WINDOW_MIN, WINDOW_MAX)
        set(v) = prefs.edit().putInt(KEY_WINDOW, v.coerceIn(WINDOW_MIN, WINDOW_MAX)).apply()

    /** Days the phone alarm fires on (`Calendar.DAY_OF_WEEK`: 1=Sun … 7=Sat).
     *
     *  EMPTY MEANS EVERY DAY — the backward-compatible default, so an existing install with no key set
     *  keeps firing daily exactly as before. Only 1..7 survive a load, so a corrupted entry cannot
     *  schedule a bogus day. Same encoding and same empty-set semantics as the STRAP alarm's
     *  `NoopPrefs.smartAlarmWeekdays`, deliberately: the two are edited by the same
     *  `AlarmWeekdayPicker`, and a user toggling identical-looking circles on one screen would not
     *  forgive them meaning different things.
     *
     *  The day tested is the one the HARD DEADLINE lands on — the morning you are actually woken —
     *  not the window's opening edge, which can sit on the previous date when the window crosses
     *  midnight. See `SmartAlarmScheduler.arm`. */
    var weekdays: Set<Int>
        get() = prefs.getStringSet(KEY_WEEKDAYS, emptySet())
            ?.mapNotNull { it.toIntOrNull() }?.filter { it in 1..7 }?.toSet() ?: emptySet()
        set(v) = prefs.edit()
            .putStringSet(KEY_WEEKDAYS, v.filter { it in 1..7 }.map { it.toString() }.toSet())
            .apply()

    /** The wall-clock epoch (ms) of the currently-scheduled HARD deadline, or 0 if none. Persisted so
     *  the boot receiver can re-arm the exact alarm after a restart without recomputing intent. */
    var scheduledDeadlineMs: Long
        get() = prefs.getLong(KEY_DEADLINE_MS, 0L)
        set(v) = prefs.edit().putLong(KEY_DEADLINE_MS, v).apply()

    /** The earliest epoch (ms) the smart logic may fire (the window's opening edge), for the watcher. */
    var scheduledWindowStartMs: Long
        get() = prefs.getLong(KEY_WINDOW_START_MS, 0L)
        set(v) = prefs.edit().putLong(KEY_WINDOW_START_MS, v).apply()

    companion object {
        private const val PREFS = "noop_smart_alarm"
        private const val KEY_ENABLED = "alarm.enabled"
        private const val KEY_TARGET = "alarm.targetMinutes"
        private const val KEY_WINDOW = "alarm.windowMinutes"
        private const val KEY_WEEKDAYS = "alarm.weekdays"
        private const val KEY_DEADLINE_MS = "alarm.scheduledDeadlineMs"
        private const val KEY_WINDOW_START_MS = "alarm.scheduledWindowStartMs"

        const val MINUTES_PER_DAY = 24 * 60
        const val DEFAULT_TARGET = 6 * 60 + 30   // 06:30
        const val DEFAULT_WINDOW = 30
        const val WINDOW_MIN = 5
        const val WINDOW_MAX = 60

        fun from(context: Context): SmartAlarmStore =
            SmartAlarmStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
