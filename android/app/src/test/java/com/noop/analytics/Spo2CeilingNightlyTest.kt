package com.noop.analytics

import com.noop.data.Spo2Sample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Queue 11a — the Oura twin of [Spo2CandidateNightlyTest]: nightly ceiling@100 mean of the ring's own
 * decoded `0x6F` SpO2 ([Spo2Sample.red]), the starting candidate transform for the Blood Oxygen tile's
 * Oura fallback. Byte-parity twin of the Swift `Spo2CeilingNightlyTests`: same fixtures, same expected
 * values. Pins the ceiling (per-sample, before averaging), the contamination floor gate, and the
 * session-window filter — the three things that make this an honest "strap estimate," not raw wire.
 */
class Spo2CeilingNightlyTest {

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun spo2(ts: Long, red: Int) = Spo2Sample(deviceId = "d", ts = ts, red = red, ir = 0)

    @Test fun meanAndSampleCountOverTheSession() {
        val r = AnalyticsEngine.nightlySpo2CeilingMean(
            listOf(session(1000, 600)), listOf(spo2(1100, 94), spo2(1200, 96), spo2(1300, 95)))
        assertEquals(95, r?.first)
        assertEquals(3, r?.second)
    }

    /**
     * The whole point of "ceiling@100": a sample above 100 counts as 100, not itself — so a night with a
     * real overshoot doesn't drag the mean above the physical ceiling the way the raw wire mean does
     * (OURA_PROTOCOL.md §6.5.0.1's documented positive bias).
     */
    @Test fun samplesAboveOneHundredAreCeilingedBeforeAveraging() {
        val r = AnalyticsEngine.nightlySpo2CeilingMean(
            listOf(session(1000, 600)), listOf(spo2(1100, 104), spo2(1200, 100)))
        assertEquals(100, r?.first)
    }

    /**
     * Mis-scaled `dc_raw`/perfusion-channel contamination (-1016 .. 11,709,098, OURA_PROTOCOL.md
     * §6.5.0.1) must not drag the mean down — the ceiling alone only guards the TOP of the range, so the
     * floor gate is load-bearing here, unlike the WHOOP @82 path (whose decoder already only ever emits
     * 70..100).
     */
    @Test fun contaminatedOutOfRangeSamplesAreExcluded() {
        val r = AnalyticsEngine.nightlySpo2CeilingMean(
            listOf(session(1000, 600)),
            listOf(spo2(1100, 96), spo2(1150, -1016), spo2(1200, 11_709_098), spo2(1300, 98)))
        assertEquals(97, r?.first)
        assertEquals(2, r?.second)
    }

    @Test fun daytimeSamplesOutsideTheSessionAreExcluded() {
        val r = AnalyticsEngine.nightlySpo2CeilingMean(
            listOf(session(1000, 600)), listOf(spo2(500, 99), spo2(1100, 94), spo2(5000, 88)))
        assertEquals(1, r?.second)
        assertEquals(94, r?.first)
    }

    @Test fun nullWhenNothingPlausibleFallsInsideASession() {
        assertNull(AnalyticsEngine.nightlySpo2CeilingMean(listOf(session(1000, 600)), listOf(spo2(1100, -1016))))
        assertNull(AnalyticsEngine.nightlySpo2CeilingMean(listOf(session(1000, 600)), listOf(spo2(9999, 95))))
        assertNull(AnalyticsEngine.nightlySpo2CeilingMean(emptyList(), listOf(spo2(1100, 95))))
        assertNull(AnalyticsEngine.nightlySpo2CeilingMean(listOf(session(1000, 600)), emptyList()))
    }

    /**
     * Found 2026-08-24 comparing a live-persisted row against the Oura app: `sum / kept` on two integer
     * types truncates toward zero, so a true 97.97 shipped as 97 — a spurious miss against an
     * app-displayed 98% the precise mean would have round-matched. Three samples averaging 97.666...
     * must round to 98, not floor to 97.
     */
    @Test fun meanRoundsRatherThanFloors() {
        val r = AnalyticsEngine.nightlySpo2CeilingMean(
            listOf(session(1000, 600)), listOf(spo2(1100, 98), spo2(1200, 98), spo2(1300, 97)))
        assertEquals(98, r?.first)
    }

    /** The plausibility floor/ceiling are inclusive, matching SPO2_SINGLE_CHANNEL_PLAUSIBLE (50..110). */
    @Test fun plausibleRangeBoundariesAreInclusive() {
        assertEquals(2, AnalyticsEngine.nightlySpo2CeilingMean(
            listOf(session(1000, 600)), listOf(spo2(1100, 50), spo2(1200, 110)))?.second)
        assertNull(AnalyticsEngine.nightlySpo2CeilingMean(listOf(session(1000, 600)), listOf(spo2(1100, 49))))
        assertNull(AnalyticsEngine.nightlySpo2CeilingMean(listOf(session(1000, 600)), listOf(spo2(1100, 111))))
    }
}
