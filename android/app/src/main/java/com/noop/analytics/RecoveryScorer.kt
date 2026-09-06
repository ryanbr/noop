package com.noop.analytics

import com.noop.data.HrSample
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * RecoveryScorer.kt — resting HR during sleep + a transparent 0–100 recovery score
 * (NOOP "Charge").
 *
 * Faithful Kotlin port of StrandAnalytics/RecoveryScorer.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/recovery.py.
 *
 * recovery() is a z-score + logistic composite. It is APPROXIMATE — not
 * WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
 * HRV-dominant, baseline-normalized proxy.
 *
 * Weighting (documented, grounded, explainable):
 *   higher HRV vs baseline        → higher recovery  (W_HRV   = 0.55, dominant)
 *   lower resting HR vs baseline   → higher recovery  (W_RHR   = 0.20)
 *   lower resp vs baseline         → higher recovery  (W_RESP  = 0.05)
 *   higher sleep performance       → higher recovery  (W_SLEEP = 0.15)
 *   skin temp NEAR baseline        → higher recovery  (W_SKIN_TEMP = 0.05)
 *
 * Skin temp is a SYMMETRIC penalty: further from the personal baseline in EITHER
 * direction (illness / overreach) lowers Charge. It enters as −|dev| / scale, like
 * the "lower is better" terms but on the absolute deviation. When skinTempDev is null
 * the term drops and the remaining weights renormalize, so the score is IDENTICAL to
 * the pre-skin-temp model (the no-skin-temp path is byte-for-byte unchanged).
 *
 * Two OPTIONAL Oura-Readiness-style terms (dormant until a caller supplies them):
 *   overnight resting-HR DECLINE slope ("Recovery Index")      → W_RECOVERY_INDEX    = 0.05
 *   previous-day Effort vs personal baseline ("Activity Balance" /
 *   "Previous Day Activity", collapsed into one term)          → W_ACTIVITY_BALANCE  = 0.05
 * Both are ADDITIVE and NON-BREAKING: each is null unless the caller supplies it, in which
 * case it folds in with its small weight above; when null the term drops and the weights
 * renormalize exactly like the skin-temp term, so the default score for every existing caller
 * is BYTE-IDENTICAL to before either term existed. Recovery Index needs no personal baseline
 * (a fixed, documented bpm/hour scale, same style as sleepPerf/skin-temp); Activity Balance
 * needs BOTH the previous-day Effort value AND its EWMA baseline ([Baselines.strainCfg]) —
 * supplying only one drops the term.
 *
 * Each metric is standardized to a robust z-score against the personal baseline
 * (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
 * renormalized. The composite z is squashed through a logistic anchored so that
 * Z = 0 → ~58% (WHOOP's published population-average recovery).
 *
 * Cold-start: if the HRV baseline (dominant driver) is not yet usable
 * (< MIN_NIGHTS_SEED valid nights), recovery() returns null. Callers may use
 * [populationMean] (58.0) as a fallback but should flag it.
 *
 * `start` / `end` are wall-clock unix SECONDS (Long), matching the com.noop.data
 * layer and HrSample.ts (the Swift source uses Int seconds).
 */

/** Resting-HR estimate + transparent recovery score. Mirrors Swift `RecoveryScorer`. */
object RecoveryScorer {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (recovery.py)
    // ─────────────────────────────────────────────────────────────────────────

    const val wHRV: Double = 0.55
    const val wRHR: Double = 0.20
    const val wResp: Double = 0.05
    const val wSleep: Double = 0.15

    /** Skin-temperature deviation weight (symmetric illness/overreach penalty). */
    const val wSkinTemp: Double = 0.05

    /**
     * Skin-temp deviation scale (°C per z-unit). The term is −|skinTempDevC| / scale,
     * so a 1.0 °C absolute deviation from the personal baseline costs ≈ 1 z-unit of
     * Charge. skinTempDevC is the raw ±°C delta (DailyMetric.skinTempDevC), not a z.
     *
     * Kept at 1.0 to match the Swift reference (RecoveryScorer.skinTempScaleC = 1.0).
     * A prior 0.5 here applied a 2× penalty Charge never intended — every user's
     * Charge diverged from macOS/iOS by the skin-temp term. (Cross-platform parity.)
     */
    const val skinTempDevScale: Double = 1.0

    /**
     * Recovery-Index weight (overnight resting-HR DECLINE slope — Oura's "Recovery Index"
     * contributor). Small and additive like [wSkinTemp]: folds in only when a slope is
     * supplied. Mirrors Swift `RecoveryScorer.wRecoveryIndex`.
     */
    const val wRecoveryIndex: Double = 0.05

    /**
     * Recovery-Index slope scale (bpm/hour): a slope this many bpm/hour steeper than flat (0)
     * costs/earns ≈ 1 z-unit before weighting. Resting HR falling through the night is the
     * physiologically expected, good pattern; flat or rising (illness, alcohol, a late
     * stimulant, restlessness) is not. The SIGN carries the meaning (negative = declining =
     * good), unlike skin-temp's symmetric |deviation| penalty. Mirrors Swift
     * `RecoveryScorer.recoveryIndexScaleBpmPerHr`.
     */
    const val recoveryIndexScaleBpmPerHr: Double = 2.0

    /**
     * Activity-Balance / previous-day-Effort weight (collapses Oura's "Previous Day Activity"
     * and "Activity Balance" readiness contributors into one term). Small and additive like
     * [wSkinTemp]: folds in only when BOTH a previous-day Effort value and its personal EWMA
     * baseline ([Baselines.strainCfg]) are supplied. Mirrors Swift
     * `RecoveryScorer.wActivityBalance`.
     */
    const val wActivityBalance: Double = 0.05

    /** Logistic spread: ±2 z-units ≈ full Red–Green band (15%–95%). */
    const val logisticK: Double = 1.6

    /** Logistic offset so Z=0 → 58%. */
    const val logisticZ0: Double = -0.20

    /** WHOOP-published population-average recovery (%). Cold-start fallback. */
    const val populationMean: Double = 58.0

    /** Recovery band thresholds (WHOOP color scheme). */
    const val bandRedMax: Double = 34.0
    const val bandYellowMax: Double = 67.0

    /** Sleep-performance center ("good night" at ~85% efficiency). */
    const val sleepPerfCenter: Double = 0.85

    /** Sleep-performance scale (±2 z spans the normal range). */
    const val sleepPerfScale: Double = 0.12

    // ───────────────────────────────────────────────────────────────────────────────────────────
    // Parasympathetic-saturation guard (Charge): DETECTED AND LOGGED, NOT APPLIED
    // Kotlin twin of the Swift guard in StrandAnalytics/RecoveryScorer.swift.
    // ───────────────────────────────────────────────────────────────────────────────────────────
    //
    // A low nightly HRV is normally a fatigue signal, so the HRV term (wHRV = 0.55, the dominant
    // driver) pulls Charge DOWN. There is a CANDIDATE benign pattern the raw z-score may mis-read:
    // parasympathetic (vagal) saturation. In a very fit or very relaxed state the RMSSD-HRV response
    // can saturate and read LOW while resting HR reads LOW too, and the two DECOUPLE. On such a night
    // the dominant HRV penalty tanks Charge even though the person is well rested.
    //
    // The candidate discriminator is the SIGN of the resting-HR term versus the HRV term. recovery()
    // builds the HRV term as (hrv - mu)/sigma (NEGATIVE when HRV is below baseline = the penalty) and
    // the RHR term as (mu - rhr)/sigma (POSITIVE when resting HR is below baseline = recovery-good). In
    // a normally-coupled autonomic response a low HRV travels WITH a HIGH resting HR (sympathetic
    // drive), so both terms point the SAME way (down). When instead the HRV term points "bad" while the
    // resting-HR term points "good", the expected HRV<->RHR coupling has broken.
    //
    // ── WHY THE EASING IS COMPUTED BUT DELIBERATELY NOT APPLIED ─────────────────────────────────
    //
    // This code DETECTS the signature and REPORTS the easing it would apply, but recovery() does NOT
    // consume it: the Charge number is byte-identical to pre-guard behaviour. Two reasons, both
    // currently unresolved:
    //
    //   1. VALIDATION GAP. The real-data validation behind this guard recorded ZERO firings over ~2
    //      weeks. That is evidence the gate does not OVER-fire; it is NOT evidence that the easing is
    //      the right size, or right at all, on a real saturation night, because no real saturation
    //      night was ever observed. Every night that would actually move Charge is covered by
    //      synthetic fixtures only (see RecoverySaturationGuardTest).
    //   2. CONTESTED PREMISE. Low HRV + low resting HR is ALSO a reported signature of parasympathetic
    //      (non-functional) OVERREACHING, which is genuinely maladaptive. From the HRV/RHR pair alone,
    //      benign saturation and overreaching are not distinguishable, and they want OPPOSITE Charge
    //      corrections. Easing the penalty on an overreaching night would hide a real problem.
    //
    // So the guard ships INSTRUMENT-FIRST: detection is live and surfaces in the Charge trace (the
    // "charge saturation active ... wouldRaiseCharge=N" line) and in the RecoveryDrivers HRV verdict,
    // so real low-HRV + low-RHR nights accumulate and can be checked against ground truth. Enabling the
    // easing is a follow-up gated on confirmed real firings, not on the synthetic fixtures.
    //
    // TO ENABLE LATER: feed [ParasympatheticSaturation.easedHrvZ] into the HRV term at the marked call
    // site in recovery(), and flip the tests that currently pin the score as UNCHANGED.

    /** Personal-sigma units BOTH the low-HRV arm and the low-resting-HR arm must clear before the guard
     *  engages. 0.5 sigma keeps it OFF marginal / noise nights. Mirrors Swift `RecoveryScorer.satEnterZ`. */
    const val satEnterZ: Double = 0.5

    /** Personal-sigma units at which the saturation signal reaches FULL strength; between [satEnterZ] and
     *  this the easing ramps linearly from 0 to [satMaxDampFraction]. Mirrors Swift `satFullZ`. */
    const val satFullZ: Double = 1.5

    /** Maximum fraction of the low-HRV penalty the easing would ever credit back. 0.5 = at most HALF the
     *  penalty would be eased, so a genuinely low-HRV night would NEVER be scored as if HRV sat at baseline.
     *  The core conservatism knob for when the easing is enabled; today it only bounds the reported would-be
     *  delta. Mirrors Swift `satMaxDampFraction`. */
    const val satMaxDampFraction: Double = 0.5

    /**
     * Outcome of the parasympathetic-saturation check for one night. Mirrors Swift
     * `RecoveryScorer.ParasympatheticSaturation`.
     *
     * COUNTERFACTUAL, not applied: [easedHrvZ] / [dampFraction] describe the easing this guard WOULD
     * apply. recovery() does not consume them (see the header above for why). Today they exist to be
     * logged by the Charge trace and to flag the RecoveryDrivers HRV verdict, so that real firings can
     * be counted before the easing is ever allowed to move the score.
     *
     * @property easedHrvZ the HRV z the easing WOULD use: the input z shrunk toward 0 (never past it),
     *   lightening the low-HRV penalty. Equals the input hrvZ when the guard is inactive. NOT fed to
     *   the score.
     * @property active true iff the saturation regime was detected, i.e. the guard WOULD have eased the
     *   penalty. The Charge number is the same either way.
     * @property dampFraction fraction of the HRV penalty the easing WOULD credit back, in
     *   [0, satMaxDampFraction]. 0 when inactive.
     */
    data class ParasympatheticSaturation(
        val easedHrvZ: Double,
        val active: Boolean,
        val dampFraction: Double,
    )

    /**
     * Detect parasympathetic saturation from tonight's HRV and resting-HR z-scores and compute the
     * easing that WOULD be applied to the low-HRV penalty (shrinking its negative z toward 0). Mirrors
     * Swift `RecoveryScorer.parasympatheticSaturation` byte-for-byte.
     *
     * This is pure detection + a counterfactual. It has no effect on Charge: recovery() scores the raw
     * HRV z regardless of what this returns. See the header above for the validation gap and the
     * contested premise that keep the easing switched off.
     *
     * @param hrvZ the HRV term as recovery() builds it, (hrv - mu)/sigma. Higher is better; a NEGATIVE
     *   value means HRV is below baseline (the penalty direction).
     * @param rhrZ the resting-HR term as recovery() builds it, (mu - rhr)/sigma. Higher is better; a
     *   POSITIVE value means resting HR is below baseline (the recovery-good direction). null when there
     *   is no resting-HR baseline — with nothing to corroborate the low HRV, the guard never fires.
     */
    internal fun parasympatheticSaturation(hrvZ: Double, rhrZ: Double?): ParasympatheticSaturation {
        // Without a resting-HR term there is nothing to corroborate the low HRV: benign saturation and
        // real fatigue are indistinguishable from HRV alone, so report no saturation.
        if (rhrZ == null) {
            return ParasympatheticSaturation(easedHrvZ = hrvZ, active = false, dampFraction = 0.0)
        }
        // Saturation SIGNATURE, in personal-sigma units:
        //   hrvLow > 0 <=> HRV below baseline (the penalty we might ease)
        //   rhrLow > 0 <=> resting HR below baseline (the corroborating "also low" signal)
        // Both must clear satEnterZ, so only a clear low-HRV + low-RHR decoupling is ever eased and a
        // low-HRV + HIGH-RHR fatigue night (rhrLow < 0) can never qualify.
        val hrvLow = -hrvZ
        val rhrLow = rhrZ
        if (hrvLow < satEnterZ || rhrLow < satEnterZ) {
            return ParasympatheticSaturation(easedHrvZ = hrvZ, active = false, dampFraction = 0.0)
        }
        // Strength is driven by the WEAKER of the two arms (min), normalized from the entry gate to
        // satFullZ and clamped to [0, 1]. Using the weaker arm is deliberately conservative.
        val couplingStrength = min(hrvLow, rhrLow)
        val s = max(0.0, min(1.0, (couplingStrength - satEnterZ) / (satFullZ - satEnterZ)))
        val dampFraction = satMaxDampFraction * s
        // The easing this WOULD apply: shrink the (negative) HRV z toward 0. (1 - dampFraction) stays
        // in [1 - satMaxDampFraction, 1], so the penalty would only ever be REDUCED — never removed,
        // never sign-flipped into a bonus. Computed for reporting only; recovery() ignores it.
        val easedHrvZ = hrvZ * (1.0 - dampFraction)
        return ParasympatheticSaturation(
            easedHrvZ = easedHrvZ,
            active = dampFraction > 0.0,
            dampFraction = dampFraction,
        )
    }

    /** Rolling-mean HR window (seconds) for the resting-HR estimate. */
    const val restingHRWindowS: Int = 5 * 60

    /**
     * Minimum HR samples a 5-min bin must hold before its mean is eligible to WIN the resting
     * floor (#686). A thinly-populated bin — at the limit a single lone beat — lets one artifact
     * (a dropout, a decode glitch) become the bin "mean" and win the night's minimum, dragging
     * resting HR implausibly low. Requiring a handful of samples means the floor is a genuine
     * sustained dip, not a one-sample fluke. Worn nights stream ~1 Hz HR so a real 5-min bin holds
     * hundreds of samples and clears this trivially; only sparse/edge bins fall below it. Does NOT
     * change the floor DEFINITION — still the min of 5-min bin means — only stops an under-sampled
     * artifact bin from being that min. Mirrors Swift `RecoveryScorer.restingHRMinBinSamples`.
     */
    const val restingHRMinBinSamples: Int = 5

    /**
     * Physiological resting-HR floor (bpm) below which a bin mean is rejected as a dropout artifact
     * (#686), never the resting floor. An adult's true sleeping resting HR essentially never sits
     * below this; a 5-min mean that does is a run of dropout/decode-zero beats, not a real cardiac
     * dip. 25 bpm clears even deeply-bradycardic trained athletes (resting HRs in the low 30s) with
     * margin while rejecting the implausible artifact range. Mirrors Swift
     * `RecoveryScorer.restingHRMinPlausibleBpm`.
     */
    const val restingHRMinPlausibleBpm: Double = 25.0

    // ─────────────────────────────────────────────────────────────────────────
    // Resting HR
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lowest sustained HR during the in-bed window (bpm, rounded), or null.
     *
     * "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
     * samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
     * the night's true floor. Returns null when there are no HR samples in window.
     *
     * The window is CLOSED at both ends, so the binning is too: bins are `[t, t + windowS)` except
     * the final one, which is `[t, end]`. Half-open bins alone would admit a sample sitting
     * exactly on an aligned `end` through the prefilter and then place it in no bin — counted as
     * data, silently ignored. A zero-length window (`start == end`) is that single closed bin.
     *
     * Artifact hardening (#686): a bin may only WIN the floor when it is BOTH well-populated
     * (≥ [restingHRMinBinSamples], so one lone artifact beat can't be a bin "mean") AND
     * physiologically plausible (mean ≥ [restingHRMinPlausibleBpm], rejecting dropout-driven
     * sub-physiological dips). The floor DEFINITION is unchanged — still the minimum of the 5-min
     * bin means — only artifact bins are barred from being that minimum. If no bin qualifies (a
     * wholly sparse/degenerate window), fall back to the lowest of ALL bin means, else the
     * all-sample mean, preserving the never-null-on-data behaviour. Mirrors Swift `restingHR`.
     *
     * @param start / @param end window bounds, unix SECONDS (Long).
     */
    fun restingHR(hr: List<HrSample>, start: Long, end: Long): Int? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null

        val means = ArrayList<Double>()      // every bin mean (legacy floor, the fallback)
        val qualified = ArrayList<Double>()  // bins eligible to WIN the floor (#686)
        var t = start
        do {
            // The last bin (its half-open end reaches or passes `end`) closes on `end` instead,
            // catching an endpoint sample the prefilter already admitted. `seg` holds nothing past
            // `end`, so "everything from t onwards" IS [t, end]. `do` runs once for a zero-length
            // window, where that single closed bin is the whole window.
            val binEnd = t + restingHRWindowS
            val isFinal = binEnd >= end
            val win = seg.filter { it.ts >= t && (isFinal || it.ts < binEnd) }
            if (win.isNotEmpty()) {
                val mean = win.sumOf { it.bpm }.toDouble() / win.size.toDouble()
                means.add(mean)
                // A bin wins the floor only if it is well-populated AND physiologically plausible —
                // a thin (single-artifact) or sub-physiological (dropout) bin can't be the minimum.
                if (win.size >= restingHRMinBinSamples && mean >= restingHRMinPlausibleBpm) {
                    qualified.add(mean)
                }
            }
            t += restingHRWindowS
        } while (t < end)
        val floor: Double = qualified.minOrNull()
            ?: means.minOrNull()
            ?: (seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble())
        return floor.roundToInt()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery Index (overnight HR-decline slope)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Minimum 5-minute bins ([restingHR]'s SAME binning) required before a slope is trusted —
     * below this, too little of the night has elapsed to fit a trend, and a 1-2-point
     * regression is noise, not a night-long pattern. 6 bins = 30 minutes of binned coverage,
     * a deliberately low floor so a short/partial night still gets a number rather than a
     * routine null. Mirrors Swift `RecoveryScorer.recoveryIndexMinBins`.
     */
    const val recoveryIndexMinBins: Int = 6

    /**
     * Overnight resting-HR DECLINE slope (bpm/hour) across the in-bed window — the "Recovery
     * Index" component of Oura's Readiness that Charge lacked (it previously only read the
     * overnight FLOOR via [restingHR] above, never the trend that reaches it).
     *
     * Computed as the least-squares slope of the SAME non-overlapping 5-minute HR bin means
     * [restingHR] uses ([restingHRWindowS]) against each bin's midpoint time (hours from
     * `start`, and for the final closed bin still its half-open midpoint `t + windowS / 2`, so a
     * partial or endpoint-only last bin keeps the same time axis as every other bin).
     * NEGATIVE = declining (HR falling through the night — the physiologically
     * expected, good pattern); POSITIVE = rising (restlessness, illness, alcohol, a late
     * stimulant). Returns null when fewer than [recoveryIndexMinBins] bins have data (too
     * little of the window to fit a trend) or there are no samples at all — it never
     * fabricates a slope from a sliver of the night. Mirrors Swift `recoveryIndexSlope`.
     *
     * @param start / @param end window bounds, unix SECONDS (Long).
     */
    fun recoveryIndexSlope(hr: List<HrSample>, start: Long, end: Long): Double? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null

        // Same non-overlapping 5-minute binning as restingHR: both read the identical
        // underlying series, one as a floor, one as a trend across it.
        val points = ArrayList<Pair<Double, Double>>() // (tHours, meanBpm)
        var t = start
        do {
            // Final bin closes on `end` — same closed-window rule as restingHR, so an
            // endpoint sample counts toward the bin gate instead of vanishing after admission.
            val binEnd = t + restingHRWindowS
            val isFinal = binEnd >= end
            val win = seg.filter { it.ts >= t && (isFinal || it.ts < binEnd) }
            if (win.isNotEmpty()) {
                val mean = win.sumOf { it.bpm }.toDouble() / win.size.toDouble()
                val midpointS = (t - start).toDouble() + restingHRWindowS / 2.0
                points.add((midpointS / 3600.0) to mean)
            }
            t += restingHRWindowS
        } while (t < end)
        if (points.size < recoveryIndexMinBins) return null

        // Least-squares slope: Σ((t−t̄)(y−ȳ)) / Σ((t−t̄)²), bpm per hour.
        val n = points.size.toDouble()
        val tBar = points.sumOf { it.first } / n
        val yBar = points.sumOf { it.second } / n
        var num = 0.0
        var den = 0.0
        for ((tHours, meanBpm) in points) {
            val dt = tHours - tBar
            num += dt * (meanBpm - yBar)
            den += dt * dt
        }
        // Degenerate (all bins at the same instant): no time spread to fit against.
        if (den <= 1e-9) return 0.0
        return num / den
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery band
    // ─────────────────────────────────────────────────────────────────────────

    /** WHOOP-style color band for a recovery score [0, 100]. */
    fun band(score: Double): String {
        if (score < bandRedMax) return "red"
        if (score < bandYellowMax) return "yellow"
        return "green"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery score
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A baseline driver: mean + spread (internal abs-dev units, as in [BaselineState]).
     * Mirrors Swift `RecoveryScorer.DriverBaseline`.
     */
    data class DriverBaseline(val mean: Double, val spread: Double) {
        constructor(state: BaselineState) : this(mean = state.baseline, spread = state.spread)
    }

    /** Robust z-score using EWMA spread: (value − mean) / (1.253 × spread). */
    internal fun zScore(value: Double, mean: Double, spread: Double): Double {
        val sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /**
     * Z-score + logistic recovery score in [0, 100]. APPROXIMATE.
     *
     * Returns null when the HRV baseline (dominant driver) is not yet usable, or
     * no valid driver is available at all.
     *
     * @param hrv tonight's HRV (RMSSD, ms).
     * @param rhr tonight's resting HR (bpm).
     * @param resp tonight's respiration (raw or calibrated — z is scale-invariant);
     *   null drops the term.
     * @param hrvBaseline HRV baseline (required for a score).
     * @param rhrBaseline resting-HR baseline; null drops the RHR term.
     * @param respBaseline respiration baseline; null drops the resp term.
     * @param sleepPerf sleep-performance proxy (Rest composite 0..1, or efficiency
     *   0..1 for legacy callers); null drops the term.
     * @param skinTempDev tonight's skin-temperature deviation from the personal
     *   baseline (raw ±°C, DailyMetric.skinTempDevC); applied as a SYMMETRIC penalty
     *   −|dev| / skinTempDevScale. null drops the term and renormalizes (score then
     *   identical to the pre-skin-temp model).
     * @param hrvBaselineUsable whether the HRV baseline has enough nights
     *   (BaselineState.usable). When false, returns null (cold-start).
     * @param recoveryIndexSlope overnight resting-HR DECLINE slope (bpm/hour, from
     *   [recoveryIndexSlope]). Negative (declining) supports recovery; positive (rising)
     *   limits it, weight [wRecoveryIndex]. null (the default) drops the term and the
     *   weights renormalize, so the no-slope score is IDENTICAL to before this parameter
     *   existed.
     * @param effortBaseline personal EWMA baseline of daily Effort/strain
     *   ([Baselines.strainCfg]). Needs [priorDayEffort] too — supplying only one drops
     *   the term.
     * @param priorDayEffort yesterday's Effort/strain (0–100, StrainScorer.strain). Lower vs
     *   [effortBaseline] supports recovery, same "lower is better" direction as RHR/resp,
     *   weight [wActivityBalance]. null (the default, like effortBaseline) drops the term
     *   and the weights renormalize, so the no-effort score is IDENTICAL to before either
     *   parameter existed.
     */
    fun recovery(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: DriverBaseline?,
        rhrBaseline: DriverBaseline?,
        respBaseline: DriverBaseline?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
        hrvBaselineUsable: Boolean = true,
        recoveryIndexSlope: Double? = null,
        effortBaseline: DriverBaseline? = null,
        priorDayEffort: Double? = null,
    ): Double? {
        // Cold-start gate: HRV is the dominant driver; if its baseline isn't
        // usable, refuse to score (more honest than a fabricated value).
        if (!hrvBaselineUsable) return null

        val terms = ArrayList<Pair<Double, Double>>() // (z, weight)

        // HRV term: higher is better.
        //
        // INSTRUMENT-FIRST CALL SITE for the parasympathetic-saturation guard. The guard is NOT applied
        // here: this term is the RAW z, so Charge is byte-identical to pre-guard behaviour. The
        // signature is still detected and reported out-of-band (Charge trace + RecoveryDrivers verdict)
        // so real firings can be counted first. See the header above for why, and swap in
        // parasympatheticSaturation(hrvZ, rhrZ).easedHrvZ here to enable it.
        hrvBaseline?.let { b ->
            terms.add(zScore(hrv, b.mean, b.spread) to wHRV)
        }
        // RHR term: lower is better → (μ − x) / σ.
        rhrBaseline?.let { b ->
            terms.add(zScore(b.mean, rhr, b.spread) to wRHR)
        }
        // Resp term: lower is better, optional.
        if (resp != null && respBaseline != null) {
            terms.add(zScore(respBaseline.mean, resp, respBaseline.spread) to wResp)
        }
        // Sleep-performance term: no baseline needed; centered at SLEEP_PERF_CENTER.
        if (sleepPerf != null) {
            terms.add(((sleepPerf - sleepPerfCenter) / sleepPerfScale) to wSleep)
        }
        // Skin-temp term: SYMMETRIC penalty, no baseline arg (skinTempDev is already a
        // deviation). Further from baseline in either direction → more negative z.
        if (skinTempDev != null) {
            terms.add((-abs(skinTempDev) / skinTempDevScale) to wSkinTemp)
        }
        // Recovery-Index term: overnight HR-DECLINE slope (bpm/hour). No baseline needed (a
        // fixed, documented scale, same style as sleepPerf/skin-temp). Negative (declining)
        // supports recovery; positive (rising) limits it. Added only when supplied.
        if (recoveryIndexSlope != null) {
            terms.add((-recoveryIndexSlope / recoveryIndexScaleBpmPerHr) to wRecoveryIndex)
        }
        // Activity-Balance / previous-day-Effort term: lower vs personal baseline is better,
        // same "lower is better" direction as RHR/resp → (μ − x) / σ. Needs BOTH the value
        // and a baseline, matching resp's pattern; added only when both are supplied.
        if (priorDayEffort != null && effortBaseline != null) {
            terms.add(
                zScore(effortBaseline.mean, priorDayEffort, effortBaseline.spread) to wActivityBalance,
            )
        }

        if (terms.isEmpty()) return null
        val totalWeight = terms.sumOf { it.second }
        if (totalWeight <= 0.0) return null

        val z = terms.sumOf { it.first * it.second } / totalWeight
        return logisticScore(z)
    }

    /**
     * The Charge logistic: weighted-composite z -> 0-100, clamped. Factored out of recovery() so the
     * trace's saturation counterfactual ("what Charge WOULD read if the easing were applied") runs
     * through the EXACT same curve the real score does and cannot drift from it. Same expression as
     * before it was extracted, so every existing score is unchanged. Mirrors Swift
     * `RecoveryScorer.logisticScore(compositeZ:)`.
     */
    internal fun logisticScore(compositeZ: Double): Double {
        val score = 100.0 / (1.0 + exp(-logisticK * (compositeZ - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /**
     * Convenience overload taking [BaselineState] directly. Enforces the cold-start
     * gate using `hrvBaseline.usable`. Mirrors the Swift `recovery(...)` overload.
     */
    fun recovery(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
        recoveryIndexSlope: Double? = null,
        effortBaseline: BaselineState? = null,
        priorDayEffort: Double? = null,
    ): Double? = recovery(
        hrv = hrv,
        rhr = rhr,
        resp = resp,
        hrvBaseline = DriverBaseline(hrvBaseline),
        rhrBaseline = rhrBaseline?.let { DriverBaseline(it) },
        respBaseline = respBaseline?.let { DriverBaseline(it) },
        sleepPerf = sleepPerf,
        skinTempDev = skinTempDev,
        hrvBaselineUsable = hrvBaseline.usable,
        recoveryIndexSlope = recoveryIndexSlope,
        effortBaseline = effortBaseline?.let { DriverBaseline(it) },
        priorDayEffort = priorDayEffort,
    )
}
