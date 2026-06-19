import Foundation

// IllnessSignalEngine.swift — multi-signal "Heads-Up" early-warning with explicit false-positive
// suppression. Pure, deterministic, DB-free.
//
// INDEPENDENT implementation of the published multi-parameter pre-symptomatic signature documented
// across the wearable literature (e.g. the Stanford/Snyder resting-HR-elevation work and successor
// studies): resting HR ↑, skin temperature ↑, HRV (RMSSD) ↓ and respiration ↑ tend to move TOGETHER,
// days before symptoms. NOOP re-derives the PATTERN, transparently, against the user's OWN rolling
// baseline — never a population cutoff.
//
// This replaces the blunt 2-of-4 threshold rule in AppModel.evaluateIllness with:
//   • a calibrated 0–100 composite anomaly score (so the surface can read "mild" vs "strong"),
//   • a minimum-corroboration gate (≥ 2 signals) so a single noisy night never fires,
//   • EXPLICIT confounder suppression cross-checked against the same-day journal tags
//     (alcohol / stress / sauna / late-or-intense workout / travel), which is the differentiating
//     part — alcohol elevates RHR + skin temp and crushes HRV exactly like early illness, so a night
//     out must NOT cry wolf,
//   • a visible "why" (which signals fired) AND "what was ruled out" (which confounders were present),
//   • honest gating: a trusted baseline is required; below that the engine is silent.
//
// WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. The engine never names a condition, illness, infection
// or fever; the copy is always "a heads-up to rest" / "consider taking it easy" (see the shipped
// IllnessNotifier copy: "On-device estimate (approximate) — not a diagnosis").
public enum IllnessSignalEngine {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Composite score (0–100) at/above which the heads-up is RAISED. Below this it is "mild" — surfaced
    /// only in a detail view, never a notification (keeps the banner from re-introducing noise).
    public static let raiseThreshold: Double = 50.0
    /// Score floor below which there is nothing worth saying at all (engine returns `.quiet`).
    public static let mildThreshold: Double = 25.0
    /// Minimum number of signals pointing the illness way before anything can raise — guards against a
    /// single noisy night driving the score on its own.
    public static let minCorroboratingSignals: Int = 2

    /// A signal's |z| must reach this to count as "firing" toward the score. Roughly the user's own ~95th
    /// percentile night (matches VitalBands.sigmaK), so normal night-to-night wobble doesn't register.
    public static let signalZThreshold: Double = 2.0
    /// Per-signal sub-score is `min(perSignalCap, kZToScore · max(0, zIllnessward − signalZThreshold))`,
    /// then the composite is their sum clamped to 100. Each strong signal caps so no single one saturates.
    public static let kZToScore: Double = 22.0
    public static let perSignalCap: Double = 40.0

    /// When a confounder is present, the composite is multiplied by this and the level is downgraded —
    /// the signals are real, but a plainer explanation exists, so we soften rather than scream.
    public static let confounderDampen: Double = 0.45

    // MARK: - Inputs

    /// One signal's recent-vs-baseline reading, already z-scored against the personal baseline by the
    /// caller (reusing `Baselines.deviation`). `zIllnessward` is the deviation ORIENTED so that a
    /// positive value always means "more illness-like": RHR ↑, skin-temp ↑, respiration ↑ pass their raw
    /// z; HRV ↓ passes the NEGATED z (a drop is illness-ward). `present == false` means the signal had no
    /// usable data this window and is skipped (not counted as corroboration).
    public struct SignalReading: Equatable, Sendable {
        public let zIllnessward: Double
        public let present: Bool
        public init(zIllnessward: Double, present: Bool = true) {
            self.zIllnessward = zIllnessward
            self.present = present
        }
    }

    /// All four signal readings for the recent window. Any may be absent (sparse 5/MG nights).
    public struct Inputs: Equatable, Sendable {
        public var restingHR: SignalReading?   // z of recent RHR vs baseline (↑ illness-ward)
        public var skinTemp: SignalReading?    // z of recent skin-temp deviation vs baseline (↑ illness-ward)
        public var hrv: SignalReading?         // NEGATED z of recent HRV vs baseline (drop = illness-ward)
        public var respiration: SignalReading? // z of recent respiration vs baseline (↑ illness-ward)
        public init(restingHR: SignalReading? = nil, skinTemp: SignalReading? = nil,
                    hrv: SignalReading? = nil, respiration: SignalReading? = nil) {
            self.restingHR = restingHR; self.skinTemp = skinTemp
            self.hrv = hrv; self.respiration = respiration
        }
    }

    /// Same-day behaviour context that can explain an anomaly away. All default-false / nil so a caller
    /// with no journal still gets the raw signal read. `travelPhaseJump` is the cross-feature hook — the
    /// CircadianEngine can flag a detected body-clock jump (jet lag), which itself shifts temp + RHR.
    public struct Context: Equatable, Sendable {
        public var alcohol: Bool
        public var stress: Bool
        public var sauna: Bool
        public var hardOrLateWorkout: Bool
        public var travelPhaseJump: Bool
        public var alreadyUnwell: Bool
        /// True iff the caller's baseline for the anomaly is `trusted` (≥ 14 valid nights, not stale).
        /// Below this the engine stays silent — we don't warn off a cold-start baseline.
        public var baselineTrusted: Bool
        public init(alcohol: Bool = false, stress: Bool = false, sauna: Bool = false,
                    hardOrLateWorkout: Bool = false, travelPhaseJump: Bool = false,
                    alreadyUnwell: Bool = false, baselineTrusted: Bool = true) {
            self.alcohol = alcohol; self.stress = stress; self.sauna = sauna
            self.hardOrLateWorkout = hardOrLateWorkout; self.travelPhaseJump = travelPhaseJump
            self.alreadyUnwell = alreadyUnwell; self.baselineTrusted = baselineTrusted
        }
    }

    // MARK: - Output

    /// How loud the heads-up is. `.quiet` shows nothing; `.alreadyUnwell` is the "rest up" path when the
    /// user has already logged feeling ill; `.suppressed` is "signals up, but a confounder explains it".
    public enum Level: String, Equatable, Sendable, Codable {
        case quiet           // nothing worth saying (below mild, or not enough corroboration, or untrusted baseline)
        case mild            // some signals up — detail view only, no notification
        case raised          // clear multi-signal anomaly, no confounder — surface + notify
        case suppressed      // anomaly present but a behaviour tag / travel explains it — quietly informative
        case alreadyUnwell   // user logged feeling unwell — "rest up", not a scare
    }

    public struct Result: Equatable, Sendable {
        /// 0–100 composite anomaly score (post-dampening for the suppressed level so the surface matches).
        public let score: Double
        public let level: Level
        /// Human-readable reasons a signal fired, e.g. "RHR +6", "HRV −22%", "skin temp +0.7 °C". The
        /// caller supplies the rendered phrases; the engine decides which to include (only firing ones).
        public let firedSignals: [String]
        /// Named confounders that were present and damped/explained the score, e.g. "alcohol", "travel".
        public let suppressedBy: [String]
        /// Count of signals over the firing threshold (corroboration), regardless of level.
        public let signalCount: Int
        /// One-line non-clinical copy, terminating in the shipped not-a-diagnosis framing where it raises.
        public let copy: String

        public init(score: Double, level: Level, firedSignals: [String], suppressedBy: [String],
                    signalCount: Int, copy: String) {
            self.score = score; self.level = level; self.firedSignals = firedSignals
            self.suppressedBy = suppressedBy; self.signalCount = signalCount; self.copy = copy
        }
    }

    /// Standing not-a-diagnosis tail reused verbatim from the shipped IllnessNotifier copy.
    public static let disclaimerTail = "On-device estimate — not a diagnosis."

    // MARK: - Evaluate

    /// Score the recent window and decide the heads-up level + copy.
    ///
    /// `firedLabels` maps a signal key to the caller-rendered phrase to show when that signal fires
    /// (e.g. ["restingHR": "RHR +6", "hrv": "HRV −22%"]). Only keys for signals that clear
    /// `signalZThreshold` are surfaced. Keeping the rendering in the caller keeps the engine free of
    /// number-formatting locale concerns and identical across platforms.
    public static func evaluate(_ inputs: Inputs, context: Context,
                                firedLabels: [String: String] = [:]) -> Result {
        // Order is fixed so firedSignals is deterministic across platforms.
        let ordered: [(key: String, reading: SignalReading?)] = [
            ("restingHR", inputs.restingHR),
            ("skinTemp", inputs.skinTemp),
            ("hrv", inputs.hrv),
            ("respiration", inputs.respiration),
        ]

        var rawScore = 0.0
        var firedKeys: [String] = []
        for (key, reading) in ordered {
            guard let r = reading, r.present else { continue }
            let over = r.zIllnessward - signalZThreshold
            guard over > 0 else { continue }
            firedKeys.append(key)
            rawScore += min(perSignalCap, kZToScore * over)
        }
        let score = min(100.0, rawScore)
        let signalCount = firedKeys.count
        let firedSignals = firedKeys.compactMap { firedLabels[$0] }

        // Gate 0: untrusted baseline → silent (don't warn off a cold-start). Score still reported for a
        // detail view, but never raised.
        if !context.baselineTrusted {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Still learning your baseline — keeping an eye out.")
        }

        // Already-unwell path: the user told us. Switch from "early warning" to a gentle "rest up" and
        // never scare — regardless of score (their log is the ground truth).
        if context.alreadyUnwell {
            let agreeing = score >= mildThreshold && signalCount >= 1
            let copy = agreeing
                ? "Rest up — you logged feeling unwell, and your numbers agree. \(disclaimerTail)"
                : "Rest up — you logged feeling unwell. Take it easy today. \(disclaimerTail)"
            return Result(score: score, level: .alreadyUnwell, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy)
        }

        // Corroboration + magnitude gate: need ≥ 2 firing signals and a mild-or-better composite, else quiet.
        guard signalCount >= minCorroboratingSignals, score >= mildThreshold else {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Nothing notable — your signals look like your normal range.")
        }

        // Confounder suppression — the differentiating part. Collect every present behaviour/travel tag
        // that offers a plainer explanation; if any are present, dampen the score and downgrade.
        var suppressedBy: [String] = []
        if context.alcohol { suppressedBy.append("alcohol") }
        if context.stress { suppressedBy.append("stress") }
        if context.sauna { suppressedBy.append("sauna") }
        if context.hardOrLateWorkout { suppressedBy.append("a hard or late workout") }
        if context.travelPhaseJump { suppressedBy.append("travel") }

        let signalsPhrase = firedSignals.isEmpty ? "Some signals are up" : firedSignals.joined(separator: ", ")

        if !suppressedBy.isEmpty {
            let dampened = score * confounderDampen
            let reason = joinReasons(suppressedBy)
            let copy = "Some signals are up (\(signalsPhrase)), but you logged \(reason) — likely that, "
                + "not illness. \(disclaimerTail)"
            return Result(score: dampened, level: .suppressed, firedSignals: firedSignals,
                          suppressedBy: suppressedBy, signalCount: signalCount, copy: copy)
        }

        // No confounder. Mild stays in the detail view; a strong composite raises.
        if score < raiseThreshold {
            let copy = "A few signals are mildly up (\(signalsPhrase)). Nothing alarming — worth a calmer "
                + "day. \(disclaimerTail)"
            return Result(score: score, level: .mild, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy)
        }

        let ruledOut = "no alcohol or travel logged"
        let copy = "Heads-up — your body looks strained. \(signalsPhrase). With \(ruledOut), consider "
            + "taking it easy. \(disclaimerTail)"
        return Result(score: score, level: .raised, firedSignals: firedSignals,
                      suppressedBy: [], signalCount: signalCount, copy: copy)
    }

    // MARK: - Helpers

    /// Join named confounders into a natural list ("alcohol", "alcohol and stress", "a, b and c").
    static func joinReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "something"
        case 1: return reasons[0]
        case 2: return "\(reasons[0]) and \(reasons[1])"
        default:
            let head = reasons.dropLast().joined(separator: ", ")
            return "\(head) and \(reasons.last!)"
        }
    }
}
