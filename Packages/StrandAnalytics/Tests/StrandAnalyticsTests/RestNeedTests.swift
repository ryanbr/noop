import XCTest
@testable import StrandAnalytics

/// `AnalyticsEngine.Rest.personalizedNeedHours` (Wave 0 · T1) — population-anchored, age-floored
/// sleep need. The load-bearing property is the anti-self-referential guard: a chronic
/// under-sleeper's need must NOT drift down toward their own deficit (which a plain trailing mean
/// would do, inverting the honesty philosophy for exactly the users with the most sleep debt); it
/// stays anchored at the age-appropriate population floor.
final class RestNeedTests: XCTestCase {
    private typealias Rest = AnalyticsEngine.Rest

    func testChronicUnderSleeperStaysAtFloor() {
        // 14 nights of ~5.5 h. A self-referential mean returns ~5.5; the anchor must hold >= 7.0.
        let nights = Array(repeating: 5.5, count: 14)
        XCTAssertGreaterThanOrEqual(Rest.personalizedNeedHours(nightlyHours: nights, age: 30), 7.0)
    }

    func testNormalSleeperReflectsUnrestrictedNights() {
        let nights = [7.2, 7.8, 8.1, 7.5, 8.4, 7.9, 8.0, 7.6, 8.2, 7.7]
        let need = Rest.personalizedNeedHours(nightlyHours: nights, age: 35)
        XCTAssertGreaterThanOrEqual(need, 7.0)
        XCTAssertLessThanOrEqual(need, 9.5)
        // Upper-quartile, not the mean: reflects what they sleep on their longer nights.
        XCTAssertGreaterThanOrEqual(need, 7.8)
    }

    func testColdStartReturnsPopulationDefault() {
        // Fewer than minNeedNights → the population default (8.0), floored.
        XCTAssertEqual(Rest.personalizedNeedHours(nightlyHours: [7.0, 8.0, 6.5], age: 30),
                       Rest.defaultNeedHours, accuracy: 0.001)
    }

    func testCapsLongSleeper() {
        let nights = Array(repeating: 11.0, count: 10)
        XCTAssertLessThanOrEqual(Rest.personalizedNeedHours(nightlyHours: nights, age: 40), 9.5)
    }

    func testMinorHasHigherFloor() {
        let nights = Array(repeating: 6.0, count: 10)   // an under-sleeping teen
        XCTAssertGreaterThanOrEqual(Rest.personalizedNeedHours(nightlyHours: nights, age: 15), 8.0)
    }

    func testNilAgeUsesAdultFloor() {
        let nights = Array(repeating: 5.0, count: 10)
        XCTAssertGreaterThanOrEqual(Rest.personalizedNeedHours(nightlyHours: nights, age: nil), 7.0)
    }

    func testZeroAndNegativeNightsIgnored() {
        // no-data days (0) must not drag the estimate down or count toward the minimum.
        let nights = [0.0, -1.0, 7.5, 8.0, 7.8, 8.2, 7.6, 8.1, 7.9, 8.3, 0.0]
        XCTAssertGreaterThanOrEqual(Rest.personalizedNeedHours(nightlyHours: nights, age: 30), 7.5)
    }
}
