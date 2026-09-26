import Foundation

/// A daily body-weight reading. Kilograms are canonical; source and date survive a database backup.
public struct WeightEntry: Equatable, Sendable {
    public let day: String
    public let kilograms: Double
    public let source: String
    public var isManual: Bool { source == WeightHistory.manualSource }

    public init(day: String, kilograms: Double, source: String) {
        self.day = day
        self.kilograms = kilograms
        self.source = source
    }
}

/// Storage contract shared with Android. No profile weight is synthesized into dated history.
public enum WeightHistory {
    public static let manualSource = "noop-weight"
    public static let key = "weight"
    // Explicit manual entries win a same-day conflict. Imported values remain stored independently.
    public static let sources = [manualSource, "apple-health", "health-connect"]

    /// Kotlin twin: `WeightHistory.validKilograms`.
    public static func validKilograms(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 1000
    }

    /// Strict Gregorian YYYY-MM-DD, independent of locale, timezone and lenient date parsers.
    /// Kotlin twin: `WeightHistory.validDay`.
    public static func validDay(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              let year = Int(day.prefix(4)), let month = Int(day.dropFirst(5).prefix(2)),
              let date = Int(day.suffix(2)), year >= 1, (1...12).contains(month) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(date)
    }

    /// One valid reading per date, oldest first, preserving provenance. Order of the input is irrelevant
    /// across sources; an exact source/day duplicate uses its last row (the metricSeries upsert rule).
    /// Kotlin twin: `WeightHistory.resolve`.
    public static func resolve(_ entries: [WeightEntry], through day: String) -> [WeightEntry] {
        var byDay: [String: WeightEntry] = [:]
        for source in sources.reversed() {
            for entry in entries where entry.source == source && entry.day <= day
                && validDay(entry.day) && validKilograms(entry.kilograms) {
                byDay[entry.day] = entry
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
