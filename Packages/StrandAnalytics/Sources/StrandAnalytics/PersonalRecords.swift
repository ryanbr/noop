import Foundation

// PersonalRecords.swift - all-time personal bests over the user's own daily history.
//
// The WHOOP app has a "personal records" surface, but its records are computed server-side and limited
// to weightlifting exercises (observed in the shipped app's model shapes; facts only, no WHOOP code).
// NOOP has no server, so this is the local equivalent over the daily metrics NOOP already stores: the
// best HRV, the lowest resting HR, the best Charge, the highest strain, the longest sleep and so on.
//
// Rules (Kotlin twin: com.noop.analytics.PersonalRecords, held aligned by mirrored fixtures):
//   - each metric has a plausibility range; values outside it never become a record;
//   - higher is better for every metric except resting HR, where lower is better;
//   - a tie does not beat a record: the EARLIEST day holding the best value keeps it;
//   - a record is "new" when it was set within the last `newWindowDays` days ending at today AND at
//     least `minPriorValues` usable values came before it.
//
// Civil-day arithmetic is TZ-free (`Baselines.isoEpochDay`). Pure: no clock, no I/O, no storage.
// PRESENTATION ONLY: nothing here feeds a score, a baseline or a stored value. No em-dashes.

/// One tracked metric. The raw value matches the Kotlin `PersonalRecords.Metric.raw`.
public enum PersonalRecordMetric: String, CaseIterable, Sendable {
    case hrv, restingHr, recovery, strain, sleep, efficiency, deepSleep, remSleep, steps

    /// True only for resting HR.
    public var lowerIsBetter: Bool { self == .restingHr }

    /// Inclusive plausibility range; values outside it are ignored.
    public var range: ClosedRange<Double> {
        switch self {
        case .hrv: return 5...300
        case .restingHr: return 25...120
        case .recovery: return 0...100
        case .strain: return 0...21
        case .sleep: return 60...960
        case .efficiency: return 0.5...1.0
        case .deepSleep, .remSleep: return 1...360
        case .steps: return 1...100_000
        }
    }
}

public enum PersonalRecords {

    /// Days (inclusive of today) a record counts as new.
    public static let newWindowDays = 7

    /// Usable values that must precede a record before it can be called new.
    public static let minPriorValues = 14

    /// One day of input. Efficiency may be a fraction (0.91) or a percent (91); it is read as a fraction.
    public struct Day: Equatable, Sendable {
        public var day: String
        public var hrvMs: Double?
        public var restingHr: Double?
        public var recovery: Double?
        public var strain: Double?
        public var sleepMin: Double?
        public var efficiency: Double?
        public var deepMin: Double?
        public var remMin: Double?
        public var steps: Double?

        public init(day: String, hrvMs: Double? = nil, restingHr: Double? = nil, recovery: Double? = nil,
                    strain: Double? = nil, sleepMin: Double? = nil, efficiency: Double? = nil,
                    deepMin: Double? = nil, remMin: Double? = nil, steps: Double? = nil) {
            self.day = day
            self.hrvMs = hrvMs
            self.restingHr = restingHr
            self.recovery = recovery
            self.strain = strain
            self.sleepMin = sleepMin
            self.efficiency = efficiency
            self.deepMin = deepMin
            self.remMin = remMin
            self.steps = steps
        }
    }

    /// The best value of one metric, the day it was set and the best that stood before it.
    public struct Record: Equatable, Sendable {
        public let metric: PersonalRecordMetric
        public let value: Double
        public let day: String
        public let previousBest: Double?
        public let isNew: Bool
        /// Usable values the record was chosen from.
        public let samples: Int
    }

    /// Read `metric` off `d`, normalising efficiency to a fraction.
    /// Kotlin twin: `PersonalRecords.value`.
    public static func value(_ d: Day, _ metric: PersonalRecordMetric) -> Double? {
        switch metric {
        case .hrv: return d.hrvMs
        case .restingHr: return d.restingHr
        case .recovery: return d.recovery
        case .strain: return d.strain
        case .sleep: return d.sleepMin
        case .efficiency: return d.efficiency.map { $0 > 1.0 ? $0 / 100.0 : $0 }
        case .deepSleep: return d.deepMin
        case .remSleep: return d.remMin
        case .steps: return d.steps
        }
    }

    /// One `Record` per metric that has at least one usable value, in `allCases` order. Rows with an
    /// unparseable day key are ignored; rows may arrive in any order. When `today` does not parse,
    /// nothing is marked new.
    /// Kotlin twin: `PersonalRecords.records`.
    public static func records(_ days: [Day], today: String) -> [Record] {
        // Chronological by civil day; stable, so same-day duplicates keep their input order.
        let dated = days.enumerated()
            .compactMap { i, d in Baselines.isoEpochDay(d.day).map { (epoch: $0, index: i, day: d) } }
            .sorted { $0.epoch != $1.epoch ? $0.epoch < $1.epoch : $0.index < $1.index }
        let todayEpoch = Baselines.isoEpochDay(today)
        var out: [Record] = []
        for metric in PersonalRecordMetric.allCases {
            var best: Double?
            var bestDay = ""
            var bestEpoch = 0
            var previous: Double?
            var priorCount = 0
            var samples = 0
            for row in dated {
                guard let v = value(row.day, metric), !v.isNaN, metric.range.contains(v) else { continue }
                let beats: Bool
                if let cur = best { beats = metric.lowerIsBetter ? v < cur : v > cur } else { beats = true }
                if beats {
                    previous = best
                    best = v
                    bestDay = row.day.day
                    bestEpoch = row.epoch
                    priorCount = samples
                }
                samples += 1
            }
            guard let b = best else { continue }
            var isNew = false
            if let t = todayEpoch {
                isNew = bestEpoch <= t && bestEpoch > t - newWindowDays && priorCount >= minPriorValues
            }
            out.append(Record(metric: metric, value: b, day: bestDay, previousBest: previous,
                              isNew: isNew, samples: samples))
        }
        return out
    }
}
