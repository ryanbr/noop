package com.noop.widget

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import com.noop.ui.stressLocalDayWindowContaining
import java.time.ZoneId
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

    /** What one wake-up should do, as a value a test can assert without WorkManager or a Context. */
    enum class Action { Retire, Skip, Score }

    /**
     * The whole of the worker's decision, kept pure for the same reason `shouldRescore` and
     * `stampAfterAttempt` are: the parts of this that can be wrong are the conditions, not the plumbing,
     * and a Context-free predicate is the only part of a widget worker a JVM test can reach at all.
     *
     * [placed] is nullable because `stressWidgetPlacement` answers null when the LOOKUP failed rather
     * than when the answer is no. Retiring on that would cancel the schedule over a transient failure
     * with nothing left to restart it before the next app launch, so only a definite no retires.
     */
    fun action(placed: Boolean?, nowMs: Long, lastScoredAtMs: Long, intervalMs: Long): Action = when {
        placed == false -> Action.Retire
        !StressWidgetProducer.shouldRescore(nowMs, lastScoredAtMs, intervalMs) -> Action.Skip
        else -> Action.Score
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
        val nowMs = System.currentTimeMillis()
        // Skip defers to whoever scored last: the BLE service rescores on this same cadence while it is
        // running, so with background connection on the widget is already fresh and a second full pass
        // would read a day of heart-rate rows to arrive at the curve already on screen. The deferral is
        // deliberately ONE-WAY. The service reads its own in-process field and knows nothing of this
        // stamp, which is correct: its cadence is what it always was, and this worker is the new cost.
        val decided = StressWidgetRefresh.action(
            placed = WidgetSnapshotStore.stressWidgetPlacement(applicationContext),
            nowMs = nowMs,
            lastScoredAtMs = WidgetSnapshotStore.lastStressScoredAtMs(applicationContext),
            intervalMs = TimeUnit.MINUTES.toMillis(StressWidgetRefresh.INTERVAL_MINUTES),
        )
        when (decided) {
            StressWidgetRefresh.Action.Retire -> {
                StressWidgetRefresh.cancel(applicationContext)
                return Result.success()
            }
            StressWidgetRefresh.Action.Skip -> return Result.success()
            StressWidgetRefresh.Action.Score -> Unit
        }
        // The cheap gate before the expensive one. `todayCurve` already declines to re-read a day whose
        // heart rate has not moved, but its memo is a process field and a worker woken after the app was
        // killed starts with an empty one — so it would pay a full pass to rebuild the curve already on
        // screen. With background connection off no rows arrive between wakes at all, which is exactly
        // the user this feature exists for, so that pass is pure waste in the common case. Two indexed
        // queries answer it instead. An empty stored fingerprint means "no idea" and admits the pass.
        val deviceId = app.activeDeviceId
        val fingerprint = runCatching {
            val nowSeconds = nowMs / 1000L
            val window = stressLocalDayWindowContaining(nowSeconds, ZoneId.systemDefault())
            val fp = app.repository.hrFingerprintWindow(deviceId, window.fromEpochSecond, nowSeconds)
            "${fp.first}:${fp.second}:${window.day.toEpochDay()}"
        }.getOrNull()
        if (fingerprint != null && fingerprint == WidgetSnapshotStore.lastStressFingerprint(applicationContext)) {
            // Nothing new to score. The stamp still moves, so the next wake measures from this check
            // rather than from the last full pass.
            WidgetSnapshotStore.noteStressScored(applicationContext, nowMs)
            return Result.success()
        }
        val curve = StressWidgetProducer.todayCurve(app.repository, deviceId)
            ?: return Result.success()
        WidgetSnapshotStore.noteStressScored(applicationContext, nowMs)
        if (fingerprint != null) WidgetSnapshotStore.noteStressFingerprint(applicationContext, fingerprint)
        // An EMPTY curve is still published: it is a real answer about today, and the day rollover
        // relies on it to drop yesterday's line rather than leave it standing.
        WidgetSnapshotStore.pushStressOnly(applicationContext, curve.points, curve.epochDay)
        return Result.success()
    }
}
