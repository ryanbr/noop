package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Daily SCORES are drawn as bars. A line asserts continuity between readings, and on a series swinging
 * about twenty points a day that climb-and-dive through values which never existed is most of what reads
 * as noise. Bars claim nothing between slots.
 */
class VitalBarChartTest {

    private fun reading(day: String, value: Double) = VitalReading(day, value, "dev")

    @Test
    fun `the daily scores are bars`() {
        assertTrue(vitalChartIsBars("strain"))
        assertTrue(vitalChartIsBars("rest"))
        assertTrue(vitalChartIsBars("recovery"))
    }

    /**
     * Levels stay lines. Resting HR, HRV, skin temperature, respiratory rate and blood oxygen genuinely do
     * vary continuously between measurements, so a connecting line is the honest shape for them; drawing
     * them as bars would be the mirror of the mistake this corrects.
     */
    @Test
    fun `levels and sparse series stay lines`() {
        listOf("rhr", "hrv", "skin", "resp", "spo2", "fitness_age", "vitality", "vo2max_est")
            .forEach { assertFalse(it, vitalChartIsBars(it)) }
    }

    // --- one slot per day ---

    /**
     * The property that positions bars by date without any spacing machinery: every day in the window gets
     * a slot, so a missing day is an empty slot of the right width rather than a bar shuffled left.
     */
    @Test
    fun `every day in the window gets a slot`() {
        val d = densifyByDay(
            listOf(reading("2026-09-01", 32.9), reading("2026-09-03", 27.5), reading("2026-09-05", 42.3)),
        )!!
        assertEquals(5, d.size)
        assertEquals(listOf("2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"), d.map { it.first })
    }

    /** A day with no reading carries NaN, which the bar chart already treats as nothing to draw. */
    @Test
    fun `a missing day is not a zero`() {
        val d = densifyByDay(listOf(reading("2026-09-01", 32.9), reading("2026-09-03", 27.5)))!!
        assertTrue(d[1].second.isNaN())
        // and a REAL zero stays a real zero, distinct from the missing day beside it
        val withZero = densifyByDay(listOf(reading("2026-09-01", 0.0), reading("2026-09-03", 27.5)))!!
        assertEquals(0.0, withZero[0].second, 0.0)
        assertTrue(withZero[1].second.isNaN())
    }

    /** Consecutive readings densify to themselves: a fully-measured stretch gains nothing and loses none. */
    @Test
    fun `a complete stretch is unchanged`() {
        val r = listOf(reading("2026-09-01", 1.0), reading("2026-09-02", 2.0), reading("2026-09-03", 3.0))
        assertEquals(r.map { it.day to it.value }, densifyByDay(r))
    }

    /** An unparseable day refuses, so the caller falls back rather than dropping readings into wrong slots. */
    @Test
    fun `an unparseable day refuses rather than mis-slotting`() {
        assertNull(densifyByDay(listOf(reading("2026-09-01", 1.0), reading("nope", 2.0))))
    }

    @Test
    fun `an empty series densifies to nothing`() {
        assertEquals(emptyList<Pair<String, Double>>(), densifyByDay(emptyList()))
    }

    /**
     * The read-out must not invent a measurement. BarChart flattens a non-finite value to 0.0 so it draws
     * nothing, which is right for the geometry and wrong for the label: an empty slot would otherwise
     * answer "0.0 %" on tap for a day that was never measured. That is the same class as a chart drawing
     * one day and labelling another, and it only became reachable once missing days got their own slots.
     *
     * Pinned through the formatter the chart uses, since the drawing itself is not reachable from a JVM
     * test: a finite value labels, and the caller now gates the non-finite case before it gets here.
     */
    @Test
    fun `a densified gap carries no value to report`() {
        val d = densifyByDay(listOf(reading("2026-09-01", 32.9), reading("2026-09-03", 27.5)))!!
        val gap = d[1].second
        assertTrue(gap.isNaN())
        // The label is only rendered for a finite value, so the gap contributes none.
        assertFalse(gap.isFinite())
        // and the readings either side still do
        assertTrue(d[0].second.isFinite())
        assertTrue(d[2].second.isFinite())
    }
}
