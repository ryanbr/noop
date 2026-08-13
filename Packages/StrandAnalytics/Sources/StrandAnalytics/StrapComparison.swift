import Foundation

// StrapComparison.swift — #1300 tier 2: a READ-ONLY, non-diagnostic comparison of the SAME metric from
// two straps (e.g. a WHOOP 4.0 and a 5/MG) for one user. It reuses the existing per-metric tolerances
// (`MetricArbitrationPolicy.tolerance`) to say whether the two straps AGREE, differ a little, or conflict —
// for a "compare my straps" card in the Devices window. It NEVER mixes the two into one score (scores stay
// single-owner-per-day, invariant I2); it only describes how they line up, with both values kept visible.
// Pure + deterministic, no clock, no I/O. Value-for-value Kotlin twin (`StrapComparison.kt`).
public enum StrapComparison {

    /// One metric's two-strap comparison. `a`/`b` are the two straps' values for that metric (nil = that
    /// strap has no value); `agreement` is `.single` when only one strap reported it.
    public struct Row: Equatable, Sendable {
        public let metric: MetricArbitrationPolicy.MetricKind
        public let a: Double?
        public let b: Double?
        public let agreement: AgreementState
        public init(metric: MetricArbitrationPolicy.MetricKind, a: Double?, b: Double?, agreement: AgreementState) {
            self.metric = metric
            self.a = a
            self.b = b
            self.agreement = agreement
        }
    }

    /// Compare two straps' per-metric values (each strap's stored daily mapped to MetricKind->value at the
    /// call site). Emits a row per metric EITHER strap reported, in `MetricKind` declaration order; `.other`
    /// is skipped (it's the non-comparable passthrough family). Read-only, non-diagnostic.
    public static func compare(_ a: [MetricArbitrationPolicy.MetricKind: Double],
                               _ b: [MetricArbitrationPolicy.MetricKind: Double]) -> [Row] {
        MetricArbitrationPolicy.MetricKind.allCases.compactMap { metric in
            guard metric != .other else { return nil }
            let va = a[metric], vb = b[metric]
            guard va != nil || vb != nil else { return nil }
            return Row(metric: metric, a: va, b: vb, agreement: agreement(metric: metric, a: va, b: vb))
        }
    }

    /// The agreement between two strap values for one metric, using that metric's published tolerance.
    /// `.single` when only one strap has it. SYMMETRIC: a percentage tolerance is taken against the LARGER
    /// magnitude, so neither strap is privileged as a "winner" (unlike the resolver, which has one).
    public static func agreement(metric: MetricArbitrationPolicy.MetricKind,
                                 a: Double?, b: Double?) -> AgreementState {
        guard let a, let b else { return .single }
        let tol = MetricArbitrationPolicy.tolerance(metric: metric)
        let delta = abs(a - b)
        let base = max(abs(a), abs(b))
        let agreeEdge = tol.isPercent ? tol.agree * base : tol.agree
        let minorEdge = tol.isPercent ? tol.minorDelta * base : tol.minorDelta
        if delta <= agreeEdge { return .agree }
        if delta <= minorEdge { return .minorDelta }
        return .conflict
    }
}
