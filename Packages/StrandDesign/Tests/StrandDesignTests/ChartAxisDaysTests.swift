import XCTest
@testable import StrandDesign

/// The Trends x-axis marks are distinct calendar days, so a date label can never print twice over itself.
///
/// The axis asked Swift Charts for a COUNT (`.automatic(desiredCount: 5)`) and let it choose the stride.
/// Over a short window the stride it chooses is sub-day, so several marks land inside one calendar day,
/// each formats to the same date, and the axis draws "Sep 21" on top of "Sep 21". The reported screenshot
/// is that duplication rather than crowding, which is why a wider card would not have helped: the same day
/// would still have been labelled more than once.
///
/// These assert the invariant itself, not a proxy for it. `xAxisDays` is a pure function over the series
/// dates, so the whole contract is checkable without Swift Charts; what no test on this side reaches is
/// Charts' own rendering.
final class ChartAxisDaysTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var day0: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_758_000_000)) }

    /// `days` calendar days, `perDay` samples inside each.
    private func series(days: Int, perDay: Int = 1) -> [Date] {
        (0..<days).flatMap { d in
            (0..<perDay).map { k in
                calendar.date(byAdding: .hour, value: d * 24 + k * (24 / max(perDay, 1)), to: day0)!
            }
        }
    }

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    /// The defect, stated directly: two marks must never format to the same date. Swept over every window
    /// the Trends ranges can ask for, because the sub-day stride only appeared at some widths.
    func testNoTwoMarksEverFallOnTheSameDay() {
        for days in 1...400 {
            let marks = ChartAxisDays.spanning(series(days: days), calendar: calendar)
            XCTAssertEqual(Set(marks.map(dayKey)).count, marks.count,
                           "two marks share a day in a \(days)-day window, which is what printed twice")
        }
    }

    /// The reported shape: a window whose samples all sit inside one day. This input used to produce five
    /// marks all carrying the same date.
    func testASingleDayOfSamplesGetsExactlyOneMark() {
        let marks = ChartAxisDays.spanning(series(days: 1, perDay: 24), calendar: calendar)
        XCTAssertEqual(marks, [day0])
    }

    /// Every mark sits at a day boundary, so none can render a time of day.
    func testEveryMarkIsDayAligned() {
        for days in [1, 2, 7, 30, 90, 365] {
            let marks = ChartAxisDays.spanning(series(days: days), calendar: calendar)
            for mark in marks {
                XCTAssertEqual(mark, calendar.startOfDay(for: mark), "\(days)-day window has an off-day mark")
            }
        }
    }

    /// The newest day is what a trend is usually read for, so it always carries a label. A stride stepping
    /// up from the lower bound does NOT give this: on a 30-day window it marks days 0/6/12/18/24 and
    /// leaves day 29 bare, which is why the marks are named outright.
    func testTheNewestDayIsAlwaysLabelled() {
        for days in 1...400 {
            let dates = series(days: days)
            let marks = ChartAxisDays.spanning(dates, calendar: calendar)
            XCTAssertEqual(marks.last, calendar.startOfDay(for: dates.max()!),
                           "newest day unlabelled in a \(days)-day window")
        }
    }

    /// Ascending, which is the order `AxisMarks(values:)` expects, and never more than the target, so the
    /// axis cannot become the smear it was by a different route.
    func testMarksAreAscendingAndBounded() {
        for days in 1...400 {
            let marks = ChartAxisDays.spanning(series(days: days), calendar: calendar)
            XCTAssertEqual(marks, marks.sorted(), "\(days)-day window is out of order")
            XCTAssertLessThanOrEqual(marks.count, 5, "\(days)-day window wants \(marks.count) marks")
            XCTAssertFalse(marks.isEmpty, "\(days)-day window has no marks at all")
        }
    }

    /// No mark may sit before the data starts, which would stretch the axis past the series.
    func testNoMarkPrecedesTheSeries() {
        for days in [2, 7, 30, 90, 365] {
            let dates = series(days: days)
            let marks = ChartAxisDays.spanning(dates, calendar: calendar)
            XCTAssertGreaterThanOrEqual(marks.first!, calendar.startOfDay(for: dates.min()!),
                                        "\(days)-day window marks before its first sample")
        }
    }

    /// Degenerate input must not produce marks the axis cannot use.
    func testEmptyAndSinglePointSeries() {
        XCTAssertTrue(ChartAxisDays.spanning([], calendar: calendar).isEmpty)
        XCTAssertEqual(ChartAxisDays.spanning([day0], calendar: calendar), [day0])
        XCTAssertEqual(ChartAxisDays.spanning([day0], targetLabels: 0, calendar: calendar), [],
                       "a nonsensical label target must not loop or divide by zero")
    }

    /// A zone that shifts its clocks AT MIDNIGHT does not break the day alignment.
    ///
    /// A day-add preserves the time of day, and on Chile's spring-forward date 00:00 does not exist, so
    /// stepping back from a start-of-day lands on 01:00. Left alone that mark is off the day boundary and
    /// every mark after it inherits the 01:00, so the tail of the axis drifts. Sweeping two years of
    /// windows in America/Santiago put 52 marks at 01:00 before each step was re-anchored.
    ///
    /// The rest of the suite runs in UTC, which has no transitions and so cannot see this at all.
    func testAZoneThatShiftsAtMidnightKeepsEveryMarkOnItsDay() {
        guard let santiago = TimeZone(identifier: "America/Santiago") else {
            return XCTFail("America/Santiago is required: it is the zone that shifts at midnight")
        }
        var chile = Calendar(identifier: .gregorian)
        chile.timeZone = santiago

        let start = chile.startOfDay(for: Date(timeIntervalSince1970: 1_690_000_000))
        for dayOffset in 0..<730 {
            let lo = chile.date(byAdding: .day, value: dayOffset, to: start)!
            for span in [6, 29, 89] {
                let hi = chile.date(byAdding: .day, value: span, to: lo)!
                let marks = ChartAxisDays.spanning([lo, hi], calendar: chile)
                for mark in marks {
                    XCTAssertEqual(mark, chile.startOfDay(for: mark),
                                   "off-day mark in a \(span)-day window starting +\(dayOffset)")
                }
                let days = marks.map { mark -> String in
                    let c = chile.dateComponents([.year, .month, .day], from: mark)
                    return "\(c.year!)-\(c.month!)-\(c.day!)"
                }
                XCTAssertEqual(Set(days).count, marks.count,
                               "two marks share a day in a \(span)-day window starting +\(dayOffset)")
            }
        }
    }

    /// The Workouts recovery chart asks for four labels rather than five, so the contract has to hold at
    /// that target too and not only at the default.
    func testTheFourLabelTargetWorkoutsUsesHoldsTheSameContract() {
        for days in 1...400 {
            let dates = series(days: days)
            let marks = ChartAxisDays.spanning(dates, targetLabels: 4, calendar: calendar)
            XCTAssertEqual(Set(marks.map(dayKey)).count, marks.count,
                           "two marks share a day at target 4 in a \(days)-day window")
            XCTAssertLessThanOrEqual(marks.count, 4, "\(days)-day window wants \(marks.count) marks at target 4")
            XCTAssertEqual(marks.last, calendar.startOfDay(for: dates.max()!),
                           "newest day unlabelled at target 4 in a \(days)-day window")
            XCTAssertFalse(marks.isEmpty)
        }
    }

    /// Distinct days are not the same thing as distinct LABELS.
    ///
    /// The day-only format the date axes use drops the year, so two marks exactly a year apart are
    /// different days that render the same string: the duplication this whole arrangement prevents,
    /// arriving by another route. Sweeping 1 to 3000 days at both label targets, 53 spans collide, the
    /// first at 1365 days, where an ALL range on about four years of history prints "Jul 10, Jul 10,
    /// Jul 9, Jul 9". `needsYear` is what the axes consult to add the year for exactly those.
    func testNeedsYearCatchesEveryMonthDayCollision() {
        for targetLabels in [4, 5] {
            for span in 1...3000 {
                let hi = calendar.date(byAdding: .day, value: span, to: day0)!
                let marks = ChartAxisDays.spanning([day0, hi], targetLabels: targetLabels, calendar: calendar)
                let monthDay = marks.map { mark -> String in
                    let c = calendar.dateComponents([.month, .day], from: mark)
                    return "\(c.month!)-\(c.day!)"
                }
                let collides = Set(monthDay).count != monthDay.count
                XCTAssertEqual(ChartAxisDays.needsYear(marks, calendar: calendar), collides,
                               "needsYear disagrees with the labels at target \(targetLabels), span \(span)")
            }
        }
    }

    /// Adding the year must actually resolve them, and must not be asked for on the ordinary windows.
    func testTheYearIsAddedOnlyWhereItIsNeededAndAlwaysResolves() {
        for targetLabels in [4, 5] {
            for span in 1...3000 {
                let hi = calendar.date(byAdding: .day, value: span, to: day0)!
                let marks = ChartAxisDays.spanning([day0, hi], targetLabels: targetLabels, calendar: calendar)
                let withYear = ChartAxisDays.needsYear(marks, calendar: calendar)
                let labels = marks.map { mark -> String in
                    let c = calendar.dateComponents([.year, .month, .day], from: mark)
                    return withYear ? "\(c.month!)-\(c.day!)-\(c.year!)" : "\(c.month!)-\(c.day!)"
                }
                XCTAssertEqual(Set(labels).count, labels.count,
                               "labels still collide at target \(targetLabels), span \(span)")
            }
        }
        // W / M / 3M / 6M / 1Y keep the shorter label.
        for span in [6, 29, 89, 182, 364] {
            let hi = calendar.date(byAdding: .day, value: span, to: day0)!
            let marks = ChartAxisDays.spanning([day0, hi], calendar: calendar)
            XCTAssertFalse(ChartAxisDays.needsYear(marks, calendar: calendar),
                           "a \(span)-day window should not need the year")
        }
    }

    /// The series is spanned by its extremes, not by its first and last element.
    func testAnUnorderedSeriesSpansByItsExtremes() {
        let ordered = series(days: 30)
        XCTAssertEqual(ChartAxisDays.spanning(ordered.shuffled(), calendar: calendar),
                       ChartAxisDays.spanning(ordered, calendar: calendar))
    }
}
