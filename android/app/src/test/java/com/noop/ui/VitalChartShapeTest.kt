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
        assertEquals(0.0..100.0, vitalChartYDomain("recovery"))
        assertEquals(0.0..100.0, vitalChartYDomain("rest"))
        assertEquals(0.0..100.0, vitalChartYDomain("strain"))
    }

    /**
     * Effort anchors to 0..100 whatever the display scale, because the readings store the RAW composite
     * and only format() converts. Taking the domain from the 0..21 display would squash every Effort
     * chart on a WHOOP-scale install into the bottom fifth of its height.
     */
    @Test
    fun `effort anchors to the stored scale, not the displayed one`() {
        assertEquals(0.0..100.0, vitalChartYDomain("strain"))
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

    /** Consecutive days are one run: nothing changes for a fully-measured stretch. */
    @Test
    fun `consecutive days stay one unbroken run`() {
        val ids = dailyGapSegmentIds(
            listOf(reading("2026-09-01", 1.0), reading("2026-09-02", 2.0), reading("2026-09-03", 3.0)),
        )
        assertEquals(1, ids.distinct().size)
    }

    /**
     * The reported shape: 9 readings across a fortnight, with 4 Sep and 29..31 Aug absent. Each gap has
     * to break the stroke, so the chart stops sloping through days nobody measured.
     */
    @Test
    fun `a missing day breaks the line`() {
        val ids = dailyGapSegmentIds(
            listOf(reading("2026-09-03", 27.5), reading("2026-09-05", 42.3), reading("2026-09-06", 1.0)),
        )
        assertEquals(listOf("gap0", "gap1", "gap1"), ids)
    }

    /** Every point is kept: breaking the line must never drop a reading. */
    @Test
    fun `no reading is dropped by the break`() {
        val readings = listOf(reading("2026-09-01", 1.0), reading("2026-09-09", 2.0))
        assertEquals(readings.size, dailyGapSegmentIds(readings).size)
    }

    /** An unparseable day degrades to a break, never to a confident wrong line. */
    @Test
    fun `an unparseable day does not join a run`() {
        val ids = dailyGapSegmentIds(
            listOf(reading("2026-09-01", 1.0), reading("not-a-date", 2.0), reading("2026-09-02", 3.0)),
        )
        assertTrue(ids.toString(), ids.distinct().size > 1)
    }

    /**
     * The case breaking the line creates and that would otherwise hide data: a day isolated between two
     * gaps forms a one-point segment, and a Path with a moveTo and no lineTo strokes nothing. On the
     * reported Effort series that day is 5 Sep, the fortnight's MAXIMUM, so the stats row would have said
     * 42.3 while the chart showed no such point.
     *
     * This pins the SEGMENTING that produces it. The chart draws a marker for any range whose first and
     * last index are equal, which is exactly the shape asserted here.
     */
    @Test
    fun `a day isolated between gaps forms its own single-point segment`() {
        val ids = dailyGapSegmentIds(
            listOf(
                reading("2026-09-01", 32.9), reading("2026-09-02", 2.2), reading("2026-09-03", 27.5),
                reading("2026-09-05", 42.3),
                reading("2026-09-07", 0.0), reading("2026-09-08", 31.6),
            ),
        )
        val ranges = lineChartSegmentRanges(ids.size, ids)
        val isolated = ranges.filter { it.first == it.last }
        assertEquals(1, isolated.size)
        assertEquals(3, isolated.single().first)   // index of 5 Sep, the maximum
    }

    /** A fully-measured stretch has no isolated points, so nothing extra is drawn on a healthy chart. */
    @Test
    fun `a consecutive run produces no isolated points`() {
        val ids = dailyGapSegmentIds(
            listOf(reading("2026-09-01", 1.0), reading("2026-09-02", 2.0), reading("2026-09-03", 3.0)),
        )
        assertTrue(lineChartSegmentRanges(ids.size, ids).none { it.first == it.last })
    }

    /**
     * The break only applies where a "missing day" means something. Fitness Age and Vitality are written
     * only when the engine has the inputs, so they are sparse BY DESIGN: breaking on every gap would
     * isolate every point and leave scattered dots where a trend used to be. VO2max segments on estimator
     * changes instead.
     */
    @Test
    fun `sparse-by-design metrics are not broken on gaps`() {
        assertTrue(vitalIsDailyCadence("recovery"))
        assertTrue(vitalIsDailyCadence("sleep_performance"))
        assertTrue(vitalIsDailyCadence("strain"))
        assertTrue(vitalIsDailyCadence("rhr"))
        assertFalse(vitalIsDailyCadence("fitness_age"))
        assertFalse(vitalIsDailyCadence("vitality"))
        assertFalse(vitalIsDailyCadence("vo2max_est"))
    }
}
