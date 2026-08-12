package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.testcentre.CaptureAccumulator
import com.noop.testcentre.TestDomain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ceil

/**
 * Pins the band sleep_state WAKE-veto ([SleepStager.applyBandStateWakeVeto]).
 *
 * NOOP's EEG-free cardiorespiratory stager over-calls WAKE. WHOOP's OWN per-second sleep-state band
 * (banked as `sleepStateJSON`) is an independent scored signal; letting its explicit "asleep"
 * ([SleepStager.bandStateAsleep]) verdict VETO an INTERIOR wake epoch recovers most of that spurious
 * wake with near-zero downside. These tests pin
 * the contract: only asleep(2) vetoes (still/up/wake never do), the leading onset-latency and trailing
 * final-wake blocks are never touched, recovery is per-EPOCH, an absent band is a no-op, the output keeps
 * tiling [start,end], and the veto only ever turns wake into sleep. [raisesEfficiencyEndToEnd] additionally
 * drives the whole [SleepStager.detectSleep] path so the Android WIRING (rawStages -> veto -> efficiency),
 * not just the pure function, is covered. Android twin of the Swift band sleep_state wake-veto tests in
 * `SleepStagerTests`.
 */
class SleepStagerBandVetoTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L

    /** Unix start at `hourUTC:00:00` on the reference day. tzOffset 0 → local hour == UTC hour. */
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    /**
     * A hypnogram tiling [0, 960] (32 epochs of 30 s): a leading onset-latency wake block, an INTERIOR
     * WASO wake block (epochs 10–15 = [300, 480)), and a trailing final-morning wake block — the exact
     * shape the veto must treat differently at the edges vs the interior.
     */
    private fun vetoHypnoFixture(): List<StageSegment> = listOf(
        StageSegment(start = 0, end = 60, stage = "wake"),      // epochs 0–1  (onset latency)
        StageSegment(start = 60, end = 300, stage = "light"),   // epochs 2–9
        StageSegment(start = 300, end = 480, stage = "wake"),   // epochs 10–15 (interior WASO)
        StageSegment(start = 480, end = 900, stage = "light"),  // epochs 16–29
        StageSegment(start = 900, end = 960, stage = "wake"),   // epochs 30–31 (final wake)
    )

    /** One band sample per 30 s epoch carrying the given [states] (the shape sessionEpochSleepState grids). */
    private fun bandSamples(start: Long, states: List<Int>): List<Pair<Long, Int>> =
        states.mapIndexed { i, s -> (start + i * 30L) to s }

    private fun bandAllAsleep(start: Long, end: Long): List<Pair<Long, Int>> {
        val n = maxOf(1, ceil((end - start).toDouble() / 30.0).toInt())
        return (0 until n).map { (start + it * 30L) to 2 }
    }

    @Test
    fun recoversInteriorFalseWake() {
        // The strap's OWN band reads "asleep" (2) across the WHOLE night. The interior WASO block is
        // recovered to light (and merges with the flanking light); the leading onset-latency and trailing
        // final-wake blocks are NEVER touched even though the band scored them asleep too.
        val out = SleepStager.applyBandStateWakeVeto(
            vetoHypnoFixture(), start = 0, end = 960,
            bandSleepState = bandAllAsleep(start = 0, end = 960), enabled = true,
        )
        assertEquals(
            "interior @81-asleep wake -> light (merged); onset-latency + final-wake blocks stay wake",
            listOf(
                StageSegment(start = 0, end = 60, stage = "wake"),
                StageSegment(start = 60, end = 900, stage = "light"),
                StageSegment(start = 900, end = 960, stage = "wake"),
            ),
            out,
        )
    }

    @Test
    fun onlyAsleepStateVetoes() {
        // Interior wake epochs 10–15 get band states still(1)/up(3)/wake(0) — none is asleep(2) — so NONE
        // is recovered. (Sleep + edge epochs are asleep(2) but the veto only ever looks at wake epochs, and
        // the edges are excluded.) The hypnogram is returned byte-identical.
        val states = MutableList(32) { 2 }
        val block = listOf(1, 1, 3, 3, 0, 0)
        for ((k, i) in (10..15).withIndex()) states[i] = block[k]
        val out = SleepStager.applyBandStateWakeVeto(
            vetoHypnoFixture(), start = 0, end = 960,
            bandSleepState = bandSamples(start = 0, states = states), enabled = true,
        )
        assertEquals(
            "still/up/wake band never vetoes — only the strap's explicit asleep(2) does",
            vetoHypnoFixture(), out,
        )
    }

    @Test
    fun partialInteriorRecovery() {
        // Per-EPOCH: within the interior WASO block, only epochs 10–12 are asleep(2); 13–15 are up(3). The
        // block splits — [300,390) recovered to light, [390,480) stays wake — proving epoch granularity.
        val states = MutableList(32) { 2 }
        for (i in 13..15) states[i] = 3
        val out = SleepStager.applyBandStateWakeVeto(
            vetoHypnoFixture(), start = 0, end = 960,
            bandSleepState = bandSamples(start = 0, states = states), enabled = true,
        )
        assertEquals(
            "only the asleep-banded sub-run of an interior wake block is recovered",
            listOf(
                StageSegment(start = 0, end = 60, stage = "wake"),
                StageSegment(start = 60, end = 390, stage = "light"),
                StageSegment(start = 390, end = 480, stage = "wake"),
                StageSegment(start = 480, end = 900, stage = "light"),
                StageSegment(start = 900, end = 960, stage = "wake"),
            ),
            out,
        )
    }

    @Test
    fun noOpWhenBandAbsent() {
        // No band stream (WHOOP 4.0 / unbanded window) → byte-identical hypnogram, whatever the flag.
        assertEquals(
            "absent band → veto is a no-op",
            vetoHypnoFixture(),
            SleepStager.applyBandStateWakeVeto(
                vetoHypnoFixture(), start = 0, end = 960, bandSleepState = emptyList(), enabled = true,
            ),
        )
        // Band entirely outside the window grids to empty → also a no-op (never fabricates asleep).
        assertEquals(
            vetoHypnoFixture(),
            SleepStager.applyBandStateWakeVeto(
                vetoHypnoFixture(), start = 0, end = 960, bandSleepState = listOf(100_000L to 2), enabled = true,
            ),
        )
    }

    @Test
    fun preservesTilingAndOnlyRemovesWake() {
        assertFalse(
            "band sleep_state veto ships default-OFF until PSG supports it — the harness currently " +
                "measures the shipped recipe UNDER-calling wake (bias -4.92 pp), so converting " +
                "wake->light by default would move away from truth",
            SleepStager.bandStateWakeVetoEnabled,
        )
        val stages = vetoHypnoFixture()
        val out = SleepStager.applyBandStateWakeVeto(
            stages, start = 0, end = 960, bandSleepState = bandAllAsleep(start = 0, end = 960), enabled = true,
        )
        assertEquals(0L, out.first().start)
        assertEquals(960L, out.last().end)
        for (i in 1 until out.size) {
            assertEquals("segments tile [start,end] with no gaps/overlaps", out[i - 1].end, out[i].start)
        }
        val wake = { segs: List<StageSegment> -> segs.filter { it.stage == "wake" }.sumOf { it.end - it.start } }
        assertTrue("the veto only ever turns wake into sleep", wake(out) < wake(stages))
    }

    @Test
    fun defaultOffLeavesHypnogramUnchangedEndToEnd() {
        // WIRING PROOF through detectSleep, for the SHIPPED default (OFF until PSG supports the veto —
        // the harness currently measures the recipe UNDER-calling wake against truth, bias -4.92 pp, so
        // default-on would move away from it). With the flag off an all-"asleep" band must change
        // NOTHING end to end; the ON-path mechanism is covered by the pure enabled=true tests above.
        // Byte-parity twin of Swift testBandStateWakeVetoDefaultOffLeavesHypnogramUnchangedEndToEnd.
        val start = startAtHour(2)                // 02:00 overnight (skips the daytime nap guard)
        val dur = 6 * 3600
        val grav = stillGravity(start, dur).toMutableList()
        val hr = hrStream(start, dur, 50).toMutableList()
        for (i in (3 * 3600) until (3 * 3600 + 5 * 60)) {  // 5-min burst at +3h: high motion + elevated HR
            grav[i] = GravitySample(deviceId = dev, ts = start + i, x = (i % 2) * 0.5, y = 0.0, z = 1.0)
            hr[i] = HrSample(deviceId = dev, ts = start + i, bpm = 95)
        }
        val noBand = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals(1, noBand.size)
        val withBand = SleepStager.detectSleep(
            hr = hr, gravity = grav,
            bandSleepState = bandAllAsleep(start = start, end = start + dur),
        )
        assertEquals(1, withBand.size)
        assertEquals("default-off: an all-asleep band changes NOTHING — byte-identical hypnogram",
            noBand[0].stages, withBand[0].stages)
        assertEquals("default-off: efficiency is untouched by the band stream",
            noBand[0].efficiency, withBand[0].efficiency, 1e-9)
    }

    @Test
    fun cutoffSparesNightsBeforeCutoff() {
        // #1210 item 2: with the veto ON, a non-zero cutoff spares a night that STARTED before it (history
        // keeps its raw hypnogram) and applies to one starting at/after it. Boundary is inclusive. Swift twin.
        val base = 1_000_000L
        val fixture = vetoHypnoFixture().map {
            StageSegment(start = it.start + base, end = it.end + base, stage = it.stage)
        }
        val band = bandAllAsleep(start = base, end = base + 960)
        val recovered = SleepStager.applyBandStateWakeVeto(fixture, start = base, end = base + 960,
            bandSleepState = band, enabled = true, cutoffTs = 0L)
        assertNotEquals("sanity: the veto does change this fixture", recovered, fixture)
        assertEquals("a night starting before the cutoff keeps its raw hypnogram",
            fixture, SleepStager.applyBandStateWakeVeto(fixture, start = base, end = base + 960,
                bandSleepState = band, enabled = true, cutoffTs = base + 1))
        assertEquals("a night starting at/after the cutoff (inclusive) gets the veto",
            recovered, SleepStager.applyBandStateWakeVeto(fixture, start = base, end = base + 960,
                bandSleepState = band, enabled = true, cutoffTs = base))
    }

    @Test
    fun shadowLineIsNamespacedAndUncountedByCaptureAccumulator() {
        // #1210 shadow: the validation line formats the recovered delta and is NEVER miscounted as a captured
        // sleep day (carries no `sleep day=` / `gate run=` / `day=` token). Byte-identical format to Swift.
        val line = SleepStager.bandVetoShadowLine(
            startTs = 1_723_000_000L, recoveredMin = 31.4, rawEff = 0.742, shadowEff = 0.808,
        )
        assertEquals("bandVeto(shadow): startTs=1723000000 recoveredMin=31 eff 74%->81%", line)
        assertEquals("shadow line must not be counted as a captured sleep day",
            0, CaptureAccumulator.capturedDays(TestDomain.SLEEP, line, 0L))
    }

    @Test
    fun shadowTraceReportsRecoveryOutputNeutral() {
        // #1210 shadow: veto DORMANT (default-off) + a band present + a collecting traceSink -> a
        // `bandVeto(shadow):` line quantifying what the veto WOULD recover, WITHOUT changing the persisted
        // hypnogram (detectSleep's documented trace contract). Same burst fixture as the default-off wiring
        // test. (The line reports MAGNITUDE only; whether the move is toward truth needs the PSG harness.)
        val start = startAtHour(2)
        val dur = 6 * 3600
        val grav = stillGravity(start, dur).toMutableList()
        val hr = hrStream(start, dur, 50).toMutableList()
        for (i in (3 * 3600) until (3 * 3600 + 5 * 60)) {  // interior 5-min burst -> false wake
            grav[i] = GravitySample(deviceId = dev, ts = start + i, x = (i % 2) * 0.5, y = 0.0, z = 1.0)
            hr[i] = HrSample(deviceId = dev, ts = start + i, bpm = 95)
        }
        val band = bandAllAsleep(start = start, end = start + dur)
        val untraced = SleepStager.detectSleep(hr = hr, gravity = grav, bandSleepState = band)
        val lines = mutableListOf<String>()
        val traced = SleepStager.detectSleep(
            hr = hr, gravity = grav, bandSleepState = band, traceSink = { lines.add(it) },
        )
        assertEquals("shadow trace must not change the persisted hypnogram",
            untraced[0].stages, traced[0].stages)
        assertTrue("a banded night with interior false-wake emits a shadow line",
            lines.any { it.startsWith("bandVeto(shadow):") && it.contains("recoveredMin=") })
    }
}
