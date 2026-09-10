package com.noop.alarm

import android.content.Context
import android.content.SharedPreferences

/**
 * Persisted state for the wind-down nudge (#207) — a gentle evening local notification suggesting
 * it's time to start winding down, so the user can hit their usual wake time with enough sleep.
 *
 * NON-safety-critical (unlike the wake alarm): a missed nudge has no consequence, so it uses an
 * inexact daily repeating alarm. The nudge time is DERIVED, not hand-set: usual wake time − sleep
 * need − a short lead, recomputed whenever the inputs change. Single-user, on-device.
 */
class WindDownStore(private val prefs: SharedPreferences) {

    /** Master enable. Default OFF (opt-in like every NOOP automation). */
    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(v) = prefs.edit().putBoolean(KEY_ENABLED, v).apply()

    /** Typical sleep need in minutes (default 8 h). Used to back-compute the nudge from the wake time. */
    var sleepNeedMinutes: Int
        get() = prefs.getInt(KEY_SLEEP_NEED, DEFAULT_SLEEP_NEED).coerceIn(SLEEP_MIN, SLEEP_MAX)
        set(v) = prefs.edit().putInt(KEY_SLEEP_NEED, v.coerceIn(SLEEP_MIN, SLEEP_MAX)).apply()

    /** Lead time (minutes) before bed to nudge, so winding down actually finishes by lights-out. */
    var leadMinutes: Int
        get() = prefs.getInt(KEY_LEAD, DEFAULT_LEAD).coerceIn(LEAD_MIN, LEAD_MAX)
        set(v) = prefs.edit().putInt(KEY_LEAD, v.coerceIn(LEAD_MIN, LEAD_MAX)).apply()

    /**
     * How many days BEFORE the wake day the nudge falls: 0 for the same day, -1 for the evening before.
     *
     * Only matters once the nudge is pinned to a WEEKDAY (#1858's per-day fan-out). The single daily
     * schedule never needed it — it fires at a minute-of-day every day, so which day "owns" it is not a
     * question anyone asks.
     *
     * It matters now because per-day wake times exist precisely to support EARLY wakes: a 03:30 wake with
     * an 8 h need and a 30 min lead puts the nudge at 19:00 the PREVIOUS evening. Pinning that to the
     * wake's own weekday would fire it eight hours AFTER the wake it is meant to precede — and it would be
     * pointing at the next day's wake, which may be a different time entirely.
     */
    fun nudgeDayShift(wakeMinutes: Int): Int =
        nudgeDayShift(wakeMinutes, sleepNeedMinutes, leadMinutes)

    /**
     * Minute-of-day the nudge should fire, derived from a wake time: wake − sleepNeed − lead,
     * wrapped into [0, 1440). With an 06:30 wake, 8 h need and 30 min lead this is 22:00.
     *
     * The wrap loses WHICH day that minute belongs to, which is why [nudgeDayShift] exists beside it.
     */
    fun nudgeMinuteOfDay(wakeMinutes: Int): Int {
        val raw = wakeMinutes - sleepNeedMinutes - leadMinutes
        val day = 24 * 60
        return ((raw % day) + day) % day
    }

    companion object {
        /** Pure form of [nudgeDayShift], so the day arithmetic is testable without a Context. */
        fun nudgeDayShift(wakeMinutes: Int, sleepNeedMinutes: Int, leadMinutes: Int): Int =
            Math.floorDiv(wakeMinutes - sleepNeedMinutes - leadMinutes, 24 * 60)

        private const val PREFS = "noop_wind_down"
        private const val KEY_ENABLED = "windDown.enabled"
        private const val KEY_SLEEP_NEED = "windDown.sleepNeedMinutes"
        private const val KEY_LEAD = "windDown.leadMinutes"

        const val DEFAULT_SLEEP_NEED = 8 * 60
        const val DEFAULT_LEAD = 30
        const val SLEEP_MIN = 5 * 60
        const val SLEEP_MAX = 11 * 60
        const val LEAD_MIN = 0
        const val LEAD_MAX = 120

        fun from(context: Context): WindDownStore =
            WindDownStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
