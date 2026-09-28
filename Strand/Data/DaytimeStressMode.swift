import Foundation
import StrandAnalytics

/// Process-level reuse of the resolved daytime-stress lens, keyed on the inputs that can change it.
///
/// The resolver folds the THIRTY DAYS BEFORE today, so its answer is fixed for the whole local day unless a
/// backfill lands rows inside that past window. Today's own heart rate, which arrives all day, is outside it
/// and cannot move the key. Without this memo every surface paid the full fold independently: Today's hosted
/// card, Stress detail on open, and each foreground pass, all reading up to thirty days of HR.
///
/// The drain it closes (#2535, reported on Android): with the lens on, Today showed 09:30 at 22:20 while
/// detail showed the current curve fifteen seconds after opening. Both are the same latency, and the card
/// holds its previous curve while a pass runs, so the morning's curve stayed on screen looking current.
///
/// `inFlight` is the half a plain memo misses, and on this platform it is also what makes the dedupe work at
/// all: a MainActor method that awaits is REENTRANT, so a second caller can arrive while the first is still
/// folding and would otherwise start its own. Sharing the task means the second awaits the first's answer.
///
/// In memory and per process, the same contract `AnalyzeRecentDayCache` keeps: never persisted, never across
/// the backup boundary, and a miss is byte-for-byte the full path. Nothing is banked from here, so there is
/// no data-loss surface.
///
/// ONE slot rather than a dictionary, deliberately: every caller resolves for the same active device and the
/// same local day, so a second slot would only hold a key nothing asks for again. Kotlin twin:
/// `com.noop.ui.StressLensCache`.
@MainActor
final class StressLensCache {
    static let shared = StressLensCache()

    private var key: String?
    private var mode: DaytimeStress.ScoringMode?
    private var inFlight: (key: String, task: Task<DaytimeStress.ScoringMode, Never>)?

    /// The lens for `candidate`, folding through `fold` only if neither a stored answer nor an in-flight one
    /// already matches.
    func resolve(_ candidate: String,
                 fold: @escaping () async -> DaytimeStress.ScoringMode) async -> DaytimeStress.ScoringMode {
        if let mode, key == candidate { return mode }
        if let inFlight, inFlight.key == candidate { return await inFlight.task.value }
        let task = Task { @MainActor in await fold() }
        inFlight = (key: candidate, task: task)
        let resolved = await task.value
        if inFlight?.key == candidate { inFlight = nil }
        key = candidate
        mode = resolved
        return resolved
    }

    /// For tests, and for any future caller that needs to force the fold.
    func clear() {
        key = nil
        mode = nil
        inFlight = nil
    }
}

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

        // One cheap fingerprint over the whole past-30-day span, then the memo. The span ENDS yesterday, so
        // today's incoming heart rate cannot invalidate it and the lens stays warm for the day. Anchored the
        // same way each day window is, so a midnight clock shift cannot put the span an hour out.
        let spanStart = calendar.date(byAdding: .day, value: -baselineHistoryDays, to: startOfToday)
            .map { calendar.startOfDay(for: $0) } ?? startOfToday
        let spanEnd = Int(calendar.startOfDay(for: startOfToday).timeIntervalSince1970) - 1
        let fingerprint = await repo.hrFingerprintUnion(from: Int(spanStart.timeIntervalSince1970), to: spanEnd)
        let cacheKey = "\(repo.deviceId)|\(Int(calendar.startOfDay(for: startOfToday).timeIntervalSince1970))"
            + "|\(TimeZone.current.identifier)|\(fingerprint)"
        return await StressLensCache.shared.resolve(cacheKey) {
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
                // The live baseline scores HR only while the RMSSD term is disabled. Skip the
                // 30 days of historical R-R reads; they cannot change the selected mode.
                let dayRR = DaytimeStress.daytimeRMSSDScoringEnabled
                    ? await repo.rrIntervals(from: from, to: to, limit: 200_000) : []
                aggregates.append(
                    DaytimeStress.dayDaytimeAggregate(hr: dayHR, rr: dayRR, tzOffsetSeconds: dayTz)
                )
        }
        return DaytimeStress.scoringModeFromAggregates(aggregates)
        }
    }
}
