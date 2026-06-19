import Foundation

// DoseResponsePriors.swift — the documented, conservative POPULATION priors that the
// per-user dose-response fit shrinks toward until the user has logged enough nights.
//
// Pure data + a tiny lookup. These are deliberately CONSERVATIVE, clearly-labelled
// "typical patterns, not yours" constants — never learned from any user, never updated
// from the field. The shrinkage in DoseResponseEngine blends the user's own OLS slope
// with one of these priors weighted by how much data they have; with no data the user
// sees the prior, with enough data the prior fades out entirely (see DoseResponseEngine).
//
// Each prior is an EFFECT PER INCREMENTAL UNIT of dose on a named outcome:
//   - Alcohol  → Charge (recovery, 0–100): roughly −Δ points per extra drink.
//   - Caffeine → HRV (ms): roughly −Δ ms for each step LATER in the day a caffeine
//     dose lands (the caffeine "dose" axis is a TIMING bucket, not mg — copy says so).
//
// Magnitudes are intentionally modest and are surfaced to the user AS priors, framed as
// "typical patterns" — wellness association, never a causal/clinical claim. Values mirror
// the Kotlin DoseResponsePriors twin byte-for-byte so a future sync round-trips.
//
// (Spec: 2026-06-19-v5-insights-correlation-engine-design.md — "Personal dose-response
// with population-prior shrinkage", DoseResponsePriors.swift in the file table.)

/// Identifies a dosed behaviour whose dose-response has a documented population prior.
/// The raw string is the stable storage / lookup key (mirrors Kotlin's enum `raw`).
public enum DosedBehavior: String, Equatable, Sendable, Codable, CaseIterable {
    /// Alcoholic drinks, dose = number of drinks (0/1/2/3+ ⇒ 0,1,2,3).
    case alcohol
    /// Caffeine, dose = a TIME-OF-DAY bucket (morning/midday/after-2pm/evening ⇒ 0..3);
    /// "dose" here is timing intensity (later = stronger), NOT milligrams.
    case caffeine
}

/// A single documented population prior: the typical per-unit effect of a dosed behaviour
/// on one outcome, with a sane clamp range so a runaway extrapolation can never escape it.
public struct DoseResponsePrior: Equatable, Sendable {
    /// The dosed behaviour this prior describes.
    public let behavior: DosedBehavior
    /// The outcome label this prior is expressed in (e.g. "Charge", "HRV").
    public let outcome: String
    /// Typical signed effect per ONE extra unit of dose (e.g. −X Charge points per drink).
    /// Negative = the outcome typically sits lower with more dose.
    public let slopePerUnit: Double
    /// Lower clamp for the (shrunk) per-unit effect — keeps a noisy personal slope sane.
    public let clampLow: Double
    /// Upper clamp for the (shrunk) per-unit effect.
    public let clampHigh: Double

    public init(behavior: DosedBehavior, outcome: String, slopePerUnit: Double,
                clampLow: Double, clampHigh: Double) {
        self.behavior = behavior
        self.outcome = outcome
        self.slopePerUnit = slopePerUnit
        self.clampLow = clampLow
        self.clampHigh = clampHigh
    }
}

public enum DoseResponsePriors {

    /// The default outcome each dosed behaviour's headline prior is expressed in.
    /// Alcohol's headline effect is on Charge; caffeine's is on HRV (timing proxy).
    public static func defaultOutcome(for behavior: DosedBehavior) -> String {
        switch behavior {
        case .alcohol: return "Charge"
        case .caffeine: return "HRV"
        }
    }

    /// The documented, conservative priors. Kept small and explicit so the Kotlin twin is
    /// byte-identical. Magnitudes are "typical, not yours" and are always overridable by the
    /// user's own data once they have enough of it (see DoseResponseEngine shrinkage).
    ///
    /// - Alcohol → Charge: ≈ −5 Charge points per extra drink (clamped −15…+2).
    /// - Caffeine → HRV:   ≈ −4 ms per step later in the day (clamped −20…+4).
    static let table: [DoseResponsePrior] = [
        DoseResponsePrior(behavior: .alcohol, outcome: "Charge",
                          slopePerUnit: -5.0, clampLow: -15.0, clampHigh: 2.0),
        DoseResponsePrior(behavior: .caffeine, outcome: "HRV",
                          slopePerUnit: -4.0, clampLow: -20.0, clampHigh: 4.0),
    ]

    /// Look up the documented prior for a `(behaviour, outcome)` pair, or nil if none is
    /// documented (the engine then can't shrink — it returns a prior-less / nil result).
    public static func prior(for behavior: DosedBehavior, outcome: String) -> DoseResponsePrior? {
        table.first { $0.behavior == behavior && $0.outcome == outcome }
    }

    /// Convenience: the prior for a behaviour's default headline outcome.
    public static func prior(for behavior: DosedBehavior) -> DoseResponsePrior? {
        prior(for: behavior, outcome: defaultOutcome(for: behavior))
    }
}
