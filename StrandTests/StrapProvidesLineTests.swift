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
            DebugDataDiagnostics.strapProvidesLine(hr: true, rr: true, motion: false, steps: false),
            "Provides(48h): HR yes · R-R yes · motion NO · steps NO"
        )
    }

    func testAFullySyncedStrapProvidesAllFour() {
        XCTAssertEqual(
            DebugDataDiagnostics.strapProvidesLine(hr: true, rr: true, motion: true, steps: true),
            "Provides(48h): HR yes · R-R yes · motion yes · steps yes"
        )
    }

    /// NO is capitalised and yes is not, deliberately: the absences are what the line exists to surface,
    /// and a reader scanning a report should catch them without reading the labels.
    func testAbsenceIsTheHalfThatStandsOut() {
        let line = DebugDataDiagnostics.strapProvidesLine(hr: true, rr: false, motion: false, steps: true)
        XCTAssertEqual(line.components(separatedBy: "NO").count - 1, 2, line)
        XCTAssertEqual(line, "Provides(48h): HR yes · R-R NO · motion NO · steps yes")
    }
}
