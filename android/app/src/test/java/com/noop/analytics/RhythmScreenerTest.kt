package com.noop.analytics

import com.noop.protocol.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * Kotlin parity for StrandAnalytics/Tests/.../RhythmScreenerTests.swift.
 *
 * Reproduces the IDENTICAL deterministic integer LCG + integer-ms R-R fixtures, so the
 * same inputs yield the same RhythmRegularity labels and rounded stats on both platforms
 * (the cross-platform parity gate). No real patient data — synthetic only.
 */
class RhythmScreenerTest {

    // ── Deterministic synthetic fixtures (mirror RhythmScreenerTests.swift exactly) ───

    /**
     * Same LCG as Swift (Numerical Recipes constants, UInt32 wrap). Kotlin has no UInt32
     * arithmetic by default; we emulate the 32-bit wrap with a Long masked to 0xFFFFFFFF.
     */
    private class Lcg(seed: Long) {
        private var state: Long = seed and 0xFFFFFFFFL
        fun nextU32(): Long {
            state = (state * 1664525L + 1013904223L) and 0xFFFFFFFFL
            return state
        }
        /** Symmetric integer jitter in [-amp, +amp]. */
        fun jitter(amp: Int): Int {
            val span = (2 * amp + 1).toLong()
            return (nextU32() % span).toInt() - amp
        }
    }

    private fun regularSinus(count: Int = 240): List<Double> {
        val rng = Lcg(1)
        val out = ArrayList<Double>(count)
        val period = 8
        for (i in 0 until count) {
            val phase = i % period
            val half = period / 2
            val tri = if (phase < half) {
                phase.toDouble() / half.toDouble()
            } else {
                (period - phase).toDouble() / half.toDouble()
            }
            val rsa = (tri * 2.0 - 1.0) * 30.0
            val v = 1000.0 + rsa + rng.jitter(2).toDouble()
            out.add(Math.round(v).toDouble())
        }
        return out
    }

    private fun afibLike(count: Int = 240): List<Double> {
        val rng = Lcg(7)
        val out = ArrayList<Double>(count)
        for (i in 0 until count) {
            val v = 1000.0 + rng.jitter(180).toDouble()
            out.add(Math.round(minOf(1900.0, maxOf(400.0, v))).toDouble())
        }
        return out
    }

    private fun isolatedEctopy(count: Int = 240): List<Double> {
        val base = regularSinus(count).toMutableList()
        var i = 20
        while (i + 1 < count) {
            base[i] = 650.0
            base[i + 1] = 1350.0
            i += 40
        }
        return base
    }

    // ── Window-level classification ───────────────────────────────────────────────────

    @Test
    fun regularSinus_readsSteady() {
        val rr = regularSinus()
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = rr, motionStill = true, meanHR = 60.0))
        assertEquals(RhythmRegularity.STEADY, r.label)
        assertEquals(rr.size, r.nBeats)
        assertNotNull(r.sd1)
        assertNotNull(r.sd2)
        assertTrue(r.sd1sd2!! < RhythmScreener.TAU_RATIO)
        assertEquals(rr.size - 1, r.poincare.size)
        assertEquals(RhythmConfidence.SOLID, r.confidence)
    }

    @Test
    fun afibLike_readsVaried() {
        val rr = afibLike()
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = rr, motionStill = true, meanHR = 60.0))
        assertEquals(RhythmRegularity.VARIED, r.label)
        assertTrue(r.sd1sd2!! >= RhythmScreener.TAU_RATIO)
        assertTrue(r.normRmssd!! >= RhythmScreener.TAU_NRMSSD)
    }

    @Test
    fun isolatedEctopy_readsOccasional() {
        val rr = isolatedEctopy()
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = rr, motionStill = true, meanHR = 60.0))
        assertEquals(RhythmRegularity.OCCASIONAL_ECTOPY, r.label)
        assertTrue(r.ectopicFraction!! > 0)
    }

    // ── Gates ─────────────────────────────────────────────────────────────────────────

    @Test
    fun motionContaminated_isUnreadable() {
        val rr = afibLike()
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = rr, motionStill = false, meanHR = 60.0))
        assertEquals(RhythmRegularity.UNREADABLE, r.label)
        assertNull(r.sd1)
        assertTrue(r.poincare.isEmpty())
    }

    @Test
    fun sparseWindow_isUnreadableCalibrating() {
        val rr = List(40) { 1000.0 }
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = rr, motionStill = true, meanHR = 60.0))
        assertEquals(RhythmRegularity.UNREADABLE, r.label)
        assertEquals(RhythmConfidence.CALIBRATING, r.confidence)
        assertEquals(40, r.nBeats)
    }

    @Test
    fun outOfRestingBand_isUnreadable() {
        val rr = regularSinus()
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = rr, motionStill = true, meanHR = 150.0))
        assertEquals(RhythmRegularity.UNREADABLE, r.label)
    }

    // ── Cross-source agreement ──────────────────────────────────────────────────────

    @Test
    fun ppgDisagreement_suppressesAgreement() {
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = afibLike(), ppgIBIms = regularSinus(),
                motionStill = true, meanHR = 60.0))
        assertEquals(RhythmRegularity.VARIED, r.label)
        assertFalse(r.agreedAcrossSources)
    }

    @Test
    fun ppgAgreement_whenBothSteady() {
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = regularSinus(), ppgIBIms = regularSinus(),
                motionStill = true, meanHR = 60.0))
        assertEquals(RhythmRegularity.STEADY, r.label)
        assertTrue(r.agreedAcrossSources)
    }

    @Test
    fun noPpgChannel_meansNoAgreement() {
        val r = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = regularSinus(), motionStill = true, meanHR = 60.0))
        assertFalse(r.agreedAcrossSources)
    }

    // ── Property / identity tests ─────────────────────────────────────────────────────

    @Test
    fun sd1_isRmssdOverRootTwo() {
        val clean = HrvAnalyzer.rangeFilter(regularSinus())
        val rmssd = HrvAnalyzer.rmssdRaw(clean)!!
        val stats = RhythmScreener.computeStats(clean)
        assertEquals(rmssd / sqrt(2.0), stats.sd1!!, 1e-9)
    }

    @Test
    fun ectopicFraction_reusesRejectEctopic() {
        val clean = HrvAnalyzer.rangeFilter(isolatedEctopy())
        val kept = HrvAnalyzer.rejectEctopic(clean)
        val expected = (clean.size - kept.size).toDouble() / clean.size.toDouble()
        assertEquals(expected, RhythmScreener.ectopicFraction(clean), 1e-12)
    }

    @Test
    fun turningPointRate_ofMonotonicIsZero() {
        val mono = (0 until 10).map { 800.0 + it.toDouble() }
        assertEquals(0.0, RhythmScreener.turningPointRate(mono)!!, 1e-12)
    }

    @Test
    fun turningPointRate_ofZigzagIsMax() {
        val zig = (0 until 11).map { if (it % 2 == 0) 800.0 else 900.0 }
        assertEquals(1.0 / (2.0 / 3.0), RhythmScreener.turningPointRate(zig)!!, 1e-12)
    }

    @Test
    fun rrInterval_convenienceComputesMeanHR() {
        val rows = (0 until 120).map { RrInterval(ts = it, rrMs = 1000) }
        val input = RhythmScreener.WindowInput.fromRr(rows, motionStill = true)
        assertEquals(60.0, input.meanHR, 1e-9)
        assertEquals(120, input.ts.size)
    }

    // ── Night aggregation (descriptive only — no verdict) ─────────────────────────────

    @Test
    fun nightSummary_countsAndRecurrence() {
        val steady = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = regularSinus(), motionStill = true, meanHR = 60.0))
        val varied = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = afibLike(), motionStill = true, meanHR = 60.0))
        val unreadable = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = List(10) { 1000.0 }, motionStill = true, meanHR = 60.0))

        val s = RhythmScreener.summarizeNight(listOf(varied, varied, varied, steady, unreadable))
        assertEquals(4, s.readableWindows)
        assertEquals(3, s.variedWindows)
        assertEquals(1, s.steadyWindows)
        assertTrue(s.variationRecurred)
        assertEquals(RhythmRegularity.VARIED, s.overall)
    }

    @Test
    fun singleVariedBlip_doesNotRecur() {
        val steady = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = regularSinus(), motionStill = true, meanHR = 60.0))
        val varied = RhythmScreener.screenWindow(
            RhythmScreener.WindowInput(rrMs = afibLike(), motionStill = true, meanHR = 60.0))
        val s = RhythmScreener.summarizeNight(listOf(steady, steady, varied, steady))
        assertFalse(s.variationRecurred)
        assertFalse(s.overall == RhythmRegularity.VARIED)
    }

    @Test
    fun emptyNight_isUnreadable() {
        val s = RhythmScreener.summarizeNight(emptyList())
        assertEquals(RhythmRegularity.UNREADABLE, s.overall)
        assertEquals(0, s.readableWindows)
    }

    // ── Non-clinical copy guard ───────────────────────────────────────────────────────

    @Test
    fun noLabelRawString_namesACondition() {
        val banned = listOf("afib", "fibrillation", "arrhythmia", "diagnos", "ecg", "ekg",
            "clinician", "disease", "cardiac", "alert")
        for (label in RhythmRegularity.values()) {
            val raw = label.raw.lowercase()
            for (term in banned) {
                assertFalse("label raw '$raw' must not contain banned term '$term'",
                    raw.contains(term))
            }
        }
    }
}
