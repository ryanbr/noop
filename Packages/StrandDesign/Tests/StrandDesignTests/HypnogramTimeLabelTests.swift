import XCTest
@testable import StrandDesign

/// Pins `Hypnogram.timeLabel` against the exact regression it used to have: subtracting `origin`
/// (`intervals.first?.start`) forced the leading axis label to always read as `nightStart` verbatim,
/// no matter where the first VISIBLE interval's own timestamp actually fell. That is harmless for an
/// ordinary night (the first stage code lands a few seconds after onset), but for a holed/partial
/// timeline — the surviving stages start hours into the night — it mislabeled the LAST part of a night
/// as its FIRST, which is exactly what a real corrupted `sleepSession` row rendered as.
final class HypnogramTimeLabelTests: XCTestCase {

    /// A holed timeline: the only two surviving stage segments start 8h10m11s (29,411s) into the night,
    /// not at its true onset. Real shape from a night whose stored hypnogram was overwritten with a
    /// tail slice: the segments carry real timestamps, but they are not the night's first.
    private let holedIntervals = [
        SleepInterval(stage: .light, start: 29_411, end: 31_061),
        SleepInterval(stage: .rem, start: 31_061, end: 31_091),
    ]

    func testElapsedLabelReadsTheIntervalsOwnTimeNotZero() {
        let h = Hypnogram(intervals: holedIntervals, nightStart: nil, showsTimeAxis: true, smoothingSeconds: 0)
        // 29,411s = 8h 10m (11s dropped by the H:MM format) — the segment's TRUE elapsed offset.
        XCTAssertEqual(h.timeLabel(holedIntervals[0].start), "8:10",
                       "the leading label must read the interval's own elapsed time, not 0:00")
    }

    func testWallClockLabelReadsTheIntervalsOwnTimeNotNightStart() {
        let nightStart = Date(timeIntervalSince1970: 1_788_551_940)   // 2026-09-04 19:59:00 UTC
        let h = Hypnogram(intervals: holedIntervals, nightStart: nightStart, showsTimeAxis: true, smoothingSeconds: 0)

        // Independent oracle: a locally-built formatter using the SAME template `timeLabel` uses, so the
        // comparison holds regardless of the test machine's locale/12-24h setting.
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.setLocalizedDateFormatFromTemplate("jmm")

        let nightStartLabel = fmt.string(from: nightStart)
        let trueLeadingLabel = fmt.string(from: nightStart.addingTimeInterval(holedIntervals[0].start))
        XCTAssertNotEqual(nightStartLabel, trueLeadingLabel, "fixture sanity: 8h10m apart must format differently")

        XCTAssertEqual(h.timeLabel(holedIntervals[0].start), trueLeadingLabel,
                       "the leading axis label must read the segment's TRUE clock time")
        XCTAssertNotEqual(h.timeLabel(holedIntervals[0].start), nightStartLabel,
                          "must not collapse to the night's onset the way the old subtract-origin code did")
    }

    func testOrdinaryNightWithNegligibleSlackStillReadsAsTheStartOfTheNight() {
        // The common case: the first real stage code lands a few seconds after the technical onset.
        let ordinary = [
            SleepInterval(stage: .awake, start: 10, end: 370),
            SleepInterval(stage: .light, start: 370, end: 1000),
        ]
        let h = Hypnogram(intervals: ordinary, nightStart: nil, showsTimeAxis: true, smoothingSeconds: 0)
        XCTAssertEqual(h.timeLabel(ordinary[0].start), "0:00",
                       "a few seconds of slack must still round to the start of the night")
    }
}
