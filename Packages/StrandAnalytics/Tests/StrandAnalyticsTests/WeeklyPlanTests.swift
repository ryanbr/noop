import XCTest
@testable import StrandAnalytics

/// Mirrored by android WeeklyPlanTest.kt - same fixtures, same expected outputs.
final class WeeklyPlanTests: XCTestCase {

    // 2026-10-21 is a Wednesday, so its week runs Mon 2026-10-19 ... Sun 2026-10-25.
    private let today = "2026-10-21"

    func testWeekdayIndexIsMondayFirst() {
        XCTAssertEqual(WeeklyPlan.weekdayIndex(Baselines.isoEpochDay("2026-10-19")!), 0)
        XCTAssertEqual(WeeklyPlan.weekdayIndex(Baselines.isoEpochDay("2026-10-25")!), 6)
        XCTAssertEqual(WeeklyPlan.weekdayIndex(0), 3)   // 1970-01-01, a Thursday
    }

    func testWeekCountsOnlyThisWeekAndPlausibleValues() {
        let days = [
            WeeklyPlan.Day(day: "2026-10-18", sleepMin: 500, strain: 15, steps: 12_000),   // last Sunday
            WeeklyPlan.Day(day: "2026-10-19", sleepMin: 430, strain: 9.9, steps: 8_000),
            WeeklyPlan.Day(day: "2026-10-20", sleepMin: 30, strain: 25, steps: 200_000),     // implausible
            WeeklyPlan.Day(day: "2026-10-21", sleepMin: 419, strain: 10, steps: 9_000),
        ]
        let w = WeeklyPlan.week(days, today: today, goals: WeeklyPlan.defaultGoals())!
        XCTAssertEqual(w.todayIndex, 2)
        XCTAssertEqual(w.mondayEpochDay, Baselines.isoEpochDay("2026-10-19"))
        let sleep = w.progress[0], effort = w.progress[1], steps = w.progress[2]
        XCTAssertEqual(sleep.hitWeekdays, [0])
        XCTAssertEqual(sleep.daysLeft, 5)          // today missed + Thu..Sun
        XCTAssertTrue(sleep.onTrack)               // 1 + 5 >= 5
        XCTAssertEqual(effort.hitWeekdays, [2])
        XCTAssertEqual(effort.daysLeft, 4)         // today already hit
        XCTAssertEqual(steps.hitWeekdays, [0, 2])
        XCTAssertFalse(steps.met)
    }

    func testOffGoalsAreDroppedAndOffTrackIsReported() {
        let goals = [WeeklyPlan.Goal(kind: .sleep, threshold: 420, targetDays: 7),
                     WeeklyPlan.Goal(kind: .steps, threshold: 8_000, targetDays: 0)]
        let w = WeeklyPlan.week([], today: today, goals: goals)!
        XCTAssertEqual(w.progress.count, 1)
        XCTAssertFalse(w.progress[0].onTrack)      // 0 + 5 < 7
        XCTAssertNil(WeeklyPlan.week([], today: "bad", goals: goals))
    }
}
