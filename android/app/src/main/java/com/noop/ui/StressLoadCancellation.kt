package com.noop.ui

import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive

/**
 * Keep failed-read fallback behaviour, but never turn cancellation into a screen update. Check both
 * sides of the suspension because CPU work and some reads may finish after their caller is cancelled.
 * Swift twin: StressLoadCancellation.
 */
internal object StressLoadCancellation {
    suspend fun <Value> read(work: suspend () -> Value): Value? {
        coroutineContext.ensureActive()
        val value = try {
            work()
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            null
        }
        coroutineContext.ensureActive()
        return value
    }
}
