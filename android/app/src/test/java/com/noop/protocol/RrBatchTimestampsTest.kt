package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** R-R batch timestamps (#1118) — twin of the Swift `RrBatchTimestampsTests`, same cases, same numbers. */
class RrBatchTimestampsTest {

    /**
     * The regression. Two ~740 ms beats used to share one second, so a frame deposited ~1.5 s of
     * beat-time onto 1 s of wall clock and coverage read 1.5. They must now occupy two seconds.
     */
    @Test fun `a batch is spread across the time it describes`() {
        val out = RrBatchTimestamps.spread(1000, listOf(740, 745))
        assertEquals(listOf(740, 745), out.map { it.rrMs })
        assertEquals(listOf(999, 1000), out.map { it.ts })
    }

    /** The most recent interval ends AT the frame; earlier ones are back-dated by what follows them. */
    @Test fun `the last interval lands on the frame timestamp`() {
        val out = RrBatchTimestamps.spread(5000, listOf(1000, 1000, 1000))
        assertEquals(listOf(4998, 4999, 5000), out.map { it.ts })
    }

    /**
     * The property that makes this a fix rather than a trade: the beat-time a batch carries now matches
     * the wall-clock span it occupies, which IS what rrCoverage measures.
     */
    @Test fun `span matches the beat-time carried`() {
        val rr = listOf(800, 820, 810, 790)
        val out = RrBatchTimestamps.spread(10_000, rr)
        val span = out.last().ts - out.first().ts
        val carriedSeconds = rr.dropLast(1).sum() / 1000
        assertTrue("span=$span carried=$carriedSeconds", abs(span - carriedSeconds) <= 1)
    }

    /** A strap that does not batch is byte-identical through this — the 5/MG's clean nights must not move. */
    @Test fun `a single interval is unchanged`() {
        val out = RrBatchTimestamps.spread(777, listOf(812))
        assertEquals(1, out.size)
        assertEquals(777, out[0].ts)
        assertEquals(812, out[0].rrMs)
    }

    @Test fun `an empty batch yields nothing`() {
        assertTrue(RrBatchTimestamps.spread(1, emptyList()).isEmpty())
    }

    /** No beat is invented or dropped — the count and the values survive exactly, in order. */
    @Test fun `no beat is added or lost`() {
        val rr = listOf(700, 1200, 650, 900, 880)
        assertEquals(rr, RrBatchTimestamps.spread(42_000, rr).map { it.rrMs })
    }

    /** A nonsense value cannot drag a timestamp forwards past the frame. */
    @Test fun `a negative value cannot move time forwards`() {
        val out = RrBatchTimestamps.spread(100, listOf(-5000, 800))
        assertTrue(out.all { it.ts <= 100 })
    }
}
