package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

class DayCycleResolverTest {
    @Test fun sleepOnsetIsTheDefaultPersistedMode() {
        assertEquals(DayCycleMode.SLEEP_ONSET, DayCycleMode.fromPersisted(null))
        assertEquals(DayCycleMode.SLEEP_ONSET, DayCycleMode.fromPersisted("unknown"))
    }

    @Test fun fallbackUsesTheFirstMidnightAtLeastEighteenHoursAfterOnset() {
        val monday2300 = 23 * 3_600L
        assertEquals(2 * 86_400L, DayCycleResolver.fallbackMidnightAfter(monday2300, 0))
    }

    @Test fun allNighterStaysOpenUntilTheAbsoluteCap() {
        val sleep = DayCycleWindow("night", 0, 0, "1970-01-01", DayCycleWindow.Source.DETECTED_SLEEP)
        assertEquals(
            DayCycleWindow.Source.DETECTED_SLEEP,
            DayCycleResolver.activeWindow(DayCycleMode.SLEEP_ONSET, sleep, 39 * 3_600L, 0).source,
        )
        assertEquals(
            DayCycleWindow.Source.SYNTHETIC_MIDNIGHT,
            DayCycleResolver.activeWindow(DayCycleMode.SLEEP_ONSET, sleep, 40 * 3_600L, 0).source,
        )
    }

    @Test fun sleepOnsetCycleStaysOpenAcrossMidnight() {
        val sleep = DayCycleWindow("night", 23 * 3_600L, 0, "1970-01-02", DayCycleWindow.Source.DETECTED_SLEEP)
        assertEquals(
            DayCycleWindow.Source.DETECTED_SLEEP,
            DayCycleResolver.activeWindow(DayCycleMode.SLEEP_ONSET, sleep, 2 * 86_400L + 60, 0).source,
        )
    }

    @Test fun midnightModeStillResetsAtCalendarMidnight() {
        val sleep = DayCycleWindow("night", 23 * 3_600L, 0, "1970-01-02", DayCycleWindow.Source.DETECTED_SLEEP)
        assertEquals(
            DayCycleWindow.Source.CALENDAR,
            DayCycleResolver.activeWindow(DayCycleMode.MIDNIGHT, sleep, 2 * 86_400L + 60, 0).source,
        )
    }
}
