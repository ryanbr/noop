package com.noop.analytics

import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the shared windowed step kernel [StepsCounter.stepsInWindow] (#398). The same wrap-aware
 * positive-delta math the daily total uses (see StepsAnalyticsTest), but exercised directly and
 * order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
 * the caller's `stepTicksPerStep` calibration). Byte-for-byte twin of the Swift StepsCounterTests.
 */
class StepsCounterTest {

    private fun step(ts: Long, counter: Int, activityClass: Int? = null) =
        StepSample(deviceId = "my-whoop", ts = ts, counter = counter, activityClass = activityClass)

    @Test fun sumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        assertEquals(120, StepsCounter.stepsInWindow(listOf(step(0, 100), step(60, 150), step(120, 220))))
    }

    @Test fun sortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        assertEquals(120, StepsCounter.stepsInWindow(listOf(step(120, 220), step(0, 100), step(60, 150))))
    }

    @Test fun handlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) and 0xFFFF = 56; then 20 -> 80 => 60. Total 116.
        assertEquals(116, StepsCounter.stepsInWindow(listOf(step(0, 65_500), step(60, 20), step(120, 80))))
    }

    @Test fun fewerThanTwoSamplesIsNull() {
        assertNull(StepsCounter.stepsInWindow(emptyList()))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100))))
    }

    @Test fun noForwardMovementIsNull() {
        // Flat counter across the window => no positive delta => null (not 0).
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 500), step(60, 500), step(120, 500))))
    }

    @Test fun dropsBigGapDeltaAsBoundary() {
        // A jump >= 512 is dropped; the real 40 + 30 survive => 70.
        assertEquals(70, StepsCounter.stepsInWindow(
            listOf(step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030))))
    }

    @Test fun maxStepDeltaBoundaryIsExclusive() {
        // Exactly MAX_STEP_DELTA (512) is dropped; 511 counts.
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 0), step(128, 512))))
        assertEquals(511, StepsCounter.stepsInWindow(listOf(step(0, 0), step(128, 511))))
    }

    @Test fun rejectsPhysicallyImpossibleOneSecondSpikeButAllowsSameTicksAcrossTime() {
        // Four ticks/second (240/min) remains available for a hard sprint. Seven ticks in one second is
        // the observed household outlier and cannot be real gait; the same seven ticks across two seconds
        // can be a small history hole and must remain recoverable.
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100), step(1, 107))))
        assertEquals(7, StepsCounter.stepsInWindow(listOf(step(0, 100), step(2, 107))))
        assertEquals(4, StepsCounter.stepsInWindow(listOf(step(0, 100), step(1, 104))))
    }

    @Test fun classedStreamCountsOnlyWalkAndRunDeltas() {
        // Attribute each counter delta to the later sample, matching the strap's per-record class.
        // still: +10 ignored; walk: +20; run: +15; unknown: +25 ignored => 35 locomotion ticks.
        assertEquals(35, StepsCounter.stepsInWindow(listOf(
            step(0, 100, 0),
            step(10, 110, 0),
            step(20, 130, 1),
            step(30, 145, 2),
            step(40, 170, null),
        )))
    }

    @Test fun legacyUnclassedStreamKeepsCounterFallback() {
        // Rows written before activityClass existed must retain their historical estimate.
        assertEquals(70, StepsCounter.stepsInWindow(listOf(
            step(0, 100), step(10, 140), step(20, 170),
        )))
    }
}
