import XCTest
@testable import StrandDesign

/// A day key parsed at UTC midnight must be marked and named as its own day whatever the device zone.
///
/// In the device zone that instant is the evening before west of UTC, so a series ending 25 Aug labelled
/// its last day "Aug 24", the tooltip said Monday and the year strip put the cell on Monday's row. Each
/// test pins the process zone, so a UTC runner catches the regression too.
final class DayKeyZoneTests: XCTestCase {

    private let zones = ["Pacific/Honolulu", "America/New_York", "UTC", "Asia/Tokyo", "Pacific/Kiritimati"]

    /// 2026-08-25, a Tuesday, as the app's day-key parsers produce it.
    private let key = DayKey.calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))!

    private func inEveryZone(_ body: (String) -> Void) {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for zone in zones {
            NSTimeZone.default = TimeZone(identifier: zone)!
            body(zone)
        }
    }

    func testADayKeyRoundTripsAndFormatsAsItsOwnDay() {
        XCTAssertEqual(DayKey.date("2026-08-25"), key)
        XCTAssertEqual(DayKey.key(key), "2026-08-25")
        XCTAssertNil(DayKey.date("25 Aug"))
        inEveryZone { zone in
            XCTAssertEqual(DayKey.formatter("d MMM").string(from: key), "25 Aug", zone)
            XCTAssertEqual(DayKey.formatter(template: "dMMM", locale: Locale(identifier: "en_US")).string(from: key),
                           "Aug 25", zone)
        }
    }

    func testTheAxisMarksAndLabelsTheKeysOwnDay() {
        inEveryZone { zone in
            let marks = ChartAxisDays.spanning([key], calendar: DayKey.calendar)
            XCTAssertEqual(marks, [key], zone)
            var style = ChartAxisDays.labelFormat(for: marks, calendar: DayKey.calendar)
            // A FormatStyle ignores NSTimeZone.default (it reads the system zone), so the pinned zone
            // above cannot expose an unzoned style on a UTC runner; assert the zone itself.
            XCTAssertEqual(style.timeZone, DayKey.calendar.timeZone, zone)
            style.locale = Locale(identifier: "en_US")
            XCTAssertEqual(key.formatted(style), "Aug 25", zone)
        }
    }

    func testTheDefaultTooltipNamesTheKeysOwnDay() {
        inEveryZone { zone in
            let label = TrendChart.defaultDateString(key, timeZone: DayKey.calendar.timeZone)
            XCTAssertTrue(label.contains("25") && !label.contains("24"), "\(zone): \(label)")
        }
    }

    func testTheYearStripPutsTheKeyOnItsOwnWeekdayAndDate() {
        inEveryZone { zone in
            let dayZone = DayZone.for(DayKey.calendar.timeZone)
            XCTAssertEqual(YearHeatStrip.weekdayRow(key, calendar: dayZone.calendar), 1,
                           "\(zone): Tuesday is row 1 of a Monday-first week")
            let label = dayZone.day.string(from: key)
            XCTAssertTrue(label.contains("25") && !label.contains("24"), "\(zone): \(label)")
        }
    }

    /// Real timestamps keep the device zone: the default is unchanged for the workout charts.
    func testTheDeviceZoneStaysTheDefaultForTimestamps() {
        let marks = ChartAxisDays.spanning([key])
        XCTAssertEqual(marks, [Calendar.current.startOfDay(for: key)])
        XCTAssertEqual(ChartAxisDays.labelFormat(for: marks).timeZone, Calendar.current.timeZone)
    }
}
