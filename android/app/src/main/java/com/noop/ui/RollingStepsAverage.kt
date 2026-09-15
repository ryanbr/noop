package com.noop.ui

import java.time.LocalDate

/** Trailing 30 calendar days, inclusive of the selected day; unrecorded days are not zero steps. */
internal fun rollingStepsAverage(readings: List<VitalReading>, through: LocalDate): Pair<Double?, Int> {
    val start = through.minusDays(29)
    val observed = readings.filter {
        val day = runCatching { LocalDate.parse(it.day) }.getOrNull()
        day != null && !day.isBefore(start) && !day.isAfter(through) && it.value.isFinite() && it.value >= 0
    }.distinctBy { it.day }
    return (observed.takeIf { it.isNotEmpty() }?.map { it.value }?.average()) to observed.size
}
