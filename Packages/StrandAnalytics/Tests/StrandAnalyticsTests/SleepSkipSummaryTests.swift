import XCTest
@testable import StrandAnalytics

/// Pins the collapsed skipped-day line (#1121). Kotlin twin: `SleepSkipSummaryTest`. The two must emit
/// byte-identical strings, so these expectations are spelled out rather than pattern-matched.
final class SleepSkipSummaryTests: XCTestCase {

    func testNothingSkippedStaysSilent() {
        XCTAssertNil(skippedSleepDaysLine([], minHrSamples: 200))
    }

    func testOneDay() {
        XCTAssertEqual(
            skippedSleepDaysLine([(day: "2026-08-25", hrSamples: 97)], minHrSamples: 200),
            "sleep SKIPPED 1 day(s) — need ≥200 hrSamples: hrSamples=97 on 1 day(s): 2026-08-25"
        )
    }

    func testGroupsByCountAscendingAndSortsDays() {
        let line = skippedSleepDaysLine([
            (day: "2026-08-07", hrSamples: 0),
            (day: "2026-08-25", hrSamples: 97),
            (day: "2026-08-05", hrSamples: 0),
        ], minHrSamples: 200)
        XCTAssertEqual(
            line,
            "sleep SKIPPED 3 day(s) — need ≥200 hrSamples: "
            + "hrSamples=0 on 2 day(s): 2026-08-05, 2026-08-07; "
            + "hrSamples=97 on 1 day(s): 2026-08-25"
        )
    }

    func testEveryDayIsListed() {
        // Lossless on purpose: a range would hide a gap, and a gap in which days lack raw HR is exactly
        // the thing an investigation is looking for.
        let days = (5...9).map { (day: String(format: "2026-08-%02d", $0), hrSamples: 0) }
        let line = skippedSleepDaysLine(days, minHrSamples: 200)!
        for d in ["2026-08-05", "2026-08-06", "2026-08-07", "2026-08-08", "2026-08-09"] {
            XCTAssertTrue(line.contains(d), "missing \(d)")
        }
    }
}
