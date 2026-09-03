package com.noop.ui

import com.noop.analytics.SkinTempDisplay
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
        assertTrue(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = false))
    }

    /** Asked for a temperature and got one: nothing to explain. */
    @Test
    fun silentWhenTheChoiceWasHonoured() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.ABSOLUTE, leadsAbsolute = true))
    }

    /** Asked for the baseline delta and got it. */
    @Test
    fun silentWhenTheDeviationWasChosen() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.DEVIATION, leadsAbsolute = false))
    }

    /** Chose the delta but only an absolute exists: the reverse fallback. It shows a temperature under a
     *  plain °C unit, which is self-describing, so it does not need a sentence. Pinned so the asymmetry is
     *  deliberate rather than an oversight. */
    @Test
    fun silentOnTheReverseFallback() {
        assertFalse(shouldExplainSkinTempFallback(SkinTempDisplay.Kind.DEVIATION, leadsAbsolute = true))
    }

    // MARK: the shortened series (#1847, found in re-review)

    /** After a sync refills the 21-night window on an install with older history, the absolute-led series
     *  drops the deviation-only nights and the reading count visibly falls. Say why. */
    @Test
    fun explainsWhenNightsWereDroppedFromTheSeries() {
        assertTrue(shouldExplainShortenedSkinTempSeries(shownReadings = 21, rowsWithEitherNumber = 40))
    }

    /** A complete series says nothing — the note must not appear on a healthy screen. */
    @Test
    fun silentWhenEveryNightIsShown() {
        assertFalse(shouldExplainShortenedSkinTempSeries(shownReadings = 23, rowsWithEitherNumber = 23))
    }

    /** No data at all is the empty state's job, not this note's. */
    @Test
    fun silentWhenThereIsNothingToShow() {
        assertFalse(shouldExplainShortenedSkinTempSeries(shownReadings = 0, rowsWithEitherNumber = 0))
    }

}
