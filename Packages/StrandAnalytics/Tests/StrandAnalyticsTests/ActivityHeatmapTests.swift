import XCTest
@testable import StrandAnalytics

/// Pins the ActivityHeatmap grid builder + its calendar arithmetic. The Kotlin twin
/// (`ActivityHeatmapTest`) asserts the same shape, so the two platforms bucket days into identical
/// week-columns / weekday-rows / intensity levels.
final class ActivityHeatmapTests: XCTestCase {

    private let today = "2026-08-11" // a Tuesday (Monday-first weekday 1)

    func testGridShapeAndTodayPlacement() {
        let values = ["2026-08-11": 400.0, "2026-08-10": 100.0, "2026-08-09": 200.0]
        let g = ActivityHeatmap.build(values: values, today: today, weeks: 13)
        XCTAssertEqual(g.weeks, 13)
        XCTAssertEqual(g.columns.count, 13)
        XCTAssertTrue(g.columns.allSatisfy { $0.count == 7 })
        XCTAssertEqual(g.scale, 400.0)   // p90 of [100,200,400] = 400 ≥ floor 250

        // The rightmost column is the current week; today sits at weekday row 1, Monday at row 0.
        let last = g.columns[12]
        XCTAssertEqual(last[1].day, "2026-08-11")
        XCTAssertEqual(last[1].value, 400.0)
        XCTAssertEqual(last[1].level, 4)          // max → level 4
        XCTAssertEqual(last[0].day, "2026-08-10")
        XCTAssertEqual(last[0].level, 1)          // 100/400 → level 1
        // Future days in the current week are empty pad cells.
        XCTAssertNil(last[2].day)
        XCTAssertEqual(last[2].level, 0)

        // The first column starts 13 weeks back on a Monday; no value → no-data cell.
        XCTAssertEqual(g.columns[0][0].day, "2026-05-18")
        XCTAssertEqual(g.columns[0][0].level, 0)
    }

    func testLevelBuckets() {
        XCTAssertEqual(ActivityHeatmap.levelFor(nil, 400.0), 0)    // no data
        XCTAssertEqual(ActivityHeatmap.levelFor(0.0, 400.0), 1)    // present but zero → 1
        XCTAssertEqual(ActivityHeatmap.levelFor(100.0, 400.0), 1)  // 25%
        XCTAssertEqual(ActivityHeatmap.levelFor(200.0, 400.0), 2)  // 50%
        XCTAssertEqual(ActivityHeatmap.levelFor(300.0, 400.0), 3)  // 75%
        XCTAssertEqual(ActivityHeatmap.levelFor(400.0, 400.0), 4)  // max
        XCTAssertEqual(ActivityHeatmap.levelFor(50.0, 0.0), 1)     // no max → 1
    }

    func testCalendarArithmeticMatchesTheProlepticGregorian() {
        XCTAssertEqual(ActivityHeatmap.epochDay("2026-08-11"), 20676)
        XCTAssertEqual(ActivityHeatmap.epochDay("1970-01-01"), 0)
        XCTAssertEqual(ActivityHeatmap.civilDay(20676), "2026-08-11")
        XCTAssertEqual(ActivityHeatmap.civilDay(0), "1970-01-01")
        XCTAssertEqual(ActivityHeatmap.mondayFirstWeekday(20676), 1) // Tue
        XCTAssertEqual(ActivityHeatmap.mondayFirstWeekday(0), 3)     // 1970-01-01 = Thu
        XCTAssertNil(ActivityHeatmap.epochDay("not-a-date"))
        XCTAssertNil(ActivityHeatmap.epochDay("2026-13-40"))
    }

    func testEmptyValuesGivesAllNoData() {
        let g = ActivityHeatmap.build(values: [:], today: today, weeks: 13)
        XCTAssertTrue(g.isEmpty)
        XCTAssertEqual(g.scale, 250.0)   // no active days → the floor
        XCTAssertTrue(g.columns.flatMap { $0 }.allSatisfy { $0.level == 0 })
    }

    func testRampScaleIsPercentileFloored() {
        XCTAssertEqual(ActivityHeatmap.rampScale([]), 250.0)                    // no active days → floor
        XCTAssertEqual(ActivityHeatmap.rampScale(Array(repeating: 100.0, count: 10)), 250.0)  // p90 100 < floor
        // 9×400 + one 8000 outlier: nearest-rank p90 (rank 9 of 10) = 400, NOT the 8000 → outlier excluded.
        XCTAssertEqual(ActivityHeatmap.rampScale(Array(repeating: 400.0, count: 9) + [8000.0]), 400.0)
    }

    func testOneHugeSessionDoesNotFlattenTheGrid() {
        // 10 recent days at 300 kcal + a single 9000 kcal monster. Under the old max-scaling the 300s
        // would all wash out to level 1 (300/9000 → 1); with percentile scaling the ramp is ~300, so a
        // 300 day shades near full and the monster just caps at 4.
        var values: [String: Double] = ["2026-08-11": 9000.0]
        for i in 1...10 { values[ActivityHeatmap.civilDay(20676 - i)] = 300.0 }
        let g = ActivityHeatmap.build(values: values, today: today, weeks: 13)
        XCTAssertLessThanOrEqual(g.scale, 300.0)   // percentile, not the 9000 max
        let monster = g.columns[12][1]
        XCTAssertEqual(monster.value, 9000.0)
        XCTAssertEqual(monster.level, 4)
        // A representative 300-day is well above the washed-out level 1 the max-scale produced.
        let a300 = g.columns.flatMap { $0 }.first { $0.value == 300.0 }
        XCTAssertGreaterThanOrEqual(a300?.level ?? 0, 3)
    }
}
