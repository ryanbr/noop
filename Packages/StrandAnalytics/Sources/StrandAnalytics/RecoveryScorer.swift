import Foundation
import WhoopProtocol

// RecoveryScorer.swift — resting HR during sleep + a transparent 0–100 recovery score.
//
// Ported from server/ingest/app/analysis/recovery.py.
//
// recovery() is a z-score + logistic composite. It is APPROXIMATE — not
// WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
// HRV-dominant, baseline-normalized proxy.
//
// Weighting (documented, grounded, explainable; this is "Charge" in the UI):
//   higher HRV vs baseline       → higher recovery  (W_HRV       = 0.55, dominant)
//   lower resting HR vs baseline → higher recovery  (W_RHR       = 0.20)
//   higher rest quality (sleep)  → higher recovery  (W_SLEEP     = 0.15)
//   lower resp vs baseline       → higher recovery  (W_RESP      = 0.05)
//   skin-temp deviation from 0   → lower recovery   (W_SKIN_TEMP = 0.05)
//
// The Charge/Effort/Rest redesign folds skin temperature in (illness/overreach
// signal): HRV dropped 0.60 → 0.55 to make room for W_SKIN_TEMP = 0.05. The
// skin-temp term is a SYMMETRIC penalty on the ±°C deviation (−|dev|/scale), so any
// drift away from the personal baseline — hot or cold — lowers Charge. It is added
// ONLY when a skin-temp deviation is supplied; when nil the term drops and the
// weights renormalize, leaving the no-skin-temp score IDENTICAL to before.
//
// Two more OPTIONAL, nil-default terms close the gap to Oura Readiness's 8 contributors (an
// Oura-reference validation found Charge already tracks Oura's readiness at r≈0.71; these are
// the two components Charge lacked):
//   overnight resting-HR DECLINE slope ("Recovery Index")      → W_RECOVERY_INDEX    = 0.05
//   previous-day Effort vs personal baseline ("Activity Balance" /
//   "Previous Day Activity", collapsed into one term)          → W_ACTIVITY_BALANCE  = 0.05
// Both are ADDITIVE and NON-BREAKING: each is nil unless the caller supplies it, in which case
// it folds in with its small weight above; when nil the term drops and the weights renormalize
// exactly like the skin-temp term, so the default score for every existing caller is
// BYTE-IDENTICAL to before either term existed. Recovery Index needs no personal baseline (a
// fixed, documented bpm/hour scale, same style as sleepPerf/skin-temp); Activity Balance needs
// BOTH the previous-day Effort value AND its EWMA baseline (`Baselines.strainCfg`) — supplying
// only one drops the term.
//
// Each metric is standardized to a robust z-score against the personal baseline
// (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
// renormalized. The composite z is squashed through a logistic anchored so that
// Z = 0 → ~58% (WHOOP's published population-average recovery).
//
// Cold-start: if the HRV baseline (dominant driver) is not yet usable
// (< MIN_NIGHTS_SEED valid nights), recovery() returns nil. Callers may use
// RECOVERY_POPULATION_MEAN (58.0) as a fallback but should flag it.

public enum RecoveryScorer {

    // MARK: - Constants (recovery.py)

    public static let wHRV: Double = 0.55
    public static let wRHR: Double = 0.20
    public static let wResp: Double = 0.05
    public static let wSleep: Double = 0.15
    /// Skin-temperature deviation weight (Charge/Effort/Rest redesign). HRV gave up
    /// 0.05 (0.60 → 0.55) to fund it.
    public static let wSkinTemp: Double = 0.05

    /// Skin-temp penalty scale (°C): a 1 °C deviation from baseline costs ≈1 z-unit of
    /// penalty before weighting. Symmetric — sign of the deviation does not matter.
    public static let skinTempScaleC: Double = 1.0

    /// Recovery-Index weight (overnight resting-HR DECLINE slope — Oura's "Recovery Index"
    /// contributor). Small and additive like wSkinTemp: folds in only when a slope is supplied.
    public static let wRecoveryIndex: Double = 0.05

    /// Recovery-Index slope scale (bpm/hour): a slope this many bpm/hour steeper than flat (0)
    /// costs/earns ≈1 z-unit before weighting. Resting HR falling through the night is the
    /// physiologically expected, good pattern; flat or rising (illness, alcohol, a late
    /// stimulant, restlessness) is not. The SIGN carries the meaning (negative = declining =
    /// good), unlike skin-temp's symmetric |deviation| penalty.
    public static let recoveryIndexScaleBpmPerHr: Double = 2.0

    /// Activity-Balance / previous-day-Effort weight (collapses Oura's "Previous Day Activity"
    /// and "Activity Balance" readiness contributors into one term). Small and additive like
    /// wSkinTemp: folds in only when BOTH a previous-day Effort value and its personal EWMA
    /// baseline (`Baselines.strainCfg`) are supplied.
    public static let wActivityBalance: Double = 0.05

    /// Logistic spread: ±2 z-units ≈ full Red–Green band (15%–95%).
    public static let logisticK: Double = 1.6
    /// Logistic offset so Z=0 → 58%.
    public static let logisticZ0: Double = -0.20
    /// WHOOP-published population-average recovery (%). Cold-start fallback.
    public static let populationMean: Double = 58.0

    /// Recovery band thresholds (WHOOP color scheme).
    public static let bandRedMax: Double = 34.0
    public static let bandYellowMax: Double = 67.0

    /// Sleep-performance center ("good night" at ~85% efficiency).
    public static let sleepPerfCenter: Double = 0.85
    /// Sleep-performance scale (±2 z spans the normal range).
    public static let sleepPerfScale: Double = 0.12

    // MARK: - Parasympathetic-saturation guard (Charge): DETECTED AND LOGGED, NOT APPLIED
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
    // This code DETECTS the signature and REPORTS the easing it would apply, but `recovery(...)` does
    // NOT consume it: the Charge number is byte-identical to pre-guard behaviour. Two reasons, both
    // currently unresolved:
    //
    //   1. VALIDATION GAP. The real-data validation behind this guard recorded ZERO firings over ~2
    //      weeks. That is evidence the gate does not OVER-fire; it is NOT evidence that the easing is
    //      the right size, or right at all, on a real saturation night, because no real saturation
    //      night was ever observed. Every night that would actually move Charge is covered by
    //      synthetic fixtures only (see RecoverySaturationGuardTests).
    //   2. CONTESTED PREMISE. Low HRV + low resting HR is ALSO a reported signature of parasympathetic
    //      (non-functional) OVERREACHING, which is genuinely maladaptive. From the HRV/RHR pair alone,
    //      benign saturation and overreaching are not distinguishable, and they want OPPOSITE Charge
    //      corrections. Easing the penalty on an overreaching night would hide a real problem.
    //
    // So the guard ships INSTRUMENT-FIRST: detection is live and surfaces in the Charge trace (the
    // "charge saturation active ... wouldRaiseCharge=N" line) and in the ChargeDrivers HRV verdict, so
    // real low-HRV + low-RHR nights accumulate and can be checked against ground truth. Enabling the
    // easing is a follow-up gated on confirmed real firings, not on the synthetic fixtures.
    //
    // TO ENABLE LATER: feed `easedHrvZ` into the HRV term at the marked call site in `recovery(...)`,
    // and flip the tests that currently pin the score as UNCHANGED.

    /// Personal-sigma units BOTH the low-HRV arm and the low-resting-HR arm must clear before the
    /// guard engages. 0.5 sigma keeps it OFF marginal / noise nights: a night must be clearly low on
    /// HRV AND clearly low on resting HR (each at least half a personal standard deviation into its
    /// saturation direction) before any easing applies.
    public static let satEnterZ: Double = 0.5

    /// Personal-sigma units at which the saturation signal reaches FULL strength. Between satEnterZ
    /// and this the easing ramps linearly from 0 to satMaxDampFraction; at/above it the easing is
    /// capped. 1.5 sigma means "both HRV and resting HR a clear 1.5 SD below baseline" is treated as
    /// unambiguous saturation.
    public static let satFullZ: Double = 1.5

    /// Maximum fraction of the low-HRV penalty the easing would ever credit back. 0.5 = at most HALF
    /// the penalty would be eased, so a genuinely low-HRV night would NEVER be scored as if HRV sat at
    /// baseline: at least half of the low-HRV penalty would always survive. The core conservatism knob
    /// for when the easing is enabled; today it only bounds the reported would-be delta.
    public static let satMaxDampFraction: Double = 0.5

    /// Outcome of the parasympathetic-saturation check for one night.
    ///
    /// COUNTERFACTUAL, not applied: `easedHrvZ` / `dampFraction` describe the easing this guard WOULD
    /// apply. `recovery(...)` does not consume them (see the MARK header for why). Today they exist to
    /// be logged by the Charge trace and to flag the ChargeDrivers HRV verdict, so that real firings
    /// can be counted before the easing is ever allowed to move the score.
    struct ParasympatheticSaturation: Equatable, Sendable {
        /// The HRV z the easing WOULD use: the input z shrunk toward 0 (never past it), lightening the
        /// low-HRV penalty. Equals the input hrvZ when the guard is inactive. NOT fed to the score.
        let easedHrvZ: Double
        /// True iff the saturation regime was detected, i.e. the guard WOULD have eased the penalty.
        /// The Charge number is the same either way.
        let active: Bool
        /// Fraction of the HRV penalty the easing WOULD credit back, in [0, satMaxDampFraction].
        /// 0 when inactive.
        let dampFraction: Double
    }

    /// Detect parasympathetic saturation from tonight's HRV and resting-HR z-scores and compute the
    /// easing that WOULD be applied to the low-HRV penalty (shrinking its negative z toward 0).
    ///
    /// This is pure detection + a counterfactual. It has no effect on Charge: `recovery(...)` scores
    /// the raw HRV z regardless of what this returns. See the MARK header for the validation gap and
    /// the contested premise that keep the easing switched off.
    ///
    /// - Parameters:
    ///   - hrvZ: the HRV term as recovery() builds it, (hrv - mu)/sigma. Higher is better; a
    ///     NEGATIVE value means HRV is below baseline (the penalty direction).
    ///   - rhrZ: the resting-HR term as recovery() builds it, (mu - rhr)/sigma. Higher is better; a
    ///     POSITIVE value means resting HR is below baseline (the recovery-good direction). Pass nil
    ///     when there is no resting-HR baseline (no RHR term) — with nothing to corroborate the low
    ///     HRV, the guard refuses to guess and never fires.
    /// - Returns: whether the signature fired, plus the eased HRV z and damp fraction it would imply.
    static func parasympatheticSaturation(hrvZ: Double, rhrZ: Double?) -> ParasympatheticSaturation {
        // Without a resting-HR term there is nothing to corroborate the low HRV: benign saturation
        // and real fatigue are indistinguishable from HRV alone, so report no saturation.
        guard let rhrZ = rhrZ else {
            return ParasympatheticSaturation(easedHrvZ: hrvZ, active: false, dampFraction: 0)
        }
        // Saturation SIGNATURE, in personal-sigma units:
        //   hrvLow  > 0  <=> HRV below baseline (the penalty we might ease)
        //   rhrLow  > 0  <=> resting HR below baseline (the corroborating "also low" signal)
        // Both must clear satEnterZ, so only a clear low-HRV + low-RHR decoupling is ever eased and a
        // low-HRV + HIGH-RHR fatigue night (rhrLow < 0) can never qualify.
        let hrvLow = -hrvZ
        let rhrLow = rhrZ
        guard hrvLow >= satEnterZ, rhrLow >= satEnterZ else {
            return ParasympatheticSaturation(easedHrvZ: hrvZ, active: false, dampFraction: 0)
        }
        // Strength is driven by the WEAKER of the two arms (min), normalized from the entry gate to
        // satFullZ and clamped to [0, 1]. Using the weaker arm is deliberately conservative: full
        // easing requires HRV clearly low AND resting HR clearly low; a very low HRV paired with only
        // a mildly low resting HR is limited by the resting-HR arm.
        let couplingStrength = min(hrvLow, rhrLow)
        let s = max(0.0, min(1.0, (couplingStrength - satEnterZ) / (satFullZ - satEnterZ)))
        let dampFraction = satMaxDampFraction * s
        // The easing this WOULD apply: shrink the (negative) HRV z toward 0. (1 - dampFraction) stays
        // in [1 - satMaxDampFraction, 1], so the penalty would only ever be REDUCED — never removed,
        // never sign-flipped into a bonus. Computed for reporting only; recovery() ignores it.
        let easedHrvZ = hrvZ * (1.0 - dampFraction)
        return ParasympatheticSaturation(easedHrvZ: easedHrvZ,
                                         active: dampFraction > 0,
                                         dampFraction: dampFraction)
    }

    /// Rolling-mean HR window (seconds) for the resting-HR estimate.
    public static let restingHRWindowS: Int = 5 * 60

    /// Minimum HR samples a 5-min bin must hold before its mean is eligible to WIN the resting
    /// floor (#686). A thinly-populated bin — at the limit a single lone beat — lets one artifact
    /// (a dropout, a decode glitch) become the bin "mean" and win the night's minimum, dragging
    /// resting HR implausibly low. Requiring a handful of samples means the floor is a genuine
    /// sustained dip, not a one-sample fluke. Worn nights stream ~1 Hz HR so a real 5-min bin holds
    /// hundreds of samples and clears this trivially; only sparse/edge bins (a partial trailing bin,
    /// a gap-straddling bin) fall below it. Does NOT change the floor DEFINITION — still the min of
    /// 5-min bin means — it only stops an under-sampled artifact bin from being that min.
    public static let restingHRMinBinSamples: Int = 5

    /// Physiological resting-HR floor (bpm) below which a bin mean is rejected as a dropout artifact
    /// (#686), never the resting floor. An adult's true sleeping resting HR essentially never sits
    /// below this; a 5-min mean that does is a run of dropout/decode-zero beats, not a real cardiac
    /// dip. 25 bpm clears even deeply-bradycardic trained athletes (resting HRs in the low 30s) with
    /// margin while rejecting the implausible artifact range. A bin below this is excluded from floor
    /// candidacy; if it were allowed to win, resting HR would read a fabricated sub-physiological value.
    public static let restingHRMinPlausibleBpm: Double = 25.0

    // MARK: - Resting HR

    /// Lowest sustained HR during the in-bed window (bpm, rounded), or nil.
    ///
    /// "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
    /// samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
    /// the night's true floor. Returns nil when there are no HR samples in window.
    ///
    /// The window is CLOSED at both ends, so the binning is too: bins are `[t, t + windowS)`
    /// except the final one, which is `[t, end]`. Half-open bins alone would admit a
    /// sample sitting exactly on an aligned `end` through the prefilter and then place it in no
    /// bin — counted as data, silently ignored. A zero-length window (`start == end`) is that
    /// single closed bin.
    ///
    /// Artifact hardening (#686): a bin may only WIN the floor when it is BOTH well-populated
    /// (≥ `restingHRMinBinSamples`, so one lone artifact beat can't be a bin "mean") AND
    /// physiologically plausible (mean ≥ `restingHRMinPlausibleBpm`, rejecting dropout-driven
    /// sub-physiological dips). The floor DEFINITION is unchanged — still the minimum of the
    /// 5-min bin means — only artifact bins are barred from being that minimum. If no bin
    /// qualifies (a wholly sparse/degenerate window), fall back to the lowest of ALL bin means,
    /// else the all-sample mean, preserving the never-nil-on-data behaviour.
    public static func restingHR(_ hr: [HRSample], start: Int, end: Int) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }

        var means: [Double] = []          // every bin mean (legacy floor, the fallback)
        var qualified: [Double] = []       // bins eligible to WIN the floor (#686)
        var t = start
        repeat {
            // The last bin (its half-open end reaches or passes `end`) closes on `end` instead,
            // catching an endpoint sample the prefilter already admitted. `seg` holds nothing
            // past `end`, so "everything from t onwards" IS [t, end]. `repeat` runs once for a
            // zero-length window, where that single closed bin is the whole window.
            let isFinal = t + restingHRWindowS >= end
            let win = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + restingHRWindowS) }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                means.append(mean)
                // A bin wins the floor only if it is well-populated AND physiologically plausible —
                // a thin (single-artifact) or sub-physiological (dropout) bin can't be the minimum.
                if win.count >= restingHRMinBinSamples && mean >= restingHRMinPlausibleBpm {
                    qualified.append(mean)
                }
            }
            t += restingHRWindowS
        } while t < end
        let floor: Double
        if let m = qualified.min() {
            floor = m
        } else if let m = means.min() {
            // No bin cleared the artifact bar (sparse window): fall back to the legacy floor.
            floor = m
        } else {
            floor = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        }
        return Int(floor.rounded())
    }

    // MARK: - Recovery Index (overnight HR-decline slope)

    /// Minimum 5-minute bins (`restingHR`'s SAME binning) required before a slope is trusted —
    /// below this, too little of the night has elapsed to fit a trend, and a 1-2-point
    /// regression is noise, not a night-long pattern. 6 bins = 30 minutes of binned coverage,
    /// a deliberately low floor so a short/partial night still gets a number rather than a
    /// routine nil.
    public static let recoveryIndexMinBins: Int = 6

    /// Overnight resting-HR DECLINE slope (bpm/hour) across the in-bed window — the "Recovery
    /// Index" component of Oura's Readiness that Charge lacked (it previously only read the
    /// overnight FLOOR via `restingHR` above, never the trend that reaches it).
    ///
    /// Computed as the least-squares slope of the SAME non-overlapping 5-minute HR bin means
    /// `restingHR` uses (`restingHRWindowS`) against each bin's midpoint time (hours from
    /// `start`, and for the final closed bin still its half-open midpoint `t + windowS / 2`, so a
    /// partial or endpoint-only last bin keeps the same time axis as every other bin).
    /// NEGATIVE = declining (HR falling through the night — the physiologically
    /// expected, good pattern); POSITIVE = rising (restlessness, illness, alcohol, a late
    /// stimulant). Returns nil when fewer than `recoveryIndexMinBins` bins have data (too
    /// little of the window to fit a trend) or there are no samples at all — it never
    /// fabricates a slope from a sliver of the night.
    public static func recoveryIndexSlope(_ hr: [HRSample], start: Int, end: Int) -> Double? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }

        // Same non-overlapping 5-minute binning as restingHR: both read the identical
        // underlying series, one as a floor, one as a trend across it.
        var points: [(tHours: Double, meanBpm: Double)] = []
        var t = start
        repeat {
            // Final bin closes on `end` — same closed-window rule as restingHR, so an
            // endpoint sample counts toward the bin gate instead of vanishing after admission.
            let isFinal = t + restingHRWindowS >= end
            let win = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + restingHRWindowS) }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                let midpointS = Double(t - start) + Double(restingHRWindowS) / 2.0
                points.append((tHours: midpointS / 3600.0, meanBpm: mean))
            }
            t += restingHRWindowS
        } while t < end
        guard points.count >= recoveryIndexMinBins else { return nil }

        // Least-squares slope: Σ((t-t̄)(y-ȳ)) / Σ((t-t̄)²), bpm per hour.
        let n = Double(points.count)
        let tBar = points.reduce(0.0) { $0 + $1.tHours } / n
        let yBar = points.reduce(0.0) { $0 + $1.meanBpm } / n
        var num = 0.0, den = 0.0
        for p in points {
            let dt = p.tHours - tBar
            num += dt * (p.meanBpm - yBar)
            den += dt * dt
        }
        // Degenerate (all bins at the same instant): no time spread to fit against.
        guard den > 1e-9 else { return 0.0 }
        return num / den
    }

    // MARK: - Recovery band

    /// WHOOP-style color band for a recovery score [0, 100].
    public static func band(_ score: Double) -> String {
        if score < bandRedMax { return "red" }
        if score < bandYellowMax { return "yellow" }
        return "green"
    }

    // MARK: - Cold-start calibration progress

    /// The recovery baseline's real seed count while it still cold-starts — the honest
    /// "Calibrating — N of <seed> nights" progress the dashboard shows in place of a bare empty state;
    /// nil once recovery exists or the baseline has crossed the seed gate. N is the HRV baseline's
    /// `nValid` from folding the SAME day-keyed, epoch-aware history the recovery engine folds
    /// (`Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)`), NOT a looser per-night bounds count.
    ///
    /// The old count advanced on every in-range night, including nights the engine's fold DROPS after a
    /// manual "Recalibrate HRV baseline" (each night dated before the epoch is discarded, not
    /// skip-and-held). A genuinely-calibrating user who had ≥ seed old in-range nights therefore read
    /// `count ≥ seed → nil` here, and the Today score side fell through to "Needs the strap" while the
    /// post-recalibration baseline was still seeding (Bug B, #393 follow-up). `nValid` is the exact count
    /// `Baselines.computeStatus` gates CALIBRATING on, so N now tracks the baseline the Charge ring rides
    /// and can never over-state it. Never claims "calibrating" at/above the seed gate (a nil recovery
    /// there is some other gap). `baselineEpoch` nil reads the persisted HRV epoch from UserDefaults,
    /// exactly like the engine's fold. Mirrors Android TodayScreen.recoveryCalibrationNights
    /// (RecoveryCalibrationTest is the oracle).
    public static func calibrationNights(nightlyHrv: [Double?],
                                         dayKeys: [String],
                                         hasRecovery: Bool,
                                         seed: Int = Baselines.minNightsSeed,
                                         cfg: MetricCfg = Baselines.hrvCfg,
                                         baselineEpoch: Double? = nil) -> Int? {
        guard !hasRecovery else { return nil }
        let n = Baselines.foldHistory(nightlyHrv, dayKeys: dayKeys, cfg: cfg,
                                      baselineEpoch: baselineEpoch).nValid
        // Include 0: a brand-new user (no banked nights yet) should read "Calibrating — 0 of N" on the
        // Charge ring, not a bare "No data" that looks broken (#335). Past days are gated to nil by the
        // caller; >= seed (recovery should exist) still returns nil.
        return (0..<seed).contains(n) ? n : nil
    }

    // MARK: - Recovery score

    /// A baseline driver: mean + spread (internal abs-dev units, as in BaselineState).
    public struct DriverBaseline: Equatable, Sendable {
        public let mean: Double
        public let spread: Double
        public init(mean: Double, spread: Double) {
            self.mean = mean; self.spread = spread
        }
        public init(_ state: BaselineState) {
            self.mean = state.baseline; self.spread = state.spread
        }
    }

    /// Robust z-score using EWMA spread: (value − mean) / (1.253 × spread).
    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /// Z-score + logistic recovery score in [0, 100]. APPROXIMATE.
    ///
    /// Returns nil when the HRV baseline (dominant driver) is not yet usable, or
    /// no valid driver is available at all.
    ///
    /// - Parameters:
    ///   - hrv: tonight's HRV (RMSSD, ms).
    ///   - rhr: tonight's resting HR (bpm).
    ///   - resp: tonight's respiration (raw or calibrated — z is scale-invariant);
    ///           nil drops the term.
    ///   - hrvBaseline: HRV baseline (required for a score).
    ///   - rhrBaseline: resting-HR baseline; nil drops the RHR term.
    ///   - respBaseline: respiration baseline; nil drops the resp term.
    ///   - sleepPerf: Rest quality (Rest composite ÷100, 0..1; was raw efficiency);
    ///     nil drops the term.
    ///   - skinTempDev: skin-temperature deviation from the personal baseline (±°C,
    ///     `DailyMetric.skinTempDevC`). Entered as a SYMMETRIC penalty −|dev|/scale,
    ///     weight wSkinTemp. nil drops the term and the weights renormalize so the
    ///     no-skin-temp score is identical to before.
    ///   - hrvBaselineUsable: whether the HRV baseline has enough nights
    ///     (BaselineState.usable). When false, returns nil (cold-start).
    ///   - recoveryIndexSlope: overnight resting-HR DECLINE slope (bpm/hour, from
    ///     `recoveryIndexSlope(_:start:end:)`). Negative (declining) supports recovery;
    ///     positive (rising) limits it, weight wRecoveryIndex. nil (the default) drops the
    ///     term and the weights renormalize, so the no-slope score is IDENTICAL to before
    ///     this parameter existed.
    ///   - effortBaseline: personal EWMA baseline of daily Effort/strain (`Baselines.strainCfg`).
    ///     Needs `priorDayEffort` too — supplying only one drops the term.
    ///   - priorDayEffort: yesterday's Effort/strain (0-100, `StrainScorer.strain`). Lower vs
    ///     `effortBaseline` supports recovery, same "lower is better" direction as RHR/resp,
    ///     weight wActivityBalance. nil (the default, like effortBaseline) drops the term and
    ///     the weights renormalize, so the no-effort score is IDENTICAL to before either
    ///     parameter existed.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: DriverBaseline?,
                                rhrBaseline: DriverBaseline?,
                                respBaseline: DriverBaseline?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                hrvBaselineUsable: Bool = true,
                                recoveryIndexSlope: Double? = nil,
                                effortBaseline: DriverBaseline? = nil,
                                priorDayEffort: Double? = nil) -> Double? {
        // Cold-start gate: HRV is the dominant driver; if its baseline isn't
        // usable, refuse to score (more honest than a fabricated value).
        if !hrvBaselineUsable { return nil }

        var terms: [(z: Double, w: Double)] = []

        // HRV term: higher is better.
        //
        // INSTRUMENT-FIRST CALL SITE for the parasympathetic-saturation guard. The guard is NOT applied
        // here: this term is the RAW z, so Charge is byte-identical to pre-guard behaviour. The
        // signature is still detected and reported out-of-band (Charge trace + ChargeDrivers verdict)
        // so real firings can be counted first. See the MARK header for why, and swap in
        // `parasympatheticSaturation(hrvZ:rhrZ:).easedHrvZ` here to enable it.
        if let b = hrvBaseline {
            terms.append((zScore(hrv, mean: b.mean, spread: b.spread), wHRV))
        }
        // RHR term: lower is better → (μ − x) / σ.
        if let b = rhrBaseline {
            terms.append((zScore(b.mean, mean: rhr, spread: b.spread), wRHR))
        }
        // Resp term: lower is better, optional.
        if let r = resp, let b = respBaseline {
            terms.append((zScore(b.mean, mean: r, spread: b.spread), wResp))
        }
        // Sleep-performance / Rest-quality term: no baseline needed; centered at SLEEP_PERF_CENTER.
        if let sp = sleepPerf {
            terms.append(((sp - sleepPerfCenter) / sleepPerfScale, wSleep))
        }
        // Skin-temp term: SYMMETRIC penalty on |deviation| (illness/overreach). Any
        // drift from the personal baseline lowers Charge; added only when supplied.
        if let dev = skinTempDev {
            terms.append((-abs(dev) / skinTempScaleC, wSkinTemp))
        }
        // Recovery-Index term: overnight HR-DECLINE slope (bpm/hour). No baseline needed (a
        // fixed, documented scale, same style as sleepPerf/skin-temp). Negative (declining)
        // supports recovery; positive (rising) limits it. Added only when supplied.
        if let slope = recoveryIndexSlope {
            terms.append((-slope / recoveryIndexScaleBpmPerHr, wRecoveryIndex))
        }
        // Activity-Balance / previous-day-Effort term: lower vs personal baseline is better,
        // same "lower is better" direction as RHR/resp → (μ − x) / σ. Needs BOTH the value
        // and a baseline, matching resp's pattern; added only when both are supplied.
        if let e = priorDayEffort, let b = effortBaseline {
            terms.append((zScore(b.mean, mean: e, spread: b.spread), wActivityBalance))
        }

        guard !terms.isEmpty else { return nil }
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        guard totalWeight > 0 else { return nil }

        let z = terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
        return logisticScore(compositeZ: z)
    }

    /// The Charge logistic: weighted-composite z -> 0-100, clamped. Factored out of `recovery(...)` so
    /// the trace's saturation counterfactual ("what Charge WOULD read if the easing were applied") runs
    /// through the EXACT same curve the real score does and cannot drift from it. Same expression as
    /// before it was extracted, so every existing score is unchanged.
    static func logisticScore(compositeZ z: Double) -> Double {
        let score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /// Convenience overload taking BaselineState directly. Enforces the cold-start
    /// gate using `hrvBaseline.usable`.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: BaselineState,
                                rhrBaseline: BaselineState?,
                                respBaseline: BaselineState?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                recoveryIndexSlope: Double? = nil,
                                effortBaseline: BaselineState? = nil,
                                priorDayEffort: Double? = nil) -> Double? {
        recovery(hrv: hrv,
                 rhr: rhr,
                 resp: resp,
                 hrvBaseline: DriverBaseline(hrvBaseline),
                 rhrBaseline: rhrBaseline.map(DriverBaseline.init),
                 respBaseline: respBaseline.map(DriverBaseline.init),
                 sleepPerf: sleepPerf,
                 skinTempDev: skinTempDev,
                 hrvBaselineUsable: hrvBaseline.usable,
                 recoveryIndexSlope: recoveryIndexSlope,
                 effortBaseline: effortBaseline.map(DriverBaseline.init),
                 priorDayEffort: priorDayEffort)
    }
}
