import Foundation

/// A completed local wake day selected explicitly, independent of the normal recent scan.
/// Calendar midnights preserve 23/25-hour days; the read includes the scorer's neighboring context.
public struct SleepRecalculationWindow: Equatable, Sendable {
    public let day: String
    public let start: Int
    public let end: Int
    public let offsetSeconds: Int
    public var readStart: Int { start - StreamReadCap.lookbackSeconds }

    public func contains(_ timestamp: Int) -> Bool {
        timestamp >= start && timestamp < end
    }

    public static func make(day: String, timeZone: TimeZone, now: Int) -> Self? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let date = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let midnight = calendar.date(from: DateComponents(year: year, month: month, day: date)),
              calendar.component(.year, from: midnight) == year,
              calendar.component(.month, from: midnight) == month,
              calendar.component(.day, from: midnight) == date,
              let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
        let start = Int(midnight.timeIntervalSince1970)
        let end = Int(next.timeIntervalSince1970)
        guard start < end, end <= now else { return nil }
        return Self(day: day, start: start, end: end, offsetSeconds: timeZone.secondsFromGMT(for: midnight))
    }
}
