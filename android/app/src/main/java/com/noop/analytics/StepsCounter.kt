package com.noop.analytics

import com.noop.data.StepSample

/**
 * Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
 * total ([AnalyticsEngine.analyzeDay]) and any windowed total (a manual workout's `[start, end]`, #398).
 *
 * `step_motion_counter@57` is a CUMULATIVE u16 motion counter: it climbs for both locomotion and some
 * non-step wrist motion, and wraps at 65536. On classed WHOOP 5/MG records, the increment ending at each
 * sample is counted only when the strap labels that sample walk (1) or run (2); still (0) and unknown are
 * rejected. A wholly unclassed legacy window retains the old counter-only estimate so pre-migration history
 * remains readable. The caller applies its per-user `stepTicksPerStep` calibration afterwards. The result is
 * still an estimate, not cloud/clinical parity.
 *
 * Byte-for-byte twin of the Swift `StepsCounter.stepsInWindow`.
 */
object StepsCounter {
    private val LOCOMOTION_ACTIVITY_CLASSES = setOf(1, 2)

    internal fun hasActivityClasses(samples: List<StepSample>): Boolean =
        samples.any { it.activityClass != null }

    internal fun shouldCountDelta(activityClass: Int?, hasActivityClasses: Boolean): Boolean =
        !hasActivityClasses || activityClass in LOCOMOTION_ACTIVITY_CLASSES

    /** Absolute reboot/wrap guard retained independently from the rate plausibility gate below. */
    const val MAX_STEP_DELTA = 512

    /** Four ticks/second is already 240 steps/minute. A larger one-second increment is wrist motion,
     * corruption or delayed counter publication, not plausible gait. The allowance scales with the real
     * timestamp gap so seven ticks across two seconds survive a missing 1 Hz record. */
    const val MAX_TICKS_PER_SECOND = 4

    internal fun isPlausibleDelta(previousTs: Long, currentTs: Long, delta: Int): Boolean {
        if (delta !in 1 until MAX_STEP_DELTA) return false
        val elapsed = currentTs - previousTs
        if (elapsed <= 0L) return false
        val rateAllowance = if (elapsed >= MAX_STEP_DELTA / MAX_TICKS_PER_SECOND) {
            MAX_STEP_DELTA - 1L
        } else {
            elapsed * MAX_TICKS_PER_SECOND
        }
        return delta.toLong() <= rateAllowance
    }

    /**
     * Raw wrap-aware locomotion-tick total across [samples]. When any sample carries [StepSample.activityClass],
     * each positive increment is attributed to the later sample and retained only for walk/run. When the
     * whole window is legacy-unclassed, all valid increments retain the historical counter-only fallback.
     * Sorts by `ts` internally and returns `null` for fewer than two samples or no retained movement.
     */
    fun stepsInWindow(samples: List<StepSample>): Int? {
        val sorted = samples.sortedBy { it.ts }
        if (sorted.size < 2) return null
        val hasActivityClasses = hasActivityClasses(sorted)
        var total = 0
        for (i in 1 until sorted.size) {
            val delta = (sorted[i].counter - sorted[i - 1].counter) and 0xFFFF // wrap-aware u16 increment
            val isLocomotion = shouldCountDelta(sorted[i].activityClass, hasActivityClasses)
            if (isLocomotion && isPlausibleDelta(sorted[i - 1].ts, sorted[i].ts, delta)) total += delta
        }
        return if (total > 0) total else null
    }
}
