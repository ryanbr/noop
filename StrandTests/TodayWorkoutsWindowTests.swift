import XCTest
import WhoopStore
@testable import Strand

/// #1702: the Today "Latest Workouts" window, pinned to Android's contract.
///
/// Android windows the feed to `today − 13` at start of day (`TodayScreen.recentCutoff`) and says so in
/// the header. iOS showed the same section from `repo.workoutRows()`, whose default is `days: 4000` —
/// effectively all-time — under a heading that says "Latest", with a trailing count of every workout
/// ever recorded. Same account, opposite readings on the two platforms.
///
/// These pin the boundary rather than the happy path: an off-by-one here silently drops a session the
/// other platform shows, which is exactly the class of drift that produced the issue.
final class TodayWorkoutsWindowTests: XCTestCase {

    /// Fixed clock so "13 days back, start of day" is not evaluated against a moving now.
    private let now = Date(timeIntervalSince1970: 1_756_000_000)  // 2025-08-24T02:26:40Z

    /// WorkoutRow takes every field on purpose (#1444), so spell them all out.
    private func row(startingAt ts: Int) -> WorkoutRow {
        WorkoutRow(startTs: ts, endTs: ts + 1_800, sport: "Running", source: "whoop",
                   durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private var cutoffTs: Int {
        let cal = Calendar.current
        return Int(cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
    }

    func testKeepsASessionExactlyOnTheCutoff() {
        let kept = TodayView.recentWorkoutsFeed([row(startingAt: cutoffTs)], now: now)
        XCTAssertEqual(kept.count, 1, "the cutoff instant is inside the window, matching Android's >=")
    }

    func testDropsTheSecondBeforeTheCutoff() {
        let kept = TodayView.recentWorkoutsFeed([row(startingAt: cutoffTs - 1)], now: now)
        XCTAssertTrue(kept.isEmpty)
    }

    func testDropsAnAllTimeSessionThatUsedToShow() {
        // The behaviour the issue described: a session from months ago listed under "Latest".
        let threeMonthsAgo = Int(now.timeIntervalSince1970) - 90 * 86_400
        XCTAssertTrue(TodayView.recentWorkoutsFeed([row(startingAt: threeMonthsAgo)], now: now).isEmpty)
    }

    func testKeepsTodaysSession() {
        let kept = TodayView.recentWorkoutsFeed([row(startingAt: Int(now.timeIntervalSince1970))], now: now)
        XCTAssertEqual(kept.count, 1)
    }

    func testPreservesInputOrderAndDropsOnlyTheStale() {
        let recentA = Int(now.timeIntervalSince1970) - 3_600
        let recentB = Int(now.timeIntervalSince1970) - 7_200
        let stale = cutoffTs - 86_400
        let kept = TodayView.recentWorkoutsFeed([row(startingAt: recentA), row(startingAt: stale), row(startingAt: recentB)], now: now)
        XCTAssertEqual(kept.map(\.startTs), [recentA, recentB], "filtering must not reorder the feed")
    }
}
