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

    // MARK: the Settings choice (#1846)

    /** Choosing the deviation leads with it even on a night that measured a real temperature. */
    @Test
    fun deviationPreferenceLeadsWithTheDelta() {
        val r = SkinTempDisplay.leadReading(absC = 33.8, devC = -0.1,
                                            prefer = SkinTempDisplay.Kind.DEVIATION)!!
        assertEquals(SkinTempDisplay.Kind.DEVIATION, r.kind)
        assertEquals("-0.1 Δ°C", SkinTempDisplay.formatReading(r, fahrenheit = false))
    }

    /** The choice is a PREFERENCE, not a filter: a night with only the other number still shows it,
     *  so flipping the setting can never blank a card. Both directions. */
    @Test
    fun eitherPreferenceFallsBackToTheNumberTheNightHas() {
        val devOnly = SkinTempDisplay.leadReading(absC = null, devC = -0.4,
                                                   prefer = SkinTempDisplay.Kind.ABSOLUTE)!!
        assertEquals("-0.4 Δ°C", SkinTempDisplay.formatReading(devOnly, fahrenheit = false))

        val absOnly = SkinTempDisplay.leadReading(absC = 34.2, devC = null,
                                                   prefer = SkinTempDisplay.Kind.DEVIATION)!!
        assertEquals("34.2 °C", SkinTempDisplay.formatReading(absOnly, fahrenheit = false))
    }

    /** The unit always names the scale ACTUALLY shown, never the one that was asked for — otherwise a
     *  fallback would print a temperature under a Δ label, or a delta as a wrist temperature. */
    @Test
    fun theUnitFollowsTheValueNotThePreference() {
        val r = SkinTempDisplay.leadReading(absC = 34.2, devC = null,
                                            prefer = SkinTempDisplay.Kind.DEVIATION)!!
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, r.kind)
        assertEquals("°C", SkinTempDisplay.unitSymbol(r.kind, fahrenheit = false))
    }

    /** Default is unchanged, so an install that never opens Settings behaves exactly as #1844 shipped. */
    @Test
    fun defaultIsAbsolute() {
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE,
                     SkinTempDisplay.leadReading(absC = 33.0, devC = 0.5)!!.kind)
    }


    /** The PERSISTED token, byte-identical to the Swift `Kind.rawValue` — both platforms share the
     *  `units.skinTempDisplay` key, so a drift here (e.g. writing `Kind.name`) would make one platform
     *  unable to read the other's stored choice. Same contract `KeyMetric.raw` already pins. */
    @Test
    fun rawTokensMatchTheSwiftRawValues() {
        assertEquals("absolute", SkinTempDisplay.Kind.ABSOLUTE.raw)
        assertEquals("deviation", SkinTempDisplay.Kind.DEVIATION.raw)
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.Kind.fromRaw("deviation"))
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.Kind.fromRaw("absolute"))
        // Anything unrecognised (including the old uppercase spelling) falls back at the read site.
        assertNull(SkinTempDisplay.Kind.fromRaw("DEVIATION"))
        assertNull(SkinTempDisplay.Kind.fromRaw(null))
    }

}
