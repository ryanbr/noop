package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins which pace a stress check-in's breath runs at: the locked resonance pace only while "Use my resonance
 * pace" is on. Same cases as the Swift `CheckInLockedPaceTests`.
 */
class CheckInLockedPaceTest {

    @Test
    fun onWithALockedPaceUsesIt() {
        assertEquals(6.2, BiofeedbackPrefs.checkInLockedPace(useResonance = true, locked = 6.2)!!, 0.0)
    }

    @Test
    fun offFallsBackEvenWithALockedPace() {
        assertNull(BiofeedbackPrefs.checkInLockedPace(useResonance = false, locked = 6.2))
    }

    @Test
    fun noLockedPaceFallsBackEitherWay() {
        assertNull(BiofeedbackPrefs.checkInLockedPace(useResonance = true, locked = null))
        assertNull(BiofeedbackPrefs.checkInLockedPace(useResonance = false, locked = null))
    }
}
