import XCTest
@testable import StrandAnalytics

/// #2517, recorded rather than corrected: a transition day stays 86,400 seconds wide and
/// `AnalyticsEngine.dayWindowSkewLine` names the hour that puts it on.
///
/// The arithmetic is cross-checked against `LocalDayWindows`, which derives the same length from the
/// zone rules instead of from two offsets, so the cheap path and the correct one are held to one answer.
/// Kotlin twin: `AnalyticsEngineDayWindowSkewTest`.
final class AnalyticsEngineDayWindowSkewTests: XCTestCase {

    /// 363 days a year this says nothing, and saying nothing is what makes it affordable always-on.
    func testAnOrdinaryDayEmitsNothing() {
        XCTAssertNil(AnalyticsEngine.dayWindowSkewLine(day: "2026-10-24", offsetAtStart: 7_200,
                                                            offsetAtFixedEnd: 7_200))
        XCTAssertNil(AnalyticsEngine.dayWindowSkewLine(day: "2026-06-01", offsetAtStart: 0,
                                                            offsetAtFixedEnd: 0))
    }

    /// The reported case: Europe/Amsterdam, 2026-10-25, the day #2852 was filed about. CEST (+2) at the
    /// day's start, CET (+1) by the time the fixed window ends, so the local day is 25 hours and the
    /// window is an hour short of it.
    func testTheFallBackDayNamesItsExtraHour() {
        XCTAssertEqual(
            AnalyticsEngine.dayWindowSkewLine(day: "2026-10-25", offsetAtStart: 7_200,
                                                   offsetAtFixedEnd: 3_600),
            "day-window-skew day=2026-10-25 realS=90000 windowS=86400 skewMin=60 "
                + "offsetStart=7200 offsetEnd=3600 policy=keep-24h")
    }

    /// And the other direction, where the window runs an hour INTO the next local day. The sign carries
    /// it: a reader who only saw a magnitude could not tell which day gained the hour.
    func testTheSpringForwardDayNamesItsMissingHour() {
        XCTAssertEqual(
            AnalyticsEngine.dayWindowSkewLine(day: "2026-03-29", offsetAtStart: 3_600,
                                                   offsetAtFixedEnd: 7_200),
            "day-window-skew day=2026-03-29 realS=82800 windowS=86400 skewMin=-60 "
                + "offsetStart=3600 offsetEnd=7200 policy=keep-24h")
    }

    /// A 30-minute transition is why the arithmetic is a subtraction rather than a hardcoded 3,600.
    /// Lord Howe Island moves by half an hour; a constant would have called this day 24 or 25 hours.
    func testAHalfHourTransitionIsReportedAtItsRealSize() {
        let line = AnalyticsEngine.dayWindowSkewLine(day: "2026-04-05", offsetAtStart: 39_600,
                                                          offsetAtFixedEnd: 37_800)
        XCTAssertEqual(line,
                       "day-window-skew day=2026-04-05 realS=88200 windowS=86400 skewMin=30 "
                           + "offsetStart=39600 offsetEnd=37800 policy=keep-24h")
    }

    // MARK: - held to the zone-rule answer

    /// The two implementations must agree on the LENGTH. `LocalDayWindows` reads the zone rules;
    /// this line subtracts two offsets. The committed oracle pins the zone-rule answers at 90,000 and
    /// 82,800 seconds, so reproducing those from offsets alone is what makes the cheap path trustworthy.
    ///
    /// Driven through `LocalDayWindows` itself rather than against literals copied from the oracle: a
    /// literal would still pass if the helper and the primitive drifted apart, which is the one thing
    /// this test exists to catch.
    func testTheOffsetArithmeticReproducesTheZoneRuleDayLength() throws {
        for (zoneName, day) in [("America/New_York", "2025-11-02"), ("America/New_York", "2025-03-09")] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneName))
            let helper = LocalDayWindows(timeZone: zone, referenceInstant: Date(timeIntervalSince1970: 2_000_000_000))
            let parts = day.split(separator: "-").map { Int($0)! }
            let date = LocalCalendarDate(year: parts[0], month: parts[1], day: parts[2])
            let window = try XCTUnwrap(helper.window(of: date))
            let fromZoneRules = Int(window.duration)

            // The same two lookups the engine's call site makes: the offset at the day's start, and the
            // offset where a FIXED 86,400-second window would have ended.
            let offsetAtStart = zone.secondsFromGMT(for: window.start)
            let offsetAtFixedEnd = zone.secondsFromGMT(for: window.start.addingTimeInterval(86_400))
            let fromOffsets = 86_400 + (offsetAtStart - offsetAtFixedEnd)

            XCTAssertEqual(fromOffsets, fromZoneRules,
                           "\(zoneName) \(day): offset arithmetic and zone rules must agree on the length")
            XCTAssertNotEqual(fromZoneRules, 86_400, "\(day) must be a transition day, or this proves nothing")
            let line = try XCTUnwrap(AnalyticsEngine.dayWindowSkewLine(
                day: day, offsetAtStart: offsetAtStart, offsetAtFixedEnd: offsetAtFixedEnd))
            XCTAssertTrue(line.contains("realS=\(fromZoneRules)"),
                          "the line must report the zone-rule length, not a second opinion: \(line)")
        }
    }
}
