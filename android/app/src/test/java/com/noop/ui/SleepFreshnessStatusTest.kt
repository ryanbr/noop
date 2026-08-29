package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SleepFreshnessStatusTest {
    @Test fun currentNightNeedsNoBanner() {
        assertNull(resolveSleepFreshness(true, true, false, false, true, false))
    }

    @Test fun doesNotDeclareMissingBeforeMorning() {
        assertNull(resolveSleepFreshness(false, false, false, false, true, false))
    }

    @Test fun progressStatesWinOverStaleHistory() {
        assertEquals(
            SleepFreshnessStatus.SYNCING,
            resolveSleepFreshness(false, true, true, true, false, true),
        )
        assertEquals(
            SleepFreshnessStatus.CALCULATING,
            resolveSleepFreshness(false, true, false, true, true, true),
        )
    }

    @Test fun completedSyncWithoutNightIsExplicitlyNotDetected() {
        assertEquals(
            SleepFreshnessStatus.NOT_DETECTED,
            resolveSleepFreshness(false, true, false, false, true, false),
        )
    }

    @Test fun distinguishesFailedAndNotYetRunSyncs() {
        assertEquals(
            SleepFreshnessStatus.SYNC_FAILED,
            resolveSleepFreshness(false, true, false, false, false, true),
        )
        assertEquals(
            SleepFreshnessStatus.AWAITING_SYNC,
            resolveSleepFreshness(false, true, false, false, false, false),
        )
    }
}
