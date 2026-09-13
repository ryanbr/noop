package com.noop.widget

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import java.util.concurrent.TimeUnit

/**
 * Periodic rescore for the stress widget, so it stops depending on the app being opened (#2185).
 *
 * The widget had no refresh of its own. Both widget XMLs carry `updatePeriodMillis="0"`, so Android
 * never rebuilds them, and the only thing that pushed a snapshot was [com.noop.ble.WhoopConnectionService],
 * whose scoring sits inside a collector driven by `ble.state` and therefore ticks at the live heart-rate
 * rate. No live link meant no push: with background connection off the service is not even running, and
 * with it on a strap that is charging or out of range stops the collector just as effectively. Either way
 * a widget looked at in the morning still showed the empty state the local-day rollover correctly left it
 * in, for a day whose data was sitting in the database.
 *
 * Scoring never needed the strap. [StressWidgetProducer.todayCurve] reads banked rows; the link is what
 * puts rows there, not what turns them into a curve. So this runs with no BLE involvement at all, which
 * is exactly the case that was broken.
 */
object StressWidgetRefresh {

    private const val WORK = "noop.stressWidgetRefresh"

    /**
     * Fifteen minutes because that is WorkManager's floor AND the cadence the service already rescores
     * on, which is itself matched to the half-hour resolution the curve resolves to. Nothing here is a
     * new argument about how often stress changes.
     */
    internal const val INTERVAL_MINUTES = 15L

    /**
     * KEEP rather than REPLACE: replacing on every call would restart the period each app launch, so a
     * user who opens NOOP more often than every fifteen minutes would never reach a single run.
     *
     * Called from [StressWidgetReceiver.onEnabled] when the first widget is placed, and again at app
     * start. The second is not redundant: a widget placed by an older version fired its `onEnabled`
     * long before this scheduler existed, and would otherwise never be scheduled at all.
     */
    fun ensureScheduled(context: Context) {
        val request = PeriodicWorkRequestBuilder<StressWidgetRefreshWorker>(
            StressWidgetRefresh.INTERVAL_MINUTES, TimeUnit.MINUTES,
        ).build()
        runCatching {
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }

    /** Stop rescoring once the last stress widget is gone. */
    fun cancel(context: Context) {
        runCatching { WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK) }
    }
}

/**
 * One rescore-and-publish pass. Always returns success: a transient failure must not poison the periodic
 * chain, and there is nothing here worth retrying sooner than the next quarter hour.
 */
class StressWidgetRefreshWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as? NoopApplication ?: return Result.success()
        // Cancels itself when the last widget has gone, so an uninstalled widget stops costing a pass.
        // A NULL placement means the lookup failed rather than answering no, and cancelling on that
        // would retire the schedule over a transient failure with nothing left to restart it until the
        // next app launch; so an unknown answer works, and only a definite no stops.
        if (WidgetSnapshotStore.stressWidgetPlacement(applicationContext) == false) {
            StressWidgetRefresh.cancel(applicationContext)
            return Result.success()
        }
        // Defer to whoever scored last. The BLE service rescores on this same cadence while it is
        // running, so with background connection on the widget is already being kept fresh and a second
        // full pass here would read a day of heart-rate rows to arrive at the curve already on screen.
        // `shouldRescore` is the service's own comparison, reused rather than restated.
        val nowMs = System.currentTimeMillis()
        if (!StressWidgetProducer.shouldRescore(
                nowMs = nowMs,
                lastScoreAtMs = WidgetSnapshotStore.lastStressScoredAtMs(applicationContext),
                intervalMs = TimeUnit.MINUTES.toMillis(StressWidgetRefresh.INTERVAL_MINUTES),
            )
        ) {
            return Result.success()
        }
        val curve = StressWidgetProducer.todayCurve(app.repository, app.activeDeviceId)
            ?: return Result.success()
        WidgetSnapshotStore.noteStressScored(applicationContext, nowMs)
        // An EMPTY curve is still published: it is a real answer about today, and the day rollover
        // relies on it to drop yesterday's line rather than leave it standing.
        WidgetSnapshotStore.pushStressOnly(applicationContext, curve.points, curve.epochDay)
        return Result.success()
    }
}
