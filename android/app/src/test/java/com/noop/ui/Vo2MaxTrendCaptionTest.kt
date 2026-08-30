package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The caption explains a break the reader can see, so it must appear exactly when the chart is actually
 * split. Deriving it from [vo2MaxTrendSegmentIds] rather than recomputing means the two cannot disagree;
 * these cases pin the behaviour that matters at the boundary.
 */
class Vo2MaxTrendCaptionTest {

    private fun r(day: String, source: String) = VitalReading(day, 42.0, source)

    @Test
    fun `a single estimator throughout needs no caption`() {
        val nes = listOf(r("2026-08-01", "nes"), r("2026-08-08", "nes"), r("2026-08-15", "nes"))
        assertFalse(vo2MaxTrendHasBreak(nes))
    }

    @Test
    fun `a method change is captioned`() {
        assertTrue(vo2MaxTrendHasBreak(listOf(r("2026-08-01", "nes"), r("2026-08-08", "uth"))))
    }

    /**
     * The distinction the caption's wording depends on: a GAP IN DAYS under one estimator is still one
     * segment and draws no break, so captioning it would explain something the reader cannot see and
     * imply a method change that never happened.
     */
    @Test
    fun `a gap in days under one estimator is not a method change`() {
        val sparse = listOf(r("2026-01-01", "nes"), r("2026-08-01", "nes"))
        assertFalse(vo2MaxTrendHasBreak(sparse))
    }

    /**
     * Returning to an earlier estimator is a THIRD segment, not a return to the first — that is exactly
     * why [vo2MaxTrendSegmentIds] carries a sequential group number. The caption must fire here too.
     */
    @Test
    fun `returning to the first estimator still counts as changed`() {
        val there_and_back = listOf(r("2026-08-01", "nes"), r("2026-08-08", "uth"), r("2026-08-15", "nes"))
        assertTrue(vo2MaxTrendHasBreak(there_and_back))
        // Three groups, not two: the non-adjacent Nes runs must not be joined.
        assertTrue(vo2MaxTrendSegmentIds(there_and_back).distinct().size == 3)
    }

    /**
     * The case that decides the caption's WORDING. An untagged legacy reading resolves to
     * "...estimator:unknown", so it splits the line exactly like a real method change would - but the
     * method may never have changed, only the record of it is missing. A caption saying "the method
     * changed" would assert something this data cannot support, which is why it says "changed or was
     * not recorded" instead.
     */
    @Test
    fun `an unrecorded method also breaks the line`() {
        val untaggedThenTagged = listOf(
            r("2026-08-01", "vo2max-estimator:unknown"),
            r("2026-08-08", "vo2max-estimator:nes"),
        )
        assertTrue(vo2MaxTrendHasBreak(untaggedThenTagged))
    }

    @Test
    fun `degenerate inputs do not claim a change`() {
        assertFalse(vo2MaxTrendHasBreak(emptyList()))
        assertFalse(vo2MaxTrendHasBreak(listOf(r("2026-08-01", "nes"))))
    }
}
