package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The steps-calibration motion cache's key and readout. Twin of the Swift `StepsMotionCacheTests`,
 * pinned against the SAME literals — the two sides must invalidate on the same facts, and pinning the
 * rendered strings is how a one-sided change to either rule is caught.
 */
class StepsMotionCacheTest {

    @Test
    fun keyIsStableForUnchangedInputs() {
        val a = StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_000L)
        val b = StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_000L)
        assertEquals(a, b)
        assertEquals("my-whoop|8640|1757000000", a)
    }

    /**
     * The three facts that MUST invalidate a fold, one at a time. A row added moves the count; a row
     * replacing another at a newer timestamp moves the max; a day changing hands moves the owner.
     */
    @Test
    fun everyInputInvalidates() {
        val base = StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_000L)
        assertNotEquals(base, StepsMotionCache.cacheKey("my-whoop", 8641, 1_757_000_000L))
        assertNotEquals(base, StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_001L))
        assertNotEquals(base, StepsMotionCache.cacheKey("whoop-5mg", 8640, 1_757_000_000L))
    }

    /**
     * An empty day is a real, cacheable answer — the key for it is well-formed and distinct from a day
     * that has rows. Caching it is what stops an unworn gap re-reading its whole stream every pass.
     */
    @Test
    fun emptyDayHasItsOwnKey() {
        assertEquals("my-whoop|0|0", StepsMotionCache.cacheKey("my-whoop", 0, 0L))
        assertNotEquals(StepsMotionCache.cacheKey("my-whoop", 0, 0L),
            StepsMotionCache.cacheKey("my-whoop", 1, 0L))
    }

    /** The owner is the FIRST field, so two devices cannot collide by arranging their counts. */
    @Test
    fun ownerBoundaryCannotBeForgedByCounts() {
        assertNotEquals(StepsMotionCache.cacheKey("a", 1, 2L), StepsMotionCache.cacheKey("a|1", 2, 0L))
    }

    @Test
    fun logLineReportsTheRatioAndSize() {
        assertEquals("analyzeRecent stepsMotion reused=58/60 size=60",
            StepsMotionCache.logLine(58, 2, 60))
        // A cold process: everything folded, nothing reused. This is the line a FIRST pass prints, and
        // seeing it on every pass is the symptom that the key is moving when it should not.
        assertEquals("analyzeRecent stepsMotion reused=0/60 size=60",
            StepsMotionCache.logLine(0, 60, 60))
    }
}
