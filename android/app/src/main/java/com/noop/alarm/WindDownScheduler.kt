package com.noop.alarm

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.noop.R
import com.noop.ui.appLaunchIntent
import java.util.Calendar

/**
 * The wind-down nudge (#207) — a gentle, NON-safety-critical evening local notification.
 *
 * Deliberately INEXACT: a missed wind-down nudge costs nothing, so we use a daily repeating inexact
 * alarm (no exact-alarm permission needed) rather than the privileged primitive the wake alarm uses.
 * The nudge minute is derived from the user's earliest wake time via [WindDownStore.nudgeMinuteOfDay].
 *
 * The fired notification is low-key (default importance, no full-screen, no DND bypass) — it's a
 * suggestion, not an alarm.
 */
object WindDownScheduler {

    private const val REQUEST_CODE = 7311
    const val ACTION_NUDGE = "com.noop.alarm.action.WIND_DOWN_NUDGE"
    const val CHANNEL_ID = "noop_wind_down"
    private const val NOTIF_ID = 4311

    /**
     * Schedule (or reschedule) the daily nudge at the minute derived from [wakeMinutes]. Cancels any
     * prior schedule first so a settings change doesn't stack two nudges. No-op'd by the caller when
     * the nudge is disabled (it calls [cancel] instead).
     */
    fun schedule(
        context: Context,
        store: WindDownStore,
        wakeMinutes: Int,
        perDayWake: Map<Int, Int> = emptyMap(),
    ) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // Cancel BOTH shapes first. Switching between them changes how many alarms exist, so cancelling
        // only the one about to be re-scheduled would strand the other's — seven weekly nudges left
        // running after a switch back to daily, or a stale daily one firing beside the seven.
        cancel(context)

        if (perDayWake.isEmpty()) {
            val first = nextOccurrence(store.nudgeMinuteOfDay(wakeMinutes))
            // Inexact, repeating, NOT wakeup — a wind-down reminder doesn't need to punch through Doze.
            am.setInexactRepeating(
                AlarmManager.RTC,
                first.timeInMillis,
                AlarmManager.INTERVAL_DAY,
                nudgePendingIntent(context),
            )
            return
        }

        // #1858 (Apple parity): with per-day wake times set, fan out to seven weekday-pinned nudges each
        // at that day's own time. Mirrors `WindDownNudge`'s #554 fan-out, which does exactly this with
        // seven UNCalendarNotificationTriggers — the nudge exists to be an hour before YOUR wake, so on a
        // day whose wake moved it has to move with it.
        //
        // A weekly repeat is a daily interval times seven; each day carries its own request code so the
        // seven PendingIntents are distinct rather than overwriting one another.
        for (weekday in 1..7) {
            val wake = perDayWake[weekday] ?: wakeMinutes
            // The nudge is pinned to the day it FIRES on, which is not always the day you wake on: an
            // early wake pushes it back over midnight. See [WindDownStore.nudgeDayShift].
            val nudgeWeekday = shiftWeekday(weekday, store.nudgeDayShift(wake))
            val first = nextWeeklyOccurrence(store.nudgeMinuteOfDay(wake), nudgeWeekday)
            am.setInexactRepeating(
                AlarmManager.RTC,
                first.timeInMillis,
                AlarmManager.INTERVAL_DAY * 7,
                nudgePendingIntent(context, weekday),
            )
        }
    }

    /** Cancel every shape the nudge can be scheduled in — the single daily one AND all seven weekday
     *  pins. Unconditional on purpose: the caller does not always know which shape is live, and a
     *  cancel that misses one leaves a reminder firing at a time the user has already changed. */
    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(nudgePendingIntent(context))
        for (weekday in 1..7) am.cancel(nudgePendingIntent(context, weekday))
    }

    /** Raise the low-key nudge notification. Called from [WindDownReceiver]. */
    fun fireNotification(context: Context) {
        ensureChannel(context)
        runCatching {
            val open = PendingIntent.getActivity(
                context, 0, appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle("Time to wind down")
                .setContentText("A calm hour now helps you hit your wake time well-rested.")
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .build()
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIF_ID, n)
        }
    }

    /** [weekday] null = the single daily nudge; 1..7 = that weekday's own pin, on its own request code
     *  so the seven do not collide with each other or with the daily one. */
    private fun nudgePendingIntent(context: Context, weekday: Int? = null): PendingIntent {
        val intent = Intent(context, WindDownReceiver::class.java).setAction(ACTION_NUDGE)
        return PendingIntent.getBroadcast(
            context, REQUEST_CODE + (weekday ?: 0), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Wind-down nudge", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "An optional evening reminder to start winding down before bed."
                    setShowBadge(false)
                },
            )
        }
    }

    /**
     * Move a `Calendar.DAY_OF_WEEK` by [shift] days, wrapping through the week end (1=Sun…7=Sat).
     *
     * [shift] is normally 0 or -1 — an early wake puts its wind-down on the previous evening — but the
     * arithmetic is general so a long sleep-need plus lead cannot produce an out-of-range weekday.
     */
    internal fun shiftWeekday(weekday: Int, shift: Int): Int =
        Math.floorMod(weekday - 1 + shift, 7) + 1

    /**
     * The next time [minuteOfDay] falls on [weekday] (Calendar 1=Sun…7=Sat) — the anchor for a weekly
     * repeat. Walks forward at most seven days, so today counts only if the minute is still ahead.
     *
     * `internal` so the day/time arithmetic is unit-testable without an AlarmManager, which is the whole
     * of what could go wrong here.
     */
    internal fun nextWeeklyOccurrence(
        minuteOfDay: Int,
        weekday: Int,
        now: Calendar = Calendar.getInstance(),
    ): Calendar {
        val cal = (now.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
            set(Calendar.MINUTE, minuteOfDay % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        var guard = 0
        while ((cal.get(Calendar.DAY_OF_WEEK) != weekday || cal.timeInMillis <= now.timeInMillis) &&
            guard < 8
        ) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
            guard++
        }
        return cal
    }

    private fun nextOccurrence(minuteOfDay: Int): Calendar =
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
            set(Calendar.MINUTE, minuteOfDay % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
        }
}

/** Receives the daily wind-down nudge alarm and raises the reminder notification. Inexact repeating
 *  alarms survive reboot on most OEMs, but we also re-schedule from [SmartAlarmBootReceiver] to be
 *  safe. Not exported. */
class WindDownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != WindDownScheduler.ACTION_NUDGE) return
        WindDownScheduler.fireNotification(context)
    }
}
