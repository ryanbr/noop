package com.noop.notif

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import com.noop.analytics.RestScorer
import com.noop.ui.NoopPrefs
import com.noop.ui.logicalDay
import com.noop.ui.resolveTodayRow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import java.time.ZonedDateTime
import java.util.concurrent.TimeUnit

/** Recheck a deferred recap without depending on a database write or an open Today screen. */
object MorningRecapRefresh {
    private const val WORK = "noop.morningRecapRefresh"

    fun reschedule(context: Context) {
        runCatching {
            val manager = WorkManager.getInstance(context.applicationContext)
            if (!NoopPrefs.morningReportEnabled(context)) {
                manager.cancelUniqueWork(WORK)
            } else {
                val request = PeriodicWorkRequestBuilder<MorningRecapRefreshWorker>(15, TimeUnit.MINUTES).build()
                manager.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, request)
            }
        }
    }
}

class MorningRecapRefreshWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        return runCatching {
            if (!NoopPrefs.morningReportEnabled(applicationContext)) return@runCatching Result.success()
            val now = ZonedDateTime.now()
            if (now.hour * 60 + now.minute < ScheduledReportPolicy.EARLIEST_MORNING_MINUTE) {
                return@runCatching Result.success()
            }
            val localKey = now.toLocalDate().toString()
            val logicalKey = logicalDay(now).toString()
            // Skip only when either row the resolver could select is already covered. The keys
            // normally agree after the morning floor; preserve the pre-rollover local-night case.
            if (logicalKey == localKey && NoopPrefs.reportMorningDay(applicationContext) == localKey) {
                return@runCatching Result.success()
            }
            val app = applicationContext as? NoopApplication ?: return@runCatching Result.success()
            val deviceId = app.sourceCoordinator.activeDeviceId.value ?: app.activeDeviceId
            val days = app.repository.recentDaysMergedFlow(deviceId).first()
            val row = resolveTodayRow(days, logicalKey, localKey)
            if (row?.totalSleepMin != null) {
                ScheduledReportNotifier.onMorning(
                    applicationContext, row.day, row.recovery.scorePctOrNull(),
                    RestScorer.restFromDaily(row).scorePctOrNull(), app.repository, deviceId,
                )
            }
            Result.success()
        }.getOrElse { error ->
            if (error is CancellationException) throw error
            Log.w("MorningRecapRefresh", "Deferred morning recap refresh failed", error)
            Result.success()
        }
    }
}
