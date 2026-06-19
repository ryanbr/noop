package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [StressOnsetDetector] — the L3 JITAI detector, the highest-value parity test (it guards the
 * credibility line). Fixtures are IDENTICAL to StressOnsetDetectorTests.swift: fires once on a fresh
 * non-metabolic dip, suppressed by the exercise gate (HR-out-of-band / motion), honours rate-limit +
 * replay-safety + the master toggle. See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
 */
class StressOnsetDetectorTest {

    private val on = StressOnsetDetector.Config(enabled = true, autoNudge = true)

    private fun flat(rrMs: Int, n: Int): List<Int> = List(n) { rrMs }

    /** Alternating ±[jitter] around [rrMs] → RMSSD ≈ 2*jitter. */
    private fun jittered(rrMs: Int, jitter: Int, n: Int): List<Int> =
        (0 until n).map { rrMs + if (it % 2 == 0) jitter else -jitter }

    @Test fun fires_once_on_fresh_dip_then_not_again() {
        val highHrv = jittered(900, 60, 60)
        var d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 10_000L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertNotNull(d.baselineRMSSD)

        val lowHrv = jittered(900, 5, 60)
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 10_060L, tzOffsetSec = 0L,
        )
        assertTrue(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.ONSET, d.reason)

        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 10_120L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.NOT_AN_EDGE, d.reason)
    }

    @Test fun exercise_gate_suppresses_when_hr_out_of_band() {
        val highHrv = jittered(900, 60, 60)
        var d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 0L, tzOffsetSec = 0L,
        )
        val lowHrv = jittered(900, 5, 60)
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 140.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.EXERCISE_GATED, d.reason)
    }

    @Test fun exercise_gate_suppresses_when_moving() {
        val highHrv = jittered(900, 60, 60)
        var d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 0L, tzOffsetSec = 0L,
        )
        val lowHrv = jittered(900, 5, 60)
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.5, sessionActive = false,
            state = d.nextState, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.EXERCISE_GATED, d.reason)
    }

    @Test fun replay_safe_cannot_refire() {
        val highHrv = jittered(900, 60, 60)
        val lowHrv = jittered(900, 5, 60)
        var d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 0L, tzOffsetSec = 0L,
        )
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertTrue(d.shouldNudge)
        val firedState = d.nextState
        val replay = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = firedState, config = on, nowSec = 61L, tzOffsetSec = 0L,
        )
        assertFalse(replay.shouldNudge)
    }

    @Test fun rate_limit_blocks_second_fire_within_window() {
        val highHrv = jittered(900, 60, 60)
        val lowHrv = jittered(900, 5, 60)
        var d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 0L, tzOffsetSec = 0L,
        )
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertTrue(d.shouldNudge)
        // recover (edge reset) then dip again 5 min after the fire → rate-limited.
        d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 120L, tzOffsetSec = 0L,
        )
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = d.nextState, config = on, nowSec = 360L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.SUPPRESSED, d.reason)
    }

    @Test fun disabled_never_fires() {
        val off = StressOnsetDetector.Config(enabled = false, autoNudge = true)
        val d = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 5, 60), currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = off, nowSec = 0L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.DISABLED, d.reason)
        assertEquals(StressOnsetDetector.State.INITIAL, d.nextState)
    }

    @Test fun active_session_suppresses() {
        val highHrv = jittered(900, 60, 60)
        val lowHrv = jittered(900, 5, 60)
        var d = StressOnsetDetector.evaluate(
            rrBuffer = highHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 0L, tzOffsetSec = 0L,
        )
        d = StressOnsetDetector.evaluate(
            rrBuffer = lowHrv, currentHR = 70.0, recentMotionG = 0.0, sessionActive = true,
            state = d.nextState, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.SUPPRESSED, d.reason)
    }

    @Test fun insufficient_data() {
        val d = StressOnsetDetector.evaluate(
            rrBuffer = flat(900, 5), currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = StressOnsetDetector.State.INITIAL, config = on, nowSec = 0L, tzOffsetSec = 0L,
        )
        assertFalse(d.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.INSUFFICIENT_DATA, d.reason)
    }
}
