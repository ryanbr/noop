package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vectors here are duplicated verbatim from Swift `RrBatchTimestampsTests` so the twins stay byte-parity. */
class RrBatchTimestampsTest {

    private fun spread(ts: Long, rrs: List<Int>) = RrBatchTimestamps.spread(ts, rrs)

    @Test
    fun `empty array stays empty`() {
        assertTrue(spread(1000L, emptyList()).isEmpty())
    }

    @Test
    fun `single interval is unchanged`() {
        // The 5/MG case: a frame arriving at about the beat rate must pass through byte-identical.
        val out = spread(1000L, listOf(820))
        assertEquals(listOf(1000L), out.map { it.ts })
        assertEquals(listOf(820), out.map { it.rrMs })
    }

    @Test
    fun `two intervals back-date the earlier beat`() {
        val out = spread(1000L, listOf(740, 740))
        assertEquals(listOf(999L, 1000L), out.map { it.ts })
        assertEquals(listOf(740, 740), out.map { it.rrMs })
    }

    @Test
    fun `three intervals accumulate what follows`() {
        val out = spread(1000L, listOf(800, 800, 800))
        assertEquals(listOf(998L, 999L, 1000L), out.map { it.ts })
        assertEquals(listOf(800, 800, 800), out.map { it.rrMs })
    }

    @Test
    fun `order and values are untouched`() {
        val rrs = listOf(700, 900, 650, 1100)
        val out = spread(5000L, rrs)
        assertEquals(rrs, out.map { it.rrMs })
        assertEquals(5000L, out.last().ts)
        assertEquals(out.map { it.ts }.sorted(), out.map { it.ts })
    }

    @Test
    fun `beat-time is neither added nor removed`() {
        // The invariant that separates this from every collapse candidate: rrCoverage's numerator is
        // identical before and after.
        val rrs = listOf(740, 760, 800, 690, 910)
        assertEquals(rrs.sum(), spread(1234L, rrs).sumOf { it.rrMs })
    }

    @Test
    fun `half a second rounds up on both platforms`() {
        assertEquals(listOf(999L, 1000L), spread(1000L, listOf(500, 500)).map { it.ts })
    }

    @Test
    fun `a negative value cannot walk the clock forwards`() {
        val out = spread(1000L, listOf(700, -50, 700))
        assertEquals(1000L, out.last().ts)
        assertTrue(out.all { it.ts <= 1000L })
        assertEquals(out.map { it.ts }.sorted(), out.map { it.ts })
    }
}
