package com.noop.notif

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import com.noop.analytics.RestScorer
import com.noop.ui.NoopPrefs
import com.noop.ui.logicalDayKeyNow
import com.noop.ui.resolveTodayRow
import kotlinx.coroutines.flow.first
import java.time.LocalDate
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
        if (!NoopPrefs.morningReportEnabled(applicationContext)) return Result.success()
        val app = applicationContext as? NoopApplication ?: return Result.success()
        return runCatching {
            val deviceId = app.sourceCoordinator.activeDeviceId.value ?: app.activeDeviceId
            val days = app.repository.recentDaysMergedFlow(deviceId).first()
            val row = resolveTodayRow(days, logicalDayKeyNow(), LocalDate.now().toString())
            if (row?.totalSleepMin != null) {
                ScheduledReportNotifier.onMorning(
                    applicationContext, row.day, row.recovery.scorePctOrNull(),
                    RestScorer.restFromDaily(row).scorePctOrNull(), app.repository, deviceId,
                )
            }
            Result.success()
        }.getOrElse { Result.success() }
    }
}
