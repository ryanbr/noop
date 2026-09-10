package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A bucket aggregate omits buckets that had no samples, and the chart spaces points by index, so
 * without a break the stroke joins the two sides of an absence and draws a steady climb across hours
 * the strap recorded nothing. These ids are what break it.
 *
 * The same table is asserted in Swift `HrGapSegmentsTests`, so the two platforms cannot start
 * disagreeing about what counts as a gap.
 */
class HrGapSegmentsTest {

    private val b = 300L

    @Test fun contiguousBucketsAreOneUnbrokenLine() {
        val ts = listOf(0L, 300L, 600L, 900L)
        assertEquals(listOf("0", "0", "0", "0"), hrGapSegmentIds(ts, b))
    }

    @Test fun oneMissingBucketBreaksIt() {
        // 0, 300, [900 missing 600], so the step from 300 to 900 spans two buckets.
        val ts = listOf(0L, 300L, 900L, 1_200L)
        assertEquals(listOf("0", "0", "1", "1"), hrGapSegmentIds(ts, b))
    }

    @Test fun everyGapAdvancesTheSegment() {
        val ts = listOf(0L, 900L, 1_200L, 3_000L)
        assertEquals(listOf("0", "1", "1", "2"), hrGapSegmentIds(ts, b))
    }

    @Test fun aLongAbsenceIsStillOneBreakNotMany() {
        // The four and a half hour hole from the report: one break, not fifty-four.
        val ts = listOf(0L, 300L, 300L + 16_200L)
        assertEquals(listOf("0", "0", "1"), hrGapSegmentIds(ts, b))
    }

    @Test fun exactlyOneBucketApartIsNotAGap() {
        assertEquals(listOf("0", "0"), hrGapSegmentIds(listOf(0L, 300L), b))
    }

    @Test fun degenerateInputsDoNotThrow() {
        assertEquals(emptyList<String>(), hrGapSegmentIds(emptyList(), b))
        assertEquals(listOf("0"), hrGapSegmentIds(listOf(42L), b))
    }

    @Test fun theBucketWidthIsRespectedRatherThanAssumed() {
        // A 15-second load (the narrow end of the dynamic sizing) must not read every step as a gap.
        val ts = listOf(0L, 15L, 30L, 90L)
        assertEquals(listOf("0", "0", "0", "1"), hrGapSegmentIds(ts, 15L))
    }
}
