package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent
import kotlin.math.roundToInt

// MARK: - Scheduled report notifications (#517)
//
// Two opt-in, default-OFF system notifications, no AI involved:
//   1. A MORNING RECAP (Charge + Rest) once a fresh night has been processed.
//   2. A POST-WORKOUT SUMMARY (Effort + duration + avg HR) when a newly synced workout is first seen.
//
// Neither is alarm-precise: NOOP reads the strap over BLE and scores on a ~15-minute analytics pass, so a
// report lands when the next sync + pass completes — NOT the instant you wake or finish a session. The copy
// is honest about that timing ("after your strap synced"). Everything is on-device.
//
// The pure [ScheduledReportPolicy] + the copy builders are JVM-testable (the CallAlertPolicy idiom); the
// notifier wires them to a real channel + the persisted dedupe markers in NoopPrefs. Call sites:
//   - morning recap: the AppViewModel days collector, when a new local-day row with a banked night appears.
//   - post-workout: after loadWorkouts(), when the newest workout start-ts is newer than the last fired.
// Both gates survive process death, so the app-open and (future) background call sites can't double-post.

/** Pure, JVM-testable policy + copy for the scheduled reports — no Android types, so the logic is pinned
 *  by ScheduledReportPolicyTest independently of the notification plumbing. */
object ScheduledReportPolicy {

    /** Fire the morning recap at most once per REPORTED NIGHT: only when enabled, a recap value exists, and
     *  we haven't already posted for [reportDay]. [reportDay] is the day of the banked night the recap is
     *  FOR (the resolved today-row's `day`), NOT the phone's calendar day — keying on the calendar day made
     *  it re-fire at midnight for anyone up late, since the row still resolves to last night's until a new
     *  night is banked (#567). */
    fun shouldNotifyMorning(
        enabled: Boolean,
        chargeOrRestPresent: Boolean,
        lastNotifiedDay: String?,
        reportDay: String,
    ): Boolean = enabled && chargeOrRestPresent && lastNotifiedDay != reportDay

    /** Fire the post-workout summary only for a workout STRICTLY newer than the last one summarised, so a
     *  re-sync of the same backlog never re-notifies. [lastWorkoutTs] is 0 before the first ever. */
    fun shouldNotifyWorkout(
        enabled: Boolean,
        newestWorkoutTs: Long?,
        lastWorkoutTs: Long,
    ): Boolean = enabled && newestWorkoutTs != null && newestWorkoutTs > lastWorkoutTs

    /** Title + body for the morning recap. Charge and Rest are each optional (a night can produce one
     *  without the other); absent ones are simply omitted — never shown as 0 or a guess. Returns null when
     *  neither is present (the caller shouldn't have been asked to build copy, but stay honest). */
    fun morningCopy(chargePct: Int?, restPct: Int?, hrvMs: Int? = null, restingHr: Int? = null, sleepMinutes: Int? = null): Pair<String, String>? {
        val parts = ArrayList<String>(5)
        chargePct?.let { parts.add("Charge $it") }
        restPct?.let { parts.add("Rest $it") }
        hrvMs?.let { parts.add("HRV $it ms") }
        restingHr?.let { parts.add("RHR $it bpm") }
        sleepMinutes?.let { parts.add("Sleep ${it / 60} h") }
        if (parts.isEmpty()) return null
        val title = "Daily Coach"
        val training = when (chargePct ?: 50) {
            in 67..100 -> "Training: a quality or harder session is reasonable if you feel well."
            in 34..66 -> "Training: keep it controlled; favour volume or technique over intensity."
            else -> "Training: favour recovery, easy movement and extra rest today."
        }
        val body = parts.joinToString(" · ") +
            ". $training"
        return title to body
    }

    /** Title + body for the post-workout summary. [effortDisplay] is already formatted on the user's
     *  chosen scale ("0–100" or "0–21"); [durationLabel] is e.g. "42 min". avgHr is optional — a session
     *  with no usable HR omits it rather than inventing one. */
    fun workoutCopy(
        sportLabel: String,
        effortDisplay: String,
        effortMaxLabel: String,
        durationLabel: String,
        avgHr: Int?,
    ): Pair<String, String> {
        val title = "Workout logged: $sportLabel"
        val pieces = ArrayList<String>(3)
        pieces.add("Effort $effortDisplay/$effortMaxLabel")
        pieces.add(durationLabel)
        avgHr?.let { pieces.add("avg $it bpm") }
        val body = pieces.joinToString(" · ") + ". Summarised after your strap synced."
        return title to body
    }

    /** "42 min" / "1 h 8 min" from a whole-minute duration; clamps a 0/negative span to "under a minute"
     *  so a mis-timed session never reads as "0 min". */
    fun durationLabel(minutes: Int): String = when {
        minutes <= 0 -> "under a minute"
        minutes < 60 -> "$minutes min"
        minutes % 60 == 0 -> "${minutes / 60} h"
        else -> "${minutes / 60} h ${minutes % 60} min"
    }
}

object ScheduledReportNotifier {
    private const val CHANNEL_ID = "noop_scheduled_reports"
    // #297: distinct ids so a report never silently replaces another notifier's (tagless notify()).
    // Map: 4201 connection, 4202 illness, 4203 inactivity, 4204 smart alarm, 4205/4206/4207 battery.
    private const val MORNING_NOTIF_ID = 4208
    private const val WORKOUT_NOTIF_ID = 4209

    /**
     * Post the morning recap if enabled and not already posted today. [chargePct]/[restPct] are the
     * just-computed Charge/Rest for the night (either may be null). No-op on every path that fails the
     * policy, so the caller can fire it freely each time the days collector republishes.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onMorning(context: Context, reportDay: String, chargePct: Int?, restPct: Int?, hrvMs: Int?, restingHr: Int?, sleepMinutes: Int?) {
        // reportDay is the banked night's day (the resolved today-row's `day`), NOT LocalDate.now() — the
        // calendar day rolls at midnight while the row still resolves to last night's until a new night is
        // banked, which re-fired the recap at the start of a new day for late-nighters (#567).
        if (!ScheduledReportPolicy.shouldNotifyMorning(
                enabled = NoopPrefs.morningReportEnabled(context),
                chargeOrRestPresent = chargePct != null || restPct != null,
                lastNotifiedDay = NoopPrefs.reportMorningDay(context),
                reportDay = reportDay,
            )
        ) return
        val copy = ScheduledReportPolicy.morningCopy(chargePct, restPct, hrvMs, restingHr, sleepMinutes) ?: return
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            post(context, MORNING_NOTIF_ID, copy.first, copy.second)
            // Mark fired only after a successful post, so a notifications-disabled night still notifies
            // once they're re-enabled while the same night's row is showing.
            NoopPrefs.setReportMorningDay(context, reportDay)
        }
    }

    /**
     * Post the post-workout summary for [newestWorkoutTs] if it's strictly newer than the last summarised.
     * The copy fields are pre-resolved by the caller (it owns the profile + Effort-scale + repo), so this
     * stays Android-only plumbing. No-op when disabled or the workout isn't new.
     */
    @SuppressLint("MissingPermission")
    fun onWorkout(
        context: Context,
        newestWorkoutTs: Long?,
        title: String,
        body: String,
    ) {
        if (!ScheduledReportPolicy.shouldNotifyWorkout(
                enabled = NoopPrefs.postWorkoutReportEnabled(context),
                newestWorkoutTs = newestWorkoutTs,
                lastWorkoutTs = NoopPrefs.reportLastWorkoutTs(context),
            )
        ) return
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            post(context, WORKOUT_NOTIF_ID, title, body)
            newestWorkoutTs?.let { NoopPrefs.setReportLastWorkoutTs(context, it) }
        }
    }

    /**
     * Seed the post-workout frontier to the current newest workout WITHOUT notifying — called once when the
     * user first enables the toggle, so turning it on doesn't immediately fire a summary for an old session
     * already in history. Only advances the marker forward.
     */
    fun seedWorkoutFrontier(context: Context, newestWorkoutTs: Long?) {
        if (newestWorkoutTs != null && newestWorkoutTs > NoopPrefs.reportLastWorkoutTs(context)) {
            NoopPrefs.setReportLastWorkoutTs(context, newestWorkoutTs)
        }
    }

    @SuppressLint("MissingPermission")
    private fun post(context: Context, id: Int, title: String, body: String) {
        val openApp = PendingIntent.getActivity(
            context, 3,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        NotificationManagerCompat.from(context).notify(id, n)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Daily reports",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "A morning recap and post-workout summary, after your strap syncs."
                },
            )
        }
    }
}

/** Round a 0–100 score to a whole number for display, or null if absent (never fabricate a 0). */
internal fun Double?.scorePctOrNull(): Int? = this?.roundToInt()
