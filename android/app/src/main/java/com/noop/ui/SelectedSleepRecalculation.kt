package com.noop.ui

import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.SleepRecalculationWindow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex

enum class SleepRecalculationResult {
    COMPLETED, NO_SLEEP_DETECTED, INSUFFICIENT_DATA, INVALID_DATE, BUSY, DELETION_SUPPRESSED, FAILED,
}

/** Serializes the explicit action and reports only the result of the selected production scan. */
class SelectedSleepRecalculation {
    private val gate = Mutex()

    suspend fun run(
        window: SleepRecalculationWindow?,
        hasDeletedWindow: suspend (SleepRecalculationWindow) -> Boolean = { false },
        scan: suspend (SleepRecalculationWindow) -> List<IntelligenceEngine.Computed>,
    ): SleepRecalculationResult {
        if (window == null) return SleepRecalculationResult.INVALID_DATE
        if (!gate.tryLock()) return SleepRecalculationResult.BUSY
        try {
            if (hasDeletedWindow(window)) return SleepRecalculationResult.DELETION_SUPPRESSED
            val selected = scan(window).firstOrNull { it.day == window.day }
                ?: return SleepRecalculationResult.INSUFFICIENT_DATA
            return if ((selected.sleepMin ?: 0.0) > 0.0) SleepRecalculationResult.COMPLETED
                else SleepRecalculationResult.NO_SLEEP_DETECTED
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return SleepRecalculationResult.FAILED
        } finally {
            gate.unlock()
        }
    }
}
