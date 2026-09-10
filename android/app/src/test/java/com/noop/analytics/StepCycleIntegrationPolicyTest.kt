package com.noop.analytics

import com.noop.data.SleepSession
import com.noop.data.StepSample
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StepCycleIntegrationPolicyTest {
    private fun sleep(owner: String, start: Long, end: Long) = SleepSession(
        deviceId = "$owner-noop",
        startTs = start,
        endTs = end,
        stagesJSON = "[{\"start\":$start,\"end\":$end,\"stage\":\"light\"}]",
    )

    @Test fun calendarFallbackExistsOnlyBeforeTheFirstConfirmedCycle() {
        assertEquals(410, DayCycleIntelligenceIntegration.integratedStepValue(410, false, null))
        assertNull(DayCycleIntelligenceIntegration.integratedStepValue(410, true, null))
        assertEquals(37, DayCycleIntelligenceIntegration.integratedStepValue(410, true, 37))
    }

    @Test fun establishedCycleAppliesEveryAdditiveDailyMetricTogether() {
        val day = "2026-09-04"
        val result = PhysiologicalStepCycleEngine.Result(
            cycleStepsByWakeDay = mapOf(day to 42),
            cycleStrainByWakeDay = mapOf(day to 61.0),
            cycleCaloriesByWakeDay = mapOf(day to 1840.0),
            cycleWorkoutCountByWakeDay = mapOf(day to 2),
            boundaryOnsetByWakeDay = emptyMap(), firstCycleWakeDay = day,
            recoveredOwnerMarkerRows = emptyList(),
        )

        val updated = DayCycleIntelligenceIntegration.apply(
            DailyMetric(deviceId = "strap-noop", day = day, steps = 1, strain = 2.0,
                activeKcalEst = 3.0, exerciseCount = 4),
            result, "strap-noop", mutableListOf(),
        )

        assertEquals(42, updated.steps)
        assertEquals(61.0, updated.strain)
        assertEquals(1840.0, updated.activeKcalEst)
        assertEquals(2, updated.exerciseCount)
    }

    @Test fun warmUnchangedCycleDoesNotReadStepRowsAgain() {
        val old = DayCycleIntelligenceIntegration.cacheKey(
            owner = "strap-a", sleepId = "night-a", onset = 100, end = 200,
            stepRevision = "20500:7",
            sleepContextSignature = "100-200:light",
            contributingDayKeys = listOf("2026-08-20" to "hr:100:199"),
        )
        val same = DayCycleIntelligenceIntegration.cacheKey(
            owner = "strap-a", sleepId = "night-a", onset = 100, end = 200,
            stepRevision = "20500:7",
            sleepContextSignature = "100-200:light",
            contributingDayKeys = listOf("2026-08-20" to "hr:100:199"),
        )

        assertFalse(DayCycleIntelligenceIntegration.shouldRecount(old, same))
    }

    @Test fun activeDayChangeOrBoundaryEditRecountsOnlyTheAffectedCycle() {
        fun key(onset: Long, witness: String) = DayCycleIntelligenceIntegration.cacheKey(
            owner = "strap-a", sleepId = "night-a", onset = onset, end = 500,
            stepRevision = "20500:7",
            sleepContextSignature = "100-200:light",
            contributingDayKeys = listOf("2026-08-21" to witness),
        )
        val old = key(100, "hr:100:400")

        assertTrue(DayCycleIntelligenceIntegration.shouldRecount(old, key(100, "hr:120:499")))
        assertTrue(DayCycleIntelligenceIntegration.shouldRecount(old, key(110, "hr:100:400")))
        assertTrue(DayCycleIntelligenceIntegration.shouldRecount(null, old))
    }

    @Test fun cacheIdentityIsDeviceScoped() {
        fun key(owner: String) = DayCycleIntelligenceIntegration.cacheKey(
            owner = owner, sleepId = "night-a", onset = 100, end = 200,
            stepRevision = "20500:7",
            sleepContextSignature = "100-200:light",
            contributingDayKeys = listOf("2026-08-20" to "same-witness"),
        )

        assertTrue(DayCycleIntelligenceIntegration.shouldRecount(key("strap-a"), key("strap-b")))
    }

    @Test fun aRealStepInsertRevisionInvalidatesButAnUnchangedRevisionDoesNot() {
        fun key(revision: String) = DayCycleIntelligenceIntegration.cacheKey(
            owner = "strap-a", sleepId = "night-a", onset = 100, end = 0,
            stepRevision = revision,
            sleepContextSignature = "100-200:light",
            contributingDayKeys = listOf("2026-08-21" to "unchanged-day-cache"),
        )
        assertFalse(DayCycleIntelligenceIntegration.shouldRecount(key("20500:7"), key("20500:7")))
        assertTrue(DayCycleIntelligenceIntegration.shouldRecount(key("20500:7"), key("20500:8")))
    }

    @Test fun effectiveSleepContextEditInvalidatesOnlyItsIntersectingCycle() {
        fun key(context: String) = DayCycleIntelligenceIntegration.cacheKey(
            "strap", "night", 100, 200, "day:7", context, emptyList(),
        )
        assertTrue(DayCycleIntelligenceIntegration.shouldRecount(key("100-180:light"), key("100-190:light")))
        assertFalse(DayCycleIntelligenceIntegration.shouldRecount(key("unrelated"), key("unrelated")))
    }

    @Test fun archivedPredecessorRestoresOnlyAMarkerBackedMainSleepBoundary() {
        val onset = 20 * 3_600L
        val end = onset + 8 * 3_600L
        val restored = DayCycleIntelligenceIntegration.persistedBoundaries(
            candidates = listOf("strap-b" to 0, "strap-a" to 4),
            sessionsByOwner = mapOf("strap-a" to listOf(sleep("strap-a", onset, end))),
            markerOnsetByOwnerAndDay = mapOf("strap-a" to mapOf("1970-01-02" to onset)),
            currentBoundaryWakeDays = emptySet(),
            tzOffsetSeconds = 0,
            habitualMidsleepSec = null,
        )

        assertEquals(1, restored.size)
        assertEquals("strap-a", restored.single().owner)
        assertEquals(onset, restored.single().boundary.onset)
        assertEquals("1970-01-02", restored.single().wakeDay)
        assertEquals(onset, restored.single().sleepContext.start)

        // Real re-add seam: archived A supplies the morning boundary/steps; active B starts at 14:00.
        val bStarts = 38 * 3_600L
        val cycleEnd = 44 * 3_600L
        assertEquals(
            listOf(
                PhysiologicalSteps.OwnerSegment("strap-a", onset, bStarts),
                PhysiologicalSteps.OwnerSegment("strap-b", bStarts, cycleEnd),
            ),
            PhysiologicalSteps.ownerSegmentsFromCoverage(
                PhysiologicalSteps.CycleWindow(restored.single().boundary.sleepId, onset, cycleEnd),
                listOf(
                    PhysiologicalSteps.OwnerCoverage("strap-a", onset, bStarts, priority = 4),
                    PhysiologicalSteps.OwnerCoverage("strap-b", bStarts, cycleEnd, priority = 0),
                ),
                fallbackOwner = "strap-a",
            ),
        )
        fun row(owner: String, ts: Long, counter: Int) = StepSample(owner, ts, counter, activityClass = 1)
        val a = SleepAwareStepCounter.Accumulator(emptyList(), hasActivityClasses = true)
            .acceptPage(listOf(row("strap-a", onset, 100), row("strap-a", onset + 3, 110))).finish()
        val b = SleepAwareStepCounter.Accumulator(emptyList(), hasActivityClasses = true)
            .acceptPage(listOf(row("strap-b", bStarts, 50), row("strap-b", bStarts + 2, 57))).finish()
        assertEquals(17, a.totalTicks + b.totalTicks)
    }

    @Test fun markerRewriteCleansEveryNamespaceThatRecoveryMayRead() {
        assertEquals(
            listOf("strap-b-noop", "my-whoop-noop", "strap-a-noop"),
            DayCycleIntelligenceIntegration.markerRewriteSourceIds(
                currentComputedSources = listOf("strap-b-noop", "my-whoop-noop"),
                candidateComputedSources = listOf("strap-b-noop", "strap-a-noop", "strap-a-noop"),
            ),
        )
    }

    @Test fun recoveredOwnerMarkerSurvivesCleanupAndProducesTheSameBoundaryOnPassTwo() {
        val onset = 20 * 3_600L
        val end = onset + 8 * 3_600L
        val sessions = mapOf("strap-a" to listOf(sleep("strap-a", onset, end)))
        val pass1 = DayCycleIntelligenceIntegration.persistedBoundaries(
            candidates = listOf("strap-b" to 0, "strap-a" to 4),
            sessionsByOwner = sessions,
            markerOnsetByOwnerAndDay = mapOf("strap-a" to mapOf("1970-01-02" to onset)),
            currentBoundaryWakeDays = emptySet(),
            tzOffsetSeconds = 0,
            habitualMidsleepSec = null,
        )

        // Model the transaction: every old candidate marker was deleted; only emitted rows survive.
        val rewritten = DayCycleIntelligenceIntegration.recoveredMarkerRows(pass1) { "$it-noop" }
        val pass2Markers = rewritten.groupBy { it.deviceId.removeSuffix("-noop") }
            .mapValues { (_, rows) -> rows.associate { it.day to it.value.toLong() } }
        val pass2 = DayCycleIntelligenceIntegration.persistedBoundaries(
            candidates = listOf("strap-b" to 0, "strap-a" to 4),
            sessionsByOwner = sessions,
            markerOnsetByOwnerAndDay = pass2Markers,
            currentBoundaryWakeDays = emptySet(),
            tzOffsetSeconds = 0,
            habitualMidsleepSec = null,
        )

        assertEquals(pass1.map { it.boundary }, pass2.map { it.boundary })
        assertEquals("strap-a-noop", rewritten.single().deviceId)
    }

    @Test fun staleMarkerWithoutMatchingMainSleepSessionIsNeverResurrected() {
        val onset = 20 * 3_600L
        val end = onset + 8 * 3_600L
        val recovered = DayCycleIntelligenceIntegration.persistedBoundaries(
            candidates = listOf("strap-a" to 4),
            sessionsByOwner = mapOf("strap-a" to listOf(sleep("strap-a", onset, end))),
            markerOnsetByOwnerAndDay = mapOf("strap-a" to mapOf("1970-01-02" to onset - 60)),
            currentBoundaryWakeDays = emptySet(),
            tzOffsetSeconds = 0,
            habitualMidsleepSec = null,
        )
        assertTrue(recovered.isEmpty())
        assertTrue(DayCycleIntelligenceIntegration.recoveredMarkerRows(recovered) { "$it-noop" }.isEmpty())
    }

    @Test fun currentDetectedOrEditedBoundaryWinsOverArchivedPersistence() {
        val onset = 20 * 3_600L
        val end = onset + 8 * 3_600L
        assertTrue(
            DayCycleIntelligenceIntegration.persistedBoundaries(
                candidates = listOf("strap-a" to 4),
                sessionsByOwner = mapOf("strap-a" to listOf(sleep("strap-a", onset, end))),
                markerOnsetByOwnerAndDay = mapOf("strap-a" to mapOf("1970-01-02" to onset)),
                currentBoundaryWakeDays = setOf("1970-01-02"),
                tzOffsetSeconds = 0,
                habitualMidsleepSec = null,
            ).isEmpty(),
        )
    }
}
