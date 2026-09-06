package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HeartRateRecoveryTest {
    private val end = 10_000L

    private fun denseEligible(endHr: Int = 170): List<HrSample> =
        (end - 300..end).map { ts -> HrSample("strap", ts, if (ts >= end - 30) endHr else 145) }

    private fun window(minutes: Int, values: List<Int>): List<HrSample> {
        val target = end + minutes * 60L
        return values.mapIndexed { i, bpm -> HrSample("strap", target - values.size / 2 + i, bpm) }
    }

    private fun result(eligibilitySamples: List<HrSample>): HeartRateRecovery.Result? =
        HeartRateRecovery.calculate(
            eligibilitySamples + window(1, listOf(140, 140, 140)), end - 300, end, 200.0,
        )

    @Test
    fun calculatesOneTwoAndFiveMinuteDropsFromRobustReadings() {
        val samples = denseEligible() +
            window(1, listOf(146, 146, 220, 146, 146)) +
            window(2, listOf(132, 132, 132)) +
            window(5, listOf(112, 112, 112))

        assertEquals(
            HeartRateRecovery.Result(170, 24, 38, 58),
            HeartRateRecovery.calculate(samples.shuffled(), end - 300, end, 200.0),
        )
    }

    @Test
    fun requiresSustainedHighIntensityRatherThanOnePeak() {
        val samples = (end - 300..end).map { HrSample("strap", it, 120) } +
            HrSample("strap", end, 190) + window(1, listOf(140, 140, 140))
        assertNull(HeartRateRecovery.calculate(samples, end - 300, end, 200.0))
    }

    @Test
    fun rejectsDisconnectedHighIntensityFragments() {
        val sparse = (end - 300..end step 15).map { HrSample("strap", it, 170) }
        assertNull(HeartRateRecovery.calculate(sparse + window(1, listOf(140, 140, 140)), end - 300, end, 200.0))
    }

    @Test
    fun rejectsThreeSeparatedFortySecondHighIntensityRuns() {
        val samples = listOf(
            HrSample("strap", end - 140, 170), HrSample("strap", end - 130, 170),
            HrSample("strap", end - 120, 170), HrSample("strap", end - 110, 170),
            HrSample("strap", end - 100, 120),
            HrSample("strap", end - 90, 170), HrSample("strap", end - 80, 170),
            HrSample("strap", end - 70, 170), HrSample("strap", end - 60, 170),
            HrSample("strap", end - 50, 120),
            HrSample("strap", end - 40, 170), HrSample("strap", end - 30, 170),
            HrSample("strap", end - 20, 170), HrSample("strap", end - 10, 170),
            HrSample("strap", end, 120),
        )

        assertNull(result(samples))
    }

    @Test
    fun gapExactlyAtCapUsesLeftSampleAndExactMinimumIsAccepted() {
        val samples = (end - 120..end - 10 step 10).map { HrSample("strap", it, 170) } +
            HrSample("strap", end, 120)

        assertEquals(HeartRateRecovery.Result(170, 30, null, null), result(samples))
    }

    @Test
    fun gapOverCapResetsTheQualifyingRun() {
        val beforeGap = (end - 180..end - 110 step 10).map { HrSample("strap", it, 170) }
        val afterGap = (end - 99..end - 9 step 10).map { HrSample("strap", it, 170) } +
            HrSample("strap", end, 170)

        assertNull(result(beforeGap + afterGap))
    }

    @Test
    fun belowThresholdIntervalResetsTheQualifyingRun() {
        val samples = (end - 130..end step 10).map { ts ->
            HrSample("strap", ts, if (ts == end - 60) 120 else 170)
        }

        assertNull(result(samples))
    }

    @Test
    fun duplicateTimestampDoesNotBreakAnOtherwiseContinuousRun() {
        val samples = (end - 120..end step 10).map { HrSample("strap", it, 170) } +
            HrSample("strap", end - 60, 120)

        assertEquals(HeartRateRecovery.Result(170, 30, null, null), result(samples))
    }

    @Test
    fun doesNotCreditPreWorkoutHeartRateTowardEligibility() {
        val samples = denseEligible() + window(1, listOf(140, 140, 140))
        assertNull(HeartRateRecovery.calculate(samples, end - 60, end, 200.0))
    }

    @Test
    fun returnsOnlyMeasurementsWithRealCoverage() {
        val samples = denseEligible() + window(1, listOf(150, 150, 150)) + window(5, listOf(110, 110))
        assertEquals(
            HeartRateRecovery.Result(170, 20, null, null),
            HeartRateRecovery.calculate(samples, end - 300, end, 200.0),
        )
    }

    @Test
    fun noPostWorkoutCoverageReturnsNull() {
        assertNull(HeartRateRecovery.calculate(denseEligible(), end - 300, end, 200.0))
    }

    @Test
    fun aHeartRateRiseRemainsSignedInsteadOfBeingClamped() {
        val result = HeartRateRecovery.calculate(
            denseEligible(160) + window(1, listOf(165, 165, 165)), end - 300, end, 200.0,
        )
        assertEquals(-5, result?.after1Minute)
    }
}
