package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [OuraRespScale] is the single seam between two different physical quantities that share the
 * `respSample` table: a WHOOP's raw respiration ADC waveform and an Oura ring's own per-window RATE
 * (0x6A `breath`). These pin the scale, and pin that a ring's rows are refused for scoring by
 * PROVENANCE — not by happening to be too sparse for the stager's window. Swift twin:
 * `OuraRespScaleTests`.
 */
class OuraRespScaleTest {

    private val ring = "oura-2H3B2405003655"
    private val strap = "whoop-AABBCCDD"

    // ── The scale ────────────────────────────────────────────────────────────────────────────────────

    /**
     * The wire field is `u8 / 8`, so its whole alphabet is 0..31.875 bpm in 0.125 steps, and milli-bpm
     * represents every one of them EXACTLY (`wireByte * 125`). This is the reason the scale is milli and
     * not the codebase's usual centi: at centi, half the alphabet lands on `x.5` and needs a rounding
     * rule both platforms would then have to agree about forever.
     */
    @Test
    fun everyWireValueIsExactInMilliBpm() {
        for (byte in 0..255) {
            val bpm = byte / 8.0
            val raw = OuraRespScale.milliBpm(bpm)
            assertEquals(byte * 125, raw)
            assertEquals(bpm, OuraRespScale.breathsPerMin(raw), 1e-12)
        }
    }

    /** The values actually observed on real nights, spelled out so a scale change cannot pass quietly. */
    @Test
    fun observedNightMediansMapAsWritten() {
        assertEquals(14_250, OuraRespScale.milliBpm(14.250))
        assertEquals(14_375, OuraRespScale.milliBpm(14.375))
        assertEquals(14_625, OuraRespScale.milliBpm(14.625))
        assertEquals(15_000, OuraRespScale.milliBpm(15.000))
    }

    // ── Which owner's rows are a rate ────────────────────────────────────────────────────────────────

    @Test
    fun onlyARingsRowsAreARate() {
        assertTrue(OuraRespScale.isRingRateStream(ring))
        assertFalse(OuraRespScale.isRingRateStream(strap))
        assertFalse(OuraRespScale.isRingRateStream("my-whoop"))
        assertFalse(OuraRespScale.isRingRateStream(""))
    }

    /**
     * A ring row plots as breaths/min; a WHOOP row plots as the ADC count it always did. Without the
     * scaling the day chart would draw a ring's 14.375 bpm as 14,375 on a track it labels "Respiration".
     */
    @Test
    fun displayValueScalesOnlyTheRingsRows() {
        assertEquals(14.375, OuraRespScale.displayValue(14_375, ring), 1e-12)
        assertEquals(14_375.0, OuraRespScale.displayValue(14_375, strap), 1e-12)
    }

    // ── The scoring refusal ──────────────────────────────────────────────────────────────────────────

    /**
     * The instrumentation disposition's hard half: stored, shown, never scored. The stager reads this
     * stream as a ~1 Hz raw ADC waveform and runs a peak detector over it, which a per-window rate is
     * not. A WHOOP's rows pass through untouched, so no existing night changes.
     */
    @Test
    fun ringRespirationIsRefusedForScoringAndWhoopIsUntouched() {
        val rows = listOf(
            RespSample(deviceId = ring, ts = 1_000L, raw = 14_375),
            RespSample(deviceId = ring, ts = 1_296L, raw = 14_500),
        )
        assertTrue(OuraRespScale.forScoring(rows, ring).isEmpty())
        assertEquals(rows, OuraRespScale.forScoring(rows, strap))
        assertTrue(OuraRespScale.forScoring(emptyList(), ring).isEmpty())
    }
}
