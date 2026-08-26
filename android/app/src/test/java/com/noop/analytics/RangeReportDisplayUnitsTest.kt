package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RangeReportDisplayUnitsTests.swift.
 * Same fixtures, same assertions — cross-platform parity is the contract.
 *
 * The expected literals below are the VERBATIM stdout of the Swift twin compiled standalone
 * (`swiftc -O twin.swift`), not values re-derived here — that is what makes this an oracle rather
 * than a second opinion.
 */
class RangeReportDisplayUnitsTest {

    private val celsius = ReportDisplayUnits.STORED
    private val fahrenheit = ReportDisplayUnits(fahrenheit = true, effortFactor = 1.0)
    private val whoopAxis = ReportDisplayUnits(fahrenheit = false, effortFactor = 21.0 / 100.0)

    // The identity

    @Test
    fun storedIsTheIdentity() {
        assertFalse(ReportDisplayUnits.STORED.fahrenheit)
        assertEquals(1.0, ReportDisplayUnits.STORED.effortFactor, 1e-12)
        for (metric in ReportMetric.entries) {
            assertEquals(
                "$metric must pass through untouched under STORED",
                42.5, RangeReportEngine.displayValue(42.5, metric, celsius), 1e-12,
            )
        }
    }

    // Skin temp: a DEVIATION scales ×9/5 with no +32 offset

    @Test
    fun skinTempDeviationScalesWithoutTheOffset() {
        // The reporter's night: 0.52 °C stored, rendered 0.9 Δ°F (NOT 32.9).
        assertEquals(
            0.9359999999999999,
            RangeReportEngine.displayValue(0.52, ReportMetric.SKIN_TEMP_DEV, fahrenheit), 1e-12,
        )
        assertEquals(
            -0.9,
            RangeReportEngine.displayValue(-0.5, ReportMetric.SKIN_TEMP_DEV, fahrenheit), 1e-12,
        )
        assertEquals(
            0.0,
            RangeReportEngine.displayValue(0.0, ReportMetric.SKIN_TEMP_DEV, fahrenheit), 1e-12,
        )
        // A whole-degree deviation is 1.8 °F, never 33.8 — the +32 offset would be wrong for a delta.
        assertEquals(
            1.8,
            RangeReportEngine.displayValue(1.0, ReportMetric.SKIN_TEMP_DEV, fahrenheit), 1e-12,
        )
        // °C leaves the stored value alone.
        assertEquals(
            0.52,
            RangeReportEngine.displayValue(0.52, ReportMetric.SKIN_TEMP_DEV, celsius), 1e-12,
        )
    }

    @Test
    fun skinTempCarriesTheDeltaSymbolTheAppShows() {
        assertEquals("Δ°C", RangeReportEngine.displayUnit(ReportMetric.SKIN_TEMP_DEV, celsius))
        assertEquals("Δ°F", RangeReportEngine.displayUnit(ReportMetric.SKIN_TEMP_DEV, fahrenheit))
        // The Effort axis has no bearing on the temperature unit.
        assertEquals("Δ°C", RangeReportEngine.displayUnit(ReportMetric.SKIN_TEMP_DEV, whoopAxis))
    }

    // Effort: the 0–100 ↔ 0–21 axis

    @Test
    fun effortRescalesAndNamesItsDenominator() {
        assertEquals(
            12.389999999999999,
            RangeReportEngine.displayValue(59.0, ReportMetric.STRAIN, whoopAxis), 1e-12,
        )
        assertEquals(
            21.0,
            RangeReportEngine.displayValue(100.0, ReportMetric.STRAIN, whoopAxis), 1e-12,
        )
        assertEquals(
            0.0,
            RangeReportEngine.displayValue(0.0, ReportMetric.STRAIN, whoopAxis), 1e-12,
        )
        // Unitless on its native axis (unchanged); named once rescaled, so a bare "12.4" can never
        // be mistaken for a 0–100 score.
        assertEquals("", RangeReportEngine.displayUnit(ReportMetric.STRAIN, celsius))
        assertEquals("/ 21", RangeReportEngine.displayUnit(ReportMetric.STRAIN, whoopAxis))
    }

    // Every other metric is untouched by every setting

    @Test
    fun metricsWithNoDisplayPreferenceNeverMove() {
        val configurable = setOf(ReportMetric.SKIN_TEMP_DEV, ReportMetric.STRAIN)
        for (metric in ReportMetric.entries.filter { it !in configurable }) {
            for (units in listOf(celsius, fahrenheit, whoopAxis)) {
                assertEquals(
                    "$metric moved under a display toggle",
                    42.5, RangeReportEngine.displayValue(42.5, metric, units), 1e-12,
                )
                assertEquals(
                    "$metric changed unit under a display toggle",
                    metric.unit, RangeReportEngine.displayUnit(metric, units),
                )
            }
        }
    }

    // The headline sentences agree with the cards

    @Test
    fun headlineRendersSkinTempInTheChosenUnit() {
        val stat = MetricRangeStat(
            metric = ReportMetric.SKIN_TEMP_DEV, n = 4, mean = 0.16,
            min = DayValue("2026-08-19", -0.5),
            max = DayValue("2026-08-14", 0.52),
            firstHalfMean = -0.2, secondHalfMean = 0.52,
            trend = ReportTrend.RISING, latest = DayValue("2026-08-25", 0.3),
        )
        assertEquals(
            "Skin temp is trending up (avg -0.2 Δ°C → 0.5 Δ°C).",
            RangeReportEngine.headline(stat, celsius),
        )
        assertEquals(
            "Skin temp is trending up (avg -0.4 Δ°F → 0.9 Δ°F).",
            RangeReportEngine.headline(stat, fahrenheit),
        )
    }

    @Test
    fun headlineRendersEffortOnTheChosenAxis() {
        val stat = MetricRangeStat(
            metric = ReportMetric.STRAIN, n = 4, mean = 49.5,
            min = DayValue("2026-08-02", 30.0),
            max = DayValue("2026-08-20", 70.0),
            firstHalfMean = 40.0, secondHalfMean = 59.0,
            trend = ReportTrend.RISING, latest = DayValue("2026-08-25", 55.0),
        )
        assertEquals(
            "Strain is trending up (avg 40.0 → 59.0) - a good sign.",
            RangeReportEngine.headline(stat, celsius),
        )
        assertEquals(
            "Strain is trending up (avg 8.4 / 21 → 12.4 / 21) - a good sign.",
            RangeReportEngine.headline(stat, whoopAxis),
        )
    }

    @Test
    fun headlineForAnUnconfigurableMetricIsIdenticalUnderEverySetting() {
        val stat = MetricRangeStat(
            metric = ReportMetric.HRV, n = 4, mean = 58.0,
            min = DayValue("2026-08-03", 50.0),
            max = DayValue("2026-08-11", 66.0),
            firstHalfMean = 62.4, secondHalfMean = 55.1,
            trend = ReportTrend.FALLING, latest = DayValue("2026-08-25", 55.1),
        )
        val expected = "HRV is trending down (avg 62.4 ms → 55.1 ms) - worth a look."
        for (units in listOf(celsius, fahrenheit, whoopAxis)) {
            assertEquals(expected, RangeReportEngine.headline(stat, units))
        }
    }

    // A display toggle never moves the statistics or the verdict

    @Test
    fun buildLeavesStatsInStoredUnitsAndKeepsTheSameTrend() {
        val skin = mapOf(
            "2026-08-01" to -0.3,
            "2026-08-02" to -0.1,
            "2026-08-03" to 0.2,
            "2026-08-04" to 0.52,
        )
        val stored = RangeReportEngine.build(
            mapOf(ReportMetric.SKIN_TEMP_DEV to skin), "2026-08-01", "2026-08-04",
        )
        val shown = RangeReportEngine.build(
            mapOf(ReportMetric.SKIN_TEMP_DEV to skin), "2026-08-01", "2026-08-04", fahrenheit,
        )
        // The statistics themselves stay in STORED units under both settings, so nothing that reads
        // them (comparison, ranking, anything persisted) depends on a cosmetic toggle.
        assertEquals(stored.metrics, shown.metrics)
        assertEquals(0.52, shown.stat(ReportMetric.SKIN_TEMP_DEV)!!.max.value, 1e-12)
        // Only the rendered sentence differs.
        assertNotEquals(stored.headlines, shown.headlines)
        assertTrue(shown.headlines[0].contains("Δ°F"))
        assertTrue(stored.headlines[0].contains("Δ°C"))
    }

    @Test
    fun defaultBuildIsUnchangedByThisFeature() {
        val skin = mapOf("2026-08-01" to -0.3, "2026-08-02" to 0.5)
        val implicitDefault = RangeReportEngine.build(
            mapOf(ReportMetric.SKIN_TEMP_DEV to skin), "2026-08-01", "2026-08-02",
        )
        val explicitStored = RangeReportEngine.build(
            mapOf(ReportMetric.SKIN_TEMP_DEV to skin), "2026-08-01", "2026-08-02",
            ReportDisplayUnits.STORED,
        )
        assertEquals(implicitDefault, explicitStored)
    }
}
