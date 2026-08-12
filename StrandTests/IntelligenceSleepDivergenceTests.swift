import XCTest
@testable import Strand

/// Pins the #674/#1244 divergence diagnostic. A COMPUTED day can carry a sleep total with zero matched
/// sessions — an edited/hand-logged block folded onto a day the detector staged nothing (often a day
/// absorbed into a neighbour's coupled window, so it never got its own pass). That total leaks to
/// Today/Coupled while the Sleep tab (session-backed) shows nothing. The line names the fold (`editFold=`)
/// so the next capture proves whether it's an orphaned edit. Pure formatter the loop calls; tested directly
/// (no store). Mirrors the Android `sleepDivergenceLogLine` so the two platforms log a byte-identical line.
@MainActor
final class IntelligenceSleepDivergenceTests: XCTestCase {

    private typealias IE = IntelligenceEngine

    func testDivergenceNamesTheEditFold() {
        // The #1244 shape: 558 min on the rollup, no matched session, folded from one edited row.
        let line = IE.sleepDivergenceLogLine(day: "2026-08-11", totalSleepMin: 558, editFold: 1)
        XCTAssertEqual(line, "sleep divergence day=2026-08-11 totalSleepMin=558 matched=0 editFold=1")
    }

    func testDivergenceWithNoEditIsAZeroFold() {
        let line = IE.sleepDivergenceLogLine(day: "2026-08-07", totalSleepMin: 0, editFold: 0)
        XCTAssertEqual(line, "sleep divergence day=2026-08-07 totalSleepMin=0 matched=0 editFold=0")
    }

    func testLineCarriesNoEmDash() {
        let line = IE.sleepDivergenceLogLine(day: "2026-08-11", totalSleepMin: 1, editFold: 0)
        XCTAssertFalse(line.contains("—"))
    }
}
