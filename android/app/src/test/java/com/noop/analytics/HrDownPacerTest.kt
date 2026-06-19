package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [HrDownPacer] — the L2 buzz-below-HR metronome. Fixtures are IDENTICAL to HRDownPacerTests.swift
 * so the two engines pin the SAME intervals on the SAME HR trajectory (the cross-platform parity contract).
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L2).
 */
class HrDownPacerTest {

    private val cfg = HrDownPacer.Config.DEFAULT   // start Δ 3, max Δ 8, ramp 120s, floor 50, calm 60, max 180s.

    // GOLDEN: elapsed 0, HR 84 → Δ 3 → target 81 → interval round(60000/81) = 741.
    @Test fun golden_start_step() {
        val step = HrDownPacer.next(currentHR = 84.0, elapsed = 0.0, config = cfg)
        assertFalse(step.stop)
        assertEquals(81.0, step.targetBpm!!, 1e-9)
        assertEquals(741, step.intervalMs)
    }

    // GOLDEN: elapsed ≥ 120, HR 84 → Δ 8 → target 76 → interval round(60000/76) = 789.
    @Test fun golden_ramped_step() {
        val step = HrDownPacer.next(currentHR = 84.0, elapsed = 120.0, config = cfg)
        assertEquals(76.0, step.targetBpm!!, 1e-9)
        assertEquals(789, step.intervalMs)
    }

    @Test fun delta_ramp_is_linear() {
        assertEquals(3.0, HrDownPacer.rampedDelta(0.0, cfg), 1e-9)
        assertEquals(5.5, HrDownPacer.rampedDelta(60.0, cfg), 1e-9)
        assertEquals(8.0, HrDownPacer.rampedDelta(120.0, cfg), 1e-9)
        assertEquals(8.0, HrDownPacer.rampedDelta(999.0, cfg), 1e-9)
    }

    @Test fun descent_is_monotone_and_bounded() {
        val trajectory = listOf(88.0, 86.0, 84.0, 82.0, 80.0, 78.0, 76.0, 74.0, 72.0, 70.0, 68.0, 66.0, 64.0, 62.0)
        for ((i, hr) in trajectory.withIndex()) {
            val elapsed = i * cfg.recomputeSeconds
            val step = HrDownPacer.next(hr, elapsed, cfg)
            if (step.stop) continue
            val target = step.targetBpm ?: continue
            assertTrue(target >= cfg.hrFloorBpm)
            assertTrue(target <= hr)
            assertTrue(target >= hr - cfg.maxDeltaBpm - 1e-9)
        }
        val s0 = HrDownPacer.next(88.0, 0.0, cfg).targetBpm!!
        val s1 = HrDownPacer.next(86.0, cfg.recomputeSeconds, cfg).targetBpm!!
        assertTrue(s1 <= s0)
    }

    @Test fun hr_floor_respected() {
        val step = HrDownPacer.next(61.0, 120.0, cfg)   // 61 − 8 = 53 > floor 50
        assertEquals(53.0, step.targetBpm!!, 1e-9)
        val highFloor = HrDownPacer.Config(hrFloorBpm = 70.0, calmTargetBpm = 55.0)
        val clamped = HrDownPacer.next(75.0, 120.0, highFloor)
        assertEquals(70.0, clamped.targetBpm!!, 1e-9)   // 75 − 8 = 67 < floor 70 → 70
    }

    @Test fun stops_on_settle() {
        val step = HrDownPacer.next(59.0, 30.0, cfg)   // ≤ calm 60
        assertTrue(step.stop)
        assertEquals(HrDownPacer.StopReason.SETTLED, step.stopReason)
        assertNull(step.intervalMs)
    }

    @Test fun stops_on_timeout() {
        val step = HrDownPacer.next(90.0, 180.0, cfg)
        assertTrue(step.stop)
        assertEquals(HrDownPacer.StopReason.TIMEOUT, step.stopReason)
    }

    @Test fun invalid_hr_stops() {
        assertEquals(HrDownPacer.StopReason.INVALID_HR, HrDownPacer.next(0.0, 0.0, cfg).stopReason)
        assertEquals(HrDownPacer.StopReason.INVALID_HR, HrDownPacer.next(-5.0, 0.0, cfg).stopReason)
    }
}
