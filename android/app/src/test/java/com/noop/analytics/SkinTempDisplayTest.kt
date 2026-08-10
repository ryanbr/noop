package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte-parity twin of Swift `SkinTempDisplayTests` (#622). */
class SkinTempDisplayTest {

    @Test
    fun kindSplitsAbsoluteAndDeviation() {
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.kind(34.2))
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.kind(20.0))
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.kind(0.1))
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.kind(-0.1))
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.kind(19.9))
    }

    @Test
    fun unitSymbolMarksDeviation() {
        assertEquals("°C", SkinTempDisplay.unitSymbol(SkinTempDisplay.Kind.ABSOLUTE, fahrenheit = false))
        assertEquals("°F", SkinTempDisplay.unitSymbol(SkinTempDisplay.Kind.ABSOLUTE, fahrenheit = true))
        assertEquals("Δ°C", SkinTempDisplay.unitSymbol(SkinTempDisplay.Kind.DEVIATION, fahrenheit = false))
        assertEquals("Δ°F", SkinTempDisplay.unitSymbol(SkinTempDisplay.Kind.DEVIATION, fahrenheit = true))
    }

    @Test
    fun numberStringAbsoluteUnsigned() {
        assertEquals(
            "34.2",
            SkinTempDisplay.numberString(34.24, SkinTempDisplay.Kind.ABSOLUTE, fahrenheit = false),
        )
    }

    @Test
    fun numberStringDeviationAlwaysSigned() {
        assertEquals(
            "-0.1",
            SkinTempDisplay.numberString(-0.1, SkinTempDisplay.Kind.DEVIATION, fahrenheit = false),
        )
        assertEquals(
            "+0.3",
            SkinTempDisplay.numberString(0.3, SkinTempDisplay.Kind.DEVIATION, fahrenheit = false),
        )
    }

    @Test
    fun fahrenheitConversionAbsoluteVsDelta() {
        assertEquals(
            "32",
            SkinTempDisplay.numberString(0.0, SkinTempDisplay.Kind.ABSOLUTE, fahrenheit = true, decimals = 0),
        )
        assertEquals(
            "+1.8",
            SkinTempDisplay.numberString(1.0, SkinTempDisplay.Kind.DEVIATION, fahrenheit = true),
        )
    }

    @Test
    fun formatCombinesNumberAndUnit() {
        assertEquals("-0.1 Δ°C", SkinTempDisplay.format(-0.1, fahrenheit = false))
        assertEquals("34.2 °C", SkinTempDisplay.format(34.2, fahrenheit = false))
    }

    @Test
    fun parityWithIsAbsoluteSkinTemp() {
        for (v in listOf(-2.0, -0.1, 0.0, 0.5, 19.9, 20.0, 30.6, 34.24)) {
            val abs = VitalBands.isAbsoluteSkinTemp(v)
            assertEquals(
                "v=$v",
                abs,
                SkinTempDisplay.kind(v) == SkinTempDisplay.Kind.ABSOLUTE,
            )
        }
    }
}
