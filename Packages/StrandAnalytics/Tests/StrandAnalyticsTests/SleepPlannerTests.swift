import XCTest
@testable import StrandAnalytics

/// Pins the display-only sleep planner. The Kotlin twin (SleepPlannerTest.kt) carries the
/// same cases and the oracle literal produced from this implementation.
final class SleepPlannerTests: XCTestCase {

    private func nights(_ rows: [(String, Double?, Double?)]) -> [(day: String, asleepMin: Double?, efficiency: Double?)] {
        rows.map { (day: $0.0, asleepMin: $0.1, efficiency: $0.2) }
    }

    func testNoPlanUnderThreeConsecutiveNights() {
        let rows = nights([("2026-10-17", 420, 0.9), ("2026-10-19", 430, 0.9), ("2026-10-20", 440, 0.9)])
        XCTAssertNil(SleepPlanner.plan(nights: rows, baseNeedMin: 480, debtMin: 0, napMinToday: 0, wakeMinuteOfDay: 420))
    }

    func testConsecutiveRunIgnoresEmptyRowsAndDuplicates() {
        let rows: [(day: String, asleepMin: Double?)] = [
            ("2026-10-16", 400), ("2026-10-17", nil), ("2026-10-18", 410),
            ("2026-10-19", 420), ("2026-10-19", 30), ("2026-10-20", 430), ("2026-10-21", nil),
        ]
        XCTAssertEqual(SleepPlanner.consecutiveNights(rows), 3)
    }

    func testConsecutiveRunCrossesMonthAndLeapDay() {
        let rows: [(day: String, asleepMin: Double?)] = [("2024-02-28", 400), ("2024-02-29", 400), ("2024-03-01", 400)]
        XCTAssertEqual(SleepPlanner.consecutiveNights(rows), 3)
        XCTAssertEqual(SleepPlanner.epochDay("1970-01-01"), 0)
        XCTAssertEqual(SleepPlanner.epochDay("2026-10-20"), 20_746)
        XCTAssertNil(SleepPlanner.epochDay("2026-13-01"))
    }

    func testTiersWithEfficiencyAndBedtimeWrap() throws {
        let rows = nights([("2026-10-18", 420, 90), ("2026-10-19", 400, 0.88), ("2026-10-20", 450, 0.92)])
        let plan = try XCTUnwrap(SleepPlanner.plan(nights: rows, baseNeedMin: 480, debtMin: 40, napMinToday: 0, wakeMinuteOfDay: 390))
        XCTAssertEqual(plan.tonightNeedMin, 520)
        XCTAssertEqual(plan.efficiencyUsed, 0.9, accuracy: 1e-12)
        XCTAssertEqual(plan.tiers.map(\.sleepTargetMin), [364, 442, 520])
        XCTAssertEqual(plan.tiers.map(\.timeInBedMin), [404, 491, 578])
        // 06:30 wake − 578 min in bed = 20:52 the evening before.
        XCTAssertEqual(plan.tiers.map(\.bedtimeMinuteOfDay), [1426, 1339, 1252])
    }

    func testNapsOnlyRepayDebt() throws {
        let rows = nights([("2026-10-18", 420, nil), ("2026-10-19", 400, nil), ("2026-10-20", 450, nil)])
        let plan = try XCTUnwrap(SleepPlanner.plan(nights: rows, baseNeedMin: 480, debtMin: 30, napMinToday: 90, wakeMinuteOfDay: 420))
        XCTAssertEqual(plan.napCreditMin, 30)
        XCTAssertEqual(plan.tonightNeedMin, 480)
        // No efficiency history: time in bed equals the target.
        XCTAssertEqual(plan.efficiencyUsed, 1.0)
        XCTAssertEqual(plan.tiers.last?.timeInBedMin, 480)
    }

    func testEfficiencyMedianAndClamp() {
        XCTAssertEqual(SleepPlanner.typicalEfficiency([0.8, nil, 0.9, 95, 0.0]) ?? -1, 0.9, accuracy: 1e-12)
        XCTAssertEqual(SleepPlanner.typicalEfficiency([0.2, 0.3]) ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertNil(SleepPlanner.typicalEfficiency([nil, 0]))
    }
}
