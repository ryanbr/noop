package com.noop.ui

import com.noop.analytics.Baselines
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The personal-baseline reference rule on the HRV and resting-HR detail charts.
 *
 * Two properties matter and they fail in different ways. The rule has to come from the SAME fold the
 * vitals grid bands against, or a reading the grid calls out of range can sit on the comfortable side of
 * the rule on the chart beside it. And it has to be placed by the SAME scale as the series, or it sits at
 * a confidently wrong height that nothing in the picture contradicts.
 */
class VitalBaselineLineTest {

    private fun reading(day: String, value: Double) = VitalReading(day, value, "dev")

    /** Enough nights for the fold to reach TRUSTED, around a steady centre. */
    private fun steady(n: Int, value: Double) =
        (1..n).map { reading("2026-01-%02d".format(it), value) }

    // --- which metrics get a rule ---

    /**
     * HRV and resting HR are levels whose absolute number means little without the reader's own normal.
     * The daily scores are already interpretable on their own ranges, and skin temperature has its own
     * signed-deviation view, so neither gets a rule that would only add furniture.
     */
    @Test
    fun `only hrv and resting hr get a baseline`() {
        val history = steady(30, 60.0)
        assertNotNull(vitalBaseline("hrv", history))
        assertNotNull(vitalBaseline("rhr", history))
        listOf("recovery", "rest", "strain", "skin", "resp", "spo2", "fitness_age", "vitality")
            .forEach { assertNull(it, vitalBaseline(it, history)) }
    }

    /**
     * `rhr` on this screen is `resting_hr` in the baseline configs. Pinned because the two names differ
     * and a silent miss returns null, which looks exactly like "not trusted yet" rather than like a bug.
     */
    @Test
    fun `the rhr key maps to the resting hr config`() {
        assertNotNull(Baselines.metricCfg["resting_hr"])
        assertNotNull("rhr must resolve through resting_hr", vitalBaseline("rhr", steady(30, 55.0)))
    }

    // --- when it is honest to draw one ---

    /**
     * A rule folded from a handful of nights would be a guess wearing the authority of a reference line,
     * and a calibrating baseline is exactly when a reader is most likely to over-read it.
     */
    @Test
    fun `no rule until the baseline is trusted`() {
        assertNull(vitalBaseline("hrv", steady(4, 60.0)))
        assertNotNull(vitalBaseline("hrv", steady(30, 60.0)))
    }

    @Test
    fun `an empty history has no rule`() {
        assertNull(vitalBaseline("hrv", emptyList()))
    }

    /** A steady series baselines at its own centre, so the rule lands where a reader would expect it. */
    @Test
    fun `a steady series baselines at its centre`() {
        val b = vitalBaseline("hrv", steady(30, 60.0))
        assertNotNull(b)
        assertEquals(60.0, b!!, 1.0)
    }

    // --- placing it on the same scale as the series ---

    /**
     * The load-bearing one. A value that IS in the series must map to the same y the series point does,
     * or the rule and the reading it explains are drawn by two different scales.
     */
    @Test
    fun `a value in the series maps to the same height as its point`() {
        val values = listOf(40.0, 50.0, 60.0, 70.0)
        val h = 100f
        val pts = pointsFor(values, width = 200f, height = h, topPad = 6f, bottomPad = 6f)
        for (i in values.indices) {
            val y = yForValue(values[i], values, h, topPad = 6f, bottomPad = 6f)
            assertNotNull("index $i", y)
            assertEquals("index $i", pts[i].y, y!!, 0.001f)
        }
    }

    /**
     * Out of range draws NOTHING rather than clamping to an edge. A rule pinned to the top of the plot
     * reads as "your baseline is the highest value here", which is a different claim from "your baseline
     * is off this chart", and only the second one is true.
     */
    @Test
    fun `a baseline outside the plotted range is not drawn`() {
        val values = listOf(40.0, 50.0, 60.0)
        assertNull(yForValue(80.0, values, 100f, 6f, 6f))
        assertNull(yForValue(10.0, values, 100f, 6f, 6f))
        assertNotNull(yForValue(50.0, values, 100f, 6f, 6f))
    }

    /** A supplied domain widens the scale, so a rule inside the WIDENED range is drawn. */
    @Test
    fun `a supplied y domain widens what the rule can sit on`() {
        val values = listOf(40.0, 50.0, 60.0)
        assertNull(yForValue(20.0, values, 100f, 6f, 6f))
        assertNotNull(yForValue(20.0, values, 100f, 6f, 6f, yDomain = 0.0..100.0))
    }

    /** Degenerate inputs refuse rather than divide by a zero span or a zero height. */
    @Test
    fun `degenerate inputs draw nothing`() {
        assertNull(yForValue(50.0, listOf(50.0), 100f, 6f, 6f))
        assertNull(yForValue(50.0, listOf(40.0, 60.0), 0f, 6f, 6f))
        assertNull(yForValue(Double.NaN, listOf(40.0, 60.0), 100f, 6f, 6f))
    }

    /** A flat series still places a rule at its centre rather than dividing by a zero span. */
    @Test
    fun `a flat series places the rule mid plot`() {
        val y = yForValue(50.0, listOf(50.0, 50.0, 50.0), 100f, 6f, 6f)
        assertNotNull(y)
        assertTrue("mid-plot, not an edge", y!! > 6f && y < 94f)
    }
}
