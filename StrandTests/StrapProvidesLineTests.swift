import XCTest
@testable import Strand

/// The line that says which scores can exist at all for the strap actually being worn.
///
/// Twin of the Kotlin `StrapProvidesLineTest`, and the expected strings are the Kotlin ones: these lines
/// exist so an Android and an Apple report compare directly, so asserting each side against itself would
/// prove only that each is self-consistent.
final class StrapProvidesLineTests: XCTestCase {

    func testAnUnbondedMGStreamsHeartDataAndNothingElse() {
        XCTAssertEqual(
            DebugDataDiagnostics.strapProvidesLine(hr: true, rr: true, motion: false, steps: false,
                                                   deviceId: "my-whoop"),
            "Provides:    HR yes · R-R yes · motion NO · steps NO (my-whoop, last 48h)"
        )
    }

    func testAFullySyncedStrapProvidesAllFour() {
        XCTAssertEqual(
            DebugDataDiagnostics.strapProvidesLine(hr: true, rr: true, motion: true, steps: true,
                                                   deviceId: "my-whoop"),
            "Provides:    HR yes · R-R yes · motion yes · steps yes (my-whoop, last 48h)"
        )
    }

    /// NO is capitalised and yes is not, deliberately: the absences are what the line exists to surface,
    /// and a reader scanning a report should catch them without reading the labels.
    func testAbsenceIsTheHalfThatStandsOut() {
        let line = DebugDataDiagnostics.strapProvidesLine(hr: true, rr: false, motion: false, steps: true,
                                                       deviceId: "my-whoop")
        XCTAssertEqual(line.components(separatedBy: "NO").count - 1, 2, line)
        XCTAssertEqual(line, "Provides:    HR yes · R-R NO · motion NO · steps yes (my-whoop, last 48h)")
    }

    /// #2012: the line asks ONE id, the active one, while every scorer reads the union of the active,
    /// canonical and computed ids. On a re-added strap or an archived spine those disagree, and the line
    /// then reads as "this install has no heart rate" when it means "the active strap id delivered none".
    /// Naming the id is what stops a reader drawing the first conclusion, which cost real triage time.
    func testTheLineNamesWhoseDataItIsDescribing() {
        XCTAssertEqual(
            "Provides:    HR NO · R-R NO · motion NO · steps NO (whoop-5A0FAKE, last 48h)",
            DebugDataDiagnostics.strapProvidesLine(hr: false, rr: false, motion: false, steps: false,
                                                   deviceId: "whoop-5A0FAKE"))
    }

    /// The funnel's heading says "latest night"; when it falls back it has to say so.
    func testTheFunnelNoteFiresOnlyWhenAnOlderNightWasAnalysed() {
        XCTAssertEqual("", DebugDataDiagnostics.funnelFallbackNote(chosenDay: "2026-09-09",
                                                                   newestDay: "2026-09-09"))
        XCTAssertEqual(
            " (NOT the latest night: 2026-09-09 carried no skin temperature)",
            DebugDataDiagnostics.funnelFallbackNote(chosenDay: "2026-09-05", newestDay: "2026-09-09"))
    }
}
