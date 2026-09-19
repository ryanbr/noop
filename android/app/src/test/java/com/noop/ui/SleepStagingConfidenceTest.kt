package com.noop.ui

import com.noop.analytics.ScoreConfidence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The #H9 UI gate: it must flag a high-efficiency night whose deep+REM share is implausibly low, and must
 * NOT flag a healthy night, a genuinely fragmented (low-efficiency) night, or an unstaged night. The gate
 * delegates to [ScoreConfidence.forRest], so these pin the UI side against the same thresholds the daily
 * pass uses. Pure: no Composable, no BLE.
 *
 * Twin of Swift `StrandTests/SleepStagingConfidenceTests`, case for case and value for value, so the two
 * platforms cannot drift apart on what earns the badge.
 */
class SleepStagingConfidenceTest {

    /** A high-efficiency night with near-zero deep+REM: flagged low-confidence (likely staging miss). */
    @Test fun `high efficiency with near-zero restorative is low confidence`() {
        // 7h asleep, ~2% restorative, 95% efficiency: well below the 10% floor on a >85%-efficiency night.
        val asleep = 7.0 * 60.0
        assertTrue(stageStagingIsLowConfidence(asleep, deepMin = 4.0, remMin = 4.0, efficiency = 0.95))
    }

    /** A healthy night (deep+REM ~45% of asleep) is NEVER flagged: its staging is plausible. */
    @Test fun `a healthy restorative share is not flagged`() {
        val asleep = 7.0 * 60.0
        assertFalse(stageStagingIsLowConfidence(asleep, deepMin = 90.0, remMin = 100.0, efficiency = 0.95))
    }

    /** A genuinely FRAGMENTED night legitimately carries less deep/REM, so the floor must not fire there. */
    @Test fun `a low efficiency night is not flagged even with low restorative`() {
        val asleep = 5.0 * 60.0
        assertFalse(stageStagingIsLowConfidence(asleep, deepMin = 3.0, remMin = 3.0, efficiency = 0.60))
    }

    /** An UNSTAGED night has no staging split to doubt; its base Rest tier already reads honestly. */
    @Test fun `an unstaged night is not flagged`() {
        assertFalse(stageStagingIsLowConfidence(6 * 60.0, deepMin = 0.0, remMin = 0.0, efficiency = 0.95))
    }

    /** A zero-asleep night cannot be evaluated: never flagged, and no divide-by-zero. */
    @Test fun `a zero asleep night is not flagged`() {
        assertFalse(stageStagingIsLowConfidence(0.0, deepMin = 0.0, remMin = 0.0, efficiency = 0.95))
    }

    /** The UI gate and the engine agree: where the gate is true, the engine's H9 overload also downgrades. */
    @Test fun `the gate agrees with the engine rest confidence`() {
        val asleep = 7.0 * 60.0
        val deep = 4.0
        val rem = 4.0
        val eff = 0.95
        assertTrue(stageStagingIsLowConfidence(asleep, deep, rem, eff))
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(
                hasSession = true,
                hasStagedSleep = true,
                asleepSeconds = asleep * 60.0,
                restorativeSeconds = (deep + rem) * 60.0,
                efficiency = eff,
            ),
        )
    }
}
