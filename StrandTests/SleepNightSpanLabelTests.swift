import XCTest
import WhoopStore
@testable import Strand

/// #2199: the night caption repeated a date. @bartmuskala reported it three times, on Android.
///
/// The carousel is keyed by the night's WAKE day, so each row is one wake date and the rows are
/// unique by construction. A night that BEGINS after midnight has its onset on that same wake date,
/// so naming it by the onset made it repeat the date the row above already leads with:
///
///     1 night ago     Sun 13 → Mon 14 Sep
///     2 nights ago    Sun 13 Sep            <- the after-midnight row, leading with Sun 13 again
///
/// Apple was never reported, because the cross-midnight branch renders a span and the repeat is a
/// shared leading date rather than an identical string. It is the same defect presented more
/// quietly. These pin the anchor on this side so the two platforms name a night identically:
/// EVERY row leads with its own wake day minus one. Android twin: SleepHeroLogicTest.kt
/// (`afterMidnightNightDoesNotRepeatTheDateAboveIt_issue2199`).
///
/// Pure: builds `Night` values directly, no store and no view mounting.
final class SleepNightSpanLabelTests: XCTestCase {

    private func at(_ day: String, _ hour: Int, _ minute: Int) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let midnight = f.date(from: day)!
        return Int(midnight.timeIntervalSince1970) + hour * 3_600 + minute * 60
    }

    private func night(onset: Int, wake: Int) -> Night {
        Night(session: CachedSleepSession(startTs: onset, endTs: wake, efficiency: nil,
                                          restingHr: nil, avgHrv: nil, stagesJSON: nil,
                                          userEdited: false, startTsAdjusted: nil),
              stages: Stages(awake: 0, light: 0, deep: 0, rem: 0))
    }

    /// The reported shape. A night beginning at 00:30 must not print the date its neighbour leads
    /// with; it is named by the evening it belongs to.
    func testNightBeginningAfterMidnightIsNamedByTheEveningBefore() {
        let crossing = night(onset: at("2026-09-13", 22, 50), wake: at("2026-09-14", 6, 48))
        let afterMidnight = night(onset: at("2026-09-13", 0, 30), wake: at("2026-09-13", 7, 0))

        let crossingLeads = crossing.spanLabel.components(separatedBy: " →").first
        XCTAssertEqual(crossingLeads, "Sun 13",
                       "a cross-midnight night already leads with its wake day minus one")
        XCTAssertEqual(afterMidnight.spanLabel, "Sat 12 Sep",
                       "#2199: an after-midnight night is named by the evening it belongs to")
        XCTAssertNotEqual(String(afterMidnight.spanLabel.prefix(6)), "Sun 13",
                          "#2199: it must not repeat the date the row above leads with")
    }

    /// The invariant rather than the four strings: consecutive rows cannot share a leading date,
    /// whatever mix of cross-midnight and after-midnight nights they are.
    func testConsecutiveNightsNeverShareALeadingDate() {
        let rows = [
            night(onset: at("2026-09-14", 22, 50), wake: at("2026-09-15", 6, 48)),
            night(onset: at("2026-09-13", 22, 50), wake: at("2026-09-14", 6, 48)),
            night(onset: at("2026-09-13", 0, 30), wake: at("2026-09-13", 7, 0)),
            night(onset: at("2026-09-12", 0, 30), wake: at("2026-09-12", 7, 0)),
        ]
        var seen: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let leading = String(row.spanLabel.prefix(6))
            if let owner = seen[leading] {
                XCTFail("rows \(owner) and \(index) both lead with \(leading): \(row.spanLabel)")
            }
            seen[leading] = index
        }
    }

    /// A cross-midnight night keeps its span: it states both ends, which is strictly more than the
    /// anchor needs, and changing it was never part of the report.
    func testCrossMidnightNightKeepsItsSpan() {
        let crossing = night(onset: at("2026-09-13", 22, 50), wake: at("2026-09-14", 6, 48))
        XCTAssertTrue(crossing.spanLabel.contains("→"),
                      "the cross-midnight span is unchanged, got \(crossing.spanLabel)")
    }
}
