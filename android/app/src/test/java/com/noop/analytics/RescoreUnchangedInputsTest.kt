package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * A post-sync pass must not redo work whose inputs did not change: tonight's growing session is not learned
 * from (so it cannot drop the day cache), and a closed cycle's Effort/calories key only moves with its inputs.
 */
class RescoreUnchangedInputsTest {
    private val midnight = 1_789_603_200L

    @Test
    fun tonightsGrowingSessionIsNotLearnedFrom() {
        val lastNight = SleepSession(deviceId = "my-whoop-noop", startTs = midnight - 86_400 + 3_600, endTs = midnight - 86_400 + 30_600)
        val tonight = SleepSession(deviceId = "my-whoop-noop", startTs = midnight + 1_800, endTs = midnight + 34_200)
        assertEquals(listOf(lastNight), IntelligenceEngine.finishedSessions(listOf(lastNight, tonight), midnight))
    }

    @Test
    fun theCycleLoadKeyMovesOnlyWithItsInputs() {
        val profile = UserProfile()
        fun key(witness: String, rhr: Double = 55.0) = PhysiologicalStepCycleEngine.loadCacheKey(
            1_000L, 87_400L, witness, rhr, 192.6, StrainScorer.Method.EDWARDS, profile)
        assertEquals(key("my-whoop=86000:87399"), key("my-whoop=86000:87399"))
        assertNotEquals(key("my-whoop=86000:87399"), key("my-whoop=86001:87399"))
        assertNotEquals(key("my-whoop=86000:87399"), key("my-whoop=86000:87399", rhr = 56.0))
    }
}
