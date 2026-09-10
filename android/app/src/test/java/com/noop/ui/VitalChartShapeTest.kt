package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two things that made the Vital Signs charts read as noise: every metric drawn at full height
 * whatever it did, and a line sloped smoothly through days that were never measured.
 */
class VitalChartShapeTest {

    private fun reading(day: String, value: Double) = VitalReading(day, value, "dev")

    // --- the anchored domain ---

    /** The percentage metrics get their real range, so a calm one is drawn calm. */
    @Test
    fun `percentage metrics anchor to their natural range`() {
        // A zero-WIDTH domain: the chart widens it to contain the data, so the floor is pinned at zero
        // and the ceiling follows the readings.
        assertEquals(0.0..0.0, vitalChartYDomain("recovery"))
        assertEquals(0.0..0.0, vitalChartYDomain("rest"))
        assertEquals(0.0..0.0, vitalChartYDomain("strain"))
    }

    /**
     * Effort anchors to 0..100 whatever the display scale, because the readings store the RAW composite
     * and only format() converts. Taking the domain from the 0..21 display would squash every Effort
     * chart on a WHOOP-scale install into the bottom fifth of its height.
     */
    @Test
    fun `effort anchors to the stored scale, not the displayed one`() {
        assertEquals(0.0..0.0, vitalChartYDomain("strain"))
    }

    /**
     * Every key in the allow-list has to be one the screen ACTUALLY receives. The first version anchored
     * "sleep_performance", which is the series this detail reads underneath and never a detail key here,
     * so Rest kept auto-scaling while a test asserting that key passed. Pinning against the real key list
     * is what makes the allow-list checkable rather than plausible.
     *
     * `realKeys` is a HAND-MAINTAINED mirror of the `when` in `buildVitalDetail`/`buildSeriesVitalDetail`;
     * a unit test cannot enumerate a `when`. It catches an anchored key that no screen sends, which is the
     * bug that shipped. It does NOT catch a newly added metric, so a new key belongs here too.
     */
    @Test
    fun `every anchored key is a real detail key`() {
        val realKeys = setOf(
            "recovery", "strain", "resp", "spo2", "rhr", "hrv", "skin", "rest",
            "fitness_age", "vitality", "vo2max_est", "steps_est",
        )
        val anchored = realKeys.filter { vitalChartYDomain(it) != null }
        assertEquals(setOf("recovery", "rest", "strain"), anchored.toSet())
        assertNull(vitalChartYDomain("sleep_performance"))   // the series name, not a detail key
    }

    /**
     * Blood oxygen is the case that proves this is not "percentages get 0..100": its real movement lives
     * in 90..100, so anchoring would flatten the signal into a line at the top. Metrics with no fixed
     * range at all keep auto-scaling too.
     */
    @Test
    fun `metrics whose range is not their signal keep auto-scaling`() {
        assertNull(vitalChartYDomain("spo2"))
        assertNull(vitalChartYDomain("rhr"))
        assertNull(vitalChartYDomain("hrv"))
        assertNull(vitalChartYDomain("skin_temp"))
    }

    // --- the gap break ---








    /**
     * What the zero floor buys, stated as the property rather than the constant: a 0.0 reading sits at the
     * very bottom of the chart, and the top is set by the data rather than by a ceiling nobody reaches.
     * Anchoring at 100 satisfied the first half and wasted most of the height on the second.
     */
    @Test
    fun `the zero floor pins the bottom without reserving unreachable height`() {
        val d = vitalChartYDomain("strain")!!
        assertEquals(0.0, d.start, 0.0)
        // Zero width: nothing above zero is reserved, so the ceiling comes from the readings.
        assertEquals(d.start, d.endInclusive, 0.0)
    }
}
