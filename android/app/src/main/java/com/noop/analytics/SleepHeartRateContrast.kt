package com.noop.analytics

/**
 * Descriptive primary-sleep vs wake HR contrast. Behavioral twin of Swift `SleepHeartRateContrast`.
 *
 * This is NOT another resting-heart-rate definition. NOOP already ships a floor-style RHR (the scoring
 * input) and collects a separate primary-session mean RHR candidate (#1174/#1188, evidence in #1169);
 * this engine leaves both untouched. It compares explicitly supplied fixed-grid wake and primary-sleep
 * HR windows and reports how the means differ.
 *
 * Descriptive wellness context only. No dipper / non-dipper / reverse-dipper / riser label, no
 * cardiovascular-risk category, and no diagnostic threshold is produced — those concepts do not transfer
 * from blood-pressure/physiology contexts to wearable HR merely because a percent difference exists.
 * Window selection is the caller's responsibility, where primary-session detection and local-time
 * semantics are available.
 */
object SleepHeartRateContrast {
    const val VALID_MIN_BPM: Double = 30.0
    const val VALID_MAX_BPM: Double = 220.0
    const val DEFAULT_MINIMUM_VALID_SAMPLES: Int = 30

    data class Result(
        val wakeMeanBpm: Double,
        val sleepMeanBpm: Double,
        /** sleep - wake; negative means lower HR during sleep. */
        val sleepMinusWakeBpm: Double,
        /** 100 * (wake - sleep) / wake. Positive means lower HR during sleep. */
        val sleepReductionPercent: Double,
        val wakeValidSamples: Int,
        val wakeTotalSamples: Int,
        val wakeCoverage: Double,
        val sleepValidSamples: Int,
        val sleepTotalSamples: Int,
        val sleepCoverage: Double,
    )

    /**
     * Compare fixed-grid wake and primary-sleep HR windows, or null when either side lacks coverage.
     *
     * Each list is expected equal-duration epochs. null is an unobserved epoch, so valid/total is a real
     * coverage fraction rather than a sample-cadence guess. Values outside 30..220 bpm are ignored and
     * never imputed — they only lower coverage. Means are unweighted across valid epochs; callers with
     * irregular raw samples should first aggregate to a declared fixed cadence.
     *
     * `minimumValidSamples` is applied independently to each window; its default mirrors the provisional
     * 30-valid-sample floor of NOOP's primary-session mean RHR experiment and is not a clinical threshold.
     */
    fun evaluate(
        wakeHR: List<Double?>,
        primarySleepHR: List<Double?>,
        minimumValidSamples: Int = DEFAULT_MINIMUM_VALID_SAMPLES,
    ): Result? {
        if (minimumValidSamples <= 0 || wakeHR.isEmpty() || primarySleepHR.isEmpty()) return null

        val wake = summarize(wakeHR)
        val sleep = summarize(primarySleepHR)
        if (wake.validCount < minimumValidSamples ||
            sleep.validCount < minimumValidSamples ||
            wake.mean <= 0.0
        ) {
            return null
        }

        val delta = sleep.mean - wake.mean
        val reduction = 100.0 * (wake.mean - sleep.mean) / wake.mean
        if (!delta.isFinite() || !reduction.isFinite()) return null

        return Result(
            wakeMeanBpm = wake.mean,
            sleepMeanBpm = sleep.mean,
            sleepMinusWakeBpm = delta,
            sleepReductionPercent = reduction,
            wakeValidSamples = wake.validCount,
            wakeTotalSamples = wakeHR.size,
            wakeCoverage = wake.validCount.toDouble() / wakeHR.size.toDouble(),
            sleepValidSamples = sleep.validCount,
            sleepTotalSamples = primarySleepHR.size,
            sleepCoverage = sleep.validCount.toDouble() / primarySleepHR.size.toDouble(),
        )
    }

    private data class Summary(val mean: Double, val validCount: Int)

    private fun summarize(values: List<Double?>): Summary {
        var sum = 0.0
        var count = 0
        for (item in values) {
            if (item == null || !item.isFinite() || item < VALID_MIN_BPM || item > VALID_MAX_BPM) continue
            sum += item
            count++
        }
        return Summary(if (count > 0) sum / count.toDouble() else 0.0, count)
    }
}
