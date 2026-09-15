import XCTest
@testable import Strand

final class DailyCoachNotifierTests: XCTestCase {
    func testBriefIncludesEveryAvailableMetric() throws {
        let brief = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: 72.2,
            rest: 88.4,
            hrv: 61.6,
            restingHR: 52,
            sleepMinutes: 479
        ))

        XCTAssertEqual(brief.charge, 72)
        XCTAssertEqual(brief.rest, 88)
        XCTAssertEqual(brief.hrvMs, 62)
        XCTAssertEqual(brief.restingHR, 52)
        XCTAssertEqual(brief.sleepHours, 8)
    }

    func testDisplayedRoundedChargeAlsoDrivesBanding() throws {
        let high = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: 66.6, rest: nil, hrv: nil, restingHR: nil, sleepMinutes: nil
        ))
        let controlled = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: 66.4, rest: nil, hrv: nil, restingHR: nil, sleepMinutes: nil
        ))

        XCTAssertEqual(high.charge, 67)
        XCTAssertEqual(high.trainingBand, .harder)
        XCTAssertEqual(controlled.charge, 66)
        XCTAssertEqual(controlled.trainingBand, .controlled)
    }

    func testBothBandBoundaries() throws {
        let recovery = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: 33.4, rest: nil, hrv: nil, restingHR: nil, sleepMinutes: nil
        ))
        let controlled = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: 33.5, rest: nil, hrv: nil, restingHR: nil, sleepMinutes: nil
        ))
        let harder = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: 66.5, rest: nil, hrv: nil, restingHR: nil, sleepMinutes: nil
        ))

        XCTAssertEqual(recovery.trainingBand, .recovery)
        XCTAssertEqual(controlled.trainingBand, .controlled)
        XCTAssertEqual(harder.trainingBand, .harder)
    }

    func testMissingChargeNeverInventsTrainingAdvice() throws {
        let brief = try XCTUnwrap(DailyCoachNotifier.makeBrief(
            recovery: nil, rest: nil, hrv: 58, restingHR: nil, sleepMinutes: nil
        ))

        XCTAssertNil(brief.charge)
        XCTAssertNil(brief.trainingBand)
    }

    func testAllMetricsMissingReturnsNil() {
        XCTAssertNil(DailyCoachNotifier.makeBrief(
            recovery: nil, rest: nil, hrv: nil, restingHR: nil, sleepMinutes: nil
        ))
    }
}
