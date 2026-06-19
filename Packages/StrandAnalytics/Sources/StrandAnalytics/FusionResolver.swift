import Foundation

// MARK: - FusionResolver (v5 — Local Multi-Device Fusion)
//
// Pure, deterministic, on-device fusion per
// docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §1–§2. Given the per-source
// values for ONE (metric, day), it:
//   1. ranks sources by trust tier (MetricArbitrationPolicy), stable tiebreak, and picks the winner's
//      value VERBATIM (best signal wins — never an average);
//   2. cross-validates the other sources against the winner and classifies agreement as
//      single / agree / minorDelta / conflict (the honest part — conflicts are shown, not merged).
// No I/O — the Repository feeds it rows it already loads. Value-for-value Kotlin twin in
// android/.../analytics/FusionResolver.kt.
public enum FusionResolver {

    /// Resolve one metric for one day from each source's value. `metricKey` is the resolver series key
    /// (e.g. "rhr", "steps", "sleep_total_min"); it picks the trust tiers and tolerance via
    /// `MetricArbitrationPolicy`. Returns nil only when `inputs` is empty (no source has the metric).
    ///
    /// The winner is the lowest-tier source, ties broken by `sourcePriority` (stable, deterministic).
    /// Its value passes through unchanged. The agreement state classifies how far the OTHER sources sit
    /// from the winning value, per the metric's tolerance band.
    public static func resolve(metricKey: String, inputs: [FusionInput]) -> FusedMetricPoint? {
        guard !inputs.isEmpty else { return nil }
        let kind = MetricArbitrationPolicy.kind(forKey: metricKey)

        // Build a contributor for every source, tagged with its trust tier + reason.
        let contributorsUnsorted: [ContributingSource] = inputs.map { input in
            ContributingSource(
                source: input.source,
                value: input.value,
                tier: MetricArbitrationPolicy.tier(metric: kind, source: input.source),
                sourcePriority: MetricArbitrationPolicy.sourcePriority(input.source),
                reason: MetricArbitrationPolicy.reason(metric: kind, source: input.source)
            )
        }

        // Winner = lowest tier, then lowest source-priority. Stable: equal keys keep input order via a
        // final index tiebreak so the result is fully deterministic across platforms.
        let ranked = contributorsUnsorted.enumerated().sorted { lhs, rhs in
            if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
            if lhs.element.sourcePriority != rhs.element.sourcePriority {
                return lhs.element.sourcePriority < rhs.element.sourcePriority
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        let winner = ranked[0]
        let agreement = classify(metric: kind, winningValue: winner.value, contributors: ranked)

        return FusedMetricPoint(
            metric: metricKey,
            value: winner.value,
            winningSource: winner.source,
            contributors: ranked,
            agreement: agreement
        )
    }

    /// Classify how the non-winning sources agree with `winningValue`, using the metric's tolerance.
    /// Worst case across all other sources wins (one conflicting source makes the point a conflict).
    /// One source ⇒ `.single` (nothing to cross-check). Public so the Repository can reuse it directly.
    public static func classify(metric: MetricArbitrationPolicy.MetricKind,
                                winningValue: Double,
                                contributors: [ContributingSource]) -> AgreementState {
        // Only one source reported the metric → nothing to compare against.
        guard contributors.count >= 2 else { return .single }

        let tol = MetricArbitrationPolicy.tolerance(metric: metric)
        var worst: AgreementState = .agree

        for c in contributors.dropFirst() {  // skip the winner (index 0)
            let delta = abs(c.value - winningValue)
            let agreeEdge: Double
            let minorEdge: Double
            if tol.isPercent {
                // Percentage band is relative to the winning value's magnitude. With a zero winner,
                // any non-zero second value can't be a fraction of it → fall back to absolute deltas.
                let base = abs(winningValue)
                agreeEdge = tol.agree * base
                minorEdge = tol.minorDelta * base
            } else {
                agreeEdge = tol.agree
                minorEdge = tol.minorDelta
            }

            let state: AgreementState
            if delta <= agreeEdge {
                state = .agree
            } else if delta <= minorEdge {
                state = .minorDelta
            } else {
                state = .conflict
            }
            worst = worse(worst, state)
        }
        return worst
    }

    /// Order of severity for the worst-case fold: agree < minorDelta < conflict. (`single` never
    /// enters here — it's the >= 2 guard's job.)
    private static func severity(_ s: AgreementState) -> Int {
        switch s {
        case .single:     return 0
        case .agree:      return 1
        case .minorDelta: return 2
        case .conflict:   return 3
        }
    }

    /// The more-severe of two agreement states.
    private static func worse(_ a: AgreementState, _ b: AgreementState) -> AgreementState {
        severity(a) >= severity(b) ? a : b
    }
}
