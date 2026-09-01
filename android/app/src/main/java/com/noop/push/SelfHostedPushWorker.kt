package com.noop.push

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.work.CoroutineWorker
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.data.WhoopDatabase
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException

internal fun persistedDeviceIndex(startDeviceIndex: Int, nextDeviceIndex: Int, retryableFailure: Boolean): Int =
    if (retryableFailure) startDeviceIndex else nextDeviceIndex
internal const val PUSH_MAX_ATTEMPTS = 32
internal fun shouldRetryPush(runAttemptCount: Int): Boolean = runAttemptCount + 1 < PUSH_MAX_ATTEMPTS
internal fun resultAfterScheduledContinuation(
    current: ListenableWorker.Result,
    scheduled: Boolean,
): ListenableWorker.Result = if (scheduled) ListenableWorker.Result.success() else current
internal fun successorOwnsEnqueueFailure(currentRequestCouldReserve: Boolean): Boolean =
    !currentRequestCouldReserve
internal fun shouldScheduleLatePendingSuccessor(willRetry: Boolean, settlementPending: Boolean): Boolean =
    !willRetry && settlementPending
internal fun isPushNetworkAvailable(
    wifiOnly: Boolean,
    isConnected: Boolean,
    isWifi: Boolean,
    isUnmetered: Boolean,
): Boolean = isConnected && (!wifiOnly || (isWifi && isUnmetered))
internal fun isPushNetworkAvailable(context: Context, wifiOnly: Boolean): Boolean {
    val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
    val network = connectivity.activeNetwork ?: return false
    val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
    return isPushNetworkAvailable(
        wifiOnly = wifiOnly,
        isConnected = true,
        isWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
        isUnmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
    )
}

/** One bounded coordinator run. Unique WorkManager work and the trigger lease keep it serial. */
class SelfHostedPushWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    private data class Decision(
        val result: Result,
        val willRetry: Boolean,
        val continueNormally: Boolean = false,
        val status: Status = Status.NONE,
        val message: String? = null,
    )

    private data class ExecutionOutcome(
        val state: Execution,
        val failure: PushFailure? = null,
    )

    private enum class Execution {
        COMPLETE,
        CONTINUE,
        RETRY_FAILURE,
        CAPABILITY_TERMINAL_FAILURE,
        TERMINAL_FAILURE,
    }
    private enum class Status { NONE, SUCCESS, CONTINUING, RETRYING, FAILED }

    override suspend fun doWork(): Result {
        val settings = SelfHostedPushSettings.from(applicationContext)
        // A stale request after disable exits before lease writes, network checks, Keystore, Room, or HTTP.
        val requestId = id.toString()
        if (settings.enabledEndpoint() == null) {
            PushRunSignal.releaseReservation(applicationContext, requestId)
            return Result.success()
        }
        var ownerFinished = false
        try {
            PushRunSignal.begin(applicationContext, requestId)
            settings.recordRunning()
            var execution = ExecutionOutcome(Execution.COMPLETE)
            var decision = try {
                when (val outcome = PushWorkerGate.run(
                    enabledEndpoint = settings::enabledEndpoint,
                    networkAvailable = {
                        isPushNetworkAvailable(applicationContext, wifiOnly = settings.wifiOnly())
                    },
                    token = settings::token,
                    execute = { endpoint, token ->
                        execution = executeOnce(settings, endpoint, token)
                        execution.state == Execution.RETRY_FAILURE
                    },
                )) {
                    PushWorkerGate.Outcome.DisabledOrInvalid -> Decision(Result.success(), false)
                    PushWorkerGate.Outcome.MissingToken -> Decision(
                        Result.failure(), false, status = Status.FAILED,
                        message = applicationContext.getString(R.string.push_error_missing_token),
                    )
                    PushWorkerGate.Outcome.NetworkUnavailable -> retryOrStop(
                        applicationContext.getString(R.string.push_error_network),
                    )
                    is PushWorkerGate.Outcome.Executed -> when {
                        outcome.retry -> retryOrStop(failureMessage(execution.failure))
                        execution.state == Execution.CONTINUE -> Decision(
                            Result.success(), false, continueNormally = true, status = Status.CONTINUING,
                        )
                        execution.state == Execution.CAPABILITY_TERMINAL_FAILURE -> Decision(
                            Result.failure(), false, status = Status.FAILED,
                            message = failureMessage(execution.failure),
                        )
                        execution.state == Execution.TERMINAL_FAILURE -> Decision(
                            Result.failure(), false, status = Status.FAILED,
                            message = failureMessage(execution.failure),
                        )
                        else -> Decision(Result.success(), false, status = Status.SUCCESS)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // Deliberately generic: exception strings from TLS/HTTP stacks may include destination data.
                retryOrStop(applicationContext.getString(R.string.push_error_start))
            }
            val settlement = PushRunSignal.settle(
                applicationContext, requestId, willRetry = decision.willRetry,
            ) { pending -> recordSettledStatus(settings, decision, pending) }
            ownerFinished = true
            // Healthy pagination/device rotation is a fresh successful work item. This deliberately
            // avoids WorkManager retry/backoff, which is reserved for real network/HTTP failures.
            val needsContinuation = !decision.willRetry && (decision.continueNormally || settlement.pending)
            if (needsContinuation && !SelfHostedPushScheduler.enqueueContinuation(applicationContext)) {
                // The append Operation itself failed asynchronously. Re-arm THIS WorkRequest so
                // WorkManager's bounded runAttemptCount/backoff handles the infrastructure failure.
                val enqueueRetry = retryOrStop(applicationContext.getString(R.string.push_error_queue))
                val currentCouldReserve = PushRunSignal.reserve(applicationContext, requestId)
                if (successorOwnsEnqueueFailure(currentCouldReserve)) {
                    // The preserved pending trigger already owns QUEUED work. Do not let this old
                    // failure (especially terminal attempt 31) overwrite its status or block it.
                    return Result.success()
                }
                PushRunSignal.begin(applicationContext, requestId)
                val enqueueFailureSettlement = PushRunSignal.settle(
                    applicationContext, requestId, willRetry = enqueueRetry.willRetry,
                ) { pending -> recordSettledStatus(settings, enqueueRetry, pending) }
                if (shouldScheduleLatePendingSuccessor(
                        enqueueRetry.willRetry,
                        enqueueFailureSettlement.pending,
                    )
                ) {
                    val scheduled = SelfHostedPushScheduler.enqueueContinuation(
                        applicationContext,
                        preserveTriggerOnFailure = true,
                    )
                    // A terminal attempt must succeed only when its APPEND prerequisite was actually
                    // installed (or another owner won inside enqueueContinuation). No retry reset.
                    return resultAfterScheduledContinuation(enqueueRetry.result, scheduled)
                }
                return enqueueRetry.result
            }
            // APPEND successors depend on this WorkSpec succeeding. A fresh pending trigger must not
            // be left BLOCKED behind a terminal failure from the snapshot that preceded that trigger.
            return resultAfterScheduledContinuation(decision.result, scheduled = needsContinuation)
        } finally {
            if (!ownerFinished) runCatching {
                PushRunSignal.finish(applicationContext, requestId, willRetry = false)
            }
        }
    }

    private suspend fun executeOnce(
        settings: SelfHostedPushSettings,
        endpoint: PushEndpointPolicy.ValidEndpoint,
        token: String,
    ): ExecutionOutcome {
        val sourceId = settings.sourceId()
        // Derive progress from the exact endpoint captured by the stale-work gate. Re-reading prefs
        // here could otherwise pair an E1 HTTP request with E2 cursor state during a concurrent edit.
        val transport = PushHttpTransport(endpoint, token) { batch ->
            settings.recordCurrentStream(batch.table.wireName)
        }
        val capabilities = when (val result = transport.capabilities()) {
            is PushCapabilitiesResult.Available -> result.capabilities
            is PushCapabilitiesResult.Rejected -> {
                return if (result.retryable) {
                    ExecutionOutcome(
                        Execution.RETRY_FAILURE,
                        result.failure ?: PushFailure(PushFailureCode.NETWORK_IO),
                    )
                } else {
                    ExecutionOutcome(
                        Execution.CAPABILITY_TERMINAL_FAILURE,
                        result.failure ?: PushFailure(PushFailureCode.CAPABILITIES_INVALID),
                    )
                }
            }
        }
        runCatching { settings.recordCapabilities(endpoint, capabilities) }
        val namespace = settings.progressNamespace(
            sourceId,
            endpoint,
            capabilities.protocolVersion,
            capabilities.receiverStateId,
        )
        // Capability discovery deliberately precedes Room: unsupported streams cause no table scan,
        // snapshot allocation, encoding, or POST. An empty allowlist is a valid caught-up receiver.
        if (capabilities.isEmpty) {
            settings.saveNextDeviceIndex(namespace, 0)
            settings.saveCycleNeedsAnotherPass(namespace, false)
            settings.saveCycleHadRejection(namespace, false)
            settings.saveCycleFailure(namespace, null)
            return ExecutionOutcome(Execution.COMPLETE)
        }
        // Room is first opened here, after the stale-work, endpoint, network-policy, token and identity gates.
        val dao = WhoopDatabase.get(applicationContext).pushDao()
        val progress = EndpointScopedProgressStore(
            SharedPrefsPushProgressStore.from(applicationContext),
            namespace,
        )
        val startDeviceIndex = settings.nextDeviceIndex(namespace)
        val run = PushCoordinator(
            source = dao,
            transport = transport,
            progress = progress,
            sourceId = sourceId,
            // The real clock and zone live HERE, at the one caller that wants them, rather than as
            // defaults 35 test constructions could inherit without saying so (#1787).
            today = { LocalDate.now() },
            zoneId = ZoneId.systemDefault(),
            destinationStillCurrent = { settings.enabledEndpoint() == endpoint },
        ).pushKnownDevices(startDeviceIndex, MAX_DEVICES_PER_RUN, capabilities)
        settings.recordAcceptedBatches(
            run.acceptedBatches,
            records = run.acceptedRecords.toLong(),
        )
        if (run.hasRetryableFailure) {
            // Do not rotate away from a failing device: this WorkRequest retries the exact same
            // device with its bounded runAttemptCount. Already-acked tables remain idempotent.
            return ExecutionOutcome(
                Execution.RETRY_FAILURE,
                run.failure ?: PushFailure(PushFailureCode.NETWORK_IO),
            )
        }
        settings.saveNextDeviceIndex(
            namespace,
            persistedDeviceIndex(startDeviceIndex, run.nextDeviceIndex, retryableFailure = false),
        )
        val cycleNeedsAnotherPass = settings.cycleNeedsAnotherPass(namespace) || run.hasMoreAppendRows
        val runHadTerminalRejection = run.rejectedBatches > 0 && !run.hasRetryableFailure
        val cycleHadRejection = settings.cycleHadRejection(namespace) || runHadTerminalRejection
        val cycleFailure = settings.cycleFailure(namespace) ?: run.failure.takeIf { runHadTerminalRejection }
        val cycleCompleted = run.nextDeviceIndex == 0
        settings.saveCycleNeedsAnotherPass(namespace, if (cycleCompleted) false else cycleNeedsAnotherPass)
        // If append pagination starts another cycle, carry any terminal rejection through that cycle;
        // otherwise a rejected table alongside a full append page could later be reported as success.
        settings.saveCycleHadRejection(
            namespace,
            if (cycleCompleted && !cycleNeedsAnotherPass) false else cycleHadRejection,
        )
        settings.saveCycleFailure(
            namespace,
            if (cycleCompleted && !cycleNeedsAnotherPass) null else cycleFailure,
        )

        return when {
            !cycleCompleted || cycleNeedsAnotherPass -> {
                ExecutionOutcome(Execution.CONTINUE)
            }
            cycleHadRejection -> {
                ExecutionOutcome(
                    Execution.TERMINAL_FAILURE,
                    cycleFailure ?: PushFailure(PushFailureCode.HTTP_PROTOCOL_REJECTED),
                )
            }
            else -> {
                ExecutionOutcome(Execution.COMPLETE)
            }
        }
    }

    private fun retryOrStop(message: String): Decision =
        if (!shouldRetryPush(runAttemptCount)) {
            Decision(
                Result.failure(), false, status = Status.FAILED,
                message = applicationContext.getString(R.string.push_error_paused, message),
            )
        } else {
            Decision(
                Result.retry(), true, status = Status.RETRYING,
                message = applicationContext.getString(R.string.push_error_retrying, message),
            )
        }

    private fun failureMessage(failure: PushFailure?): String = pushFailureMessage(
        applicationContext,
        failure ?: PushFailure(PushFailureCode.NETWORK_IO),
    )

    private fun recordSettledStatus(
        settings: SelfHostedPushSettings,
        decision: Decision,
        pending: Boolean,
    ) {
        when {
            pending && !decision.willRetry -> settings.recordContinuation()
            decision.status == Status.SUCCESS -> settings.recordSuccess()
            decision.status == Status.CONTINUING -> settings.recordContinuation()
            decision.status == Status.RETRYING -> settings.recordRetrying(decision.message.orEmpty())
            decision.status == Status.FAILED -> settings.recordError(decision.message.orEmpty())
            else -> Unit
        }
    }

    private companion object {
        const val MAX_DEVICES_PER_RUN = 1
    }
}
