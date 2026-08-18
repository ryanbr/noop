package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class ReadinessTrainingLoadTest {
    private fun metric(day: Int, strain: Double?, hrv: Double = 60.0, rhr: Int = 52): DailyMetric =
        DailyMetric(
            deviceId = "test-device",
            day = String.format(Locale.US, "2026-01-%02d", day),
            restingHr = rhr,
            avgHrv = hrv,
            strain = strain,
            respRateBpm = 14.0,
        )

    @Test
    fun pairedApiLeavesExistingReadinessExactlyUnchanged() {
        val days = (1..28).map { day ->
            metric(
                day,
                strain = if (day <= 21) 5.0 else 15.0,
                hrv = if (day % 2 == 0) 62.0 else 58.0,
                rhr = if (day % 2 == 0) 54 else 50,
            )
        }

        val existing = ReadinessEngine.evaluate(days)
        val paired = ReadinessEngine.evaluateWithTrainingLoad(days)

        assertEquals(existing, paired.readiness)
        assertTrue(paired.trainingLoad.isAvailable)
        assertEquals(TrainingLoadEngine.State.BUILDING, paired.trainingLoad.state)
        assertNotNull(paired.trainingLoad.ctl)
        assertNotNull(paired.trainingLoad.atl)
        assertNotNull(paired.trainingLoad.tsb)
    }

    @Test
    fun existingAcwrAndMonotonyRemainOwnedByReadiness() {
        val days = (1..28).map { day ->
            metric(day, if (day <= 21) 5.0 else (12 + day % 3).toDouble())
        }
        val paired = ReadinessEngine.evaluateWithTrainingLoad(days)

        assertNotNull(paired.readiness.acwr)
        assertNotNull(paired.readiness.monotony)
        assertTrue(paired.trainingLoad.isAvailable)
        assertEquals("2026-01-28", paired.trainingLoad.endDay)
    }

    @Test
    fun missingLoadBreaksTrainingModelWithoutSuppressingReadiness() {
        val days = (1..28).map { metric(it, if (it == 21) null else 10.0) }
        val paired = ReadinessEngine.evaluateWithTrainingLoad(days)

        assertNotEquals(ReadinessEngine.Level.INSUFFICIENT, paired.readiness.level)
        assertEquals(TrainingLoadEngine.State.UNAVAILABLE, paired.trainingLoad.state)
        assertEquals(
            TrainingLoadEngine.UnavailableReason.NOT_ENOUGH_CONTIGUOUS_DAYS,
            paired.trainingLoad.unavailableReason,
        )
        assertEquals(7, paired.trainingLoad.contiguousDays)
    }

    @Test
    fun explicitMissingTodayFailsClosedForBothAnalyses() {
        val days = (1..28).map { metric(it, 10.0) }
        val paired = ReadinessEngine.evaluateWithTrainingLoad(days, today = "2026-02-01")

        assertEquals(ReadinessEngine.Level.INSUFFICIENT, paired.readiness.level)
        assertEquals(TrainingLoadEngine.State.UNAVAILABLE, paired.trainingLoad.state)
        assertEquals(TrainingLoadEngine.UnavailableReason.MISSING_TARGET_DAY, paired.trainingLoad.unavailableReason)
    }

    @Test
    fun explicitTodayIgnoresFutureTrainingRows() {
        val days = (1..28).map { day -> metric(day, if (day <= 20) 10.0 else 100.0) }
        val paired = ReadinessEngine.evaluateWithTrainingLoad(days, today = "2026-01-20")

        assertEquals("2026-01-20", paired.trainingLoad.endDay)
        assertEquals(20, paired.trainingLoad.contiguousDays)
        assertEquals(10.0, paired.trainingLoad.points.last().load, 0.0)
    }
}
