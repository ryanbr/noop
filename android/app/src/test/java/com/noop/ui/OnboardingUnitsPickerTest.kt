package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Guards the onboarding Units control (#781). The ProfileStep onboarding step now carries a
 * Metric/Imperial [SegmentedPillControl] so US users can pick their units during setup, instead of being
 * locked to kg/cm until they later found Settings. That control writes [NoopPrefs.KEY_UNIT_SYSTEM] (via
 * NoopPrefs.setUnitSystem) and labels its segments from the [UnitSystem] raw values, exactly like the
 * Settings -> Units card.
 *
 * These tests pin that wiring contract so a rename of the key or a raw value can't silently leave the
 * onboarding picker writing one place while the formatter reads another (the bug #781 fixed). Mirrors the
 * macOS OnboardingUnitsPickerTests case-for-case.
 */
class OnboardingUnitsPickerTest {

    /** The onboarding picker, the Settings card, and the formatter must all read/write the SAME key. */
    @Test
    fun unitSystemKeyIsTheSharedPrefsKey() {
        assertEquals("units.system", NoopPrefs.KEY_UNIT_SYSTEM)
        assertEquals("units.distance", NoopPrefs.KEY_DISTANCE_UNIT_SYSTEM)
    }

    /** The control's items are the [UnitSystem] entries; their raw values must round-trip through the
     *  same [UnitSystem.fromRaw] resolver every screen reads units with. */
    @Test
    fun rawValuesRoundTripThroughResolver() {
        assertEquals(UnitSystem.METRIC, UnitSystem.fromRaw(UnitSystem.METRIC.raw))
        assertEquals(UnitSystem.IMPERIAL, UnitSystem.fromRaw(UnitSystem.IMPERIAL.raw))
        assertEquals("metric", UnitSystem.METRIC.raw)
        assertEquals("imperial", UnitSystem.IMPERIAL.raw)
    }

    /** An unset or unknown stored value resolves to Metric, matching the wizard's default. */
    @Test
    fun unknownRawDefaultsToMetric() {
        assertEquals(UnitSystem.METRIC, UnitSystem.fromRaw("nonsense"))
        assertEquals(UnitSystem.METRIC, UnitSystem.fromRaw(null))
    }

    /** Picking Imperial must actually change what the Weight/Height steppers render. */
    @Test
    fun pickingImperialChangesTheDisplayedWeightAndHeight() {
        val kg = 74.5
        val cm = 178.0
        assertEquals("74.5 kg", UnitFormatter.massFromKilograms(kg, UnitSystem.METRIC))
        assertNotEquals(
            UnitFormatter.massFromKilograms(kg, UnitSystem.METRIC),
            UnitFormatter.massFromKilograms(kg, UnitSystem.IMPERIAL),
        )
        assertEquals("178 cm", UnitFormatter.heightFromCentimeters(cm, UnitSystem.METRIC))
        assertNotEquals(
            UnitFormatter.heightFromCentimeters(cm, UnitSystem.METRIC),
            UnitFormatter.heightFromCentimeters(cm, UnitSystem.IMPERIAL),
        )
    }
}
