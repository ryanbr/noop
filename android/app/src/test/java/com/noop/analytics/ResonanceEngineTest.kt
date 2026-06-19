package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [ResonanceEngine] — the L1 resonance-pace sweep. Fixtures + the synthetic R-R generator are
 * IDENTICAL to ResonanceEngineTests.swift so the two engines select the SAME pace on the SAME beats (the
 * cross-platform parity contract). See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
 */
class ResonanceEngineTest {

    /**
     * Generate a paced candidate's R-R: a steady baseline R-R with a once-per-breath-cycle triangle swing
     * of [swingMs] peak-to-trough, sampled at ~1 beat/sec over [durationSec]. Larger [swingMs] = larger
     * RSA amplitude. Deterministic + integer so Swift and Kotlin generate the IDENTICAL series.
     */
    private fun pacedBeats(bpm: Double, baselineMs: Int, swingMs: Int, startTs: Int, durationSec: Int): List<ResonanceEngine.RrBeat> {
        val cycleSec = 60.0 / bpm
        val out = ArrayList<ResonanceEngine.RrBeat>()
        var t = startTs
        val end = startTs + durationSec
        while (t <= end) {
            val phase = ((t - startTs).toDouble() % cycleSec) / cycleSec
            val tri = if (phase < 0.5) (phase * 2.0) else (2.0 - phase * 2.0)   // 0→1→0
            val delta = ((tri - 0.5) * swingMs.toDouble()).toInt()
            out.add(ResonanceEngine.RrBeat(ts = t, rrMs = baselineMs + delta))
            t += 1
        }
        return out
    }

    // GOLDEN: three paces, the MIDDLE (5.5) carries the biggest swing → it must be locked.
    @Test fun golden_selects_max_rsa_pace() {
        val samples = listOf(
            ResonanceEngine.PaceSample(4.5, pacedBeats(4.5, 900, 40, 0, 150), 0, 150),
            ResonanceEngine.PaceSample(5.5, pacedBeats(5.5, 900, 120, 1000, 150), 1000, 1150),
            ResonanceEngine.PaceSample(6.5, pacedBeats(6.5, 900, 40, 2000, 150), 2000, 2150),
        )
        val result = ResonanceEngine.sweep(samples)
        assertTrue(result.didLock)
        assertEquals(5.5, result.lockedBpm, 1e-9)
        val rsa55 = result.scores.first { it.bpm == 5.5 }.rsaAmplitude
        val rsa45 = result.scores.first { it.bpm == 4.5 }.rsaAmplitude
        assertNotNull(rsa55)
        assertNotNull(rsa45)
        assertTrue(rsa55!! > rsa45!!)
    }

    // A pace with too few clean beats is UNSCORED (rsaAmplitude null).
    @Test fun too_few_beats_pace_is_unscored() {
        val sparse = (0 until 10).map { ResonanceEngine.RrBeat(ts = 40 + it, rrMs = 900) }
        val score = ResonanceEngine.scorePace(ResonanceEngine.PaceSample(5.5, sparse, 0, 200))
        assertNull(score.rsaAmplitude)
        assertFalse(score.scored)
    }

    // Fewer than MIN_SCORED_PACES (3) scored → honest "no lock", fall back to 5.5.
    @Test fun no_lock_fallback_to_5p5() {
        val good = ResonanceEngine.PaceSample(6.0, pacedBeats(6.0, 900, 60, 0, 150), 0, 150)
        val sparseA = ResonanceEngine.PaceSample(4.5, (0 until 5).map { ResonanceEngine.RrBeat(1040 + it, 900) }, 1000, 1200)
        val sparseB = ResonanceEngine.PaceSample(7.0, (0 until 5).map { ResonanceEngine.RrBeat(2040 + it, 900) }, 2000, 2200)
        val result = ResonanceEngine.sweep(listOf(good, sparseA, sparseB))
        assertFalse(result.didLock)
        assertEquals(ResonanceEngine.FALLBACK_BPM, result.lockedBpm, 1e-9)
        assertEquals(5.5, result.lockedBpm, 1e-9)
    }

    // The transient drop excludes the first 30 s.
    @Test fun transient_drop_excludes_early_beats() {
        val flat = pacedBeats(5.5, 900, 0, 0, 150)
        val score = ResonanceEngine.scorePace(ResonanceEngine.PaceSample(5.5, flat, 0, 150))
        score.rsaAmplitude?.let { assertEquals(0.0, it, 1e-9) }
        assertTrue(score.cleanBeats <= 121)
    }
}
