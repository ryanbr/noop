package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import kotlinx.coroutines.runBlocking
import org.junit.Test

/**
 * Pins the sliding read buffer against the only contract that matters: for every window, it returns
 * EXACTLY what a direct store read would have returned. Twin of Swift `SlidingStreamWindowTests`.
 *
 * The test store is a plain sorted list, so "what a direct read would have returned" is computable
 * independently rather than asserted from the implementation's own behaviour — otherwise the test would
 * agree with a wrong splice.
 */
class SlidingStreamWindowTest {

    private val day = 86_400L
    private val h30 = 108_000L
    private val midnight = 1_787_875_200L

    /** One row per second across five days, which is the 1 Hz shape the real HR stream has. */
    private val store: List<Long> = (midnight - 5 * day..midnight + day step 1L).toList()

    private fun direct(from: Long, to: Long, limit: Int = 1_000_000): List<Long> =
        store.filter { it in from..to }.take(limit)

    private fun window(limit: Int = 1_000_000) =
        SlidingStreamWindow<Long>({ it }, limit) { _, f, t -> direct(f, t, limit) }

    @Test fun backwardWalkMatchesDirectReadsAndReadsEachRowOnce() = runBlocking {
        val w = window()
        for (offset in 0 until 5) {
            val dayStart = midnight - offset * day
            val from = dayStart - h30
            val to = dayStart + day
            val got = w.rows("owner", from, to)
            assertEquals("window $offset must equal a direct read", direct(from, to), got)
        }
        // Day 0 reads its whole 54 h window; each later day reads exactly one 24 h stride. Without the
        // buffer this walk reads 5 x 54 h. The union of all five windows is what it now reads instead.
        val firstFrom = midnight - h30
        val lastFrom = midnight - 4 * day - h30
        val expectedDistinct = direct(lastFrom, midnight + day).size.toLong()
        assertEquals("each row read exactly once", expectedDistinct, w.rowsRead)
        assertTrue("and most rows came from the buffer", w.rowsServed > w.rowsRead / 2)
        assertTrue(firstFrom > lastFrom)
    }

    @Test fun ownerFlipFallsBackToADirectRead() = runBlocking {
        val w = window()
        val from = midnight - h30
        val to = midnight + day
        w.rows("a", from, to)
        val readAfterFirst = w.rowsRead
        val got = w.rows("b", from - day, to - day)
        assertEquals(direct(from - day, to - day), got)
        // A different strap cannot reuse the buffer, so this is a full window read, not a stride.
        assertEquals((to - from + 1), w.rowsRead - readAfterFirst)
    }

    /**
     * A truncated read cannot be sliced, because `ORDER BY ts ASC LIMIT` drops the NEWEST rows — the
     * buffer would be missing its tail with nothing to say so. The next day must read in full and still
     * match a direct read at the same limit.
     */
    @Test fun truncatedReadIsNeverSliced() = runBlocking {
        val limit = 1_000
        val w = window(limit)
        val from = midnight - h30
        val to = midnight + day
        val first = w.rows("owner", from, to)
        assertEquals(limit, first.size)
        val next = w.rows("owner", from - day, to - day)
        assertEquals(direct(from - day, to - day, limit), next)
    }

    /** A gap (the day cache skipped a day) must not splice across the hole. */
    @Test fun gapDoesNotSpliceAcrossTheMissingDay() = runBlocking {
        val w = window()
        val a0 = midnight - h30
        w.rows("owner", a0, midnight + day)
        // Skip one day entirely, as a dayCache HIT would, then ask for the one after it.
        val skipStart = midnight - 2 * day
        val got = w.rows("owner", skipStart - h30, skipStart + day)
        assertEquals(direct(skipStart - h30, skipStart + day), got)
    }
}
