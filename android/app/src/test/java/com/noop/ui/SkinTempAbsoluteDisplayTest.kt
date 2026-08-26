package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1636: the Skin Temperature screen leads with the night's ABSOLUTE, with the deviation beneath it.
 *
 * A deviation with no anchor cannot be read — the reporter's flu night was "+0.94 Δ°F", which looks
 * like nothing, against 96.4 °F on a 94.4 °F mean, which reads as a fever. Both numbers are needed and
 * neither is sufficient.
 *
 * `buildVitalDetail` resolves strings through `NoopApplication` and cannot run in a JVM test, so the
 * BRANCH and the FORMATTING are extracted and asserted here — the same arrangement `Spo2MissingCaptionTest`
 * uses for the same reason. Twin of Swift `SkinTempAbsoluteDisplayTests`.
 */
class SkinTempAbsoluteDisplayTest {

    private fun row(day: String, abs: Double? = null, dev: Double? = null) =
        DailyMetric(deviceId = "my-whoop", day = day, skinTempC = abs, skinTempDevC = dev)

    // The branch: absolute-led or the pre-#1636 deviation-led fallback

    @Test
    fun theFreshestMeasuredAbsoluteWins() {
        val days = listOf(
            row("2026-08-23", abs = 33.9, dev = -0.2),
            row("2026-08-24", abs = 34.1, dev = 0.0),
            row("2026-08-25", abs = 34.6, dev = 0.52),
        )
        assertEquals(34.6, latestSkinAbsoluteC(days)!!, 1e-12)
    }

    @Test
    fun historyPredatingTheColumnFallsBackRatherThanShowingNothing() {
        // Every night deviation-only: the screen must keep its old behaviour, not blank out.
        val days = listOf(row("2026-08-24", dev = -0.2), row("2026-08-25", dev = 0.52))
        assertNull(latestSkinAbsoluteC(days))
    }

    @Test
    fun aPartlyRescoredHistoryStillLeadsWithTheAbsolute() {
        // Older nights predate the column; the recent ones were re-scored. Newest-first means the
        // wearer gets the absolute rather than waiting for the whole history to refill.
        val days = listOf(
            row("2026-08-20", dev = -0.4),
            row("2026-08-21", dev = -0.1),
            row("2026-08-25", abs = 34.6, dev = 0.52),
        )
        assertEquals(34.6, latestSkinAbsoluteC(days)!!, 1e-12)
    }

    @Test
    fun anEmptyHistoryHasNoAbsolute() {
        assertNull(latestSkinAbsoluteC(emptyList()))
    }

    /**
     * The regression this guard exists for: an import-only night is NEWER than the last strap night.
     * Leading with the absolute would show a stale reading dressed as the current one, so the screen
     * stays deviation-led until the strap catches up.
     */
    @Test
    fun aNewerImportOnlyNightSuppressesTheOlderAbsolute() {
        val days = listOf(
            row("2026-08-24", abs = 34.6, dev = 0.52),   // the strap's last scored night
            row("2026-08-25", dev = 0.20),               // a WHOOP CSV import: deviation only
        )
        assertNull(latestSkinAbsoluteC(days))
    }

    @Test
    fun anImportOnlyNightOLDERThanTheAbsoluteDoesNotSuppressIt() {
        val days = listOf(
            row("2026-08-24", dev = 0.20),               // older import
            row("2026-08-25", abs = 34.6, dev = 0.52),   // the freshest night has both
        )
        assertEquals(34.6, latestSkinAbsoluteC(days)!!, 1e-12)
    }

    @Test
    fun anAbsoluteOnTheSameDayAsTheFreshestDeviationStillLeads() {
        val days = listOf(row("2026-08-25", abs = 34.6, dev = 0.52))
        assertEquals(34.6, latestSkinAbsoluteC(days)!!, 1e-12)
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

    @Test
    fun aNightWithNoDeviationOmitsTheLine() {
        // Printing an empty note under the headline would read as a missing value rather than none.
        assertNull(skinTempSecondaryNote(null, fahrenheit = false))
        assertNull(skinTempSecondaryNote(null, fahrenheit = true))
    }
}
