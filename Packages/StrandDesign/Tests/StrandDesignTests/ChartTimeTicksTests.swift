import XCTest
@testable import StrandDesign

/// The Swift half of a tier table written twice, in two languages: `chartTimeTicks` here and
/// `chartTimeTicks` in Kotlin `Charts.kt`, pinned there by `ChartTimeTicksTest`. Eight thresholds
/// duplicated across platforms is exactly the shape that drifts, and a drift is invisible in a build.
///
/// Only POSITIONS are compared, because only positions are shared: Swift draws its labels with
/// `AxisValueLabel()` in the viewer's locale while Kotlin formats "HH:mm" itself, so the function
/// returns dates and never formats a string.
final class ChartTimeTicksTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return calendar.date(from: c)!
    }

    /// "HH:mm" purely so a failure reads as clock times rather than as epoch seconds.
    private func hhmm(_ dates: [Date]) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return dates.map { f.string(from: $0) }
    }

    private func ticks(_ start: Date, _ end: Date, deepZoom: Bool = false) -> [String] {
        hhmm(chartTimeTicks(start: start, end: end, calendar: calendar, deepZoom: deepZoom))
    }

    // MARK: The static tiers, shared by every caller

    func testSixHourTicksAboveTwentyHours() {
        XCTAssertEqual(ticks(at(2026, 7, 9, 10, 30), at(2026, 7, 10, 10, 30)).filter { $0 == "00:00" },
                       ["00:00"], "a window crossing midnight lands on 00:00 exactly once")
    }

    func testTwoHourTicksAboveFiveHours() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 9, 30), at(2026, 7, 10, 15, 30)),
                       ["10:00", "12:00", "14:00"])
    }

    func testOneHourTicksAboveTwoHours() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 13, 10), at(2026, 7, 10, 16, 10)),
                       ["14:00", "15:00", "16:00"])
    }

    func testQuarterHourTicksOnAnHourWindow() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 14, 5), at(2026, 7, 10, 15, 5)),
                       ["14:15", "14:30", "14:45", "15:00"])
    }

    // MARK: The deep-zoom tiers, opened only by the surface that zooms

    func testFiveMinuteTicksAboveHalfAnHour() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 14, 2), at(2026, 7, 10, 14, 32), deepZoom: true),
                       ["14:05", "14:10", "14:15", "14:20", "14:25", "14:30"])
    }

    func testTwoMinuteTicksAboveTenMinutes() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 14, 1), at(2026, 7, 10, 14, 11), deepZoom: true),
                       ["14:02", "14:04", "14:06", "14:08", "14:10"])
    }

    func testOneMinuteTicksBelowTenMinutes() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 14, 0, 30), at(2026, 7, 10, 14, 5, 30), deepZoom: true),
                       ["14:01", "14:02", "14:03", "14:04", "14:05"])
    }

    /// The Today guarantee. Today's HR card shares this chart and hands it the RENDERED extent of its
    /// banked buckets, not a nominal window, so a morning holding ten minutes of HR arrives here with a
    /// ten-minute span. Without `deepZoom` the walk must stay at 15-minute steps: the per-tick dotted
    /// gridlines have no overlap-skip, so finer tiers would put ten of them on a small card.
    func testAShortWindowKeepsQuarterHourTicksWithoutDeepZoom() {
        XCTAssertEqual(ticks(at(2026, 7, 10, 14, 1), at(2026, 7, 10, 14, 11)), [],
                       "no quarter-hour boundary falls inside, so there is nothing to draw")
        XCTAssertEqual(ticks(at(2026, 7, 10, 14, 10), at(2026, 7, 10, 14, 20)), ["14:15"],
                       "one boundary inside gives exactly one tick, not six")
    }

    /// A malformed window yields nothing rather than spinning the bounded walk.
    func testAnEmptyOrInvertedWindowHasNoTicks() {
        let t = at(2026, 7, 10, 14, 0)
        XCTAssertEqual(ticks(t, t), [])
        XCTAssertEqual(ticks(at(2026, 7, 10, 15, 0), at(2026, 7, 10, 14, 0)), [])
    }
}
