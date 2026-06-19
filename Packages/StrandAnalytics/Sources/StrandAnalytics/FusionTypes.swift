import Foundation

// MARK: - Fusion value types (v5 — Local Multi-Device Fusion)
//
// The plain inputs/outputs for the pure fusion engine described in
// docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md. No I/O, no model, no
// network — the Repository feeds these rows it already loads, the engine returns a resolved point.
// These deliberately mirror the existing `DailyMetricSource` / `SourcedDailyMetric` provenance
// vocabulary (Repository.swift L61-82) but generalised to cover every importer source so a future
// Polar/Garmin/Oura is a table entry, not a type change. Value-for-value Kotlin twin in
// android/.../analytics/FusionTypes.kt.

/// Where a fused number came from — a superset of the legacy `DailyMetricSource` (whoopImport /
/// noopComputed / appleHealth / localCache), extended to every source the importers already write.
/// The rawValue is the canonical source id (`Repository.whoopSource` etc.) so a `FusionSource` round-
/// trips to/from the stored `deviceId` / source string without a lookup table.
public enum FusionSource: String, Equatable, Sendable, CaseIterable, Codable {
    /// Imported WHOOP record (CSV/zip export under the strap's `deviceId`, e.g. "my-whoop").
    case whoopImport = "my-whoop"
    /// NOOP-computed score derived on-device from the raw strap streams (the "$deviceId-noop" sibling).
    case noopComputed = "my-whoop-noop"
    /// Apple Health aggregate of a declared-compatible quantity.
    case appleHealth = "apple-health"
    /// Health Connect aggregate (Android's Apple-equivalent body-metric source).
    case healthConnect = "health-connect"
    /// Mi Band / Xiaomi import — a dedicated wrist band (counts steps directly).
    case xiaomiBand = "xiaomi-band"
    /// Nutrition CSV import (single-source passthrough — calories/macros).
    case nutritionCsv = "nutrition-csv"
    /// Locally-cached fallback row with no richer provenance.
    case localCache = "local-cache"

    /// Human-facing source name for a provenance pill ("from WHOOP"). Never a clinical claim.
    public var displayName: String {
        switch self {
        case .whoopImport:   return "WHOOP"
        case .noopComputed:  return "NOOP"
        case .appleHealth:   return "Apple Health"
        case .healthConnect: return "Health Connect"
        case .xiaomiBand:    return "Mi Band"
        case .nutritionCsv:  return "Nutrition"
        case .localCache:    return "Cached"
        }
    }
}

/// How well a metric's value agrees across the sources that reported it on the same day.
/// `agree` → quiet parenthetical; `minorDelta` → show both, neutral; `conflict` → flag, never merge.
/// Deterministic threshold output (no statistics beyond a clamp + a percentage); see
/// `MetricArbitrationPolicy.tolerance(metric:)`.
public enum AgreementState: String, Equatable, Sendable, CaseIterable, Codable {
    /// Only one source reported the metric — nothing to cross-check, no chip shown.
    case single
    /// Within the metric's tolerance — sources agree.
    case agree
    /// Outside tolerance but inside the plausible-spread band — show both, no alarm.
    case minorDelta
    /// Large divergence — flag prominently, keep both, never silently average.
    case conflict
}

/// One source's value for a `(metric, day)`, with the trust tier the policy assigned it. The winner
/// is the lowest `tier` (most trusted), ties broken by `sourcePriority` (stable). `reason` is the
/// published, plain-English justification ("counts directly", "best stager") — the honesty contract.
public struct ContributingSource: Equatable, Sendable {
    public let source: FusionSource
    public let value: Double
    /// Trust tier (lower = more trusted); from `MetricArbitrationPolicy.tier(metric:source:)`.
    public let tier: Int
    /// Stable tiebreak within a tier (lower wins); from the policy's source ordering.
    public let sourcePriority: Int
    /// The visible "best signal" reason for this source on this metric. Never "accurate"/"correct".
    public let reason: String

    public init(source: FusionSource, value: Double, tier: Int, sourcePriority: Int, reason: String) {
        self.source = source
        self.value = value
        self.tier = tier
        self.sourcePriority = sourcePriority
        self.reason = reason
    }
}

/// The fused result for one `(metric, day)`: the winning value, the source that supplied it, every
/// contributor (for the compare sheet), and the agreement classification. Pure data — existing
/// consumers that ignore `agreement` are unaffected.
public struct FusedMetricPoint: Equatable, Sendable {
    /// The metric key this point resolves (matches the resolver's series keys, e.g. "rhr", "steps").
    public let metric: String
    /// The chosen value (verbatim from `winningSource`'s row — never an average).
    public let value: Double
    /// The source that supplied `value` (highest trust, stable tiebreak).
    public let winningSource: FusionSource
    /// Every source that reported this metric for the day, winner first, then by tier/priority.
    public let contributors: [ContributingSource]
    /// Cross-validation outcome across `contributors`.
    public let agreement: AgreementState

    public init(metric: String, value: Double, winningSource: FusionSource,
                contributors: [ContributingSource], agreement: AgreementState) {
        self.metric = metric
        self.value = value
        self.winningSource = winningSource
        self.contributors = contributors
        self.agreement = agreement
    }
}

/// A single source's raw input to the fusion engine: a value for a metric on a day. The Repository
/// builds these from rows it already reads (it does the I/O); the engine stays pure.
public struct FusionInput: Equatable, Sendable {
    public let source: FusionSource
    public let value: Double
    public init(source: FusionSource, value: Double) {
        self.source = source
        self.value = value
    }
}
