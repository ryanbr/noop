package com.noop.ui

import java.util.Locale
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * #1662: a metric's scrub read-out must print what the screen around it prints.
 *
 * `formatValue` was added for #463, when Trends' Effort chart tapped to the stored 0–100 number beside
 * a 0–21 axis. Only that call site was wired up, so every other scrubbable chart kept the default —
 * [lineChartSelectionLabel]'s fallback, which collapses near-integers and otherwise prints one decimal.
 * The reporter's screenshot is the same defect on the screens #463 never reached: a rounded headline
 * with a one-decimal graph beneath it.
 *
 * These pin the DIVERGENCE (what the default does) beside the FIX (what each injected formatter does),
 * so a future caller that forgets one has a written statement of what goes wrong.
 */
class ChartScrubFormatterParityTest {

    /**
     * Vital Signs detail: `detail.format` is `it.roundToInt().toString()` for the rounded metrics, and
     * the screen renders it WITH the unit — the scrub read-out has to match the whole reading, not just
     * the number, or "62" still disagrees with the "62 ms" beside it.
     */
    private val roundedMetric: (Double) -> String = { "${it.roundToInt()} ms".trim() }

    /** Stress: the Today/Avg/Peak footer prints one decimal on the 0–3 scale. */
    private val stressScore: (Double) -> String = { String.format(Locale.US, "%.1f", it) }

    /** Sleep cards: hours with a unit, matching the Avg/Min/Max row above the bars. */
    private val sleepHours: (Double) -> String = { String.format(Locale.US, "%.1f h", it) }

    @Test
    fun theDefaultDisagreesWithARoundedHeadline() {
        // An HRV of 62.4 is a "62" everywhere on the Vital Signs detail screen except, until now, the
        // graph — which is exactly what the report shows.
        assertEquals("62.4", lineChartSelectionLabel(62.4, null))
        assertEquals("62 ms", lineChartSelectionLabel(62.4, roundedMetric))
        assertNotEquals(lineChartSelectionLabel(62.4, null), lineChartSelectionLabel(62.4, roundedMetric))
    }

    @Test
    fun aRoundedMetricAgreesWithItsGraphAcrossTheRange() {
        for ((raw, expected) in listOf(62.4 to "62 ms", 72.5 to "73 ms", 99.9 to "100 ms", 0.4 to "0 ms")) {
            assertEquals(expected, lineChartSelectionLabel(raw, roundedMetric))
        }
    }

    /**
     * The default's near-integer collapse is its own mismatch: it drops the decimal a one-decimal
     * read-out keeps, so a flat 2.0 stress day scrubbed as "2" beside a footer reading "2.0".
     */
    @Test
    fun theDefaultCollapsesAnExactValueThatTheScreenSpellsOut() {
        assertEquals("2", lineChartSelectionLabel(2.0, null))
        assertEquals("2.0", lineChartSelectionLabel(2.0, stressScore))
    }

    /** Sleep hours carry a unit; the bare number was a different reading, not a rounder one. */
    @Test
    fun sleepHoursKeepTheirUnit() {
        assertEquals("7.3", lineChartSelectionLabel(7.3, null))
        assertEquals("7.3 h", lineChartSelectionLabel(7.3, sleepHours))
    }

    /**
     * Explore was the worst of them: `values` are RAW stored numbers and `MetricSpec.format` is what
     * rescales Effort to WHOOP's 0–21 axis. The Y labels and the hero went through it and the scrub
     * read-out did not, so the axis said one number and tapping the same point said another — a
     * different VALUE, not a different precision. This is the #463 failure, unfixed on that screen.
     */
    @Test
    fun anAxisConvertedMetricDisagreedOnTheValueItself() {
        val toWhoopScale: (Double) -> String = { UnitFormatter.effortDisplay(it, EffortScale.WHOOP) }
        assertEquals("59", lineChartSelectionLabel(59.0, null))          // raw, as the chart used to say
        assertEquals("12.4", lineChartSelectionLabel(59.0, toWhoopScale)) // what the axis says
    }

    /** A day label still prefixes the formatted value, so #691's date context survives the fix. */
    @Test
    fun theDayLabelStillPrefixesTheFormattedValue() {
        assertEquals("16 Jul · 62 ms", lineChartSelectionLabel(62.4, roundedMetric, pointLabel = "16 Jul"))
    }
}
