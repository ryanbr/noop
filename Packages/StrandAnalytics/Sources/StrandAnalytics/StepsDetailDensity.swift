import Foundation

/// The eight step-detail windows. Kotlin twin: `StepsDetailRange`.
public enum StepsDetailRange: String, CaseIterable, Sendable {
    case week = "W"
    case twoWeeks = "2W"
    case threeWeeks = "3W"
    case month = "M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case year = "1Y"
    case all = "ALL"

    /// Inclusive calendar-day count, or nil for all history.
    /// Kotlin twin: `StepsDetailRange.dayCount`.
    public func dayCount() -> Int? {
        switch self {
        case .week: return 7
        case .twoWeeks: return 14
        case .threeWeeks: return 21
        case .month: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .year: return 365
        case .all: return nil
        }
    }

    /// Kotlin twin: `StepsDetailRange.granularity`.
    fileprivate func granularity() -> StepsDetailGranularity {
        switch self {
        case .week, .twoWeeks, .threeWeeks, .month: return .daily
        case .threeMonths: return .weekly
        case .sixMonths, .year, .all: return .monthly
        }
    }
}

/// One already-resolved daily step observation; Kotlin uses the same fields and validation boundary.
public struct StepsDetailReading: Equatable, Sendable {
    public let day: String
    public let value: Double

    public init(day: String, value: Double) {
        self.day = day
        self.value = value
    }
}

/// One chart bucket, retaining the raw sum and observed-day denominator.
/// Kotlin uses the same key, display anchor, sum, observed-day count and rounded mean.
public struct StepsDetailBucket: Equatable, Sendable {
    public let key: String
    public let displayDay: String
    public let sum: Double
    public let observedDayCount: Int
    public let mean: Int

    public init(key: String, displayDay: String, sum: Double,
                observedDayCount: Int, mean: Int) {
        self.key = key
        self.displayDay = displayDay
        self.sum = sum
        self.observedDayCount = observedDayCount
        self.mean = mean
    }
}

private enum StepsDetailGranularity {
    case daily
    case weekly
    case monthly
}

/// Pure calendar projection for step-detail charts. Swift and Kotlin deliberately expose the same
/// inputs and outputs, and both are pinned by the one Android-hosted JSON oracle.
/// Kotlin twin: `StepsDetailDensity`.
public enum StepsDetailDensity {
    /// Window, deduplicate and aggregate readings. The explicit anchor is optional so callers that
    /// already know the latest valid measurement can reuse it without changing the contract.
    /// Kotlin twin: `StepsDetailDensity.project`.
    public static func project(readings: [StepsDetailReading], range: StepsDetailRange,
                               anchorDay: String? = nil) -> [StepsDetailBucket] {
        var byDay: [LocalCalendarDate: Double] = [:]
        for reading in readings {
            guard let day = strictDay(reading.day), reading.value.isFinite, reading.value >= 0 else {
                continue
            }
            byDay[day] = reading.value
        }

        let anchor: LocalCalendarDate
        if let anchorDay {
            guard let parsed = strictDay(anchorDay) else { return [] }
            anchor = parsed
        } else {
            guard let newest = byDay.keys.max() else { return [] }
            anchor = newest
        }
        let lower = range.dayCount().map { anchor.adding(days: -($0 - 1)) }

        struct Accumulator {
            let key: String
            let displayDay: String
            var sum: Double
            var observedDayCount: Int
        }
        var buckets: [String: Accumulator] = [:]
        for day in byDay.keys.sorted() {
            guard day <= anchor, lower.map({ day >= $0 }) ?? true, let value = byDay[day] else { continue }
            let identity = bucketIdentity(for: day, granularity: range.granularity())
            if var existing = buckets[identity.key] {
                existing.sum += value
                existing.observedDayCount += 1
                buckets[identity.key] = existing
            } else {
                buckets[identity.key] = Accumulator(
                    key: identity.key, displayDay: identity.displayDay,
                    sum: value, observedDayCount: 1)
            }
        }

        return buckets.values.sorted { $0.displayDay < $1.displayDay }.map {
            StepsDetailBucket(
                key: $0.key,
                displayDay: $0.displayDay,
                sum: $0.sum,
                observedDayCount: $0.observedDayCount,
                mean: positiveHalfUp($0.sum / Double($0.observedDayCount)))
        }
    }

    /// Parse exactly yyyy-MM-dd and reject impossible proleptic-Gregorian dates.
    /// Kotlin twin: `StepsDetailDensity.strictDay`.
    private static func strictDay(_ text: String) -> LocalCalendarDate? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        for index in [0, 1, 2, 3, 5, 6, 8, 9] where !(48...57).contains(bytes[index]) {
            return nil
        }
        guard let year = Int(text.prefix(4)),
              let month = Int(text.dropFirst(5).prefix(2)),
              let day = Int(text.suffix(2)),
              (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day) else { return nil }
        return LocalCalendarDate(year: year, month: month, day: day)
    }

    /// Proleptic-Gregorian month length. Kotlin twin: `StepsDetailDensity.daysInMonth`.
    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Gregorian leap-year rule. Kotlin twin: `StepsDetailDensity.isLeapYear`.
    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    /// Canonical bucket key and period-start display anchor.
    /// Kotlin twin: `StepsDetailDensity.bucketIdentity`.
    private static func bucketIdentity(for day: LocalCalendarDate,
                                       granularity: StepsDetailGranularity) -> (key: String, displayDay: String) {
        switch granularity {
        case .daily:
            return (day.key, day.key)
        case .weekly:
            let weekdayFromMonday = ((day.daysSinceEpoch + 3) % 7 + 7) % 7
            let monday = day.adding(days: -weekdayFromMonday).key
            return (monday, monday)
        case .monthly:
            let first = LocalCalendarDate(year: day.year, month: day.month, day: 1).key
            return (String(first.prefix(7)), first)
        }
    }

    /// Positive half-up rounding, independent of platform banker-rounding defaults.
    /// Kotlin twin: `StepsDetailDensity.positiveHalfUp`.
    private static func positiveHalfUp(_ value: Double) -> Int {
        Int(floor(value + 0.5))
    }
}
