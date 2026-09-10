package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Recovery Vitals card's HR-only note (#1801) — when it appears, and whose night it describes.
 *
 * A field log showed HRV and resting HR blank for a week beside a populated respiratory rate, which reads
 * as a failed sync. It was not: with no motion the HR-only spine stages the night and nulls both vitals on
 * purpose. The note says so. These pin the two ways it could lie instead: appearing on a night that has
 * its vitals, and explaining a DIFFERENT night's staging than the numbers shown.
 */
class HrOnlyNoteTest {

    private fun day(hrOnly: Boolean?) =
        DailyMetric(deviceId = "my-whoop", day = "2026-09-03", sleepHrOnly = hrOnly)

    @Test
    fun `shows when today was staged from heart rate alone and a vital is blank`() {
        assertTrue(showsHrOnlyNote(day(true), null, carriedFromVitals = false, hrv = null, rhr = null))
    }

    @Test
    fun `stays quiet when the night kept its vitals`() {
        // Both present: nothing to explain, so the note would be noise.
        assertFalse(showsHrOnlyNote(day(true), null, carriedFromVitals = false, hrv = 42.0, rhr = 55))
    }

    @Test
    fun `an unknown flag earns no claim`() {
        // Tri-state: null is "not known" (every row scored before v36), not "had motion".
        assertFalse(showsHrOnlyNote(day(null), null, carriedFromVitals = false, hrv = null, rhr = null))
        assertFalse(showsHrOnlyNote(day(false), null, carriedFromVitals = false, hrv = null, rhr = null))
    }

    @Test
    fun `it describes the night the shown vitals came from, not today`() {
        // Carried: the numbers on screen are the CARRY's, so the note must read the carry's flag.
        assertTrue(showsHrOnlyNote(day(null), day(true), carriedFromVitals = true, hrv = null, rhr = null))
        // And the reverse — today's own blank night must not be explained by a carry that had motion.
        assertFalse(showsHrOnlyNote(day(false), day(true), carriedFromVitals = false, hrv = null, rhr = null))
        // The bug this shape avoids: `day?.sleepHrOnly ?: vitalsDay?.sleepHrOnly` would fall through on a
        // pre-v36 today and stamp the carry's staging onto today's numbers.
        assertFalse(showsHrOnlyNote(day(null), day(true), carriedFromVitals = false, hrv = null, rhr = null))
    }
}
