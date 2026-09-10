package com.noop.ui

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.glance.appwidget.updateAll
import com.noop.R
import com.noop.ai.AiCoach
import com.noop.ai.AiKeyStore
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * PRD-K5: the scheduled Coach morning brief (Android twin of Swift `CoachBriefScheduler`).
 *
 * A user-armed, LOCAL notification carrying today's coaching brief (readiness + training plan),
 * generated on-device via the user's already-configured Coach provider, once a day at a chosen
 * time. Tap opens the app (same convention every other NOOP notification uses — see
 * [BatteryAlertNotifier]); the full brief is stored for [CoachViewModel]/[CoachScreen] to surface.
 * No push server, no cloud — the network call is the SAME bring-your-own-key request Coach already
 * makes on every send, just user-armed on a daily WorkManager job instead of triggered by a tap.
 * Default OFF, like every NOOP automation.
 *
 * SCHEDULING — WorkManager (mirrors [DebugExportScheduler]), not AlarmManager: a brief sliding a few
 * minutes into a maintenance window is fine, and it must survive reboot/app-kill without the
 * exact-alarm permission.
 */
object CoachBriefScheduler {

    /** Unique work name so every (re)schedule + cancel addresses the SAME daily job. */
    private const val WORK_NAME = "noop_coach_brief_daily"

    /**
     * (Re)schedule the daily brief from the persisted [CoachBriefSettings]. No-op + cancels any
     * existing job when the feature is disabled. Call this on settings change and from app start so
     * the schedule self-heals after a reboot/relaunch.
     */
    fun reschedule(context: Context, settings: CoachBriefSettings = CoachBriefSettings.from(context)) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!settings.enabled) {
            wm.cancelUniqueWork(WORK_NAME)
            publishToWidgetSync(context, null)  // K10: clear the widget when the feature is turned off
            return
        }
        val initialDelayMs = delayToNextOccurrenceMs(settings.timeMinutes)
        val request = PeriodicWorkRequestBuilder<CoachBriefWorker>(1, TimeUnit.DAYS)
            .setInitialDelay(initialDelayMs, TimeUnit.MILLISECONDS)
            .build()
        // KEEP: an already-scheduled daily brief keeps its existing period anchor rather than being
        // reset every app-start. A time-of-day CHANGE goes through [applyTimeChange] instead.
        wm.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /** Force a fresh schedule (cancel then enqueue) so a changed time-of-day takes effect immediately. */
    fun applyTimeChange(context: Context, settings: CoachBriefSettings = CoachBriefSettings.from(context)) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
        reschedule(context, settings)
    }

    /** Cancel the daily brief entirely. */
    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
    }

    /**
     * Milliseconds from [nowMs] until the next wall-clock occurrence of [minuteOfDay] (today if
     * still ahead, else tomorrow). Pure + injectable so the unit test pins the arithmetic. Mirrors
     * [DebugExportScheduler.delayToNextOccurrenceMs].
     */
    fun delayToNextOccurrenceMs(minuteOfDay: Int, nowMs: Long = System.currentTimeMillis()): Long {
        val next = Calendar.getInstance().apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
            set(Calendar.MINUTE, minuteOfDay % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= nowMs) add(Calendar.DAY_OF_YEAR, 1)
        }
        return next.timeInMillis - nowMs
    }

    /**
     * The explicit "Generate now" button: always generates and stores, ignoring the once-per-day
     * dedup. Does NOT post a notification (the user is already looking at Coach) and does NOT touch
     * `lastRunDayKey`, so today's scheduled slot still fires normally. Returns the brief text, or
     * null on failure (no key/consent/network) — the caller surfaces that.
     */
    suspend fun generateNow(context: Context): String? {
        val ctx = context.applicationContext
        val provider = AiKeyStore.readProvider(ctx)
        val model = AiKeyStore.readModel(ctx, provider)
        val consent = AiKeyStore.readConsent(ctx)
        val customUrl = AiKeyStore.readCustomBaseUrl(ctx)
        val customHeader = AiKeyStore.readCustomAuthHeader(ctx)
        val includeSignals = consent && NoopPrefs.coachSignals(ctx)
        // #1304/#512 parity with CoachViewModel: thread the ACTIVE strap id so a headless generation
        // reasons off the same strap the user sees in the app, not a hardcoded canonical fallback.
        val aiCoach = AiCoach(
            WhoopRepository(WhoopDatabase.get(ctx)),
            activeStrapId = { (ctx as? com.noop.NoopApplication)?.activeDeviceId ?: WhoopRepository.WHOOP_SOURCE },
        )
        return aiCoach.generateBrief(ctx, provider, model, consent, customUrl, customHeader, includeSignals)
    }

    /** yyyy-MM-dd local-day key for the once-per-day dedup. Locale-fixed so the key is stable. */
    private fun dayKey(date: Long = System.currentTimeMillis()): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(java.util.Date(date))

    /**
     * Pure: the notification body is the brief's first non-empty line, trimmed and length-capped so
     * it fits a notification banner. Byte-identical shape to the Swift twin's `oneLineSummary`.
     */
    fun oneLineSummary(brief: String, maxLength: Int = 120): String {
        val firstLine = brief.split("\n").firstOrNull { it.isNotBlank() }?.trim() ?: brief.trim()
        if (firstLine.length <= maxLength) return firstLine
        return firstLine.take(maxLength).trimEnd() + "…"
    }

    private const val CHANNEL_ID = "noop_coach_brief"
    private const val NOTIF_ID = 4213
    private const val NOTIF_ID_UNAVAILABLE = 4214

    // K10: Widget-facing publish. Mirrors the brief into the widget's SharedPreferences so the
    // Glance widget (separate process) can render it without DB/network access. Matches the iOS
    // twin's App Group publish. Nudges Glance to recompose via WidgetSnapshotStore.push pattern.
    private const val WIDGET_BRIEF_KEY = "coachBriefText"
    private const val WIDGET_BRIEF_DATE_KEY = "coachBriefDateMs"

    /// Suspend version — called from the worker's `doWork`. Writes prefs + nudges Glance.
    private suspend fun publishToWidget(context: Context, text: String?) {
        writeBriefToWidgetPrefs(context, text)
        if (text != null) {
            runCatching { com.noop.widget.CoachBriefGlanceWidget().updateAll(context.applicationContext) }
        }
    }

    /// Non-suspend version — called from `reschedule` (disable path). Writes prefs only; the
    /// widget will pick up the cleared state on its next periodic refresh.
    private fun publishToWidgetSync(context: Context, text: String?) {
        writeBriefToWidgetPrefs(context, text)
    }

    private fun writeBriefToWidgetPrefs(context: Context, text: String?) {
        val prefs = context.getSharedPreferences("noop_widget", Context.MODE_PRIVATE)
        val e = prefs.edit()
        if (text != null) {
            e.putString(WIDGET_BRIEF_KEY, text)
            e.putLong(WIDGET_BRIEF_DATE_KEY, System.currentTimeMillis())
        } else {
            e.remove(WIDGET_BRIEF_KEY)
            e.remove(WIDGET_BRIEF_DATE_KEY)
        }
        e.apply()
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun postBrief(context: Context, text: String) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val body = oneLineSummary(text)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.coach_brief_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(
                    android.app.PendingIntent.getActivity(
                        context, 5, appLaunchIntent(context),
                        android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID, n)
        }
    }

    @SuppressLint("MissingPermission")
    private fun postUnavailable(context: Context) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.coach_brief_unavailable_title))
                .setContentText(context.getString(R.string.coach_brief_unavailable_body))
                .setContentIntent(
                    android.app.PendingIntent.getActivity(
                        context, 6, appLaunchIntent(context),
                        android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID_UNAVAILABLE, n)
        }
    }

    private fun ensureChannel(context: Context) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, context.getString(R.string.coach_brief_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = context.getString(R.string.coach_brief_channel_desc)
                },
            )
        }
    }

    /**
     * The worker that runs one scheduled brief generation: dedupes on the local day (WorkManager can
     * retry/redeliver), calls [AiCoach.generateBrief] under the persisted key/provider/consent, and
     * either posts the brief notification + stores it for the Coach screen, or posts a low-key
     * "unavailable, tap to retry" notification WITHOUT marking the day done (so the next periodic
     * run retries). Always returns success so a failed generation doesn't poison the daily chain —
     * the dedup key, not the WorkManager result, governs retry.
     */
    internal class CoachBriefWorker(
        context: Context,
        params: WorkerParameters,
    ) : CoroutineWorker(context, params) {
        override suspend fun doWork(): Result {
            val ctx = applicationContext
            val settings = CoachBriefSettings.from(ctx)
            if (!settings.enabled) return Result.success()
            if (settings.lastRunDayKey == dayKey()) return Result.success() // already ran today

            val text = generateNow(ctx)
            if (text == null) {
                postUnavailable(ctx)
                return Result.success()
            }
            settings.lastRunDayKey = dayKey()
            settings.storedBrief = text
            settings.hasUnconsumedBrief = true
            publishToWidget(ctx, text)  // K10: mirror into the widget's SharedPreferences
            postBrief(ctx, text)
            return Result.success()
        }
    }
}

/**
 * Persisted, opt-in settings for the scheduled Coach morning brief (K5). Mirrors
 * [DebugExportSettings]'s SharedPreferences shape: enable flag (default OFF) + a time-of-day in
 * minutes since local midnight, plus the dedup/tap-through state the worker and Coach screen share.
 */
class CoachBriefSettings(private val prefs: SharedPreferences) {

    /** Master enable. Default OFF. */
    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(v) = prefs.edit().putBoolean(KEY_ENABLED, v).apply()

    /** Time-of-day to generate, minutes since midnight. Clamped to a valid minute. Default 07:00. */
    var timeMinutes: Int
        get() = prefs.getInt(KEY_TIME, DEFAULT_TIME).coerceIn(0, MINUTES_PER_DAY - 1)
        set(v) = prefs.edit().putInt(KEY_TIME, v.coerceIn(0, MINUTES_PER_DAY - 1)).apply()

    /** yyyy-MM-dd of the last successfully GENERATED brief (once-per-day dedup). */
    var lastRunDayKey: String?
        get() = prefs.getString(KEY_LAST_RUN, null)
        set(v) = prefs.edit().putString(KEY_LAST_RUN, v).apply()

    /** The most recently generated full brief text, for the notification tap-through. */
    var storedBrief: String?
        get() = prefs.getString(KEY_STORED_BRIEF, null)
        set(v) = prefs.edit().putString(KEY_STORED_BRIEF, v).apply()

    /** True when a generated brief hasn't yet been surfaced in the Coach transcript. */
    var hasUnconsumedBrief: Boolean
        get() = prefs.getBoolean(KEY_UNCONSUMED, false)
        set(v) = prefs.edit().putBoolean(KEY_UNCONSUMED, v).apply()

    /** Coach reads this once (on an empty transcript) to surface the stored brief as its first
     *  message without re-generating or re-sending anything. Null when there's nothing unconsumed. */
    fun consumeStoredBrief(): String? {
        if (!hasUnconsumedBrief) return null
        val text = storedBrief ?: return null
        hasUnconsumedBrief = false
        return text
    }

    companion object {
        private const val PREFS = "noop_coach_brief"
        private const val KEY_ENABLED = "coachBrief.enabled"
        private const val KEY_TIME = "coachBrief.timeMinutes"
        private const val KEY_LAST_RUN = "coachBrief.lastRunDayKey"
        private const val KEY_STORED_BRIEF = "coachBrief.storedText"
        private const val KEY_UNCONSUMED = "coachBrief.hasUnconsumedBrief"

        const val MINUTES_PER_DAY = 24 * 60
        const val DEFAULT_TIME = 7 * 60 // 07:00 — a brief waiting when you check your phone.

        fun from(context: Context): CoachBriefSettings =
            CoachBriefSettings(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
