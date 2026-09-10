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

        // #1858: the deadline minute is per-day now, so the DAY is chosen first and its own target read
        // from it. The window start is still derived from the deadline, so the two edges stay on the same
        // night even when the window opens the previous evening.
        val weekdays = store.weekdays
        val deadline = nextDeadline(
            now = Calendar.getInstance(),
            weekdays = weekdays,
            windowMinutes = store.windowMinutes,
            afterFire = afterFire,
        ) { store.targetFor(it) } ?: run {
            // No day is reachable, so there IS no next wake — clear the persisted edges rather than
            // leaving the previous ones behind. The watcher reads exactly those two fields to decide it is
            // inside a wake window, so a stale pair is a phantom window: it would keep feeding HR to the
            // detector and could advance an alarm that no longer exists.
            //
            // Deliberately NOT the same as the `canScheduleExact` bail above. There the intent still
            // stands and the OS is only refusing right now, so the stored edges must survive for
            // `rearmPersisted` to retry. Here there is nothing to retry.
            //
            // `SmartAlarmStore.weekdays` filters to 1..7, so this is unreachable through the store today;
            // the guard is for the caller that forgets, on a path where the failure is silent.
            cancel(context, store)
            return null
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

    /**
     * The EARLIEST-wake minute of the next scheduled window (#1858) — what the guarantee card names.
     *
     * The card promises a specific time ("a backup alarm is set for 04:45"), so once wake times vary by
     * day it has to show the next one rather than the default; on a moved day the default is simply the
     * wrong number. DERIVED from [nextDeadline] rather than recomputed, so the card and the alarm cannot
     * disagree — two independent time computations drifting apart is the failure this change already had
     * to fix in two other places.
     *
     * Falls back to [defaultTarget] when no day is reachable, so the card degrades to the previous
     * behaviour rather than blanking. Pure but for the clock, so it is testable without Compose.
     */
    internal fun nextWindowStartMinutes(
        now: Calendar,
        weekdays: Set<Int>,
        windowMinutes: Int,
        defaultTarget: Int,
        targetForDay: (Int) -> Int,
    ): Int {
        val deadline = nextDeadline(now, weekdays, windowMinutes, afterFire = false, targetForDay)
            ?: return defaultTarget
        val deadlineMin = deadline.get(Calendar.HOUR_OF_DAY) * 60 + deadline.get(Calendar.MINUTE)
        return (deadlineMin - windowMinutes + SmartAlarmStore.MINUTES_PER_DAY) %
            SmartAlarmStore.MINUTES_PER_DAY
    }

    /**
     * The next hard-deadline instant, honouring PER-DAY wake times (#1858).
     *
     * Replaces the old "find the next occurrence of one minute-of-day, then roll to an enabled day":
     * with per-day targets the deadline minute is no longer a single number, so the day must be chosen
     * FIRST and its own target read from it.
     *
     * Walks candidate days forward from today. For each day the alarm is allowed to fire on, the deadline
     * is that day's own `target + window`, and the first such instant strictly in the future wins. The
     * weekday tested is therefore still the day the DEADLINE lands on — the morning you are actually
     * woken — which is what [SmartAlarmStore.weekdays] has always meant and what a person means by
     * "Monday at 04:45".
     *
     * `target + window` can roll past midnight (23:50 + 30). Taking it modulo the day places the deadline
     * on the enabled day itself and lets the WINDOW START fall on the previous evening, which is the same
     * relationship the single-time version produced.
     *
     * [afterFire] skips today outright. When the smart logic fires early — 04:35 for an 04:45 deadline —
     * today's deadline is still ahead, and re-arming onto it would wake the user a second time the same
     * morning. Skipping the day is a cleaner statement of that than adjusting a date afterwards, and it
     * cannot land on a disabled day because the loop only ever considers enabled ones.
     *
     * Pure but for the clock passed in, so every one of those cases is unit-testable without an
     * AlarmManager. Returns null only if no day is reachable, which [SmartAlarmStore.weekdays]'s 1..7
     * filter already prevents.
     */
    internal fun nextDeadline(
        now: Calendar,
        weekdays: Set<Int>,
        windowMinutes: Int,
        afterFire: Boolean = false,
        targetForDay: (Int) -> Int,
    ): Calendar? {
        for (offset in 0..7) {
            if (afterFire && offset == 0) continue
            val candidate = (now.clone() as Calendar).apply {
                add(Calendar.DAY_OF_YEAR, offset)
            }
            val dow = candidate.get(Calendar.DAY_OF_WEEK)
            if (weekdays.isNotEmpty() && dow !in weekdays) continue
            val deadlineMin =
                (targetForDay(dow) + windowMinutes) % SmartAlarmStore.MINUTES_PER_DAY
            candidate.set(Calendar.HOUR_OF_DAY, deadlineMin / 60)
            candidate.set(Calendar.MINUTE, deadlineMin % 60)
            candidate.set(Calendar.SECOND, 0)
            candidate.set(Calendar.MILLISECOND, 0)
            if (candidate.timeInMillis > now.timeInMillis) return candidate
        }
        return null
    }
}
