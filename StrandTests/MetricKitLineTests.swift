import XCTest
@testable import Strand

/// The strap-log lines for iOS's MetricKit reports say only what iOS reported, in words a person can read.
final class MetricKitLineTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let begin = Date(timeIntervalSince1970: 1_790_035_200)   // 2026-09-22 00:00 UTC

    func testADayReadsAsOneLine() {
        var day = MetricKitLine.Day(begin: begin, end: begin.addingTimeInterval(86_400), appVersion: "11.8.0")
        day.foreground = 4_320
        day.background = 34_800
        day.cpu = 372
        day.peakMemoryBytes = 180 * 1_048_576
        day.diskWriteBytes = 1_536 * 1_048_576
        day.hangs = 3
        day.exits = [.init(reason: "normal", count: 4), .init(reason: "CPU limit", count: 1),
                     .init(reason: "crash", count: 0)]
        XCTAssertEqual(MetricKitLine.day(day, timeZone: utc),
                       "MetricKit day 2026-09-22 00:00 → 2026-09-23 00:00 (NOOP 11.8.0): foreground 1h 12m, "
                       + "background 9h 40m, CPU 6m 12s, peak memory 180 MB, disk writes 1.5 GB, hangs 3, "
                       + "exits: normal 4, CPU limit 1")
    }

    /// A field MetricKit left out is left out of the line — never printed as a zero it did not report.
    func testWhatIOSDidNotReportIsNotPrinted() {
        let day = MetricKitLine.Day(begin: begin, end: begin.addingTimeInterval(86_400), appVersion: "11.8.0")
        XCTAssertEqual(MetricKitLine.day(day, timeZone: utc),
                       "MetricKit day 2026-09-22 00:00 → 2026-09-23 00:00 (NOOP 11.8.0): exits: none")
    }

    func testADiagnosticNamesItsKind() {
        XCTAssertEqual(MetricKitLine.diagnostic("CPU exception", appVersion: "11.8.0", at: begin,
                                                detail: "48s of CPU in 1m 0s", timeZone: utc),
                       "MetricKit CPU exception (NOOP 11.8.0, reported 2026-09-22 00:00): 48s of CPU in 1m 0s")
    }

    func testDurationsAndSizes() {
        XCTAssertEqual(MetricKitLine.duration(2.44), "2.4s")
        XCTAssertEqual(MetricKitLine.duration(3), "3s")
        XCTAssertEqual(MetricKitLine.duration(48), "48s")
        XCTAssertEqual(MetricKitLine.duration(372), "6m 12s")
        XCTAssertEqual(MetricKitLine.duration(34_800), "9h 40m")
        XCTAssertEqual(MetricKitLine.duration(.nan), "?")
        XCTAssertEqual(MetricKitLine.bytes(180 * 1_048_576), "180 MB")
        XCTAssertEqual(MetricKitLine.bytes(1_536 * 1_048_576), "1.5 GB")
    }
}
