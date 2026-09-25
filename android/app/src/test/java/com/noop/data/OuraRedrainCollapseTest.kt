package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A ring record served twice is recognised by the record it came in, not by its timestamps (#2456).
 * Twin of Swift's OuraRedrainCollapseTests, case for case.
 *
 * History is re-served whenever it is refetched: after a link drops mid-drain, and also after a night
 * has already drained, which no resume cursor prevents. Each connection anchors on its own SyncTime, so
 * the second copy lands a second or two off the first, misses the row key, and is stored again.
 */
class OuraRedrainCollapseTest {

    /** One banked 0x60 record: six intervals stamped on a single second. */
    private fun record(ts: Long, rr: List<Int>, channel: Int = 3): List<RrInterval> =
        rr.mapIndexed { i, ms ->
            RrInterval(deviceId = "ring", ts = ts, rrMs = ms, seq = 0, ord = i, srcChannel = channel)
        }

    private val six = listOf(531, 570, 751, 904, 1000, 1002)

    @Test
    fun `a record served again one second later is collapsed`() {
        val beats = record(1_790_223_482, six) + record(1_790_223_483, six)
        val kept = OuraRedrainCollapse.withoutRedrainedRuns(beats)
        assertEquals(6, kept.size)
        assertEquals(List(6) { 1_790_223_482L }, kept.map { it.ts })
    }

    @Test
    fun `two seconds out is also collapsed`() {
        assertEquals(6, OuraRedrainCollapse.withoutRedrainedRuns(record(100, six) + record(102, six)).size)
    }

    @Test
    fun `an identical run further out is kept`() {
        assertEquals(12, OuraRedrainCollapse.withoutRedrainedRuns(record(100, six) + record(105, six)).size)
    }

    @Test
    fun `a record served three times collapses to one`() {
        val beats = record(100, six) + record(101, six) + record(102, six)
        val kept = OuraRedrainCollapse.withoutRedrainedRuns(beats)
        assertEquals(6, kept.size)
        assertEquals(List(6) { 100L }, kept.map { it.ts })
    }

    /** #163: equal successive beats are physiological. */
    @Test
    fun `equal successive beats are not themselves a duplicate`() {
        val flat = record(100, listOf(800, 800, 800, 800, 800, 800))
        assertEquals(6, OuraRedrainCollapse.withoutRedrainedRuns(flat).size)
    }

    /** On a clean night 2.5% of beats already have an equal neighbour a second away. */
    @Test
    fun `short coincidental repeats are kept`() {
        val beats = record(100, listOf(820, 830)) + record(101, listOf(820, 830))
        assertEquals(4, OuraRedrainCollapse.withoutRedrainedRuns(beats).size)
    }

    @Test
    fun `whoop channels are untouched`() {
        val beats = record(100, six, channel = 6) + record(101, six, channel = 6)
        assertEquals(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).size)
    }

    @Test
    fun `the same run on a different channel is independent`() {
        val beats = record(100, six, channel = 3) + record(101, six, channel = 1)
        assertEquals(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).size)
    }

    @Test
    fun `untagged rows are kept`() {
        val beats = record(100, six, channel = 3).map { it.copy(srcChannel = null) } +
            record(101, six, channel = 3).map { it.copy(srcChannel = null) }
        assertEquals(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).size)
    }

    @Test
    fun `a reordered run is not a copy`() {
        val beats = record(100, six) + record(101, six.reversed())
        assertEquals(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).size)
    }

    @Test
    fun `order and content of kept beats are unchanged`() {
        val first = record(100, six)
        val other = record(101, listOf(611, 640, 655, 690, 700, 710))
        val kept = OuraRedrainCollapse.withoutRedrainedRuns(first + other + record(102, six))
        assertEquals(first + other, kept)
    }

    @Test
    fun `a clean night is unchanged`() {
        val beats = (0 until 600).flatMap { second ->
            record(1_000L + second, (0 until 6).map { 700 + (second * 7 + it * 13) % 400 })
        }
        assertEquals(beats, OuraRedrainCollapse.withoutRedrainedRuns(beats))
    }
}
