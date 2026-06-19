import Foundation

// MARK: - MetricArbitrationPolicy (v5 — Local Multi-Device Fusion)
//
// The heart of v5 per docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md:
// a DATA table (not if/else branches) keyed by metric × source that yields a trust tier + a plain,
// published reason string, plus the per-metric cross-validation tolerances. It is the single place a
// future Polar/Garmin/Oura source is registered. Pure constants + two lookups. Value-for-value Kotlin
// twin in android/.../analytics/MetricArbitrationPolicy.kt.
//
// Trust tiers (lower = more trusted), grounded in what a device MEASURES vs ESTIMATES (spec §1):
//   0 — Direct dedicated sensor for this metric (WHOOP R-R for HRV; a wrist band's pedometer for
//       steps; chest/PPG strap for avg/max/resting HR; ring/strap temp for skin temp).
//   1 — Derived on-device from raw by NOOP (computed recovery/strain/sleep from strap streams).
//   2 — Phone aggregate (Apple Health / Health Connect) of a declared-compatible quantity.
//   3 — Estimate / proxy (a strap's STEP estimate; a calories estimate).
//
// "Best signal" is always backed by a NAMED, VISIBLE reason — never "accurate"/"correct"/"clinical".
// This is wellness transparency, not a diagnosis.
public enum MetricArbitrationPolicy {

    /// The canonical fusion metric families. The string `key`s the resolver uses (e.g. "rhr",
    /// "sleep_total_min", "sleep_deep_min") map onto one of these for tiering; raw keys that don't map
    /// fall through to `.other` (single-source passthrough, tier by source kind only).
    public enum MetricKind: String, Equatable, Sendable, CaseIterable {
        case restingHR
        case heartRate      // avg/max HR
        case hrv
        case spo2
        case skinTemp
        case steps
        case sleep          // any sleep stage/total
        case calories
        case other
    }

    /// Map a resolver series key onto a `MetricKind`. Keys mirror `Repository.appleCompatibleKey`'s
    /// vocabulary so the policy lines up with the existing cross-source resolver.
    public static func kind(forKey key: String) -> MetricKind {
        switch key {
        case "rhr", "resting_hr":
            return .restingHR
        case "avg_hr", "max_hr":
            return .heartRate
        case "hrv":
            return .hrv
        case "spo2":
            return .spo2
        case "skin_temp", "skinTemp":
            return .skinTemp
        case "steps":
            return .steps
        case "sleep_total_min", "asleep_min",
             "sleep_deep_min", "deep_min",
             "sleep_rem_min", "rem_min",
             "sleep_light_min", "core_min",
             "in_bed_min":
            return .sleep
        case "active_kcal", "energy_kcal":
            return .calories
        default:
            return .other
        }
    }

    /// Trust tier for a `(metric, source)` pair — lower is more trusted. Encodes the spec's
    /// measure-vs-estimate intuition as data, e.g. a wrist band's pedometer (tier 0) beats the strap's
    /// step ESTIMATE (tier 3); WHOOP sleep stages (tier 0) beat phone sleep buckets (tier 2). The
    /// `other`/unmapped keys tier purely by source kind (import vs computed vs phone vs cache).
    public static func tier(metric: MetricKind, source: FusionSource) -> Int {
        switch metric {
        case .restingHR, .heartRate, .hrv, .spo2:
            // Worn-sensor vitals: the strap measures them directly; the phone aggregates them.
            switch source {
            case .whoopImport:   return 0   // direct dedicated sensor (R-R / PPG)
            case .xiaomiBand:    return 0   // dedicated wrist PPG
            case .noopComputed:  return 1   // derived on-device from raw strap streams
            case .appleHealth:   return 2   // phone aggregate
            case .healthConnect: return 2
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .skinTemp:
            // Redundancy metric: the strap/ring measures it; the phone rarely carries it.
            switch source {
            case .whoopImport:   return 0
            case .xiaomiBand:    return 0
            case .noopComputed:  return 1
            case .appleHealth:   return 2
            case .healthConnect: return 2
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .steps:
            // The device that ACTUALLY COUNTS steps wins; the strap only ESTIMATES from motion.
            switch source {
            case .xiaomiBand:    return 0   // wrist pedometer — counts directly
            case .appleHealth:   return 0   // phone pedometer — counts directly
            case .healthConnect: return 0
            case .whoopImport:   return 3   // strap step estimate is a last resort
            case .noopComputed:  return 3   // NOOP step estimate from motion
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .sleep:
            // The best STAGER wins: imported WHOOP stages > NOOP-computed stages > phone sleep buckets.
            switch source {
            case .whoopImport:   return 0
            case .noopComputed:  return 1
            case .xiaomiBand:    return 1   // a band with its own staging, below WHOOP's
            case .appleHealth:   return 2   // phone sleep buckets
            case .healthConnect: return 2
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .calories:
            // Active energy is an estimate everywhere; phone aggregate slightly over a strap estimate.
            switch source {
            case .appleHealth:   return 2
            case .healthConnect: return 2
            case .whoopImport:   return 3
            case .noopComputed:  return 3
            case .xiaomiBand:    return 3
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .other:
            // Unmapped keys (nutrition/mood/passthrough): tier by source kind only.
            switch source {
            case .whoopImport:   return 0
            case .xiaomiBand:    return 0
            case .noopComputed:  return 1
            case .appleHealth:   return 2
            case .healthConnect: return 2
            case .nutritionCsv:  return 0   // its own single-source metric
            case .localCache:    return 3
            }
        }
    }

    /// Stable tiebreak WITHIN a tier (lower wins). Mirrors the existing precedence baked into
    /// `sourceCandidates`: imported WHOOP first, then NOOP-computed, then phone (Apple before Health
    /// Connect, matching the #443 ordering), then a dedicated band, then single-source, then cache.
    /// Used only when two sources land on the SAME tier, so the resolver stays deterministic.
    public static func sourcePriority(_ source: FusionSource) -> Int {
        switch source {
        case .whoopImport:   return 0
        case .noopComputed:  return 1
        case .appleHealth:   return 2
        case .healthConnect: return 3
        case .xiaomiBand:    return 4
        case .nutritionCsv:  return 5
        case .localCache:    return 6
        }
    }

    /// The published "best signal" reason a source wins (or appears) for a metric. Plain English,
    /// wellness-only — never asserts a value is true or medically valid. Drives the one-line caption
    /// on the fused row.
    public static func reason(metric: MetricKind, source: FusionSource) -> String {
        let t = tier(metric: metric, source: source)
        switch (metric, source) {
        case (.steps, .xiaomiBand), (.steps, .appleHealth), (.steps, .healthConnect):
            return "counts directly"
        case (.steps, .whoopImport), (.steps, .noopComputed):
            return "step estimate"
        case (.sleep, .whoopImport):
            return "best stager"
        case (.sleep, .noopComputed):
            return "computed stages"
        case (.sleep, .appleHealth), (.sleep, .healthConnect):
            return "phone sleep buckets"
        case (.skinTemp, _):
            return "worn sensor"
        default:
            switch t {
            case 0: return "direct sensor"
            case 1: return "computed on device"
            case 2: return "phone aggregate"
            default: return "estimate"
            }
        }
    }

    // MARK: - Cross-validation tolerances
    //
    // Per-metric hand-set bands for the agreement classifier (spec §2). A delta inside `agree` is
    // agreement; inside `minorDelta` is a plausible measurement spread (show both, no alarm);
    // anything larger is a `conflict` (flag, never merge). Both platforms read the SAME constants.
    // Some metrics use a percentage band (steps), most use an absolute band; `Tolerance` carries both
    // and the classifier picks per `isPercent`.

    public struct Tolerance: Equatable, Sendable {
        /// Within this delta from the winning value → `agree`.
        public let agree: Double
        /// Within this delta (but beyond `agree`) → `minorDelta`; beyond it → `conflict`.
        public let minorDelta: Double
        /// When true the deltas are FRACTIONS of the winning value (e.g. 0.10 = ±10%), else absolute.
        public let isPercent: Bool

        public init(agree: Double, minorDelta: Double, isPercent: Bool) {
            self.agree = agree
            self.minorDelta = minorDelta
            self.isPercent = isPercent
        }
    }

    /// The tolerance band for a metric. Defaults (spec §2 / Open question 3): RHR ±3 bpm, asleep ±20
    /// min, steps ±10%. `minorDelta` is the outer plausible-spread edge before a `conflict`.
    public static func tolerance(metric: MetricKind) -> Tolerance {
        switch metric {
        case .restingHR:
            return Tolerance(agree: 3, minorDelta: 8, isPercent: false)      // bpm
        case .heartRate:
            return Tolerance(agree: 5, minorDelta: 12, isPercent: false)     // bpm
        case .hrv:
            return Tolerance(agree: 8, minorDelta: 20, isPercent: false)     // ms
        case .spo2:
            return Tolerance(agree: 2, minorDelta: 4, isPercent: false)      // %
        case .skinTemp:
            return Tolerance(agree: 0.5, minorDelta: 1.5, isPercent: false)  // °C
        case .steps:
            return Tolerance(agree: 0.10, minorDelta: 0.30, isPercent: true) // ±10% / ±30%
        case .sleep:
            return Tolerance(agree: 20, minorDelta: 60, isPercent: false)    // min
        case .calories:
            return Tolerance(agree: 0.15, minorDelta: 0.40, isPercent: true) // ±15% / ±40%
        case .other:
            return Tolerance(agree: 0.10, minorDelta: 0.30, isPercent: true)
        }
    }

    /// Convenience: tolerance for a raw resolver key (maps via `kind(forKey:)`).
    public static func tolerance(forKey key: String) -> Tolerance {
        tolerance(metric: kind(forKey: key))
    }
}
