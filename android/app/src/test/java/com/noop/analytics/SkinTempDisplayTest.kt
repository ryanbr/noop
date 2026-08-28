package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    // ---- dominantKind (#1705) ----

    @Test fun dominantKindIsTheNewestEntrys() {
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.dominantKind(listOf(34.6, 35.1, -0.2)))
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.dominantKind(listOf(-0.2, 0.1, 34.6)))
        assertNull(SkinTempDisplay.dominantKind(emptyList()))
    }

    @Test fun dominantKindOfASingleKindWindowIsThatKind() {
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.dominantKind(listOf(-0.24, 0.21, 0.01)))
        assertEquals(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.dominantKind(listOf(32.39, 34.60, 36.64)))
    }

    /**
     * The regression guard the issue asked for: filtering by [SkinTempDisplay.dominantKind] must leave a
     * window that no aggregate can straddle. Values are the reported ones — a 313-row absolute import
     * (32.39..36.64, mean 34.60) coexisting with computed deviations inside +/-0.3.
     */
    @Test fun filteringByDominantKindLeavesOneScale() {
        val mixed = listOf(34.60, 35.12, 32.39, 36.64, -0.24, 0.21, 0.01, 0.11, 0.0)
        val keep = SkinTempDisplay.dominantKind(mixed)!!
        val kept = mixed.filter { SkinTempDisplay.kind(it) == keep }
        assertEquals(listOf(-0.24, 0.21, 0.01, 0.11, 0.0), kept)
        assertTrue(kept.all { SkinTempDisplay.kind(it) == keep })
        // The defect: unfiltered, the mean of a should-be-near-zero deviation window clears a degree and
        // then reads BELOW 20, so it gets labelled deviation — plausible-looking and wrong.
        val unfilteredMean = mixed.average()
        assertTrue(unfilteredMean > 1.0)
        assertEquals(SkinTempDisplay.Kind.DEVIATION, SkinTempDisplay.kind(unfilteredMean))
        assertTrue(kotlin.math.abs(kept.average()) < 0.3)
    }
}