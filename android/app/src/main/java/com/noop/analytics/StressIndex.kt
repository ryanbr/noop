package com.noop.analytics

import com.noop.data.RrInterval
import kotlin.math.floor

/*
 * StressIndex.kt, Baevsky's Stress Index (SI), a histogram-based autonomic-balance metric.
 *
 * Byte-for-byte twin of StrandAnalytics/StressIndex.swift. PURELY ADDITIVE display metric; no change to any
 * Charge / Effort / Rest / sleep output.
 *
 *     SI = AMo / (2 * Mo * MxDMn)
 *
 *   • Mo    (mode, s)            : R-R histogram bin centre with the highest count.
 *   • AMo   (amplitude of mode,%): share of intervals in the modal bin, a tall narrow peak (rigid,
 *                                  sympathetically driven) gives a high AMo.
 *   • MxDMn (variation range, s) : max R-R minus min R-R, a wide range (flexible, vagal) lowers SI.
 *
 * High SI = tall/narrow/low-range histogram = rigid rhythm = high sympathetic stress; low SI = broad/flat
 * = relaxed. R-R in SECONDS, AMo as a percentage (0–100), so SI is dimensionless. APPROXIMATE, non-clinical.
 */
object StressIndex {

    /** Histogram bin width in SECONDS, Baevsky's canonical 50 ms cardiointervalography grid. */
    const val BIN_WIDTH_SEC: Double = 0.05

    /** Minimum clean intervals before an SI is computed. */
    const val MIN_BEATS: Int = 20

    /** Intermediate histogram terms, exposed so the UI / a test can show the "why" behind an SI. */
    data class Components(
        val moSec: Double,
        val aMoPercent: Double,
        val mxDMnSec: Double,
        val si: Double,
    )

    /**
     * Baevsky Stress Index from R-R intervals (cleaned with the shared range + Malik ectopic pipeline).
     * null when too few clean beats survive or the variation range is degenerate (all-equal beats → MxDMn 0
     * → an honest null, not Infinity).
     */
    fun stressIndex(rr: List<RrInterval>): Double? = components(rr)?.si

    /** As [stressIndex] but from a raw R-R series in milliseconds. */
    fun stressIndexRaw(rawRR: List<Double>): Double? = componentsRaw(rawRR)?.si

    /** Full SI components from R-R intervals. */
    fun components(rr: List<RrInterval>): Components? = componentsRaw(rr.map { it.rrMs.toDouble() })

    /** Full SI components from a raw R-R series (ms). Pure, deterministic, no clock / IO. */
    fun componentsRaw(rawRR: List<Double>): Components? {
        val clean = HrvAnalyzer.cleanRR(rawRR)
        if (clean.size < MIN_BEATS) return null
        // #585 spot-honesty gate, matching HrvAnalyzer.analyzeRaw: a mostly-rejected capture (out-of-range
        // or ectopic beats) is too noisy to label as stress. clean.size >= MIN_BEATS > 0 => rawRR non-empty.
        if (1.0 - clean.size.toDouble() / rawRR.size.toDouble() > HrvAnalyzer.DEFAULT_SPOT_MAX_REJECTED_FRACTION) return null

        val sec = clean.map { it / 1000.0 }
        val minV = sec.min()
        val maxV = sec.max()
        val mxDMn = maxV - minV
        if (mxDMn <= 0) return null   // all-equal beats: SI undefined.

        val binCount = maxOf(1, floor(mxDMn / BIN_WIDTH_SEC).toInt() + 1)
        val counts = IntArray(binCount)
        for (v in sec) {
            var idx = floor((v - minV) / BIN_WIDTH_SEC).toInt()
            if (idx < 0) idx = 0
            if (idx >= binCount) idx = binCount - 1
            counts[idx]++
        }
        // Modal bin: highest count; ties resolve to the LOWEST index (deterministic across platforms).
        var modeIdx = 0
        var modeCount = counts[0]
        for (i in 1 until binCount) {
            if (counts[i] > modeCount) {
                modeCount = counts[i]
                modeIdx = i
            }
        }
        val mo = minV + (modeIdx + 0.5) * BIN_WIDTH_SEC
        val aMo = modeCount.toDouble() / sec.size.toDouble() * 100.0

        if (mo <= 0) return null
        val si = aMo / (2.0 * mo * mxDMn)
        return Components(moSec = mo, aMoPercent = aMo, mxDMnSec = mxDMn, si = si)
    }
}
