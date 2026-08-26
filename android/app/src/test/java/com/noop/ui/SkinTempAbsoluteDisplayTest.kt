package com.noop.ui

import com.noop.analytics.VitalBands
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1636: the skin-temp TILE leads with the night's ABSOLUTE, with the deviation beneath it.
 *
 * A deviation with no anchor cannot be read — the reporter's flu night was "+0.94 Δ°F", which looks
 * like nothing, against 96.4 °F on a 94.4 °F mean. Both numbers are needed and neither is sufficient.
 *
 * `vitalsFor` resolves strings through `NoopApplication` and cannot run in a JVM test at all, so the
 * BRANCH and the FORMATTING are asserted through their pure seams — the arrangement
 * `Spo2MissingCaptionTest` already uses for the same reason. Twin of Swift `SkinTempAbsoluteDisplayTests`.
 */
class SkinTempAbsoluteDisplayTest {

    // The branch: absolute-led, or the pre-#1636 deviation-led display

    @Test
    fun aNightThatMeasuredAnAbsoluteLeadsWithIt() {
        assertTrue(skinTempLeadsWithAbsolute(34.6))
    }

    @Test
    fun aNightPredatingTheColumnKeepsTheOldDisplay() {
        // Deviation-only: the tile must look exactly as it did before, not blank out.
        assertFalse(skinTempLeadsWithAbsolute(null))
    }

    // The secondary note: the deviation, in the user's own unit

    @Test
    fun theNoteCarriesTheSignAndTheDeltaUnit() {
        // The reporter's Aug 14, both ways round.
        assertEquals("+0.5 Δ°C", skinTempSecondaryNote(0.52, fahrenheit = false))
        assertEquals("+0.9 Δ°F", skinTempSecondaryNote(0.52, fahrenheit = true))
    }

    @Test
    fun aNegativeDeviationKeepsItsSign() {
        assertEquals("-0.5 Δ°C", skinTempSecondaryNote(-0.5, fahrenheit = false))
        assertEquals("-0.9 Δ°F", skinTempSecondaryNote(-0.5, fahrenheit = true))
    }

    @Test
    fun aFahrenheitDeviationScalesWithoutTheOffset() {
        // A whole degree of DEVIATION is 1.8 °F, never 33.8 — the +32 offset would be wrong for a delta.
        assertEquals("+1.8 Δ°F", skinTempSecondaryNote(1.0, fahrenheit = true))
    }

    // The caption ordering, the Kotlin twin of Swift's stateCaption assertions

    private fun tile(secondary: String?, caveat: String? = null, band: VitalBands.Band = VitalBands.Band.IN_RANGE) =
        Vital(
            key = "skin", label = "Skin Temp", unit = "°C", value = 34.6,
            format = { String.format(java.util.Locale.US, "%.1f", it) },
            missingCaption = "none",
            banding = VitalBands.Result(band, VitalBands.Basis.PERSONAL, 24),
            metricColor = androidx.compose.ui.graphics.Color.Yellow,
            caveat = caveat, secondary = secondary,
        )

    @Test
    fun theSecondaryLeadsTheCaptionSoItSitsUnderTheValue() {
        assertTrue(tile(secondary = "+0.9 Δ°F").stateCaption.startsWith("+0.9 Δ°F · "))
    }

    @Test
    fun withoutASecondaryTheCaptionIsUnchanged() {
        // Every other vital passes null, so their captions must be byte-identical to before.
        assertEquals("In your range", tile(secondary = null).stateCaption)
    }

    @Test
    fun theSecondaryIsIndependentOfTheCaveat() {
        // `caveat` says the reading is unreliable; `secondary` says what it means. A tile may carry
        // both, and they must not be confused for one another.
        val caption = tile(secondary = "+0.9 Δ°F", caveat = "unverified").stateCaption
        assertTrue(caption.startsWith("+0.9 Δ°F · "))
        assertTrue(caption.endsWith("unverified"))
    }

    @Test
    fun anEmptyTileNeverCarriesASecondary() {
        // The caption there is the "why it's empty" line; a number beside it would contradict it.
        assertEquals("none", tile(secondary = "+0.9 Δ°F", band = VitalBands.Band.NO_DATA).stateCaption)
    }

    /**
     * A CALIBRATING night is the case worth having: `recomputeSkinTempDev` returns null until the
     * baseline is usable (~4 nights) while the absolute is already measured. The tile leads with the
     * temperature and simply omits the note, rather than printing an empty line under the headline.
     */
    @Test
    fun aCalibratingNightLeadsWithTheAbsoluteAndOmitsTheNote() {
        assertTrue(skinTempLeadsWithAbsolute(34.6))
        assertNull(skinTempSecondaryNote(null, fahrenheit = false))
        assertNull(skinTempSecondaryNote(null, fahrenheit = true))
    }
}
