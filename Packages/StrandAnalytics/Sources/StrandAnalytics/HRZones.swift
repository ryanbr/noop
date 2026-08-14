import Foundation
import WhoopProtocol

// HRZones.swift — HR-max + 5 heart-rate zones and time-in-zone from an HR stream.
//
// HR-max uses Tanaka et al. (2001): HRmax = 208 − 0.7 × age (gender-independent),
// with an optional manual override. The five zones are the conventional %HRmax
// bands used across consumer wearables:
//
//   Zone 1 (50–60% HRmax) — very light / recovery
//   Zone 2 (60–70% HRmax) — light / fat-burn
//   Zone 3 (70–80% HRmax) — moderate / aerobic
//   Zone 4 (80–90% HRmax) — hard / threshold
//   Zone 5 (90–100% HRmax) — maximum
//
// NOTE: the Python source (strain.py) uses Karvonen %HRR zones (Edwards 5-zone,
// 50/60/70/80/90 %HRR) for TRIMP/strain. Those are reproduced faithfully in
// StrainScorer.swift. This file provides the simpler, age-only %HRmax zone model
// the task asks for (zones from age, time-in-zone from [HRSample]); it is the
// "display" zone model and is independent of the HRR-based strain math.

/// A single heart-rate zone defined as a bpm interval [lower, upper).
public struct HRZone: Equatable, Sendable {
    /// Zone number 1...5.
    public let number: Int
    /// Lower bound (bpm), inclusive.
    public let lower: Double
    /// Upper bound (bpm); exclusive except for the top zone where it is inclusive.
    public let upper: Double
    /// Fraction-of-HRmax lower bound (e.g. 0.50 for Zone 1).
    public let lowerPct: Double
    /// Fraction-of-HRmax upper bound (e.g. 0.60 for Zone 1).
    public let upperPct: Double

    public init(number: Int, lower: Double, upper: Double, lowerPct: Double, upperPct: Double) {
        self.number = number
        self.lower = lower
        self.upper = upper
        self.lowerPct = lowerPct
        self.upperPct = upperPct
    }
}

/// Five HR zones derived from a max HR or personalized BPM boundaries, plus the max HR itself and
/// its source.
public struct HRZoneSet: Equatable, Sendable {
    /// The five zones, z1...z5, in ascending order.
    public let zones: [HRZone]
    /// Max HR (bpm) the zones were built from.
    public let maxHR: Double
    /// "tanaka" (age formula), "manual" (caller override), or "custom" (personalized boundaries).
    public let source: String

    public init(zones: [HRZone], maxHR: Double, source: String) {
        self.zones = zones
        self.maxHR = maxHR
        self.source = source
    }

    /// Return the zone number (1...5) for a bpm value, or 0 when below Zone 1.
    public func zoneNumber(forBPM bpm: Double) -> Int {
        for z in zones {
            // Top zone is inclusive at its upper edge so HRmax itself lands in z5.
            if z.number == 5 {
                if bpm >= z.lower { return 5 }
            } else if bpm >= z.lower && bpm < z.upper {
                return z.number
            }
        }
        return 0
    }
}

/// Time spent in each zone (seconds), including below-Zone-1 time as `belowZone1`.
public struct TimeInZone: Equatable, Sendable {
    /// Seconds in each of the five zones, indexed z1...z5 (zone[0] == Zone 1).
    public let seconds: [Double]
    /// Seconds spent below Zone 1 (HR under 50% HRmax).
    public let belowZone1: Double

    public init(seconds: [Double], belowZone1: Double) {
        self.seconds = seconds
        self.belowZone1 = belowZone1
    }

    /// Total counted seconds (Zone 1...5 plus below-Zone-1).
    public var total: Double { seconds.reduce(0, +) + belowZone1 }

    /// Seconds in a specific zone (1...5); 0 for out-of-range zone numbers.
    public func seconds(inZone zone: Int) -> Double {
        guard zone >= 1 && zone <= 5 else { return 0 }
        return seconds[zone - 1]
    }
}

public enum HRZones {

    /// %HRmax band edges for zones 1...5: [0.50, 0.60, 0.70, 0.80, 0.90, 1.00].
    public static let zoneEdges: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    /// Sensible editable BPM range for personalized zone starts. The analytics API accepts any
    /// positive finite values; the app UIs use this range to keep steppers practical.
    public static let customBPMRange: ClosedRange<Int> = 30...250

    /// Tanaka (2001) age-predicted max HR: 208 − 0.7 × age (gender-independent).
    public static func tanakaMaxHR(age: Double) -> Double {
        208.0 - 0.7 * age
    }

    /// Build the 5-zone set from age (Tanaka) or a manual `maxHROverride`.
    ///
    /// - Parameters:
    ///   - age: age in years (used only when `maxHROverride` is nil).
    ///   - maxHROverride: explicit HRmax (bpm); when provided, `source == "manual"`.
    public static func zones(age: Double,
                             maxHROverride: Double? = nil,
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        let maxHR: Double
        let source: String
        if let override = maxHROverride {
            maxHR = override
            source = "manual"
        } else {
            maxHR = tanakaMaxHR(age: age)
            source = "tanaka"
        }
        return zones(maxHR: maxHR, source: source, customLowerBounds: customLowerBounds)
    }

    /// Build the 5-zone set directly from a known max HR, optionally replacing the conventional
    /// percentage edges with five personalized inclusive lower bounds in BPM. Invalid custom input
    /// falls back to the conventional model, so malformed restored preferences can never create gaps.
    public static func zones(maxHR: Double,
                             source: String = "manual",
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        let custom = customLowerBounds.flatMap(validCustomLowerBounds)
        var built: [HRZone] = []
        for i in 0..<5 {
            let lower = custom?[i] ?? zoneEdges[i] * maxHR
            let upper = custom.map { i < 4 ? $0[i + 1] : max(maxHR, $0[i]) }
                ?? zoneEdges[i + 1] * maxHR
            let loPct = maxHR > 0 ? lower / maxHR : 0
            let hiPct = maxHR > 0 ? upper / maxHR : 0
            built.append(HRZone(
                number: i + 1,
                lower: lower,
                upper: upper,
                lowerPct: loPct,
                upperPct: hiPct
            ))
        }
        return HRZoneSet(zones: built, maxHR: maxHR, source: custom == nil ? source : "custom")
    }

    /// The conventional five inclusive lower bounds, rounded up to whole BPM for an editor. Rounding
    /// up preserves the existing integer-sample classification (e.g. a 93.5 edge starts at 94 bpm).
    public static func defaultLowerBounds(maxHR: Double) -> [Int] {
        Array(zoneEdges.prefix(5)).map { Int(ceil($0 * maxHR)) }
    }

    /// Return a valid five-boundary custom model, or nil unless values are positive, finite, and
    /// strictly increasing. Kept public so persistence layers can reject hand-edited backup values
    /// using the exact same invariant as the analytics engine.
    public static func validCustomLowerBounds(_ values: [Double]) -> [Double]? {
        guard values.count == 5,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        for i in 1..<values.count where values[i] <= values[i - 1] { return nil }
        return values
    }

    /// Compute time-in-zone (seconds) from a time-ordered HR stream.
    ///
    /// Each sample is credited with the duration until the next sample (the
    /// "hold until next reading" convention). The final sample is credited with
    /// the median inter-sample interval (so a constant-rate stream is fully
    /// accounted for). Samples are sorted defensively by ts.
    ///
    /// - Parameters:
    ///   - hr: time-ordered (or unordered) `[HRSample]`.
    ///   - zoneSet: the zone definitions to bucket against.
    public static func timeInZone(_ hr: [HRSample], zoneSet: HRZoneSet) -> TimeInZone {
        let sorted = hr.sorted { $0.ts < $1.ts }
        var zoneSeconds = [Double](repeating: 0, count: 5)
        var below: Double = 0

        guard !sorted.isEmpty else {
            return TimeInZone(seconds: zoneSeconds, belowZone1: 0)
        }

        // Tail sample gets the median inter-sample gap so the series is fully counted.
        let tailDuration = medianInterval(sorted)

        for i in 0..<sorted.count {
            let dur: Double
            if i < sorted.count - 1 {
                let gap = Double(sorted[i + 1].ts - sorted[i].ts)
                // Guard against zero/negative or pathological gaps; cap at the median
                // so a single huge wall-clock gap doesn't blow up one bucket.
                dur = (gap > 0) ? min(gap, tailDuration) : tailDuration
            } else {
                dur = tailDuration
            }
            let z = zoneSet.zoneNumber(forBPM: Double(sorted[i].bpm))
            if z >= 1 {
                zoneSeconds[z - 1] += dur
            } else {
                below += dur
            }
        }
        return TimeInZone(seconds: zoneSeconds, belowZone1: below)
    }

    /// Median spacing between consecutive timestamps, restricted to plausible
    /// (0, 300 s] gaps. Falls back to 1.0 s when no plausible gap exists.
    static func medianInterval(_ sorted: [HRSample]) -> Double {
        guard sorted.count >= 2 else { return 1.0 }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let g = Double(sorted[i].ts - sorted[i - 1].ts)
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 1.0 }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }
}
