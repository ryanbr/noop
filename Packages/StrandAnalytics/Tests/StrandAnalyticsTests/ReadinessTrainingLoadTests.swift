import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ReadinessTrainingLoadTests: XCTestCase {
    private func metric(day: Int, strain: Double?, hrv: Double = 60, rhr: Int = 52) -> DailyMetric {
        DailyMetric(
            day: String(format: "2026-01-%02d", day),
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: strain,
            exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14
        )
    }

    func testPairedAPILeavesExistingReadinessExactlyUnchanged() {
        let days = (1...28).map { day in
            metric(day: day, strain: day <= 21 ? 5 : 15,
                   hrv: day.isMultiple(of: 2) ? 62 : 58,
                   rhr: day.isMultiple(of: 2) ? 54 : 50)
        }

        let existing = ReadinessEngine.evaluate(days: days)
        let paired = ReadinessEngine.evaluateWithTrainingLoad(days: days)

        XCTAssertEqual(paired.readiness, existing)
        XCTAssertTrue(paired.trainingLoad.isAvailable)
        XCTAssertEqual(paired.trainingLoad.state, .building)
        XCTAssertNotNil(paired.trainingLoad.ctl)
        XCTAssertNotNil(paired.trainingLoad.atl)
        XCTAssertNotNil(paired.trainingLoad.tsb)
    }

    func testExistingAcwrAndMonotonyRemainOwnedByReadiness() {
        let days = (1...28).map { day in
            metric(day: day, strain: day <= 21 ? 5 : Double(12 + day % 3))
        }
        let paired = ReadinessEngine.evaluateWithTrainingLoad(days: days)

        XCTAssertNotNil(paired.readiness.acwr)
        XCTAssertNotNil(paired.readiness.monotony)
        XCTAssertTrue(paired.trainingLoad.isAvailable)
        XCTAssertEqual(paired.trainingLoad.endDay, "2026-01-28")
    }

    func testMissingLoadBreaksTrainingModelWithoutSuppressingReadiness() {
        var days = (1...28).map { metric(day: $0, strain: 10) }
        // An unobserved load is not a zero-load rest day. It breaks the model's contiguous suffix, while
        // the existing Readiness engine can still synthesize its other signals from the same history.
        days[20] = metric(day: 21, strain: nil)

        let paired = ReadinessEngine.evaluateWithTrainingLoad(days: days)
        XCTAssertNotEqual(paired.readiness.level, .insufficient)
        XCTAssertEqual(paired.trainingLoad.state, .unavailable)
        XCTAssertEqual(paired.trainingLoad.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(paired.trainingLoad.contiguousDays, 7)
    }

    func testExplicitMissingTodayFailsClosedForBothAnalyses() {
        let days = (1...28).map { metric(day: $0, strain: 10) }
        let paired = ReadinessEngine.evaluateWithTrainingLoad(days: days, today: "2026-02-01")

        XCTAssertEqual(paired.readiness.level, .insufficient)
        XCTAssertEqual(paired.trainingLoad.state, .unavailable)
        XCTAssertEqual(paired.trainingLoad.unavailableReason, .missingTargetDay)
    }

    func testExplicitTodayIgnoresFutureTrainingRows() {
        let days = (1...28).map { day in metric(day: day, strain: day <= 20 ? 10 : 100) }
        let paired = ReadinessEngine.evaluateWithTrainingLoad(days: days, today: "2026-01-20")

        XCTAssertEqual(paired.trainingLoad.endDay, "2026-01-20")
        XCTAssertEqual(paired.trainingLoad.contiguousDays, 20)
        XCTAssertEqual(paired.trainingLoad.points.last?.load, 10)
    }
}
