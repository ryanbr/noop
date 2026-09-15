package com.noop.analytics

import java.time.LocalDate
import kotlin.math.floor

/** The eight step-detail windows. Swift twin: `StepsDetailRange`. */
enum class StepsDetailRange(val label: String) {
    WEEK("W"),
    TWO_WEEKS("2W"),
    THREE_WEEKS("3W"),
    MONTH("M"),
    THREE_MONTHS("3M"),
    SIX_MONTHS("6M"),
    YEAR("1Y"),
    ALL("ALL");

    /** Inclusive calendar-day count, or null for all history.
     * Swift twin: `StepsDetailRange.dayCount`. */
    fun dayCount(): Int? = when (this) {
        WEEK -> 7
        TWO_WEEKS -> 14
        THREE_WEEKS -> 21
        MONTH -> 30
        THREE_MONTHS -> 90
        SIX_MONTHS -> 180
        YEAR -> 365
        ALL -> null
    }

    /** Swift twin: `StepsDetailRange.granularity`. */
    internal fun granularity(): StepsDetailGranularity = when (this) {
        WEEK, TWO_WEEKS, THREE_WEEKS, MONTH -> StepsDetailGranularity.DAILY
        THREE_MONTHS -> StepsDetailGranularity.WEEKLY
        SIX_MONTHS, YEAR, ALL -> StepsDetailGranularity.MONTHLY
    }
}

/** One already-resolved daily step observation. Swift twin: `StepsDetailReading`. */
data class StepsDetailReading(val day: String, val value: Double)

/** One chart bucket, retaining the raw sum and observed-day denominator.
 * Swift twin: `StepsDetailBucket`. */
data class StepsDetailBucket(
    val key: String,
    val displayDay: String,
    val sum: Double,
    val observedDayCount: Int,
    val mean: Int,
)

internal enum class StepsDetailGranularity { DAILY, WEEKLY, MONTHLY }

/** Pure calendar projection for step-detail charts. Swift and Kotlin deliberately expose the same
 * inputs and outputs, and both are pinned by the one Android-hosted JSON oracle.
 * Swift twin: `StepsDetailDensity`. */
object StepsDetailDensity {
    /** Window, deduplicate and aggregate readings. The explicit anchor is optional so callers that
     * already know the latest valid measurement can reuse it without changing the contract.
     * Swift twin: `StepsDetailDensity.project`. */
    fun project(
        readings: List<StepsDetailReading>,
        range: StepsDetailRange,
        anchorDay: String? = null,
    ): List<StepsDetailBucket> {
        val byDay = linkedMapOf<LocalDate, Double>()
        for (reading in readings) {
            val day = strictDay(reading.day) ?: continue
            if (!reading.value.isFinite() || reading.value < 0.0) continue
            byDay[day] = reading.value
        }

        val anchor = if (anchorDay != null) strictDay(anchorDay) ?: return emptyList()
        else byDay.keys.maxOrNull() ?: return emptyList()
        val lower = range.dayCount()?.let { anchor.minusDays((it - 1).toLong()) }

        data class Accumulator(
            val key: String,
            val displayDay: String,
            var sum: Double,
            var observedDayCount: Int,
        )
        val buckets = linkedMapOf<String, Accumulator>()
        for (day in byDay.keys.sorted()) {
            if (day > anchor || (lower != null && day < lower)) continue
            val value = byDay.getValue(day)
            val identity = bucketIdentity(day, range.granularity())
            val existing = buckets[identity.first]
            if (existing == null) {
                buckets[identity.first] = Accumulator(identity.first, identity.second, value, 1)
            } else {
                existing.sum += value
                existing.observedDayCount += 1
            }
        }

        return buckets.values.sortedBy { it.displayDay }.map {
            StepsDetailBucket(
                key = it.key,
                displayDay = it.displayDay,
                sum = it.sum,
                observedDayCount = it.observedDayCount,
                mean = positiveHalfUp(it.sum / it.observedDayCount),
            )
        }
    }

    /** Parse exactly yyyy-MM-dd and reject impossible proleptic-Gregorian dates.
     * Swift twin: `StepsDetailDensity.strictDay`. */
    private fun strictDay(text: String): LocalDate? {
        if (text.length != 10 || text[4] != '-' || text[7] != '-' ||
            text.withIndex().any { (index, char) -> index !in setOf(4, 7) && char !in '0'..'9' }
        ) return null
        val year = text.substring(0, 4).toInt()
        val month = text.substring(5, 7).toInt()
        val day = text.substring(8, 10).toInt()
        if (month !in 1..12 || day !in 1..daysInMonth(year, month)) return null
        return LocalDate.of(year, month, day)
    }

    /** Proleptic-Gregorian month length. Swift twin: `StepsDetailDensity.daysInMonth`. */
    private fun daysInMonth(year: Int, month: Int): Int = when (month) {
        2 -> if (isLeapYear(year)) 29 else 28
        4, 6, 9, 11 -> 30
        else -> 31
    }

    /** Gregorian leap-year rule. Swift twin: `StepsDetailDensity.isLeapYear`. */
    private fun isLeapYear(year: Int): Boolean =
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)

    /** Canonical bucket key and period-start display anchor.
     * Swift twin: `StepsDetailDensity.bucketIdentity`. */
    private fun bucketIdentity(day: LocalDate, granularity: StepsDetailGranularity): Pair<String, String> =
        when (granularity) {
            StepsDetailGranularity.DAILY -> day.toString() to day.toString()
            StepsDetailGranularity.WEEKLY -> day.minusDays((day.dayOfWeek.value - 1).toLong()).toString().let { it to it }
            StepsDetailGranularity.MONTHLY -> day.withDayOfMonth(1).toString().let { it.substring(0, 7) to it }
        }

    /** Positive half-up rounding, independent of platform banker-rounding defaults.
     * Swift twin: `StepsDetailDensity.positiveHalfUp`. */
    private fun positiveHalfUp(value: Double): Int = floor(value + 0.5).toInt()
}
