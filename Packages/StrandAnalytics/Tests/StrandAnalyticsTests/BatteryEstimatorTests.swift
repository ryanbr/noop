import XCTest
@testable import StrandAnalytics

final class BatteryEstimatorTests: XCTestCase {

    private let h = 3600

    func testNilWhenNoReadings() {
        XCTAssertNil(BatteryEstimator.estimate(readings: [], ratedLifeHours: BatteryEstimator.ratedLifeHoursWhoop5))
    }

    func testMeasuredRateFromCleanDischarge() {
        // 100% → 90% over 10 h = 1 %/h; at 90% → 90 h left, from the user's OWN discharge.
        let e = BatteryEstimator.estimate(readings: [(0, 100), (10 * h, 90)],
                                          ratedLifeHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 90, accuracy: 1e-6)
        XCTAssertEqual(e.currentSoc, 90, accuracy: 1e-6)
    }

    func testRatedFallbackWhenSpanTooShort() {
        // One reading (no span) → rated: 50 / (100/108) = 54 h.
        let e = BatteryEstimator.estimate(readings: [(0, 50)],
                                          ratedLifeHours: BatteryEstimator.ratedLifeHoursWhoop4)!
        XCTAssertEqual(e.source, .rated)
        XCTAssertEqual(e.remainingHours, 54, accuracy: 1e-6)
    }

    func testChargeRestartsTheDischargeRun() {
        // discharge 100→70, a CHARGE back to 100, then 100→88 over 6 h. Rate is fit on the post-charge
        // segment (2 %/h), NOT across the charge.
        let e = BatteryEstimator.estimate(readings: [(0, 100), (4 * h, 70), (5 * h, 100), (11 * h, 88)],
                                          ratedLifeHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 44, accuracy: 1e-6)   // 88 / 2
    }

    func testRatedFallbackWhenDropTooSmall() {
        // 100→99 over 10 h: 1% drop < minDropPct(2) → rated, not a wild ~1000 h.
        let e = BatteryEstimator.estimate(readings: [(0, 100), (10 * h, 99)],
                                          ratedLifeHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .rated)
        XCTAssertEqual(e.remainingHours, 285.12, accuracy: 1e-6)   // 99 / (100/288) — anchored to the latest SoC
    }

    func testLabelSwitchesHoursToDaysAt48h() {
        XCTAssertEqual(BatteryEstimator.label(hours: 14), "~14 h")
        XCTAssertEqual(BatteryEstimator.label(hours: 108), "~4.5 days")
    }
}
