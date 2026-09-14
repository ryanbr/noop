package com.noop.analytics

import com.noop.data.DailyMetric
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class V5HealthSignalsTest {

    private fun day(
        offset: Long,
        restingHr: Int? = null,
        hrv: Double? = null,
        skinTemp: Double? = null,
        respiration: Double? = null,
    ) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = LocalDate.of(2026, 1, 1).plusDays(offset).toString(),
        restingHr = restingHr,
        avgHrv = hrv,
        skinTempDevC = skinTemp,
        respRateBpm = respiration,
    )

    @Test
    fun `different vital rows cannot combine into a trusted illness baseline`() {
        val history = (0L until 14L).map { offset ->
            if (offset % 2L == 0L) day(offset, restingHr = 55)
            else day(offset, hrv = 50.0)
        }
        val snapshot = V5HealthSignals.evaluate(
            days = history + day(14, skinTemp = 0.6, respiration = 18.0),
            cycleOptedIn = false,
        )

        assertFalse(snapshot.baselineTrusted)
        assertEquals(IllnessSignalEngine.Level.QUIET, snapshot.illness.level)
        assertEquals("Still learning your baseline - keeping an eye out.", snapshot.illness.copy)
    }

    @Test
    fun `fourteen nights for one illness signal are trusted`() {
        val history = (0L until 14L).map { offset ->
            day(offset, restingHr = 54 + (offset % 3L).toInt())
        }
        val snapshot = V5HealthSignals.evaluate(
            days = history + day(14, restingHr = 64),
            cycleOptedIn = false,
        )

        assertTrue(snapshot.baselineTrusted)
    }

    @Test
    fun `temperature trust remains local to the cycle engine`() {
        val days = (0L until 56L).map { offset -> day(offset, skinTemp = 0.2) }
        val snapshot = V5HealthSignals.evaluate(days = days, cycleOptedIn = true)

        assertFalse(snapshot.baselineTrusted)
        assertEquals(IllnessSignalEngine.Level.QUIET, snapshot.illness.level)
        assertNotEquals(CyclePhaseEngine.Phase.LEARNING, snapshot.cycle.phase)
    }
}
