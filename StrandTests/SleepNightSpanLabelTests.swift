import XCTest
import WhoopStore
@testable import Strand

/// #2199: the night caption repeated a date. @bartmuskala reported it three times, on Android.
///
/// The carousel is keyed by the night's WAKE day, so each row is one wake date and the rows are
/// unique by construction. A night that BEGINS after midnight has its onset on that same wake date,
/// so naming it by the onset made it lead with the date the row above already leads with:
///
///     1 night ago     Sun 13 → Mon 14 Sep
///     2 nights ago    Sun 13 Sep            <- leading with Sun 13 a second time
///
/// Apple was never reported, because the cross-midnight branch renders a span, so the repeat is a
/// shared LEADING date rather than an identical string and reads as coincidence. It is the same
/// defect presented more quietly. These pin the anchor so both platforms name a night identically:
/// every row leads with its own wake day minus one. Android twin: SleepHeroLogicTest.kt
/// (`afterMidnightNightDoesNotRepeatTheDateAboveIt_issue2199`).
///
/// The assertions derive their expected dates through a formatter carrying the SAME format and the
/// system locale, rather than hardcoding English. `Night.dateFmt` pins no locale, by design, so it
/// renders in the reader's; a test spelling out "Sat 12 Sep" would pass here and fail on a runner
/// configured for anywhere else. What is under test is the DATE, not its spelling.
///
/// Pure: builds `Night` values directly, no store and no view mounting.
final class SleepNightSpanLabelTests: XCTestCase {

    private let calendar = Calendar.current

    private func at(_ day: String, _ hour: Int, _ minute: Int) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let midnight = f.date(from: day)!
        return Int(midnight.timeIntervalSince1970) + hour * 3_600 + minute * 60
    }

    private func night(onset: Int, wake: Int) -> Night {
        Night(session: CachedSleepSession(startTs: onset, endTs: wake, efficiency: nil,
                                          restingHr: nil, avgHrv: nil, stagesJSON: nil,
                                          userEdited: false, startTsAdjusted: nil),
              stages: Stages(awake: 0, light: 0, deep: 0, rem: 0))
    }

    /// The date a row should lead with: its wake day minus one, rendered the way `Night.dateFmt`
    /// renders it on whatever machine is running this.
    private func expectedNightDate(wake: Int, format: String = "EEE d MMM") -> String {
        let wakeDay = Date(timeIntervalSince1970: TimeInterval(wake))
        let nightDay = calendar.date(byAdding: .day, value: -1, to: wakeDay)!
        let f = DateFormatter()
        f.dateFormat = format
        return f.string(from: nightDay)
    }

    /// Whatever a row leads with: the onset side of a span, or the whole label when it is one date.
    private func leadingDate(_ label: String) -> String {
        label.components(separatedBy: " →").first ?? label
    }

    /// The reported shape. A night beginning at 00:30 is named by the evening it belongs to, not by
    /// the calendar date its sleep began, so it cannot repeat its neighbour's date.
    func testNightBeginningAfterMidnightIsNamedByTheEveningBefore() {
        let wake = at("2026-09-13", 7, 0)
        let afterMidnight = night(onset: at("2026-09-13", 0, 30), wake: wake)
        let crossing = night(onset: at("2026-09-13", 22, 50), wake: at("2026-09-14", 6, 48))

        XCTAssertEqual(afterMidnight.spanLabel, expectedNightDate(wake: wake),
                       "#2199: an after-midnight night is named by the evening it belongs to")
        XCTAssertNotEqual(leadingDate(afterMidnight.spanLabel), leadingDate(crossing.spanLabel),
                          "#2199: it must not lead with the date the row above leads with")
    }

    /// The invariant rather than four strings: consecutive rows never share a leading date, whatever
    /// mix of cross-midnight and after-midnight nights they are. This is the property the reporter
    /// asked for, and it holds in any locale.
    func testConsecutiveNightsNeverShareALeadingDate() {
        let rows = [
            night(onset: at("2026-09-14", 22, 50), wake: at("2026-09-15", 6, 48)),
            night(onset: at("2026-09-13", 22, 50), wake: at("2026-09-14", 6, 48)),
            night(onset: at("2026-09-13", 0, 30), wake: at("2026-09-13", 7, 0)),
            night(onset: at("2026-09-12", 0, 30), wake: at("2026-09-12", 7, 0)),
        ]
        var seen: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let leading = leadingDate(row.spanLabel)
            if let owner = seen[leading] {
                XCTFail("rows \(owner) and \(index) both lead with \(leading): \(row.spanLabel)")
            }
            seen[leading] = index
        }
    }

    /// Every row leads with its own wake day minus one, which is the anchor Android prints.
    func testEveryRowLeadsWithItsOwnWakeDayMinusOne() {
        let wakes = [at("2026-09-15", 6, 48), at("2026-09-14", 6, 48),
                     at("2026-09-13", 7, 0), at("2026-09-12", 7, 0)]
        let onsets = [at("2026-09-14", 22, 50), at("2026-09-13", 22, 50),
                      at("2026-09-13", 0, 30), at("2026-09-12", 0, 30)]
        for (onset, wake) in zip(onsets, wakes) {
            let label = night(onset: onset, wake: wake).spanLabel
            // A span leads with "EEE d", dropping the month its wake side carries; a single date
            // spells the month. Compare against whichever this row is, exactly: `hasPrefix` would
            // let "Sun 1" pass against "Sun 13 Sep".
            let expected = expectedNightDate(wake: wake,
                                             format: label.contains("→") ? "EEE d" : "EEE d MMM")
            XCTAssertEqual(leadingDate(label), expected,
                           "row leading \(leadingDate(label)) should name \(expected): \(label)")
        }
    }

    /// A cross-midnight night keeps its span: it states both ends, which is more than the anchor
    /// needs, and changing it was never part of the report.
    func testCrossMidnightNightKeepsItsSpan() {
        let crossing = night(onset: at("2026-09-13", 22, 50), wake: at("2026-09-14", 6, 48))
        XCTAssertTrue(crossing.spanLabel.contains("→"),
                      "the cross-midnight span is unchanged, got \(crossing.spanLabel)")
    }
}
