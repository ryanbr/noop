package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure coverage for the stepped-hypnogram time axis (#sleep-chart-style): the exact onset/wake anchor the
 * edges, round-hour marks fill the middle, and a WIDER screen (larger maxLabels) yields MORE marks. Labels
 * depend on the JVM default timezone; these assert the fraction structure, which does not.
 */
class HypnogramAxisTicksTest {

    private val onset = 1_786_000_000L
    private val eightHours = onset + 8 * 3600L

    @Test fun edgesAreExactOnsetAndWake() {
        val ticks = hypnogramAxisTicks(onset, eightHours, maxLabels = 5)
        assertEquals(0f, ticks.first().first, 1e-4f)
        assertEquals(1f, ticks.last().first, 1e-4f)
        assertTrue("expected at least one interior mark", ticks.size >= 3)
    }

    @Test fun interiorMarksAreStrictlyBetweenTheEdges() {
        hypnogramAxisTicks(onset, eightHours, maxLabels = 6).drop(1).dropLast(1).forEach { (frac, _) ->
            assertTrue("interior frac $frac must be inside (0,1)", frac > 0f && frac < 1f)
        }
    }

    @Test fun widerScreenGivesAtLeastAsManyMarks() {
        val narrow = hypnogramAxisTicks(onset, eightHours, maxLabels = 3)
        val wide = hypnogramAxisTicks(onset, eightHours, maxLabels = 8)
        assertTrue("wide=${wide.size} should be >= narrow=${narrow.size}", wide.size >= narrow.size)
        assertTrue("a wide axis over an 8h night should have >3 marks", wide.size > 3)
    }

    @Test fun zeroOrNegativeSpanYieldsASingleTick() {
        assertEquals(1, hypnogramAxisTicks(onset, onset, maxLabels = 5).size)
        assertEquals(1, hypnogramAxisTicks(onset, onset - 100L, maxLabels = 5).size)
    }
}
