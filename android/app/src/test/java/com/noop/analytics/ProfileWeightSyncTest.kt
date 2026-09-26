package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale

/** The resolver both the profile weight sync and the Today Weight tile read. */
class ProfileWeightSyncTest {

    @Test
    fun newest_picksTheLatestDay_notTheLastListed() {
        val readings = listOf(
            WeightReading("2026-09-20", 73.0),
            WeightReading("2026-09-25", 72.4),
            WeightReading("2026-09-22", 72.9),
        )
        assertEquals(WeightReading("2026-09-25", 72.4), ProfileWeightSync.newest(readings))
    }

    @Test
    fun newest_nullWhenThereIsNoReading() {
        assertNull(ProfileWeightSync.newest(emptyList()))
    }

    @Test
    fun captionDate_followsTheGivenLocale() {
        // The regression guard for the Locale.US / hardcoded-English pattern: an Italian UI must not
        // read an English month.
        assertEquals("25 set", ProfileWeightSync.captionDate("2026-09-25", Locale.ITALIAN))
        assertEquals("25 Sep", ProfileWeightSync.captionDate("2026-09-25", Locale.US))
    }

    @Test
    fun captionDate_unparseableDayIsReturnedVerbatim() {
        assertEquals("not-a-day", ProfileWeightSync.captionDate("not-a-day", Locale.US))
    }
}
