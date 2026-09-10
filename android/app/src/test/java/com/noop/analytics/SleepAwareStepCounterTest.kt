package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SleepAwareStepCounterTest {
    private fun step(ts: Long, counter: Int, activityClass: Int? = 1) =
        StepSample("strap", ts, counter, activityClass)

    private fun sleep(start: Long, end: Long, stages: List<StageSegment> = emptyList()) =
        DetectedSleep(start, end, 0.9, stages, null, null)

    @Test fun outsideSleepUsesTheNormalCounterRulesExactly() {
        val samples = listOf(
            step(0, 100, 0),
            step(1, 102, 1),
            step(2, 110, 1), // impossible 8 ticks/s: rejected by StepsCounter too
            step(4, 117, 2),
            step(5, 120, 0),
        )

        assertEquals(StepsCounter.stepsInWindow(samples), SleepAwareStepCounter.stepsInWindow(samples, emptyList()))
        assertEquals(9, SleepAwareStepCounter.stepsInWindow(samples, emptyList()))
        val detail = SleepAwareStepCounter.count(samples, emptyList())
        assertEquals(3, detail.rejectedActivityClassTicks)
        assertEquals(8, detail.rejectedImplausibleTicks)
    }

    @Test fun awakeGapInsideSleepCountsWithNormalRules() {
        val session = sleep(
            0, 120,
            listOf(
                StageSegment(0, 30, "light"),
                StageSegment(30, 60, "awake"),
                StageSegment(60, 120, "deep"),
            ),
        )
        val samples = listOf(step(29, 100), step(30, 101), step(31, 103), step(32, 104))

        // The isolated +1 at t=30 and the following awake deltas are all in an explicitly awake gap.
        assertEquals(4, SleepAwareStepCounter.stepsInWindow(samples, listOf(session)))
    }

    @Test fun isolatedWalkClassBedTicksAreRejected() {
        val session = sleep(0, 180, listOf(StageSegment(0, 180, "light")))
        val samples = listOf(
            step(0, 100), step(10, 101), step(11, 102),
            step(70, 102), step(71, 104),
            step(150, 104),
        )

        assertNull(SleepAwareStepCounter.stepsInWindow(samples, listOf(session)))
        val detail = SleepAwareStepCounter.count(samples, listOf(session))
        assertEquals(4, detail.rejectedIsolatedSleepTicks)
        assertEquals(0, detail.totalTicks)
    }

    @Test fun shortCoherentToiletWalkDuringScoredSleepIsPreservedExactly() {
        val session = sleep(0, 120, listOf(StageSegment(0, 120, "light")))
        val samples = buildList {
            add(step(20, 500))
            var counter = 500
            for (second in 21L..30L) {
                counter += 2
                add(step(second, counter))
            }
        }

        // Ten coherent seconds, twenty raw locomotion ticks. No calibration/conversion belongs here.
        assertEquals(20, SleepAwareStepCounter.stepsInWindow(samples, listOf(session)))
        val detail = SleepAwareStepCounter.count(samples, listOf(session))
        assertEquals(20, detail.acceptedSleepBoutTicks)
        assertEquals(20, detail.totalTicks)
    }

    @Test fun coherentSleepBoutFailsSafeWhenGravityIsMissing() {
        val session = sleep(0, 90, listOf(StageSegment(0, 90, "rem")))
        val samples = listOf(
            step(10, 10), step(11, 12), step(12, 14), step(13, 16),
            step(14, 18), step(15, 20), step(16, 22),
        )

        assertEquals(12, SleepAwareStepCounter.stepsInWindow(samples, listOf(session), gravity = emptyList()))
    }

    @Test fun decisionDoesNotDependOnADeviceOrientationVector() {
        val session = sleep(0, 90, listOf(StageSegment(0, 90, "deep")))
        val samples = listOf(
            step(10, 10), step(11, 12), step(12, 14), step(13, 16),
            step(14, 18), step(15, 20), step(16, 22),
        )
        fun gravity(x: Double, y: Double, z: Double) = (10L..16L).map {
            GravitySample("strap", it, x, y, z)
        }

        val faceUp = SleepAwareStepCounter.stepsInWindow(samples, listOf(session), gravity(0.0, 0.0, 1.0))
        val rotated = SleepAwareStepCounter.stepsInWindow(samples, listOf(session), gravity(0.8, -0.6, 0.0))
        assertEquals(12, faceUp)
        assertEquals(faceUp, rotated)
    }

    @Test fun sleepSessionWithoutStagesIsConservativelyTreatedAsSleep() {
        val samples = listOf(step(10, 100), step(11, 101), step(12, 102))
        assertNull(SleepAwareStepCounter.stepsInWindow(samples, listOf(sleep(0, 60))))
    }

    @Test fun pagingKeepsCounterPredecessorAndOpenGaitBout() {
        val session = sleep(0, 90, listOf(StageSegment(0, 90, "light")))
        val all = listOf(
            step(10, 100), step(11, 102), step(12, 104), step(13, 106),
            step(14, 108), step(15, 110), step(16, 112),
        )
        val accumulator = SleepAwareStepCounter.Accumulator(listOf(session), hasActivityClasses = true)
        accumulator.acceptPage(all.take(4))
        // Intentional one-row overlap also proves that page boundaries do not double count.
        accumulator.acceptPage(all.drop(3))

        assertEquals(SleepAwareStepCounter.count(all, listOf(session)), accumulator.finish())
        assertEquals(12, accumulator.finish().acceptedSleepBoutTicks)
    }

    @Test fun pagingUsesOneActivityClassModeForTheWholeWindow() {
        val accumulator = SleepAwareStepCounter.Accumulator(emptyList(), hasActivityClasses = true)
        accumulator.acceptPage(listOf(step(0, 100, null), step(1, 102, null)))
        accumulator.acceptPage(listOf(step(2, 104, 1)))

        // Unknown +2 in page one is rejected because a later page proves this is a classed stream.
        assertEquals(2, accumulator.finish().totalTicks)
    }

    @Test fun editedBoundsKeepStagesAndTreatNewEdgesAsSleep() {
        val detected = sleep(100, 200, listOf(StageSegment(100, 200, "light")))
        val edited = SleepAwareStepCounter.withBounds(detected, start = 90, end = 220)
        val samples = listOf(
            step(89, 100), step(90, 101), step(91, 102),
            step(210, 102), step(211, 104),
        )

        assertEquals(listOf(StageSegment(100, 200, "light")), edited.stages)
        assertNull(SleepAwareStepCounter.stepsInWindow(samples, listOf(edited)))
    }

    @Test fun wakeEditChangesOnlyIntersectingCycleContextSignature() {
        val before = sleep(100, 180, listOf(StageSegment(100, 180, "light")))
        val after = SleepAwareStepCounter.withBounds(before, 100, 190)
        assertEquals(
            SleepAwareStepCounter.contextSignature(listOf(before), 200, 300),
            SleepAwareStepCounter.contextSignature(listOf(after), 200, 300),
        )
        org.junit.Assert.assertNotEquals(
            SleepAwareStepCounter.contextSignature(listOf(before), 100, 200),
            SleepAwareStepCounter.contextSignature(listOf(after), 100, 200),
        )
    }
}
