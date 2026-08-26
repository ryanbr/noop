package com.noop.ui

import com.noop.analytics.ReportDisplayUnits
import com.noop.analytics.ReportMetric
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The metric-card row the reporter actually pasted in #1637 — `SKIN TEMP  -0.0 °C`, `min -0.5 °C`.
 *
 * Every other test for this fix sits one layer BELOW this: they pin the engine helpers and the
 * headline sentence, so reverting [TrendsReportFormat.valueText] to `metric.unit` would leave all
 * of them green while the exported page went back to printing °C. This is the one that fails.
 *
 * Twin of Swift `TrendsReportValueTextTests` in StrandTests; same fixtures, same assertions.
 */
class TrendsReportValueTextTest {

    private val celsius = ReportDisplayUnits.STORED
    private val fahrenheit = ReportDisplayUnits(fahrenheit = true, effortFactor = 1.0)
    private val whoopAxis = ReportDisplayUnits(fahrenheit = false, effortFactor = 21.0 / 100.0)

    @Test
    fun skinTempRowCarriesTheChosenUnit() {
        // The reporter's Aug 14: 0.52 °C stored. The app showed Δ°F; the PDF showed °C.
        assertEquals("+0.5 Δ°C", TrendsReportFormat.valueText(0.52, ReportMetric.SKIN_TEMP_DEV, celsius))
        assertEquals("+0.9 Δ°F", TrendsReportFormat.valueText(0.52, ReportMetric.SKIN_TEMP_DEV, fahrenheit))
        // Their Aug 19 minimum.
        assertEquals("-0.5 Δ°C", TrendsReportFormat.valueText(-0.5, ReportMetric.SKIN_TEMP_DEV, celsius))
        assertEquals("-0.9 Δ°F", TrendsReportFormat.valueText(-0.5, ReportMetric.SKIN_TEMP_DEV, fahrenheit))
    }

    @Test
    fun onlyPositiveDeviationsGetAnExplicitSign() {
        assertEquals("0.0 Δ°C", TrendsReportFormat.valueText(0.0, ReportMetric.SKIN_TEMP_DEV, celsius))
        assertEquals("+0.1 Δ°C", TrendsReportFormat.valueText(0.1, ReportMetric.SKIN_TEMP_DEV, celsius))
        assertEquals("-0.1 Δ°C", TrendsReportFormat.valueText(-0.1, ReportMetric.SKIN_TEMP_DEV, celsius))
    }

    @Test
    fun effortRowFollowsTheChosenAxis() {
        // Native 0–100: a whole number, no unit — unchanged from before the fix.
        assertEquals("59", TrendsReportFormat.valueText(59.0, ReportMetric.STRAIN, celsius))
        // WHOOP 0–21: rescaled, one decimal, and the denominator named.
        assertEquals("12.4 / 21", TrendsReportFormat.valueText(59.0, ReportMetric.STRAIN, whoopAxis))
        assertEquals("21.0 / 21", TrendsReportFormat.valueText(100.0, ReportMetric.STRAIN, whoopAxis))
    }

    @Test
    fun rowsWithNoDisplayPreferenceAreIdenticalUnderEverySetting() {
        val cases = listOf(
            ReportMetric.HRV to "58 ms",
            ReportMetric.RESTING_HR to "58 bpm",
            ReportMetric.RECOVERY to "58",
            ReportMetric.RESP_RATE to "58.0 br/min",
            ReportMetric.SLEEP_HOURS to "58.0 h",
            ReportMetric.WORKOUTS to "58.0 /day",
            ReportMetric.STRESS to "58.0",
        )
        for ((metric, expected) in cases) {
            for (units in listOf(celsius, fahrenheit, whoopAxis)) {
                assertEquals("$metric under $units", expected,
                    TrendsReportFormat.valueText(58.0, metric, units))
            }
        }
    }

    /**
     * The one-decimal formatter, pinned to Swift's verbatim stdout:
     *
     *     func round1Text(_ x: Double) -> String { String(format: "%.1f", (x * 10).rounded() / 10) }
     *
     * Android rounded ties toward +∞ (`roundToInt`) where Swift rounds half away from zero, so every
     * NEGATIVE tie disagreed. Skin temp is the report's only signed metric, so it was the only row
     * that could reach it — and -0.05 lost its sign entirely, one platform reading "below baseline"
     * where the other read "at baseline".
     */
    @Test
    fun negativeTiesRoundAwayFromZeroLikeSwift() {
        assertEquals("-0.3", TrendsReportFormat.round1(-0.25))
        assertEquals("-0.4", TrendsReportFormat.round1(-0.35))
        assertEquals("-0.5", TrendsReportFormat.round1(-0.45))
        assertEquals("-0.2", TrendsReportFormat.round1(-0.15))
        assertEquals("-0.1", TrendsReportFormat.round1(-0.05))
        assertEquals("-0.8", TrendsReportFormat.round1(-0.75))
    }

    @Test
    fun positiveTiesAndOrdinaryValuesAreUnchanged() {
        assertEquals("0.3", TrendsReportFormat.round1(0.25))
        assertEquals("0.4", TrendsReportFormat.round1(0.35))
        assertEquals("0.8", TrendsReportFormat.round1(0.75))
        assertEquals("0.9", TrendsReportFormat.round1(0.9359999999999999))
        assertEquals("12.4", TrendsReportFormat.round1(12.389999999999999))
        assertEquals("0.0", TrendsReportFormat.round1(0.0))
    }

    /** A negative tie must reach the SKIN TEMP row, not just the formatter. */
    @Test
    fun aNegativeTieRendersIdenticallyToSwiftInTheRowItself() {
        assertEquals("-0.3 Δ°C", TrendsReportFormat.valueText(-0.25, ReportMetric.SKIN_TEMP_DEV, celsius))
    }
}
