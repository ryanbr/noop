package com.noop.ui

import com.noop.analytics.SkinTempDisplay
import com.noop.analytics.VitalBands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1847: the skin-temp screen has to say when it could not honour the Settings choice.
 *
 * `leadReading` falls back rather than blanking, which is right but invisible — both settings then render
 * the same Δ°C and the toggle reads as broken. The note fires in exactly one case.
 */
class SkinTempFallbackNoteTest {

    /** Asked for a temperature, no night has one — the reported case, and the only one that explains. */
    @Test
    fun explainsWhenTemperatureWasAskedForAndNoneExists() {
        assertTrue(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = false,
                                                  anyAbsoluteInWindow = false))
    }

    /** Asked for a temperature and got one: nothing to explain. */
    @Test
    fun silentWhenTheChoiceWasHonoured() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = true,
                                                   anyAbsoluteInWindow = true))
    }

    /** Asked for the baseline delta and got it. */
    @Test
    fun silentWhenTheDeviationWasChosen() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.DEVIATION, leadsAbsolute = false,
                                                   anyAbsoluteInWindow = false))
    }

    /** Chose the delta but only an absolute exists: the reverse fallback. It shows a temperature under a
     *  plain °C unit, which is self-describing, so it does not need a sentence. Pinned so the asymmetry is
     *  deliberate rather than an oversight. */
    @Test
    fun silentOnTheReverseFallback() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.DEVIATION, leadsAbsolute = true,
                                                   anyAbsoluteInWindow = true))
    }

    // MARK: the shortened series (#1847, found in re-review)

    /** After a sync refills the 21-night window on an install with older history, the absolute-led series
     *  drops the deviation-only nights and the reading count visibly falls. Say why. */
    @Test
    fun explainsWhenNightsWereDroppedFromTheSeries() {
        assertTrue(shouldExplainShortenedSkinTempSeries(leadsAbsolute = true, shownReadings = 21,
                                                        rowsWithEitherNumber = 40))
    }

    /** A complete series says nothing — the note must not appear on a healthy screen. */
    @Test
    fun silentWhenEveryNightIsShown() {
        assertFalse(shouldExplainShortenedSkinTempSeries(leadsAbsolute = true, shownReadings = 23,
                                                         rowsWithEitherNumber = 23))
    }

    /** No data at all is the empty state's job, not this note's. */
    @Test
    fun silentWhenThereIsNothingToShow() {
        assertFalse(shouldExplainShortenedSkinTempSeries(leadsAbsolute = true, shownReadings = 0,
                                                         rowsWithEitherNumber = 0))
    }


    // MARK: what the second re-review caught — the note must never say the opposite of what happened

    /**
     * The deviation-led branch ALSO drops rows: calibrating nights that have only an absolute, and the #622
     * bimodal partition. Those are the OPPOSITE kind, so "only nights with a measured temperature are
     * shown" would be precisely backwards. Ungated, this fired the moment a wearer picked "vs baseline"
     * with any calibrating night in the window.
     */
    @Test
    fun neverExplainsAShortenedSeriesWhenLeadingWithTheDeviation() {
        assertFalse(shouldExplainShortenedSkinTempSeries(leadsAbsolute = false, shownReadings = 21,
                                                         rowsWithEitherNumber = 40))
    }

    /**
     * The newest night has no absolute but an older one does. "No measured temperature for these nights" is
     * false for those older nights, so the screen says nothing rather than something untrue.
     */
    @Test
    fun silentWhenSomeOlderNightDoesHaveATemperature() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = false,
                                                  anyAbsoluteInWindow = true))
    }


    // MARK: third re-review — an absolute is an absolute, whichever column holds it

    /**
     * A WHOOP CSV import writes absolute °C into skinTempDevC (`skin_temp_celsius`, the #622 bimodal
     * field). Those nights belong in an absolute-led series — same scale — and counting them as dropped
     * made the note describe real temperatures as "a baseline difference only".
     *
     * Pins the discriminator the series selection leans on, so a change to the 20.0 threshold surfaces
     * here rather than as a mislabelled chart.
     */
    @Test
    fun anImportedAbsoluteIsRecognisedAsAbsolute() {
        assertTrue(VitalBands.isAbsoluteSkinTemp(34.0))    // WHOOP export, stored in skinTempDevC
        assertTrue(VitalBands.isAbsoluteSkinTemp(20.0))    // boundary is inclusive
        assertFalse(VitalBands.isAbsoluteSkinTemp(0.5))    // a real deviation
        assertFalse(VitalBands.isAbsoluteSkinTemp(-0.6))
    }

    /** With imported absolutes now IN the series, only genuine deviations count as dropped — so a window
     *  holding nothing but absolutes (however stored) shows no note. */
    @Test
    fun silentWhenEveryDroppedRowWasActuallyAnAbsolute() {
        assertFalse(shouldExplainShortenedSkinTempSeries(leadsAbsolute = true, shownReadings = 12,
                                                         rowsWithEitherNumber = 12))
    }


    // MARK: #1850 — the preference now applies across the WINDOW

    /**
     * The reported install: Temperature selected, deltas on screen, no explanation. The cause was not the
     * missing sentence I first added — it was that the whole screen keyed off the NEWEST row, so twenty
     * stored temperatures lost to one recent night without. The window-wide rule is what fixes it, and
     * the fallback note is now reserved for a window that genuinely holds none.
     */
    @Test
    fun oneStoredTemperatureAnywhereMeansNoFallbackNote() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = true,
                                                  anyAbsoluteInWindow = true))
    }

    /** Only a window with NO temperature at all still explains itself. */
    @Test
    fun anEmptyWindowStillExplains() {
        assertTrue(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = false,
                                                 anyAbsoluteInWindow = false))
    }

    /**
     * The whole grid for the ABSOLUTE preference, so no quadrant can fall silent again. With the
     * window-wide rule, `leadsAbsolute == anyAbsolute`, and the only speaking case is neither.
     */
    @Test
    fun everyAbsolutePreferenceCaseIsAccountedFor() {
        for (anyAbsolute in listOf(false, true)) {
            val leads = anyAbsolute      // the window-wide rule, stated as the test's own model
            val explains = shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leads, anyAbsolute)
            assertEquals("leads=$leads any=$anyAbsolute", !anyAbsolute, explains)
        }
    }

}
