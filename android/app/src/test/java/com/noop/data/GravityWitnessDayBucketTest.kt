package com.noop.data

import com.noop.analytics.IntelligenceEngine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The contract the batched gravity witness rests on.
 *
 * `WhoopDao.gravityWitnessByDay` groups by `(ts + tzOffset) / 86400` in SQL, while the steps-calibration
 * loop looks a day up by `(dayMid + tzOffset) / 86400` in Kotlin, with `dayMid` from
 * `IntelligenceEngine.midnightLocal`. Those two have to name the same bucket for every sample in a day, or
 * the loop reads a witness belonging to a different day and the motion cache silently serves the wrong
 * fold. Sixty per-day queries could not get this wrong because each one carried its own window; one
 * grouped query can, so it is pinned here.
 *
 * Both sides truncate toward zero, which equals floor only while `ts + tzOffset` is non-negative. Real
 * timestamps sit above the 1.7e9 plausibility floor and offsets are at most 14h, so it always is, and the
 * final case says so rather than leaving it to be rediscovered.
 */
class GravityWitnessDayBucketTest {

    private val day = 86_400L

    /** Mirrors `IntelligenceEngine.midnightLocal`. */
    private fun midnightLocal(ts: Long, offsetSec: Long): Long = ts - Math.floorMod(ts + offsetSec, day)

    /** The PRODUCTION expression, not a copy of it: the caller and the SQL `GROUP BY` share this. */
    private fun bucket(ts: Long, offsetSec: Long): Long = IntelligenceEngine.localDayBucket(ts, offsetSec)

    // Auckland standard and DST, UTC, India's half hour, and a western offset.
    private val offsets = listOf(12 * 3600L, 13 * 3600L, 0L, 5 * 3600L + 1800L, -5 * 3600L, -11 * 3600L)

    @Test
    fun `every second of a local day shares that day's bucket`() {
        val anchor = 1_789_000_000L
        for (off in offsets) {
            val dayMid = midnightLocal(anchor, off)
            val expected = bucket(dayMid, off)
            for (probe in listOf(0L, 1L, 3600L, day / 2, day - 2, day - 1)) {
                assertEquals(
                    "offset=$off probe=$probe must land in the day's own bucket",
                    expected, bucket(dayMid + probe, off),
                )
            }
        }
    }

    @Test
    fun `the second after a day ends belongs to the next bucket`() {
        val anchor = 1_789_000_000L
        for (off in offsets) {
            val dayMid = midnightLocal(anchor, off)
            assertEquals(
                "offset=$off: dayEnd + 1 is the next day",
                bucket(dayMid, off) + 1, bucket(dayMid + day, off),
            )
        }
    }

    @Test
    fun `sixty consecutive days occupy sixty consecutive buckets`() {
        val anchor = 1_789_000_000L
        for (off in offsets) {
            val now = midnightLocal(anchor, off)
            val buckets = (0 until 60).map { bucket(midnightLocal(now - it * day, off), off) }
            assertEquals("offset=$off: no two days may share a bucket", 60, buckets.toSet().size)
            assertEquals("offset=$off: and they must be contiguous", buckets.min()..buckets.max(),
                         buckets.min()..(buckets.min() + 59))
        }
    }

    @Test
    fun `a day with no rows is absent, which is why the caller supplies the zero`() {
        // The query cannot return a bucket for a day that banked nothing: GROUP BY emits a row per
        // surviving group. The loop's `?: (0 to 0L)` is that missing row, not a defensive flourish.
        val present = mapOf(10L to (5 to 1_789_000_000L))
        assertEquals(5 to 1_789_000_000L, present[10L] ?: (0 to 0L))
        assertEquals(0 to 0L, present[11L] ?: (0 to 0L))
    }

    @Test
    fun `truncation equals floor across the plausible timestamp range`() {
        // Truncation toward zero and floor diverge only for a negative dividend. Every real ts clears the
        // 1.7e9 plausibility floor and the largest western offset is well under a day, so the sum stays
        // positive and the two agree.
        for (off in offsets) {
            for (ts in listOf(1_700_000_000L, 1_789_000_000L, 2_000_000_000L)) {
                assertTrue("ts=$ts offset=$off must keep the dividend positive", ts + off > 0)
                assertEquals(Math.floorDiv(ts + off, day), bucket(ts, off))
            }
        }
    }
}
