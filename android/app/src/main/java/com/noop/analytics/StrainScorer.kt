package com.noop.analytics

import com.noop.data.HrSample
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.roundToLong

/*
 * StrainScorer.kt — cardiovascular load (NOOP "Effort") on a 0–100 logarithmic scale.
 *
 * Faithful Kotlin port of StrandAnalytics/StrainScorer.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation
 * of published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
 * proprietary algorithm; not medical advice).
 *
 * SCALE: the internal metric key stays `strain`, but the published axis is now 0–100
 * ("Effort"). This is a pure RESCALE — `maxStrain` went 21.0 → 100.0 while the
 * denominator D = 7201 is UNCHANGED, so the log curve and its saturation point
 * (TRIMP 7200 ≈ max) are preserved: a max-Effort day stays exactly as rare as a 21.0
 * day was. trimpToStrain now returns 0–100.
 *
 * Pipeline:
 *   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
 *   2. Per-sample intensity as %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
 *   3. TRIMP accumulated over the window:
 *        a. Edwards 5-zone summation (default): sample contributes its zone weight
 *           (1..5 at 50/60/70/80/90 %HRR cut-offs) × duration.
 *        b. Banister exponential: sample contributes duration × x × 0.64 × e^(b·x).
 *   4. Logarithmic compression onto [0, 100]:
 *        effort = 100 × ln(TRIMP + 1) / ln(D)
 *      D belongs to the METHOD, not to the scorer: Edwards uses [strainDenominator] (7201, from its
 *      sex-independent 7200 ceiling), Banister its own sex-dependent ceiling + 1. See
 *      [logMapDenominator] — reusing one for the other silently rescales the axis (#1545).
 *
 * References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
 * (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 − 0.7×age).
 *
 * Operates on the Room [HrSample] (ts:Long unix seconds, bpm:Int). The HRR-based
 * zone math here is INDEPENDENT of the %HRmax display zones in [HrZones]; this port
 * uses [HrZones] only where the Swift used HRZones (none in this file — strain has
 * its own Edwards %HRR thresholds).
 */
object StrainScorer {

    // ---- Constants (strain.py) ----

    /** Minimum HR readings before computing strain on a DENSE stream (≈10 min at 1 Hz). */
    const val minReadings: Int = 600
    /**
     * Sparse-stream acceptance (#482/#480): a low-cadence strap — the WHOOP 5/MG sends live
     * standard HR only ~every 30 s — would need ~5 h of continuous wear to reach [minReadings], so
     * Effort sat un-scored (null → a stale prior-day value on the gauge) for most of the day. Also
     * accept once the HR series SPANS at least [minSpanSeconds] of wall-clock with a small sample
     * floor. This never fabricates load: TRIMP still integrates honestly, so a genuine low-HR day
     * scores 0 either way — it just lets the live gauge reflect TODAY. A dense 1 Hz stream is
     * unaffected (it clears [minReadings] first).
     */
    const val minSparseReadings: Int = 20
    /** Wall-clock coverage (seconds) qualifying a sparse stream. 600 s = 10 min, matching the dense
     *  gate's ≈10 min of 600 × 1 Hz samples, so both cadences trust the number at the same age. */
    const val minSpanSeconds: Int = 600

    /** Top of the Effort scale (was 21.0 — rescaled to 0–100 for "Effort"). */
    const val maxStrain: Double = 100.0

    /**
     * Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
     * (top zone weight 5 sustained 24 h = 7200) maps to exactly maxStrain:
     * D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1, so the curve shape and
     * its saturation point are independent of maxStrain (the 21→100 rescale is a
     * pure linear scaling of the whole curve).
     */
    const val strainDenominator: Double = 7201.0

    /**
     * Banister's daily ceiling: 24 h held at ΔHRR = 1.0. Unlike Edwards' 7200 this is SEX-DEPENDENT,
     * because the exponent `b` differs — which is the whole reason [strainDenominator] cannot be reused
     * for it. Feeding Banister TRIMP through the Edwards denominator would score every day against a
     * ceiling ~14% (men) or ~32% (women) higher than Banister can actually reach, so nobody would ever
     * see 100 and the two methods would not be on the same axis. (#1545)
     */
    fun banisterDailyCeiling(b: Double): Double = 24.0 * 60.0 * 1.0 * banisterScale * kotlin.math.exp(b)

    /**
     * The log-map denominator for a method, so a caller never has to know which constant belongs to
     * which recipe. Ceiling + 1 in both cases, mirroring how [strainDenominator] was derived, so a
     * theoretical maximum day maps to exactly [maxStrain] under either method.
     */
    fun logMapDenominator(method: Method, sex: String): Double = when (method) {
        Method.EDWARDS -> strainDenominator
        Method.BANISTER ->
            banisterDailyCeiling(if (sex.lowercase().startsWith("f")) banisterBWomen else banisterBMen) + 1.0
    }
    val lnStrainDenominator: Double get() = ln(strainDenominator)

    /** Fallback per-sample duration (minutes) — 1 s at 1 Hz. */
    const val fallbackSampleMin: Double = 1.0 / 60.0

    const val defaultAge: Int = 30
    const val defaultRestingHR: Double = 60.0

    /** Minimum HR samples before the observed high-percentile HRmax is trusted. */
    const val hrmaxMinSamples: Int = 600

    /** Upper percentile for the observed-HRmax estimate. */
    const val hrmaxPercentile: Double = 99.5

    /** Banister coefficients. */
    const val banisterScale: Double = 0.64
    const val banisterBMen: Double = 1.92
    const val banisterBWomen: Double = 1.67

    /** Edwards zone cut-offs as (%HRR threshold, weight), highest-first. */
    val edwardsZones: List<Pair<Double, Int>> = listOf(
        90.0 to 5, 80.0 to 4, 70.0 to 3, 60.0 to 2, 50.0 to 1,
    )

    /** TRIMP accumulation method. */
    enum class Method { EDWARDS, BANISTER }

    /** Strain calibration / fit errors. Mirrors Swift `StrainError`. */
    enum class StrainError { TOO_FEW_PAIRS, DEGENERATE }

    /** Thrown by [fitStrainDenominator] when the fit is impossible. */
    class StrainException(val error: StrainError) : Exception("Strain fit failed: $error")

    // ---- HRmax helpers ----

    /** Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent). */
    fun tanakaHRmax(age: Double): Double = 208.0 - 0.7 * age

    /** Classic 220 − age. Last-resort fallback only. */
    fun defaultMaxHR(age: Int = defaultAge): Int = 220 - age

    /** Linear-interpolated percentile of an already-sorted sequence (numpy-style). */
    fun percentile(sortedValues: List<Double>, pct: Double): Double {
        val n = sortedValues.size
        if (n == 0) return 0.0
        if (n == 1) return sortedValues[0]
        val position = (pct / 100.0) * (n - 1).toDouble()
        val lower = position.toInt()
        val upper = minOf(lower + 1, n - 1)
        val frac = position - lower.toDouble()
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /**
     * Estimate a personalized HRmax from a trailing HR series.
     * Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
     */
    fun estimateHRmax(hrHistory: List<Double>, age: Double?): Pair<Double, String> {
        val n = hrHistory.size
        val tanaka = age?.let { tanakaHRmax(it) }

        if (n >= hrmaxMinSamples) {
            val observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            if (tanaka == null) return observed to "observed"
            return if (observed >= tanaka) observed to "observed" else tanaka to "tanaka"
        }
        if (tanaka != null) return tanaka to "tanaka"
        return 0.0 to "unknown"
    }

    // ---- Karvonen %HRR and Edwards zone weight ----

    /** Karvonen %HRR, clamped [0, 100]. */
    fun pctHRR(bpm: Double, restingHR: Double, hrReserve: Double): Double {
        val pct = (bpm - restingHR) / hrReserve * 100.0
        if (pct < 0) return 0.0
        if (pct > 100) return 100.0
        return pct
    }

    /**
     * Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
     * the clamped path at both ends).
     */
    fun zoneWeight(bpm: Double, restingHR: Double, hrReserve: Double): Int {
        val pct = (bpm - restingHR) / hrReserve * 100.0
        for ((threshold, weight) in edwardsZones) {
            if (pct >= threshold) return weight
        }
        return 0
    }

    // ---- TRIMP accumulation ----

    /**
     * Longest span (minutes) a single reading may be credited with. A wear or connection dropout leaves a
     * gap with no data in it; without a ceiling the last reading before the gap would be credited with the
     * whole of it, so one sample in zone 5 could invent hours of effort. 2 min is 4x the sparsest real
     * cadence we know of (the 5/MG's ~30 s, see [minSparseReadings]), so no genuine cadence is truncated.
     */
    const val maxSampleGapMin: Double = 2.0

    /**
     * The one Effort figure every read-out on Today must show (#1001).
     *
     * Effort has two sources. [stored] is the daily row, rewritten only when the heavy daily pass runs.
     * [live] is today's in-progress recompute over the raw HR stream (local midnight → now), which exists
     * precisely because the stored row lags — early in the day it still holds yesterday's Effort or a
     * stale 0.0 (#402). Past days have no live value and use the row.
     *
     * Taking the MAX rather than preferring [live] is not a tie-break: Effort accrues over a day and must
     * never visibly DROP. The live recompute can UNDER-read when today's HR is sparse, or when a logged
     * workout's load is not in the raw stream — a 5/MG user who trained in the morning had a real 38.3
     * replaced by a live 0 (#489/#506). Flooring at what is already earned is what stops that.
     *
     * Shared so the hero ring, the Key Metrics tile and the chart's edge badge cannot drift apart: they
     * each resolved Effort themselves, and only the ring knew about [live], so an active morning showed
     * 2.3 on the ring and 0.5 in the other two until the daily pass caught up (#1001).
     */
    fun effectiveEffort(live: Double?, stored: Double?): Double? {
        if (live == null) return stored
        if (stored == null) return live
        return kotlin.math.max(live, stored)
    }

    /**
     * Infer per-sample duration (minutes) from the first two timestamps. Falls
     * back to 1 s when fewer than two samples or coincident timestamps.
     *
     * No production caller remains — TRIMP uses [sampleDurationsMinutes] (#950). Kept ONLY so the
     * uniform-identity regression test can compare the new accumulation against the SHIPPED old formula
     * rather than a reimplementation of it. Delete it if that test ever goes.
     */
    fun sampleDurationMinutes(hr: List<HrSample>): Double {
        if (hr.size < 2) return fallbackSampleMin
        val deltaS = abs((hr[1].ts - hr[0].ts).toDouble())
        return if (deltaS > 0) deltaS / 60.0 else fallbackSampleMin
    }

    /**
     * Per-sample durations (minutes): each reading covers the gap to the NEXT one, clamped to
     * [maxSampleGapMin]; the last reuses the gap before it.
     *
     * #950: TRIMP used to take ONE duration inferred from the first two timestamps and multiply the whole
     * zone-weight sum by it. NOOP's HR stream is not uniformly spaced — live Bluetooth arrives ~1 s apart,
     * banked 5/MG history ~30 s, and dropouts leave larger holes — so whichever gap happened to be first
     * set the scale for the entire window. Worse, a workout window and the day that contains it start at
     * different samples, so they picked different factors and the two Effort numbers stopped being
     * comparable, which is what the report was about.
     *
     * For a UNIFORMLY spaced series every gap is the same, so this returns the old value for every sample
     * and the resulting TRIMP is unchanged — which is why no existing test moves.
     */
    fun sampleDurationsMinutes(hr: List<HrSample>): List<Double> {
        if (hr.isEmpty()) return emptyList()
        if (hr.size == 1) return listOf(fallbackSampleMin)
        val out = ArrayList<Double>(hr.size)
        for (i in 0 until hr.size - 1) {
            val deltaS = abs((hr[i + 1].ts - hr[i].ts).toDouble())
            val min = if (deltaS > 0) deltaS / 60.0 else fallbackSampleMin
            out.add(kotlin.math.min(min, maxSampleGapMin))
        }
        out.add(out.last())   // the final reading has no successor; reuse the gap before it
        return out
    }

    fun edwardsTRIMP(
        hr: List<HrSample>,
        restingHR: Double,
        hrReserve: Double,
        durations: List<Double>,
    ): Double {
        var acc = 0.0
        for (i in hr.indices) {
            acc += zoneWeight(hr[i].bpm.toDouble(), restingHR, hrReserve) * durations[i]
        }
        return acc
    }

    fun banisterTRIMP(
        hr: List<HrSample>,
        restingHR: Double,
        hrReserve: Double,
        durations: List<Double>,
        b: Double,
    ): Double {
        var acc = 0.0
        for (i in hr.indices) {
            val x = pctHRR(hr[i].bpm.toDouble(), restingHR, hrReserve) / 100.0
            if (x > 0) acc += durations[i] * x * banisterScale * exp(b * x)
        }
        return acc
    }

    // ---- Logarithmic map ----

    /**
     * Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
     * TRIMP ≤ 0 → 0.
     *
     * The default D is **Edwards'**. A Banister TRIMP passed here without an explicit denominator is
     * scored against the wrong ceiling and reads low — prefer [strain], which resolves the method's own
     * denominator, or pass [logMapDenominator] yourself. (#1545)
     */
    fun trimpToStrain(trimp: Double, denominator: Double = strainDenominator): Double {
        if (trimp <= 0) return 0.0
        val value = maxStrain * ln(trimp + 1.0) / ln(denominator)
        return (value * 100).roundToLong() / 100.0
    }

    // ---- Denominator calibration ----

    /**
     * Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
     * least-squares line: ln(D) = maxStrain × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
     * Reference strains are on the maxStrain (0–100) scale. Throws [StrainException]
     * when fewer than 2 usable pairs (TRIMP>0, strain>0) or degenerate.
     */
    fun fitStrainDenominator(pairs: List<Pair<Double, Double>>): Double {
        val usable = pairs.filter { it.first > 0 && it.second > 0 }
        if (usable.size < 2) throw StrainException(StrainError.TOO_FEW_PAIRS)
        var sumXX = 0.0
        var sumXY = 0.0
        for ((trimp, strain) in usable) {
            val x = ln(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        if (!(sumXY > 0 && sumXX > 0)) throw StrainException(StrainError.DEGENERATE)
        return exp(maxStrain * sumXX / sumXY)
    }

    // ---- Public API ----

    /**
     * Cardiovascular Effort (0–100) from an HR series. APPROXIMATE.
     *
     * Returns null when there isn't yet enough data to trust the number — fewer than [minReadings]
     * samples AND less than [minSpanSeconds] of HR coverage (the sparse-strap path, #482) — or when
     * maxHR ≤ restingHR (invalid HRR).
     *
     * @param hr time-ordered [HrSample] list.
     * @param maxHR HRmax (bpm). Defaults to 220 − defaultAge when null.
     * @param restingHR resting HR (bpm) for the HRR denominator (default 60).
     * @param method [Method.EDWARDS] (default) or [Method.BANISTER].
     * @param sex "male"/"female" — selects the Banister coefficient (ignored by Edwards).
     * @param denominator log-map D (default [strainDenominator]).
     */
    fun strain(
        hr: List<HrSample>,
        maxHR: Double? = null,
        restingHR: Double = defaultRestingHR,
        method: Method = Method.EDWARDS,
        sex: String = "male",
        // null (the default) resolves to the denominator that BELONGS to [method] — Edwards' 7201, or
        // Banister's sex-dependent ceiling. Pass a value only to override.
        denominator: Double? = null,
    ): Double? {
        val resolvedDenominator = denominator ?: logMapDenominator(method, sex)
        val effMax = maxHR ?: defaultMaxHR().toDouble()
        // Enough data to trust the score: a dense stream (≥ minReadings) OR a sparse-but-sustained
        // one spanning ≥ minSpanSeconds with a sample floor (#482 — the 5/MG's ~30 s HR cadence).
        val enoughData = when {
            hr.size >= minReadings -> true
            hr.size >= minSparseReadings -> {
                val tss = hr.map { it.ts }
                (tss.maxOrNull() ?: 0L) - (tss.minOrNull() ?: 0L) >= minSpanSeconds
            }
            else -> false
        }
        if (!enoughData || effMax <= restingHR) return null

        val durations = sampleDurationsMinutes(hr)
        val hrReserve = effMax - restingHR

        val trimp: Double = when (method) {
            Method.BANISTER -> {
                val b = if (sex.lowercase().startsWith("f")) banisterBWomen else banisterBMen
                banisterTRIMP(hr, restingHR, hrReserve, durations, b)
            }
            Method.EDWARDS -> {
                edwardsTRIMP(hr, restingHR, hrReserve, durations)
            }
        }
        return trimpToStrain(trimp, resolvedDenominator)
    }
}
