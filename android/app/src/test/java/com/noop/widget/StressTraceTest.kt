package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stress widget's pure half. The two tests that matter most are the ones pinning where it departs
 * from [HrTrace]: the domain is fixed rather than normalised, and an unscored hour is a hole rather
 * than a point to draw through.
 */
class StressTraceTest {

    private val h = 3_600L
    private fun at(hour: Int, level: Double?, moving: Boolean = false) =
        StressPoint(ts = hour * h, level = level, moving = moving)

    // MARK: - the fixed domain

    @Test
    fun `a calm day is drawn low, not stretched across the box`() {
        val calm = listOf(at(0, 0.2), at(1, 0.3), at(2, 0.25))
        val pts = StressTrace.segments(calm, width = 100f, height = 100f).single()
        // Every point sits in the bottom tenth, because 0.3 of 3 IS low. Normalising to the day's own
        // range would have spread these three across the full height and drawn a dramatic day.
        assertTrue("calm day should hug the bottom, got $pts", pts.all { it.y >= 88f })
    }

    @Test
    fun `the same shape at a higher level draws higher`() {
        val calm = StressTrace.segments(listOf(at(0, 0.2), at(1, 0.4)), 100f, 100f).single()
        val tense = StressTrace.segments(listOf(at(0, 2.2), at(1, 2.4)), 100f, 100f).single()
        // Identical spread, different absolute level: under a normalising domain these would be drawn
        // identically, which is the lie the fixed domain exists to prevent.
        assertTrue("tense day must sit above the calm one", tense[0].y < calm[0].y)
    }

    @Test
    fun `the top of the domain is the top of the box and zero is the bottom`() {
        val pts = StressTrace.segments(listOf(at(0, 3.0), at(1, 0.0)), 100f, 100f).single()
        assertEquals(0f, pts[0].y, 0.001f)
        assertEquals(100f, pts[1].y, 0.001f)
    }

    // MARK: - gaps

    @Test
    fun `an unscored hour splits the line rather than being drawn through`() {
        val day = listOf(at(0, 1.0), at(1, 1.2), at(2, null), at(3, 0.9), at(4, 1.1))
        val segs = StressTrace.segments(day, 100f, 100f)
        assertEquals("the hole must break the line in two", 2, segs.size)
        assertEquals(2, segs[0].size)
        assertEquals(2, segs[1].size)
    }

    @Test
    fun `the gap keeps its width, so the afternoon does not slide left`() {
        val day = listOf(at(0, 1.0), at(1, null), at(2, 1.0))
        val segs = StressTrace.segments(day, 100f, 100f)
        // x is placed on the hour's position in the day's span, so the survivors sit at the ends.
        assertEquals(0f, segs[0].single().x, 0.001f)
        assertEquals(100f, segs[1].single().x, 0.001f)
    }

    @Test
    fun `a day with nothing scored draws nothing`() {
        val day = listOf(at(0, null), at(1, null, moving = true))
        assertTrue(StressTrace.segments(day, 100f, 100f).isEmpty())
        assertNull(StressTrace.stats(day))
    }

    // MARK: - movement

    @Test
    fun `hours masked as movement are marked and do not join the line`() {
        val day = listOf(at(0, 1.0), at(1, null, moving = true), at(2, 1.0))
        assertEquals(2, StressTrace.segments(day, 100f, 100f).size)
        val marks = StressTrace.movingMarks(day, 100f)
        assertEquals(1, marks.size)
        assertEquals(50f, marks.single(), 0.001f)
    }

    // MARK: - the high band

    @Test
    fun `only hours at or above the high band get a dot`() {
        val day = listOf(at(0, 1.0), at(1, 1.9), at(2, 2.0), at(3, 2.8), at(4, null))
        val dots = StressTrace.highPoints(day, 100f, 100f)
        // 2.0 is the floor itself, so it counts; 1.9 does not.
        assertEquals(2, dots.size)
    }

    @Test
    fun `a dot lands on its own vertex`() {
        val day = listOf(at(0, 0.5), at(1, 2.5))
        val vertex = StressTrace.segments(day, 100f, 100f).single()[1]
        val dot = StressTrace.highPoints(day, 100f, 100f).single()
        // The dot and the line are placed by the same rule, so a nudge to one cannot leave the other
        // behind. The renderer lifts the dot above the stroke; the geometry must agree exactly.
        assertEquals(vertex.x, dot.x, 0.001f)
        assertEquals(vertex.y, dot.y, 0.001f)
    }

    @Test
    fun `a calm day gets no dots at all`() {
        assertTrue(StressTrace.highPoints(listOf(at(0, 0.4), at(1, 1.2)), 100f, 100f).isEmpty())
    }

    // MARK: - stats

    @Test
    fun `mean covers scored hours only and peak is the highest of them`() {
        val day = listOf(at(0, 1.0), at(1, null), at(2, 2.0), at(3, null, moving = true))
        val stats = StressTrace.stats(day)!!
        assertEquals(1.5, stats.mean, 0.0001)
        assertEquals(2.0, stats.peak.level!!, 0.0001)
        assertEquals(2 * h, stats.peak.ts)
        assertEquals(2, stats.scoredHours)
        assertEquals(1, stats.movingHours)
    }

    // MARK: - the prefs round trip

    @Test
    fun `encode and decode preserve levels, holes and movement`() {
        val day = listOf(at(0, 1.25), at(1, null), at(2, null, moving = true), at(3, 2.5))
        val back = StressTrace.decode(StressTrace.encode(day))
        assertEquals(day.size, back.size)
        assertEquals(1.25, back[0].level!!, 0.001)
        assertNull(back[1].level)
        assertTrue(back[2].moving)
        assertEquals(2.5, back[3].level!!, 0.001)
    }

    @Test
    fun `decode skips malformed pieces instead of throwing`() {
        // This runs on the widget's render path, where the alternative to a partial curve is a crashed
        // home screen.
        val back = StressTrace.decode("0:1.0:0,nonsense,7::1,3600:2.0:1,,9999:99:0")
        assertEquals(2, back.size)
        assertEquals(1.0, back[0].level!!, 0.001)
        assertTrue(back[1].moving)
    }

    @Test
    fun `decode of nothing is empty rather than a crash`() {
        assertTrue(StressTrace.decode(null).isEmpty())
        assertTrue(StressTrace.decode("").isEmpty())
    }

    // MARK: - axes

    @Test
    fun `the level scale is fixed so two days can be compared`() {
        assertEquals(listOf(3, 2, 1, 0), StressTrace.levelTicks())
    }

    @Test
    fun `time ticks anchor to the scored hours, not to the day`() {
        val day = listOf(at(0, null), at(8, 1.0), at(12, 1.5), at(16, 2.0), at(23, null))
        val ticks = StressTrace.timeTicks(day)
        // An evening-only day must not label its axis with a morning that was never sampled.
        assertEquals(listOf(8 * h, 12 * h, 16 * h), ticks)
    }

    @Test
    fun `one scored hour names one instant`() {
        assertEquals(listOf(9 * h), StressTrace.timeTicks(listOf(at(9, 1.0), at(10, null))))
    }
}
