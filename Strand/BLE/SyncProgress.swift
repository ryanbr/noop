import Foundation

/// How far a history sync has got, and roughly how long is left.
///
/// The strap drains its banked history oldest-first, so the newest sample time decoded so far (the
/// frontier) is the honest measure of progress. The target is "now": the strap keeps recording while it
/// drains, so the goal line moves forward one second per second. The estimate compares how fast the
/// frontier advances against that, which is why a drain only finishes when it outruns real time.
///
/// Chunk counts cannot give a total: the strap does not report how many chunks a sync will take, and
/// the connect-time page backlog uses a different unit. Time can, so every figure here is in seconds.
struct SyncProgress: Equatable {
    /// 0...1 share of the session's catch-up done so far.
    let fraction: Double
    /// Newest sample time synced so far (unix seconds).
    let syncedThroughUnix: Int
    /// Estimated seconds until caught up, or nil while there is too little to measure or the drain is
    /// not outrunning real time.
    let secondsRemaining: Int?

    /// Within this distance of now the history counts as caught up: the strap banks in chunks, so the
    /// last few minutes always trail.
    static let caughtUpSlackSeconds = 300
    /// Too short a session gives a wild rate; hold the estimate back until this much has run.
    static let minimumElapsedSeconds = 20
    /// A drain barely faster than real time would project hours from noise; require a clear margin.
    static let minimumCatchUpRate = 1.05

    /// - Parameters:
    ///   - firstDataUnix: earliest sample time the session decoded (where this catch-up started).
    ///   - frontierUnix: newest sample time decoded so far.
    ///   - sessionStartedUnix: wall-clock time the session began.
    ///   - nowUnix: wall-clock time now.
    static func estimate(firstDataUnix: Int, frontierUnix: Int, sessionStartedUnix: Int, nowUnix: Int) -> SyncProgress? {
        guard frontierUnix >= firstDataUnix, nowUnix > firstDataUnix else { return nil }
        let behind = max(0, nowUnix - frontierUnix)
        if behind <= caughtUpSlackSeconds {
            return SyncProgress(fraction: 1, syncedThroughUnix: frontierUnix, secondsRemaining: 0)
        }
        let done = Double(frontierUnix - firstDataUnix)
        let total = Double(nowUnix - firstDataUnix)
        let fraction = min(1, max(0, done / total))

        let elapsed = nowUnix - sessionStartedUnix
        var remaining: Int? = nil
        if elapsed >= minimumElapsedSeconds {
            // Data seconds drained per wall second; the target gains one second per second meanwhile.
            let rate = done / Double(elapsed)
            if rate >= minimumCatchUpRate {
                remaining = Int((Double(behind - caughtUpSlackSeconds) / (rate - 1)).rounded())
            }
        }
        return SyncProgress(fraction: fraction, syncedThroughUnix: frontierUnix, secondsRemaining: remaining)
    }

    /// Whole percent for display, never showing 100% before the sync is actually caught up.
    var percent: Int {
        fraction >= 1 ? 100 : min(99, Int((fraction * 100).rounded(.down)))
    }

    /// "1:34 AM", or "Wed 1:34 AM" when the frontier is on an earlier day. Follows the Clock format setting.
    func syncedThroughText(now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(syncedThroughUnix))
        let time = AppClock.hourMinuteFormatter().string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// One line for the sync card: "62% · synced up to 1:34 AM · about 50 min left".
    func summaryLine(now: Date = Date()) -> String {
        var parts = [String(localized: "\(percent)%"),
                     String(localized: "synced up to \(syncedThroughText(now: now))")]
        if let left = remainingText { parts.append(left) }
        return parts.joined(separator: " · ")
    }

    /// "about 50 min left" / "about 2 h 10 min left" / "less than a minute left" / "finishing up", or nil
    /// without an estimate.
    var remainingText: String? {
        guard let s = secondsRemaining else { return nil }
        // Caught up to within the slack: the session is only draining its last few records.
        if s == 0 { return String(localized: "finishing up") }
        if s < 60 { return String(localized: "less than a minute left") }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return String(localized: "about \(minutes) min left") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? String(localized: "about \(h) h left") : String(localized: "about \(h) h \(m) min left")
    }
}
