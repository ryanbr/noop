import Foundation
import StrandAnalytics

/// The one foreground-surface resolver for daytime-stress scoring.
///
/// Stress detail and Today's hosted Stress card both call this funnel. With the personal lens off it
/// returns immediately, preserving the historical day-relative path without trailing-history reads.
/// Background widget publishing deliberately does not opt in: a display preference must not turn an
/// unprompted periodic publisher into 30 days of raw reads.
enum DaytimeStressMode {
    private static let baselineHistoryDays = 30

    @MainActor
    static func selected(repo: Repository, startOfToday: Date,
                         calendar: Calendar = .current,
                         personalBaseline: Bool) async -> DaytimeStress.ScoringMode {
        guard personalBaseline else { return .dayRelative }

        var aggregates: [(hr: Double?, rmssd: Double?)] = []
        aggregates.reserveCapacity(baselineHistoryDays)
        // Oldest -> newest so the EWMA fold replays history in order. Reduce each day immediately:
        // the fold needs two Doubles per day, not 30 days of raw HR and R-R retained together (#2107).
        for back in stride(from: baselineHistoryDays, through: 1, by: -1) {
            // Re-anchored, because a day-add preserves the TIME of day: in a zone whose clocks shift at
            // midnight, `startOfToday` on the transition date is 01:00 and every window walked back from
            // it runs 01:00 to 01:00, taking an hour of the next day and dropping its own first hour. A
            // sweep of two years in America/Santiago puts 60 of 21900 windows an hour out. The Kotlin
            // twin walks LocalDate and is immune, so this is also what keeps the two resolvers the same.
            guard let rawStart = calendar.date(byAdding: .day, value: -back, to: startOfToday) else { continue }
            let dayStart = calendar.startOfDay(for: rawStart)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                .map({ calendar.startOfDay(for: $0) }) else { continue }
            let from = Int(dayStart.timeIntervalSince1970)
            let to = Int(dayEnd.timeIntervalSince1970) - 1
            let dayTz = TimeZone.current.secondsFromGMT(for: dayStart)
            let dayHR = await repo.hrSamples(from: from, to: to, limit: 200_000)
            guard !dayHR.isEmpty else { continue }
            let dayRR = await repo.rrIntervals(from: from, to: to, limit: 200_000)
            aggregates.append(
                DaytimeStress.dayDaytimeAggregate(hr: dayHR, rr: dayRR, tzOffsetSeconds: dayTz)
            )
        }
        return DaytimeStress.scoringModeFromAggregates(aggregates)
    }
}
