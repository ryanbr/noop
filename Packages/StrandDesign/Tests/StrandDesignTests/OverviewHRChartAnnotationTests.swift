#if !os(watchOS)
import XCTest
import SwiftUI
@testable import StrandDesign

/// Deep Timeline annotation parity (#979 spin-off): the pure span-scoping that decides WHICH sleep
/// band and workout glyphs annotate a visible day window. These mirror the classic Today's picks
/// (longest overlapping sleep = the main night; edge-inclusive workout overlap), so the two whole-day
/// charts can never disagree about what a day looked like.
final class OverviewHRChartAnnotationTests: XCTestCase {

    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
    private func sleep(_ lo: TimeInterval, _ hi: TimeInterval, label: String? = nil) -> OverviewHRChart.SleepSpan {
        .init(start: date(lo), end: date(hi), label: label)
    }
    private func workout(_ lo: TimeInterval, _ hi: TimeInterval) -> OverviewHRChart.WorkoutSpan {
        .init(start: date(lo), end: date(hi), symbol: "figure.run")
    }

    /// A day window: 86 400 s starting at t=100 000 (arbitrary epoch, values only matter relatively).
    private let day: ClosedRange<Date> = Date(timeIntervalSince1970: 100_000)...Date(timeIntervalSince1970: 186_400)

    func testRebuiltWorkoutAnnotationsKeepIdentity() {
        let original = workout(110_000, 113_600)
        XCTAssertEqual(original.id, workout(110_000, 113_600).id)
        XCTAssertNotEqual(original.id, workout(110_000, 114_000).id)
        let otherSport = OverviewHRChart.WorkoutSpan(start: original.start, end: original.end,
                                                     symbol: "figure.walk")
        XCTAssertNotEqual(original.id, otherSport.id)
        let saved = OverviewHRChart.WorkoutSpan(start: original.start, end: original.end,
                                                symbol: "figure.run", sport: "Running", source: "manual")
        let imported = OverviewHRChart.WorkoutSpan(start: original.start, end: original.end,
                                                   symbol: "figure.run", sport: "Running", source: "import")
        XCTAssertNotEqual(saved.id, imported.id, "Coincident annotations from different sources remain distinct")
    }

    func testVerticalScrollingDoesNotPanTheChart() {
        for dx in [-8.0, 0, 8] {
            for dy in [-30.0, 30] {
                XCTAssertFalse(OverviewHRChart.isHorizontalPan(CGSize(width: dx, height: dy)))
            }
        }
        XCTAssertFalse(OverviewHRChart.isHorizontalPan(.zero))
        XCTAssertFalse(OverviewHRChart.isHorizontalPan(CGSize(width: 20, height: 20)))
        XCTAssertTrue(OverviewHRChart.isHorizontalPan(CGSize(width: -30, height: 8)))
        XCTAssertTrue(OverviewHRChart.isHorizontalPan(CGSize(width: 30, height: -8)))
    }

    // MARK: mainSleep — the main night, never a nap

    /// The LONGEST overlapping block wins, exactly like the classic Today: a 7h night beats a 40m nap.
    func testMainSleepPicksLongestOverlappingBlock() {
        let night = sleep(95_000, 120_200, label: "7:00")     // 25 200 s = 7h, straddles the day start
        let nap = sleep(150_000, 152_400, label: "0:40")      // 2 400 s afternoon nap
        let picked = OverviewHRChart.mainSleep([nap, night], overlapping: day)
        XCTAssertEqual(picked?.start, night.start)
        XCTAssertEqual(picked?.end, night.end)
        XCTAssertEqual(picked?.label, "7:00")
    }

    /// A night that merely STRADDLES the window edge still counts (the pre-midnight onset case #144
    /// lives on) — overlap, not containment.
    func testMainSleepKeepsStraddlingNight() {
        let night = sleep(80_000, 110_000)                    // starts well before the day, ends inside
        XCTAssertNotNil(OverviewHRChart.mainSleep([night], overlapping: day))
    }

    /// Blocks entirely OUTSIDE the window never band it — including exact edge-touching ones, which
    /// contribute zero visible band (mirrors Today's strict `>` / `<` sleep filter).
    func testMainSleepDropsNonOverlappingAndEdgeTouching() {
        let before = sleep(10_000, 50_000)
        let endsAtStart = sleep(90_000, 100_000)              // ends exactly at window start → zero band
        let startsAtEnd = sleep(186_400, 190_000)             // starts exactly at window end → zero band
        let after = sleep(200_000, 220_000)
        XCTAssertNil(OverviewHRChart.mainSleep([before, endsAtStart, startsAtEnd, after], overlapping: day))
    }

    /// Empty candidates → nil, never a fabricated band.
    func testMainSleepEmptyIsNil() {
        XCTAssertNil(OverviewHRChart.mainSleep([], overlapping: day))
    }

    // MARK: workouts — edge-inclusive overlap, order preserved

    /// Overlapping workouts are kept in their supplied order; disjoint ones are dropped.
    func testWorkoutsKeepsOverlappingInOrder() {
        let morning = workout(110_000, 113_600)
        let evening = workout(170_000, 173_600)
        let lastWeek = workout(10_000, 13_600)
        let kept = OverviewHRChart.workouts([morning, lastWeek, evening], overlapping: day)
        XCTAssertEqual(kept.map(\.start), [morning.start, evening.start])
    }

    /// Edge-TOUCHING workouts are kept (inclusive `>=` / `<=`, mirroring Today's workout filter — a
    /// session ending exactly at midnight still belongs to the day it filled).
    func testWorkoutsKeepsEdgeTouching() {
        let endsAtStart = workout(96_400, 100_000)            // ends exactly at the window start
        let startsAtEnd = workout(186_400, 190_000)           // starts exactly at the window end
        let kept = OverviewHRChart.workouts([endsAtStart, startsAtEnd], overlapping: day)
        XCTAssertEqual(kept.count, 2)
    }

    /// A workout spanning the WHOLE window (an ultra, a long hike) is kept.
    func testWorkoutsKeepsWindowSpanning() {
        let ultra = workout(90_000, 200_000)
        XCTAssertEqual(OverviewHRChart.workouts([ultra], overlapping: day).count, 1)
    }

    func testWorkoutsEmptyIsEmpty() {
        XCTAssertTrue(OverviewHRChart.workouts([], overlapping: day).isEmpty)
    }
}
#endif
