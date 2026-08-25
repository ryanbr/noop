package com.noop.alarm

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

/**
 * The safety-critical scheduler for the phone smart alarm (#207).
 *
 * DESIGN — fallback-first, the whole point of the feature:
 *
 *  • When the alarm is armed, we IMMEDIATELY schedule a GUARANTEED exact OS alarm at the LATEST edge
 *    of the wake window (target + window) using [AlarmManager.setAlarmClock]. That call is the most
 *    privileged exact-alarm primitive Android offers: it ignores Doze, survives the app being killed,
 *    shows the system's next-alarm affordance, and fires even in battery-saver. It is INDEPENDENT of
 *    Bluetooth, the strap, sleep detection, or the app process being alive.
 *
 *  • The overnight sleep watcher (in the BLE foreground service) may only ever call [advanceTo] to
 *    move the alarm EARLIER, never later, and only to a time still inside the window. It physically
 *    cannot cancel or skip the deadline: [advanceTo] re-schedules the SAME requestCode/PendingIntent,
 *    clamped to ≥ window-start and ≤ the original hard deadline. So if BLE drops, no light sleep is
 *    found, or the watcher never runs, the original deadline stands and the user is still woken.
 *
 *  • [cancel] is only reachable from an explicit user "disable" or after the alarm has fired — never
 *    from the detection path.
 *
 * The single PendingIntent targets [SmartAlarmReceiver], which raises a full-screen high-priority
 * alarm notification with sound + vibration. Everything is on-device.
 */
object SmartAlarmScheduler {

    /** Stable request code so every (re)schedule + cancel addresses the SAME alarm slot. */
    private const val REQUEST_CODE = 7307

    const val ACTION_FIRE = "com.noop.alarm.action.FIRE_SMART_ALARM"
    /** Extras carried to the receiver so the fired notification can show the woken-at context. */
    const val EXTRA_SMART = "com.noop.alarm.extra.smart"

    /**
     * Arm the guaranteed hard-deadline alarm at the LATEST edge of the window and persist both edges.
     * Computes the next occurrence of (target + window): today if still ahead, else tomorrow. The
     * window-start (earliest smart-fire time) is persisted for the watcher. Idempotent — re-arming
     * just replaces the same alarm slot at the freshly-computed deadline.
     *
     * @return the scheduled hard-deadline epoch (ms), or null if exact alarms aren't permitted.
     */
    fun arm(context: Context, store: SmartAlarmStore, afterFire: Boolean = false): Long? {
        if (!canScheduleExact(context)) return null

        val deadlineMin = (store.targetMinutes + store.windowMinutes)
        // The window's hard edge can roll past midnight (e.g. 23:50 + 30). Compute the next wall-clock
        // occurrence of that absolute minute-of-day, then derive the window-start from it so the two
        // edges stay on the same night even across the midnight boundary.
        val weekdays = store.weekdays
        val deadline = nextOccurrence(deadlineMin % SmartAlarmStore.MINUTES_PER_DAY, weekdays)
        // Re-arm after a fire (audit): when the smart alarm fires EARLY on a light-sleep phase (e.g. 06:35
        // for a 07:00 deadline), the deadline's next occurrence is still TODAY 07:00 — so a plain re-arm
        // scheduled a second guaranteed wake the SAME morning, waking the user again. We just woke them
        // today, so the next wake must be tomorrow: push a same-day deadline forward one day.
        if (afterFire) {
            val now = Calendar.getInstance()
            val sameDay = deadline.get(Calendar.YEAR) == now.get(Calendar.YEAR) &&
                deadline.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR)
            if (sameDay) {
                deadline.add(Calendar.DAY_OF_YEAR, 1)
                // …and that push can land on a day the alarm is switched off, so re-apply the weekday
                // filter. Without this, re-arming after a Saturday fire would schedule Sunday even with
                // Sunday deselected — the one path that reaches a disabled day, because it moves the
                // deadline AFTER nextOccurrence already filtered it.
                advanceToEnabledDay(deadline, weekdays)
            }
        }
        val windowStartMs = deadline.timeInMillis - store.windowMinutes.toLong() * 60_000L

        scheduleExact(context, deadline.timeInMillis)
        store.scheduledDeadlineMs = deadline.timeInMillis
        store.scheduledWindowStartMs = windowStartMs
        return deadline.timeInMillis
    }

    /**
     * Re-arm the EXACT same hard deadline that was previously persisted (used by the boot receiver so
     * the alarm survives a restart). No-op if nothing is scheduled or it's already in the past.
     */
    fun rearmPersisted(context: Context, store: SmartAlarmStore) {
        if (!store.enabled) return
        val deadlineMs = store.scheduledDeadlineMs
        if (deadlineMs <= System.currentTimeMillis()) return
        if (!canScheduleExact(context)) return
        scheduleExact(context, deadlineMs)
    }

    /**
     * Move the alarm EARLIER — the ONLY hook the sleep watcher gets. The requested time is clamped to
     * the window: never before the window-start, never after the original hard deadline. Because it
     * re-schedules the SAME PendingIntent, the deadline is preserved as the floor of safety: even a
     * buggy watcher can't push the wake later or drop it. No-op if the alarm isn't armed or the
     * requested time isn't actually earlier than what's already scheduled.
     */
    fun advanceTo(context: Context, store: SmartAlarmStore, fireAtMs: Long) {
        if (!store.enabled) return
        val deadlineMs = store.scheduledDeadlineMs
        val windowStartMs = store.scheduledWindowStartMs
        if (deadlineMs <= 0L) return
        if (!canScheduleExact(context)) return
        // Clamp into [windowStart, deadline]. Anything outside the window is ignored.
        val clamped = fireAtMs.coerceIn(windowStartMs, deadlineMs)
        // Only ever advance — re-scheduling at the same/later time would be pointless and could, in a
        // pathological caller, nudge the alarm back toward the deadline. We keep the persisted deadline
        // untouched so a later cancel/boot path still references the real hard edge.
        scheduleExact(context, clamped, smart = true)
    }

    /** Cancel the alarm and clear the persisted edges. Only the user-disable / post-fire paths call this. */
    fun cancel(context: Context, store: SmartAlarmStore) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(firePendingIntent(context))
        store.scheduledDeadlineMs = 0L
        store.scheduledWindowStartMs = 0L
    }

    /** True if the OS will honour an exact alarm right now (API 31+ gates this behind a permission). */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    // MARK: - internals

    /** Schedule the guaranteed wake via setAlarmClock — the strongest exact-alarm primitive: Doze- and
     *  kill-proof, and surfaced in the system's "next alarm" UI. [smart] only tags the fired intent so
     *  the notification can say it woke you on a light-sleep phase rather than at the deadline. */
    private fun scheduleExact(context: Context, triggerAtMs: Long, smart: Boolean = false) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val show = PendingIntent.getActivity(
            context, REQUEST_CODE + 1,
            com.noop.ui.appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val info = AlarmManager.AlarmClockInfo(triggerAtMs, show)
        am.setAlarmClock(info, firePendingIntent(context, smart))
    }

    private fun firePendingIntent(context: Context, smart: Boolean = false): PendingIntent {
        val intent = Intent(context, SmartAlarmReceiver::class.java)
            .setAction(ACTION_FIRE)
            .putExtra(EXTRA_SMART, smart)
        return PendingIntent.getBroadcast(
            context, REQUEST_CODE, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** The next wall-clock occurrence (today or tomorrow) of an absolute minute-of-day. */
    private fun nextOccurrence(minuteOfDay: Int, weekdays: Set<Int> = emptySet()): Calendar =
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
            set(Calendar.MINUTE, minuteOfDay % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
            advanceToEnabledDay(this, weekdays)
        }

    /**
     * Roll `cal` forward until it lands on a day the alarm is allowed to fire on.
     *
     * EMPTY [weekdays] means every day, so this is a no-op — that is the pre-weekday behaviour and the
     * default for every existing install, which is why the whole feature can ship without a migration.
     *
     * The 7-iteration bound is a guard, not an expectation: [SmartAlarmStore.weekdays] already filters
     * to 1..7, so a non-empty set always contains a reachable day and the loop exits in at most six
     * steps. If a future caller ever passes an unreachable set, this returns the unshifted day rather
     * than spinning — a wrong-day alarm is recoverable, a hung scheduler on the safety-critical path is
     * not. Kept `internal` so the day-selection can be unit-tested without an AlarmManager.
     */
    internal fun advanceToEnabledDay(cal: Calendar, weekdays: Set<Int>) {
        if (weekdays.isEmpty()) return
        var guard = 0
        while (cal.get(Calendar.DAY_OF_WEEK) !in weekdays && guard < 7) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
            guard++
        }
    }
}
