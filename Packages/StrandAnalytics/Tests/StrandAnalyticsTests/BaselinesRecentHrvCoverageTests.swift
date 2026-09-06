import XCTest
@testable import StrandAnalytics

/// The counts behind "N of the last M nights recorded no HRV".
///
/// The line only helps if both numbers are right, and both are Ints with the same units, so an inverted
/// pair reads as "5 of the last 3 nights" — absurd to a person, invisible to a compiler. These pin the
/// order as well as the arithmetic. Byte-identical twin: Kotlin `RecentHrvCoverageTest`.
final class BaselinesRecentHrvCoverageTests: XCTestCase {

    /// The reported shape: five observed nights, three of them empty.
    func testCountsObservedNightsAndTheEmptyOnesAmongThem() {
        let days = ["2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05", "2026-09-06"]
        let hrv: [Double?] = [44.0, nil, nil, 47.0, nil]
        let cov = Baselines.recentHrvCoverage(dayKeys: days, nightlyHrv: hrv, today: "2026-09-06")
        XCTAssertEqual(cov.observed, 5)
        XCTAssertEqual(cov.missing, 3)
    }

    /// Only days the app has a row for, so a fresh install is not charged for nights it never saw.
    func testADayOutsideTheWindowIsNotObserved() {
        let cov = Baselines.recentHrvCoverage(dayKeys: ["2026-08-01", "2026-09-06"],
                                              nightlyHrv: [nil, nil], today: "2026-09-06", window: 14)
        XCTAssertEqual(cov.observed, 1, "the August night is 36 days back, outside the window")
        XCTAssertEqual(cov.missing, 1)
    }

    /// A future-dated row cannot be a night that already happened.
    func testADayAfterTodayIsIgnored() {
        let cov = Baselines.recentHrvCoverage(dayKeys: ["2026-09-07"], nightlyHrv: [nil],
                                              today: "2026-09-06")
        XCTAssertEqual(cov.observed, 0)
        XCTAssertEqual(cov.missing, 0)
    }

    /// Every night counted: the caller must then say nothing extra.
    func testACompleteWindowReportsNothingMissing() {
        let cov = Baselines.recentHrvCoverage(dayKeys: ["2026-09-05", "2026-09-06"],
                                              nightlyHrv: [50.0, 51.0], today: "2026-09-06")
        XCTAssertEqual(cov.observed, 2)
        XCTAssertEqual(cov.missing, 0)
    }

    /// No rows, and an unparseable today, both yield zeroes rather than a fabricated count.
    func testEmptyAndUnparseableInputsAreZero() {
        XCTAssertEqual(Baselines.recentHrvCoverage(dayKeys: [], nightlyHrv: [], today: "2026-09-06").observed, 0)
        XCTAssertEqual(Baselines.recentHrvCoverage(dayKeys: ["2026-09-06"], nightlyHrv: [nil],
                                                   today: "not-a-day").observed, 0)
    }
}
