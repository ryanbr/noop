package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #377: the Steps detail must resolve steps with the SAME precedence as the Today Steps tile —
 * a REAL on-device count wins over the motion-model estimate, which previously flat-lined at the
 * StepsEstimateEngine.MAX_DAILY_STEPS (60,000) clamp for a WHOOP 5.0 that had real steps.
 */
class StepsReadingsMergeTest {

    private fun r(day: String, v: Double, src: String) = VitalReading(day, v, src)

    @Test
    fun realWinsOverEstimateAndImportedPerDay() {
        val real = mapOf("2026-07-13" to r("2026-07-13", 9_000.0, "whoop-x-noop"))          // real @57 count
        val imported = mapOf(
            "2026-07-13" to r("2026-07-13", 8_000.0, "health-connect"),                    // loses to real
            "2026-07-10" to r("2026-07-10", 7_000.0, "apple-health"),                      // fills (no real)
        )
        val est = mapOf(
            "2026-07-13" to r("2026-07-13", 60_000.0, "whoop-x-noop"),                     // the buggy clamp — must lose
            "2026-07-11" to r("2026-07-11", 60_000.0, "whoop-x-noop"),                     // est-only day keeps est
        )
        val out = mergeStepsReadings(real, imported, est)

        // Ascending by day, one reading per day across the union.
        assertEquals(listOf("2026-07-10", "2026-07-11", "2026-07-13"), out.map { it.day })
        // The bug: the 60k estimate no longer wins a day that has a real count.
        assertEquals(9_000.0, out.first { it.day == "2026-07-13" }.value, 0.0)
        // Imported fills a day with no real count.
        assertEquals(7_000.0, out.first { it.day == "2026-07-10" }.value, 0.0)
        // The estimate still shows where there is genuinely nothing else (matches the card's "est." fallback).
        assertEquals(60_000.0, out.first { it.day == "2026-07-11" }.value, 0.0)
    }

    @Test
    fun emptyInputsYieldEmpty() {
        assertEquals(emptyList<VitalReading>(), mergeStepsReadings(emptyMap(), emptyMap(), emptyMap()))
    }

    @Test
    fun invalidHigherPrecedenceValuesYieldToTheNextValidSourceAndZeroIsObserved() {
        val real = mapOf(
            "2026-07-10" to r("2026-07-10", Double.NaN, "real"),
            "2026-07-11" to r("2026-07-11", -1.0, "real"),
        )
        val imported = mapOf(
            "2026-07-10" to r("2026-07-10", 0.0, "health-connect"),
            "2026-07-11" to r("2026-07-11", 42.0, "apple-health"),
        )

        assertEquals(
            listOf(0.0, 42.0),
            mergeStepsReadings(real, imported, emptyMap()).map { it.value },
        )
    }
}
