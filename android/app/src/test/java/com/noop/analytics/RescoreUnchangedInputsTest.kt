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

    /** Each profile field moves the key: calories read weight, height, age and sex. */
    @Test
    fun everyProfileFieldMovesTheLoadKey() {
        val base = UserProfile()
        fun key(p: UserProfile) = PhysiologicalStepCycleEngine.loadCacheKey(
            1_000L, 87_400L, "my-whoop=1:2", 55.0, 192.6, StrainScorer.Method.EDWARDS, p)
        listOf(base.copy(weightKg = 71.0), base.copy(heightCm = 171.0), base.copy(age = 31.0),
               base.copy(sex = "male"), base.copy(stepTicksPerStep = 2.0), base.copy(waistCm = 80.0))
            .forEach { assertNotEquals(key(base), key(it)) }
        assertEquals(key(base), key(base.copy()))
    }
}
