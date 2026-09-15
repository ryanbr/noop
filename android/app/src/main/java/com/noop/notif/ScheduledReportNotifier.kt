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
//   1. A MORNING RECAP (available Charge / Rest / HRV / resting HR / sleep) once a fresh night has
//      been processed, plus training guidance only when Charge exists.
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

    /** Fire the morning recap at most once per REPORTED NIGHT: only when enabled, a metric exists, and
     *  we haven't already posted for [reportDay]. [reportDay] is the day of the banked night the recap is
     *  FOR (the resolved today-row's `day`), NOT the phone's calendar day — keying on the calendar day made
     *  it re-fire at midnight for anyone up late, since the row still resolves to last night's until a new
     *  night is banked (#567). */
    fun shouldNotifyMorning(
        enabled: Boolean,
        metricsPresent: Boolean,
        lastNotifiedDay: String?,
        reportDay: String,
    ): Boolean = enabled && metricsPresent && lastNotifiedDay != reportDay

    /** Fire the post-workout summary only for a workout STRICTLY newer than the last one summarised, so a
     *  re-sync of the same backlog never re-notifies. [lastWorkoutTs] is 0 before the first ever. */
    fun shouldNotifyWorkout(
        enabled: Boolean,
        newestWorkoutTs: Long?,
        lastWorkoutTs: Long,
    ): Boolean = enabled && newestWorkoutTs != null && newestWorkoutTs > lastWorkoutTs

    enum class MorningTrainingBand { RECOVERY, CONTROLLED, HARDER }

    data class MorningBrief(
        val charge: Int?,
        val rest: Int?,
        val hrvMs: Int?,
        val restingHr: Int?,
        val sleepHours: Int?,
        val trainingBand: MorningTrainingBand?,
    )

    /** Pure data selection for the morning recap. Every displayed number is rounded here, and that same
     *  rounded Charge drives the recommendation band so the text can never disagree with the number. A
     *  missing Charge omits the recommendation instead of fabricating a mid-band value. */
    fun morningBrief(
        charge: Double?,
        rest: Double?,
        hrvMs: Double? = null,
        restingHr: Int? = null,
        sleepMinutes: Double? = null,
    ): MorningBrief? {
        val roundedCharge = charge?.roundToInt()
        val roundedRest = rest?.roundToInt()
        val roundedHrv = hrvMs?.roundToInt()
        val roundedSleepHours = sleepMinutes?.div(60.0)?.roundToInt()
        if (roundedCharge == null && roundedRest == null && roundedHrv == null &&
            restingHr == null && roundedSleepHours == null
        ) return null
        val trainingBand = roundedCharge?.let {
            when {
                it >= 67 -> MorningTrainingBand.HARDER
                it >= 34 -> MorningTrainingBand.CONTROLLED
                else -> MorningTrainingBand.RECOVERY
            }
        }
        return MorningBrief(roundedCharge, roundedRest, roundedHrv, restingHr, roundedSleepHours, trainingBand)
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
     * Post the morning recap if enabled and not already posted today. Every metric is optional and the
     * recommendation is omitted when Charge is absent. No-op on every path that fails the policy, so the
     * caller can fire it freely each time the days collector republishes.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onMorning(
        context: Context,
        reportDay: String,
        charge: Double?,
        rest: Double?,
        hrvMs: Double?,
        restingHr: Int?,
        sleepMinutes: Double?,
    ) {
        // reportDay is the banked night's day (the resolved today-row's `day`), NOT LocalDate.now() — the
        // calendar day rolls at midnight while the row still resolves to last night's until a new night is
        // banked, which re-fired the recap at the start of a new day for late-nighters (#567).
        val brief = ScheduledReportPolicy.morningBrief(charge, rest, hrvMs, restingHr, sleepMinutes) ?: return
        if (!ScheduledReportPolicy.shouldNotifyMorning(
                enabled = NoopPrefs.morningReportEnabled(context),
                metricsPresent = true,
                lastNotifiedDay = NoopPrefs.reportMorningDay(context),
                reportDay = reportDay,
            )
        ) return
        val copy = morningCopy(context, brief)
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            post(context, MORNING_NOTIF_ID, copy.first, copy.second)
            // Mark fired only after a successful post, so a notifications-disabled night still notifies
            // once they're re-enabled while the same night's row is showing.
            NoopPrefs.setReportMorningDay(context, reportDay)
        }
    }

    private fun morningCopy(context: Context, brief: ScheduledReportPolicy.MorningBrief): Pair<String, String> {
        val parts = ArrayList<String>(5)
        brief.charge?.let { parts.add("${context.getString(R.string.today_metric_charge)} $it") }
        brief.rest?.let { parts.add("${context.getString(R.string.today_metric_rest)} $it") }
        brief.hrvMs?.let { parts.add("${context.getString(R.string.today_metric_hrv)} $it ms") }
        brief.restingHr?.let { parts.add("${context.getString(R.string.l10n_insights_screen_rhr_04edf9b3)} $it bpm") }
        brief.sleepHours?.let { parts.add("${context.getString(R.string.today_card_sleep)} $it h") }
        val training = when (brief.trainingBand) {
            ScheduledReportPolicy.MorningTrainingBand.HARDER -> context.getString(R.string.today_readiness_primed_summary)
            ScheduledReportPolicy.MorningTrainingBand.CONTROLLED -> context.getString(R.string.today_readiness_strained_summary)
            ScheduledReportPolicy.MorningTrainingBand.RECOVERY -> context.getString(R.string.today_readiness_run_down_summary)
            null -> null
        }
        return context.getString(R.string.coach_morning_brief) to
            (parts.joinToString(" · ") + (training?.let { ". $it" } ?: ""))
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
