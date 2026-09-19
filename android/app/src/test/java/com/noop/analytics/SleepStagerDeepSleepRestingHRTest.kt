package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The night's resting HR is the mean HR across its deep-sleep segments, not its single calmest 5-min bin.
 * Twin of Swift `SleepStagerDeepSleepRestingHRTests`.
 */
class SleepStagerDeepSleepRestingHRTest {

    private val start = 1_000_000L
    private val dev = "test"

    private fun samples(from: Long, to: Long, bpm: Int) = (from until to).map { HrSample(deviceId = dev, ts = it, bpm = bpm) }

    /** A 40-min night: 10 min light at 60, 20 min deep at 55, 10 min light holding a 5-min dip at 48. */
    private val hr = samples(start, start + 600, 60) + samples(start + 600, start + 1_800, 55) +
        samples(start + 1_800, start + 2_100, 48) + samples(start + 2_100, start + 2_400, 60)
    private val stages = listOf(
        StageSegment(start, start + 600, "light"),
        StageSegment(start + 600, start + 1_800, "deep"),
        StageSegment(start + 1_800, start + 2_400, "light"),
    )
    private val end = start + 2_400

    @Test
    fun theRestingHrIsTheDeepSleepMeanNotTheLowestBin() {
        assertEquals(55, SleepStager.sessionDeepSleepRestingHR(start, end, hr, stages))
        assertEquals(48, SleepStager.sessionRestingHR(start, end, hr))
    }

    @Test
    fun implausibleSamplesDoNotPullTheDeepSleepMeanDown() {
        assertEquals(55, SleepStager.sessionDeepSleepRestingHR(start, end, samples(start + 600, start + 660, 0) + hr, stages))
    }

    @Test
    fun tooLittleDeepSleepFallsBackToTheLowerQuartileBin() {
        val briefDeep = listOf(StageSegment(start + 600, start + 840, "deep"))
        assertEquals(55, SleepStager.sessionDeepSleepRestingHR(start, end, hr, briefDeep))
        assertEquals(55, SleepStager.sessionDeepSleepRestingHR(start, end, hr, emptyList()))
    }

    @Test
    fun aSessionWithNoSamplesHasNoRestingHr() {
        assertNull(SleepStager.sessionDeepSleepRestingHR(start, start + 600, emptyList(), stages))
    }
}
