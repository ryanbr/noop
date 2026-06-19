package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [BreathPacer] — the L1 paced-breathing cue list. Fixtures are IDENTICAL to
 * BreathPacerTests.swift so the two engines prove byte-identical output (the cross-platform parity
 * contract). See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
 */
class BreathPacerTest {

    // GOLDEN VECTOR A: 6.0 br/min, 0.4 inhale, 2 cycles. cycleMs = 10000; inhaleMs = 4000.
    @Test fun golden_6bpm_2cycles() {
        val cues = BreathPacer.schedule(bpm = 6.0, inhaleFraction = 0.4, cycles = 2)
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(4000, BreathPhase.EXHALE, 2),
                BreathCue(10000, BreathPhase.INHALE, 1),
                BreathCue(14000, BreathPhase.EXHALE, 2),
            ),
            cues,
        )
    }

    // GOLDEN VECTOR B: 5.5 br/min, default inhale, 3 cycles. cycleMs = 10909; inhaleMs = 4364.
    @Test fun golden_5p5bpm_3cycles_default_fraction() {
        val cues = BreathPacer.schedule(bpm = 5.5, cycles = 3)
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(4364, BreathPhase.EXHALE, 2),
                BreathCue(10909, BreathPhase.INHALE, 1),
                BreathCue(15273, BreathPhase.EXHALE, 2),
                BreathCue(21818, BreathPhase.INHALE, 1),
                BreathCue(26182, BreathPhase.EXHALE, 2),
            ),
            cues,
        )
    }

    @Test fun inhale_lighter_than_exhale_always() {
        for (cue in BreathPacer.schedule(bpm = 4.5, cycles = 4)) {
            when (cue.phase) {
                BreathPhase.INHALE -> assertEquals(1, cue.loops)
                BreathPhase.EXHALE -> assertEquals(2, cue.loops)
            }
        }
    }

    @Test fun two_cues_per_cycle_in_time_order() {
        val cues = BreathPacer.schedule(bpm = 7.0, cycles = 5)
        assertEquals(10, cues.size)
        for (i in 1 until cues.size) {
            assertTrue(cues[i - 1].offsetMs <= cues[i].offsetMs)
        }
    }

    @Test fun zero_or_negative_cycles_is_empty() {
        assertTrue(BreathPacer.schedule(bpm = 6.0, cycles = 0).isEmpty())
        assertTrue(BreathPacer.schedule(bpm = 6.0, cycles = -3).isEmpty())
    }

    @Test fun bpm_and_fraction_clamped_not_trapped() {
        // bpm clamps to 3 → cycleMs = 20000; fraction clamps to 0.1 → inhaleMs = 2000.
        val slow = BreathPacer.schedule(bpm = 0.5, inhaleFraction = -1.0, cycles = 1)
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(2000, BreathPhase.EXHALE, 2),
            ),
            slow,
        )
        // bpm clamps to 12 → cycleMs = 5000; fraction clamps to 0.9 → inhaleMs = 4500.
        val fast = BreathPacer.schedule(bpm = 99.0, inhaleFraction = 5.0, cycles = 1)
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(4500, BreathPhase.EXHALE, 2),
            ),
            fast,
        )
    }

    @Test fun session_duration() {
        assertEquals(20000, BreathPacer.sessionDurationMs(bpm = 6.0, cycles = 2))
        assertEquals(0, BreathPacer.sessionDurationMs(bpm = 6.0, cycles = 0))
    }
}
