package com.noop.analytics

import com.noop.data.HrSample
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Heart-rate recovery after a sufficiently intense workout (#516). Kotlin twin of
 * `StrandAnalytics/HeartRateRecovery.swift`.
 *
 * Missing post-workout coverage stays null: the engine never interpolates across a disconnect or turns
 * a missing reading into zero.
 */
object HeartRateRecovery {
    data class Result(
        val endHr: Int,
        val after1Minute: Int?,
        val after2Minutes: Int?,
        val after5Minutes: Int?,
    ) {
        val hasMeasurement: Boolean
            get() = after1Minute != null || after2Minutes != null || after5Minutes != null
    }

    const val eligibilityFractionOfMaxHr = 0.70
    const val minimumHighIntensitySeconds = 120L
    const val eligibilityLookbackSeconds = 300L
    const val cessationWindowSeconds = 30L
    const val measurementToleranceSeconds = 15L
    const val minimumSamplesPerReading = 3
    const val maximumContinuousGapSeconds = 10L

    fun calculate(samples: List<HrSample>, workoutStart: Long, workoutEnd: Long, maxHr: Double): Result? {
        if (workoutStart <= 0L || workoutEnd <= workoutStart || maxHr <= 0.0) return null
        val lowerBound = maxOf(workoutStart, workoutEnd - eligibilityLookbackSeconds)
        val upperBound = workoutEnd + 5 * 60 + measurementToleranceSeconds
        val sorted = samples
            .filter { it.ts in lowerBound..upperBound && it.bpm in 30..250 }
            .sortedWith(compareBy<HrSample> { it.ts }.thenBy { it.bpm })
        if (sorted.size < minimumSamplesPerReading) return null

        val beforeEnd = sorted.filter { it.ts <= workoutEnd }
        val threshold = maxHr * eligibilityFractionOfMaxHr
        if (sustainedSeconds(threshold, beforeEnd) < minimumHighIntensitySeconds) return null

        val cessation = beforeEnd
            .filter { it.ts >= workoutEnd - cessationWindowSeconds }
            .map { it.bpm }
        if (cessation.size < minimumSamplesPerReading) return null
        val endHr = cessation.maxOrNull() ?: return null

        fun recovery(minutes: Int): Int? {
            val target = workoutEnd + minutes * 60L
            val values = sorted.filter { abs(it.ts - target) <= measurementToleranceSeconds }.map { it.bpm }
            if (values.size < minimumSamplesPerReading) return null
            return endHr - (median(values) ?: return null)
        }

        return Result(
            endHr = endHr,
            after1Minute = recovery(1),
            after2Minutes = recovery(2),
            after5Minutes = recovery(5),
        ).takeIf { it.hasMeasurement }
    }

    private fun sustainedSeconds(threshold: Double, samples: List<HrSample>): Long {
        if (samples.size < 2) return 0L
        var currentSeconds = 0L
        var longestSeconds = 0L
        for (i in 0 until samples.lastIndex) {
            val gap = samples[i + 1].ts - samples[i].ts
            if (gap <= 0L) continue
            if (gap > maximumContinuousGapSeconds) {
                currentSeconds = 0L
                continue
            }
            if (samples[i].bpm.toDouble() < threshold) {
                currentSeconds = 0L
                continue
            }
            currentSeconds += gap
            longestSeconds = maxOf(longestSeconds, currentSeconds)
        }
        return longestSeconds
    }

    private fun median(values: List<Int>): Int? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            ((sorted[middle - 1] + sorted[middle]) / 2.0).roundToInt()
        } else {
            sorted[middle]
        }
    }
}
