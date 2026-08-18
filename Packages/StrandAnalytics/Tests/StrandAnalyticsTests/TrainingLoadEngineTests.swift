import Foundation
import XCTest
@testable import StrandAnalytics

final class TrainingLoadEngineTests: XCTestCase {
    func testConstantLoadConvergesExactlyToLoadAndZeroBalance() {
        let result = TrainingLoadEngine.evaluateDense(Array(repeating: 50, count: 42))
        XCTAssertEqual(result.state, .established)
        XCTAssertNil(result.unavailableReason)
        XCTAssertEqual(result.contiguousDays, 42)
        XCTAssertEqual(result.points.count, 36)
        XCTAssertEqual(result.ctl!, 50, accuracy: 1e-12)
        XCTAssertEqual(result.atl!, 50, accuracy: 1e-12)
        XCTAssertEqual(result.tsb!, 0, accuracy: 1e-12)
    }

    func testStepUpRaisesAcuteLoadFasterThanChronicLoad() {
        let loads = Array(repeating: 50.0, count: 7) + Array(repeating: 100.0, count: 7)
        let result = TrainingLoadEngine.evaluateDense(loads)

        XCTAssertEqual(result.state, .building)
        XCTAssertEqual(result.contiguousDays, 14)
        XCTAssertEqual(result.ctl!, 57.67591375546929, accuracy: 1e-10)
        XCTAssertEqual(result.atl!, 81.6060279414279, accuracy: 1e-10)
        XCTAssertEqual(result.tsb!, -23.930114185958608, accuracy: 1e-10)
        XCTAssertGreaterThan(result.atl!, result.ctl!)
        XCTAssertLessThan(result.tsb!, 0)
    }

    func testStepDownProducesPositiveBalanceAsAcuteLoadFallsFaster() {
        let loads = Array(repeating: 100.0, count: 7) + Array(repeating: 20.0, count: 14)
        let result = TrainingLoadEngine.evaluateDense(loads)
        XCTAssertEqual(result.state, .building)
        XCTAssertGreaterThan(result.ctl!, result.atl!)
        XCTAssertGreaterThan(result.tsb!, 0)
    }

    func testMinimumAndEstablishedHistoryBoundariesAreExplicit() {
        let thirteen = TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 13))
        XCTAssertEqual(thirteen.state, .unavailable)
        XCTAssertEqual(thirteen.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(thirteen.contiguousDays, 13)
        XCTAssertTrue(thirteen.points.isEmpty)

        let fourteen = TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 14))
        XCTAssertEqual(fourteen.state, .building)
        XCTAssertEqual(fourteen.contiguousDays, 14)

        let fortyTwo = TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 42))
        XCTAssertEqual(fortyTwo.state, .established)
    }

    func testRealZeroLoadDayIsObservedRatherThanTreatedAsMissing() {
        var loads = Array(repeating: 50.0, count: 13)
        loads.append(0)
        let result = TrainingLoadEngine.evaluateDense(loads)
        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.contiguousDays, 14)
        XCTAssertEqual(result.points.last?.load, 0)
        XCTAssertLessThan(result.atl!, 50)
    }

    func testMissingLoadBreaksContiguousSuffixInsteadOfInventingZero() {
        var days: [TrainingLoadEngine.DailyLoad] = []
        for day in 1...20 {
            days.append(.init(day: String(format: "2026-07-%02d", day), load: day == 12 ? nil : 50))
        }
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(result.contiguousDays, 8)
        XCTAssertEqual(result.startDay, "2026-07-13")
        XCTAssertEqual(result.endDay, "2026-07-20")
    }

    func testMissingCalendarDayBreaksSuffixRatherThanCompressingTime() {
        var days: [TrainingLoadEngine.DailyLoad] = []
        for day in 1...20 where day != 15 {
            days.append(.init(day: String(format: "2026-06-%02d", day), load: 50))
        }
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(result.contiguousDays, 5)
        XCTAssertEqual(result.startDay, "2026-06-16")
    }

    func testExplicitTargetUsesOnlyHistoryThroughThatDay() {
        let days = (1...25).map {
            TrainingLoadEngine.DailyLoad(day: String(format: "2026-05-%02d", $0), load: Double($0))
        }
        let result = TrainingLoadEngine.evaluate(days: days, through: "2026-05-20")
        XCTAssertEqual(result.contiguousDays, 20)
        XCTAssertEqual(result.endDay, "2026-05-20")
        XCTAssertEqual(result.points.last?.day, "2026-05-20")
    }

    func testMissingExplicitTargetFailsClosed() {
        let days = (1...20).map {
            TrainingLoadEngine.DailyLoad(day: String(format: "2026-04-%02d", $0), load: 50)
        }
        let result = TrainingLoadEngine.evaluate(days: days, through: "2026-04-25")
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.unavailableReason, .missingTargetDay)
    }

    func testInputOrderDoesNotChangeResult() {
        let days = (1...20).map {
            TrainingLoadEngine.DailyLoad(day: String(format: "2026-03-%02d", $0), load: Double(20 + $0))
        }
        XCTAssertEqual(TrainingLoadEngine.evaluate(days: days),
                       TrainingLoadEngine.evaluate(days: Array(days.reversed())))
    }

    func testMalformedDuplicateNegativeAndNonFiniteInputFailClosed() {
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [.init(day: "2026-02-30", load: 10)]).unavailableReason,
            .invalidDay
        )
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [
                .init(day: "2026-02-01", load: 10), .init(day: "2026-02-01", load: 11),
            ]).unavailableReason,
            .duplicateDay
        )
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [.init(day: "2026-02-01", load: -1)]).unavailableReason,
            .invalidLoad
        )
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [.init(day: "2026-02-01", load: .nan)]).unavailableReason,
            .invalidLoad
        )
    }

    func testInvalidConfigurationFailsClosed() {
        let bad = TrainingLoadEngine.Configuration(chronicTimeConstantDays: 0)
        let result = TrainingLoadEngine.evaluateDense(Array(repeating: 50, count: 42), configuration: bad)
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.unavailableReason, .invalidConfiguration)
    }

    func testLeapDayAndMonthBoundaryStayContiguousWithoutTimezoneMath() {
        let days = [
            "2024-02-22", "2024-02-23", "2024-02-24", "2024-02-25", "2024-02-26", "2024-02-27",
            "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-02", "2024-03-03", "2024-03-04",
            "2024-03-05", "2024-03-06",
        ].map { TrainingLoadEngine.DailyLoad(day: $0, load: 30) }
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.state, .building)
        XCTAssertEqual(result.contiguousDays, 14)
        XCTAssertEqual(result.ctl!, 30, accuracy: 1e-12)
        XCTAssertEqual(result.atl!, 30, accuracy: 1e-12)
    }
}
