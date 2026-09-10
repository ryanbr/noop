package com.noop.ui

import com.noop.data.HrBucket
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #852: the pure half of the body-clock binning. Android had the CircadianEngine, its tests and the
 * BodyClockCard all along, and only ever lacked this input — `V5HealthSignals` hardcoded `bodyClock =
 * null` behind a comment claiming the data did not exist. It did: Swift derives the same profile from
 * HR buckets Android also banks (`AppModel.computeCircadianPhase`).
 *
 * These pin the maths that has to match that twin: the >= 24-bucket floor, pooling by LOCAL hour, the
 * mean per populated hour, and `daysObserved` as distinct local days.
 */
class CircadianBinsTest {

    /** One bucket per hour for [hours] consecutive hours from [startTs], all at [bpm]. */
    private fun series(startTs: Long, hours: Int, bpm: Double = 60.0) =
        (0 until hours).map {
            HrBucket(bucket = startTs + it * 3_600L, avgBpm = bpm, minBpm = bpm, maxBpm = bpm)
        }

    @Test fun underTwentyFourBucketsIsRefused() {
        val (bins, days) = circadianBinsFrom(series(0, 23), tzOffsetSeconds = 0)
        assertTrue("a sub-day span cannot carry a 24 h rhythm", bins.isEmpty())
        assertEquals(0, days)
    }

    @Test fun exactlyTwentyFourBucketsGivesTwentyFourBins() {
        val (bins, days) = circadianBinsFrom(series(0, 24), tzOffsetSeconds = 0)
        assertEquals(24, bins.size)
        assertEquals((0..23).map { it.toDouble() }, bins.map { it.hour })
        assertEquals(1, days)
    }

    /** The activity value is the MEAN over that local hour across days, not the sum. */
    @Test fun repeatedHoursAverageRatherThanAccumulate() {
        val day1 = series(0, 24, bpm = 50.0)
        val day2 = series(86_400, 24, bpm = 70.0)
        val (bins, days) = circadianBinsFrom(day1 + day2, tzOffsetSeconds = 0)
        assertEquals(24, bins.size)
        assertTrue("every hour should read the mean of 50 and 70", bins.all { it.activity == 60.0 })
        assertEquals(2, days)
    }

    /** Pooling is by LOCAL hour: a +1 h zone shifts every bucket one slot, and can roll a day over. */
    @Test fun poolingUsesTheLocalHourNotUtc() {
        val utc = circadianBinsFrom(series(0, 48), tzOffsetSeconds = 0)
        val plus1 = circadianBinsFrom(series(0, 48), tzOffsetSeconds = 3_600)
        assertEquals(24, utc.first.size)
        assertEquals(24, plus1.first.size)
        // 48 h from epoch spans 2 UTC days; shifted +1 h it touches a third local day.
        assertEquals(2, utc.second)
        assertEquals(3, plus1.second)
    }

    /** A negative offset must not produce a negative hour — the double-modulo guards that. */
    @Test fun negativeOffsetWrapsRatherThanGoingNegative() {
        val (bins, _) = circadianBinsFrom(series(0, 48), tzOffsetSeconds = -5 * 3_600L)
        assertTrue("hours stay in 0..23", bins.all { it.hour >= 0.0 && it.hour <= 23.0 })
        assertEquals(24, bins.size)
    }

    /** Sparse coverage yields only the populated hours — the caller's >= 6 floor decides usability. */
    @Test fun onlyPopulatedHoursBecomeBins() {
        // 30 buckets all landing in the same 6 local hours (one per hour across 5 days).
        val sparse = (0 until 5).flatMap { d ->
            (0 until 6).map { h ->
                HrBucket(bucket = d * 86_400L + h * 3_600L, avgBpm = 55.0, minBpm = 55.0, maxBpm = 55.0)
            }
        }
        val (bins, days) = circadianBinsFrom(sparse, tzOffsetSeconds = 0)
        assertEquals(6, bins.size)
        assertEquals((0..5).map { it.toDouble() }, bins.map { it.hour })
        assertEquals(5, days)
    }
}
