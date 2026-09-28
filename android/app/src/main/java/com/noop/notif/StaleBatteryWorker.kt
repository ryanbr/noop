package com.noop.notif

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * The periodic wake behind the stale-battery warning (#2556).
 *
 * The live crossings run on the BLE service's state collector, which is entirely change-driven: it combines
 * `ble.state` with a Room flow and has no tick of its own. That is fine for a strap that is present, and
 * useless for the case this exists for. A strap that goes flat produces a burst of emissions while
 * reconnect is retried, all of them too early to clear the staleness window, and then nothing at all. The
 * check would decline every time it ran and never run again.
 *
 * So the wake has to come from outside the connection. It is NOT hung off `StressWidgetRefreshWorker`,
 * whose period would otherwise have done: that one is cancelled when the last stress widget is removed, so
 * battery warnings would silently depend on the wearer keeping an unrelated widget on their home screen.
 */
class StaleBatteryWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        runCatching {
            val app = applicationContext as NoopApplication
            // The SUSPEND registry accessor, not `app.activeDeviceId`: that property resolves through
            // `runBlocking` on first access, and in a worker cold start this IS the first access, so
            // reading it here would block the coroutine's thread inside a suspend function.
            val deviceId = app.deviceRegistry.activeDeviceId() ?: return@runCatching
            val last = app.repository.latestBattery(deviceId)
            BatteryAlertNotifier.onStrapNotSeen(
                applicationContext,
                lastSocPct = last?.soc?.roundToInt(),
                lastTsSec = last?.ts,
                lastCharging = last?.charging,
                nowSec = System.currentTimeMillis() / 1000L,
                // Always false here, and that is sound rather than a shortcut: a CONNECTED strap banks a
                // reading about every minute, so its last banked value can never be old enough to clear the
                // staleness window. The window is therefore its own connectivity test, and the worker does
                // not need to ask the service anything. Should a connected strap ever stop reporting for
                // that long, the message it produces is still true: it names what was last banked and when.
                connected = false,
            )
        }
        // Never Result.retry(): a missed wake is covered by the next period, and the persisted
        // once-per-reading gate means a late run cannot double-notify.
        return Result.success()
    }

    companion object {
        private const val WORK = "noop.staleBattery"

        /** Battery moves slowly and the warning is about hours of silence, so a half hour is ample. */
        const val INTERVAL_MINUTES = 30L

        /**
         * KEEP, not REPLACE, for the reason [com.noop.widget.StressWidgetRefresh] documents: replacing on
         * every launch restarts the period, so someone who opens NOOP often would never reach a run.
         */
        fun ensureScheduled(context: Context) {
            val request = PeriodicWorkRequestBuilder<StaleBatteryWorker>(
                INTERVAL_MINUTES, TimeUnit.MINUTES,
            ).build()
            runCatching {
                WorkManager.getInstance(context.applicationContext)
                    .enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, request)
            }
        }
    }
}
