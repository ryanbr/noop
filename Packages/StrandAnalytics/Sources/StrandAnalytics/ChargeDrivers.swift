import Foundation

// ChargeDrivers.swift - the ordered "why is my Charge what it is" driver list.
//
// SHARED CONTRACT (engine <-> iOS UI <-> Android): the Charge (recovery) result gains an
// ordered list of drivers, one row per real term that fed the score. Each row carries the
// term's signed contribution to the score in POINTS, the measured value, the personal
// baseline it was compared against, and a short plain-English verdict. The UI renders one
// row per driver under the Charge ring; it never recomputes the score or invents a row.
//
// HONESTY RULES (non-negotiable, mirror RecoveryScorer.recovery exactly):
//   - A driver exists ONLY when its term actually fed the score. A missing / uncalibrated
//     input (nil HRV-baseline-not-usable, nil resp, nil sleepPerf, nil skin-temp deviation)
//     produces NO row, never a fabricated zero.
//   - deltaPoints is the term's REAL marginal contribution to the 0-100 score: the score
//     WITH every present term minus the score recomputed with THIS term omitted (and the
//     remaining weights renormalized, which is exactly what recovery(...) already does when
//     an input is nil). So the points come from the same weighting the headline uses, not an
//     invented number. A positive deltaPoints means the term pushed Charge UP vs leaving it
//     out; negative means it pulled Charge DOWN.
//   - The score is logistic, so per-term deltas do NOT sum to the headline; they are each an
//     honest "what this term was worth" marginal, ordered by magnitude (biggest mover first).
//
// Pure and side-effect-free: no clock, no I/O. The Kotlin twin is RecoveryScorer.chargeDrivers.
// No em-dashes.

/// One row of the Charge driver breakdown (SHARED CONTRACT shape).
public struct ChargeDriver: Equatable, Sendable {
    /// Human label for the term, e.g. "Resting heart rate".
    public let label: String
    /// Signed contribution of this term to the 0-100 Charge score, in points. Positive =
    /// supported recovery (pushed Charge up vs omitting the term); negative = suppressed it.
    public let deltaPoints: Int
    /// The measured value, formatted with units, e.g. "58 bpm".
    public let valueText: String
    /// The personal baseline this value was compared against, e.g. "61 bpm baseline".
    /// Empty for the sleep / skin-temp terms whose reference is a fixed centre / zero, not a
    /// learned per-night baseline; the UI omits the baseline line when this is empty.
    public let baselineText: String
    /// Short plain-English read of the direction, e.g. "below baseline, supporting recovery".
    public let verdict: String

    public init(label: String, deltaPoints: Int, valueText: String,
                baselineText: String, verdict: String) {
        self.label = label
        self.deltaPoints = deltaPoints
        self.valueText = valueText
        self.baselineText = baselineText
        self.verdict = verdict
    }
}

/// A5: a skin-temperature reading presented as a RELATIVE deviation from the personal
/// baseline (a trend), never a fake clinical absolute. Carries the signed deviation and the
/// relative tier so the UI can label it "warmer / typical / cooler than your baseline".
public struct SkinTempRelative: Equatable, Sendable {

    /// Relative tier: where tonight's skin temp sits versus the personal baseline. NOT a
    /// clinical absolute - purely a deviation band.
    public enum Tier: String, Equatable, Sendable, Codable {
        case cooler   // meaningfully below the personal baseline
        case typical  // within the normal personal range
        case warmer   // meaningfully above the personal baseline
    }

    /// Signed deviation from the personal baseline, in °C (value - baseline). + is warmer.
    public let deviationC: Double
    /// The relative tier for that deviation.
    public let tier: Tier

    public init(deviationC: Double, tier: Tier) {
        self.deviationC = deviationC
        self.tier = tier
    }
}

extension RecoveryScorer {

    // MARK: - A5: skin-temp relative tier

    /// Half the width (°C) of the "typical" band around the personal baseline. A deviation
    /// whose magnitude is at or below this reads `.typical`; beyond it reads `.warmer` /
    /// `.cooler`. 0.3 °C matches `VitalBands.skinTempDeviationCfg.floorSpread` (the floored
    /// per-night spread of the deviation series), so the band tracks real measurement noise
    /// rather than an arbitrary clinical cutoff.
    public static let skinTempTypicalBandC: Double = 0.3

    /// Build the RELATIVE skin-temp marker from a signed deviation (°C from the personal
    /// baseline). Returns nil when no deviation is available (no baseline yet / not worn), so
    /// the UI shows nothing rather than a fake absolute. The tier is a deviation band only.
    public static func skinTempRelative(deviationC: Double?) -> SkinTempRelative? {
        guard let dev = deviationC else { return nil }
        let tier: SkinTempRelative.Tier
        if dev > skinTempTypicalBandC {
            tier = .warmer
        } else if dev < -skinTempTypicalBandC {
            tier = .cooler
        } else {
            tier = .typical
        }
        return SkinTempRelative(deviationC: dev, tier: tier)
    }

    // MARK: - A2/A1: Charge driver list

    /// Build the ordered Charge driver list from the SAME inputs `recovery(...)` reads.
    ///
    /// One row per term that actually fed the score (HRV, resting HR, rest quality,
    /// respiration, skin-temp deviation). A term whose input is missing / uncalibrated is
    /// OMITTED (no row), exactly as `recovery(...)` drops it. Each row's `deltaPoints` is the
    /// term's marginal contribution to the 0-100 score: `recovery(all terms)` minus
    /// `recovery(this term omitted)`, rounded - real points from the real weighting, never
    /// invented. Rows are ordered by |deltaPoints| descending (biggest mover first); ties keep
    /// a stable term order (hrv, rhr, sleepPerf, resp, skinTempDev).
    ///
    /// Returns an EMPTY list when there is no score at all (cold-start: HRV baseline not
    /// usable), since there are no real contributions to attribute. Parameters mirror
    /// `recovery(...)`; `*ValueText` closures format each measured value for display so the
    /// engine stays unit-agnostic (the caller supplies "58 bpm" etc.).
    ///
    /// The Kotlin twin is `RecoveryScorer.chargeDrivers`.
    public static func chargeDrivers(hrv: Double,
                                     rhr: Double,
                                     resp: Double?,
                                     hrvBaseline: BaselineState,
                                     rhrBaseline: BaselineState?,
                                     respBaseline: BaselineState?,
                                     sleepPerf: Double?,
                                     skinTempDev: Double? = nil) -> [ChargeDriver] {

        // No score => no real contributions to attribute (cold-start). recovery(...) enforces
        // the usable gate; mirror it so a nil headline never yields fabricated driver rows.
        guard let full = recovery(hrv: hrv, rhr: rhr, resp: resp,
                                  hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                  respBaseline: respBaseline, sleepPerf: sleepPerf,
                                  skinTempDev: skinTempDev) else {
            return []
        }

        // Marginal-vs-neutral attribution: a term's deltaPoints is the full score minus the score
        // recomputed with THAT term held at its personal baseline (its z forced to 0) while every
        // term, including this one, keeps its weight. So a term sitting exactly at baseline is
        // worth 0 points; a term above/below baseline is worth the points it added/subtracted vs
        // being neutral. This routes through recovery(...) itself (same terms, same weighting, same
        // logistic), so the points can never drift from the headline. A term reaches z = 0 at:
        // HRV / resting HR / respiration = the baseline mean (recovery uses BaselineState.baseline
        // as the mean), Rest quality = sleepPerfCenter, skin-temp deviation = 0. Renormalised
        // leave-one-out would be WRONG here: when the surviving terms average to the same z as the
        // full set, dropping one and renormalising returns the same score, collapsing the delta to
        // 0 even for a clearly good or bad term.
        func points(_ neutralised: Double?) -> Int {
            // Shared Swift/Kotlin rule: nearest integer, with exact half-ties away from zero.
            Int((full - (neutralised ?? full)).rounded(.toNearestOrAwayFromZero))
        }

        var drivers: [ChargeDriver] = []

        // Did the parasympathetic-saturation signature fire on THIS night (low HRV corroborated by a
        // low, decoupled resting HR)? Detection ONLY: the guard's easing is not applied, so deltaPoints
        // below is the full, unguarded HRV penalty. The verdict merely NAMES the detected pattern so the
        // UI can surface it while real firings accumulate. See the MARK header in RecoveryScorer.swift.
        let hrvZFull = zScore(hrv, mean: hrvBaseline.baseline, spread: hrvBaseline.spread)
        let rhrZFull: Double? = rhrBaseline.map { zScore($0.baseline, mean: rhr, spread: $0.spread) }
        let hrvSaturationDetected = parasympatheticSaturation(hrvZ: hrvZFull, rhrZ: rhrZFull).active

        // ── HRV (dominant driver; always present once the score exists) ──────────
        // Higher HRV vs baseline supports recovery. Neutral = HRV at the baseline mean.
        drivers.append(ChargeDriver(
            label: "Heart rate variability",
            deltaPoints: points(recovery(hrv: hrvBaseline.baseline, rhr: rhr, resp: resp,
                                         hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                         respBaseline: respBaseline, sleepPerf: sleepPerf,
                                         skinTempDev: skinTempDev)),
            valueText: "\(Int(hrv.rounded())) ms",
            baselineText: "\(Int(hrvBaseline.baseline.rounded())) ms baseline",
            verdict: hrvVerdict(value: hrv, baseline: hrvBaseline.baseline,
                                saturationDetected: hrvSaturationDetected)))

        // ── Resting HR (lower vs baseline supports recovery) ─────────────────────
        // Neutral = resting HR at the baseline mean.
        if let b = rhrBaseline {
            drivers.append(ChargeDriver(
                label: "Resting heart rate",
                deltaPoints: points(recovery(hrv: hrv, rhr: b.baseline, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: skinTempDev)),
                valueText: "\(Int(rhr.rounded())) bpm",
                baselineText: "\(Int(b.baseline.rounded())) bpm baseline",
                verdict: rhrVerdict(value: rhr, baseline: b.baseline)))
        }

        // ── Rest quality (the Rest composite; neutral at sleepPerfCenter) ────────
        if let sp = sleepPerf {
            drivers.append(ChargeDriver(
                label: "Sleep quality",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerfCenter,
                                             skinTempDev: skinTempDev)),
                valueText: "\(Int((sp * 100).rounded()))%",
                baselineText: "",   // centred on a fixed "good night", not a learned baseline
                verdict: sleepVerdict(sleepPerf: sp)))
        }

        // ── Respiration (lower vs baseline supports recovery) ────────────────────
        // Neutral = respiration at the baseline mean.
        if let r = resp, let b = respBaseline {
            drivers.append(ChargeDriver(
                label: "Respiratory rate",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: b.baseline,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: skinTempDev)),
                valueText: String(format: "%.1f br/min", locale: Locale(identifier: "en_US_POSIX"), r),
                baselineText: String(format: "%.1f br/min baseline", locale: Locale(identifier: "en_US_POSIX"), b.baseline),
                verdict: respVerdict(value: r, baseline: b.baseline)))
        }

        // ── Skin-temp deviation (symmetric penalty: any drift lowers Charge) ─────
        // Neutral = zero drift, so the delta is always <= 0 (a penalty removed).
        if let dev = skinTempDev {
            drivers.append(ChargeDriver(
                label: "Skin temperature",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: 0)),
                valueText: skinTempDevText(dev),
                baselineText: "",   // a deviation already; the reference is the personal baseline (0)
                verdict: skinTempVerdict(dev)))
        }

        // Biggest mover first; stable on ties (preserves the append order above).
        return drivers.enumerated()
            .sorted { a, b in
                let am = abs(a.element.deltaPoints), bm = abs(b.element.deltaPoints)
                return am != bm ? am > bm : a.offset < b.offset
            }
            .map { $0.element }
    }

    // MARK: - Plain-English verdicts (no fabricated numbers; direction only)

    static func hrvVerdict(value: Double, baseline: Double, saturationDetected: Bool = false) -> String {
        if value > baseline { return "above baseline, supporting recovery" }
        if value < baseline {
            // Parasympathetic-saturation signature detected: resting HR is also low and decoupled from
            // HRV. NAME the pattern, but keep the plain "limiting recovery" read, because that is what
            // the score actually did: the easing is detected-only and did NOT change these points. The
            // hedge is deliberate too, since the same low-HRV + low-RHR pattern is also reported for
            // non-functional overreaching, which is the opposite of benign.
            return saturationDetected
                ? "below baseline, limiting recovery, though low resting HR suggests this may be parasympathetic saturation rather than fatigue"
                : "below baseline, limiting recovery"
        }
        return "at baseline"
    }

    static func rhrVerdict(value: Double, baseline: Double) -> String {
        if value < baseline { return "below baseline, supporting recovery" }
        if value > baseline { return "above baseline, limiting recovery" }
        return "at baseline"
    }

    static func respVerdict(value: Double, baseline: Double) -> String {
        if value < baseline { return "below baseline, supporting recovery" }
        if value > baseline { return "above baseline, limiting recovery" }
        return "at baseline"
    }

    static func sleepVerdict(sleepPerf: Double) -> String {
        if sleepPerf > sleepPerfCenter { return "a strong night, supporting recovery" }
        if sleepPerf < sleepPerfCenter { return "below a good night, limiting recovery" }
        return "a typical night"
    }

    static func skinTempVerdict(_ dev: Double) -> String {
        // Symmetric penalty: any drift from baseline lowers Charge; at baseline it is neutral.
        if abs(dev) <= skinTempTypicalBandC { return "near baseline" }
        return dev > 0
            ? "warmer than baseline, limiting recovery"
            : "cooler than baseline, limiting recovery"
    }

    static func skinTempDevText(_ dev: Double) -> String {
        // Negative zero needs its sign taken from the IEEE bit, never from a comparison: `-0.0 >= 0` is
        // TRUE, so the hand-built sign this replaced prepended "+" to a value that already formatted as
        // "-0.0", printing "+-0.0". `%+.1f` on its own gets BOTH zeroes right (checked against C printf
        // and Java's Formatter, which the Kotlin twin uses); the explicit branch is redundant there and
        // kept only to pin this edge, so the two zeroes cannot drift apart from the twin on a Foundation
        // whose formatter we have not checked.
        if dev == 0 {
            return dev.sign == .minus ? "-0.0 C vs baseline" : "+0.0 C vs baseline"
        }
        return String(format: "%+.1f C vs baseline", locale: Locale(identifier: "en_US_POSIX"), dev)
    }
}
