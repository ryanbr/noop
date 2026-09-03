package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1844: which of a night's two skin-temp numbers a surface leads with, and how it reads once formatted.
 *
 * The rule the Health tile has used since #1665, made pure so Today and the detail screen can share it:
 * a deviation with no anchor cannot be read, so a measured absolute wins whenever the night has one.
 */
class SkinTempLeadReadingTest {

    /** The everyday case: the night measured a real temperature, so that is what shows. */
    @Test
    fun absoluteWinsWhenTheNightMeasuredOne() {
        val r = SkinTempDisplay.leadReading(absC = 33.8, devC = -0.1)!!
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, r.kind)
        assertEquals(33.8, r.value, 1e-9)
        assertEquals("33.8 °C", SkinTempDisplay.formatReading(r, fahrenheit = false))
    }

    /** A night scored before skinTempC shipped (2026-08-27) keeps EXACTLY the display that shipped before. */
    @Test
    fun deviationLedNightIsUnchanged() {
        val r = SkinTempDisplay.leadReading(absC = null, devC = -0.1)!!
        assertEquals(SkinTempDisplay.Kind.DEVIATION, r.kind)
        assertEquals("-0.1 Δ°C", SkinTempDisplay.formatReading(r, fahrenheit = false))
    }

    /** A CALIBRATING night is the reverse — measured absolute, no usable baseline yet, so no deviation.
     *  This is the case that previously showed an empty card with a real temperature behind it. */
    @Test
    fun calibratingNightStillShowsItsTemperature() {
        val r = SkinTempDisplay.leadReading(absC = 34.1, devC = null)!!
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, r.kind)
        assertEquals("34.1 °C", SkinTempDisplay.formatReading(r, fahrenheit = false))
    }

    /** Nothing measured stays nothing: the carry must never invent a reading. */
    @Test
    fun noNumbersCarryNothing() {
        assertNull(SkinTempDisplay.leadReading(absC = null, devC = null))
    }

    /** °F uses the full conversion for an absolute and the offset-free one for a deviation — the whole
     *  reason the kind has to travel with the value rather than being re-guessed at the format call. */
    @Test
    fun fahrenheitConvertsEachKindByItsOwnRule() {
        val abs = SkinTempDisplay.leadReading(absC = 35.0, devC = null)!!
        assertEquals("95.0 °F", SkinTempDisplay.formatReading(abs, fahrenheit = true))
        val dev = SkinTempDisplay.leadReading(absC = null, devC = 1.0)!!
        assertEquals("+1.8 Δ°F", SkinTempDisplay.formatReading(dev, fahrenheit = true))
    }

    /** #1842 still holds through the new path: a deviation that rounds to zero drops its sign. */
    @Test
    fun signedZeroStaysFixedThroughLeadReading() {
        val r = SkinTempDisplay.leadReading(absC = null, devC = -0.02)!!
        assertEquals("0.0 Δ°C", SkinTempDisplay.formatReading(r, fahrenheit = false))
    }
}
