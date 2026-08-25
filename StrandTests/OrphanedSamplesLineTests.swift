import XCTest
@testable import Strand

/// #1617 follow-up: the funnel's zero-sample line must distinguish "the samples are not there" from
/// "the samples are under a different device id" (#1193/#740). The old line asserted the first
/// unconditionally, which is the wrong answer to give an investigation exactly when it matters.
///
/// Kotlin twin: `OrphanedSamplesLineTest` (`android/app/src/test/.../testcentre/`). The two must emit the
/// same strings, so these expectations are written out in full rather than pattern-matched — and the
/// literals below were generated from the verified cross-platform diff, not retyped.
final class OrphanedSamplesLineTests: XCTestCase {

    func testNoSamplesAnywhereKeepsTheFreshReAddWording() {
        XCTAssertEqual(
            DebugDataDiagnostics.orphanedSamplesLine(activeId: "my-whoop", othersWithSamples: []),
            "(no raw biometric samples under 'my-whoop' for this night — expected on a freshly re-added strap; reconnect + let a history sync run, then re-export)"
        )
    }

    func testSamplesUnderAnotherIdReportTheSplitInstead() {
        let line = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "my-whoop",
            othersWithSamples: [("whoop-F1:D4:F7:24:53:DE", 4213)]
        )
        XCTAssertEqual(line, "(no raw biometric samples under the ACTIVE id 'my-whoop' for this night — they are under 'whoop-F1:D4:F7:24:53:DE' (4213 rows) instead. The history spine and the raw stream are on different device ids (#1193); this is NOT a fresh re-add, the samples exist and are not being read.)")
        // The benign explanation must not survive anywhere in the split wording — a reader scanning the
        // log for "freshly re-added" would otherwise still stop here.
        XCTAssertFalse(line.contains("freshly re-added"))
    }

    func testSeveralHoldersAreListedHeaviestFirst() {
        let line = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "my-whoop",
            othersWithSamples: [("whoop-aa", 12), ("whoop-bb", 900), ("whoop-cc", 300)]
        )
        XCTAssertTrue(line.contains("'whoop-bb' (900 rows), 'whoop-cc' (300 rows), 'whoop-aa' (12 rows)"))
    }

    func testEqualCountsBreakTheTieOnIdSoBothPlatformsAgree() {
        // Swift's `sorted` is not a stable sort; without an explicit tie-break the twin lines could list
        // the same two ids in different orders.
        let line = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "my-whoop",
            othersWithSamples: [("whoop-zz", 50), ("whoop-aa", 50)]
        )
        XCTAssertTrue(line.contains("'whoop-aa' (50 rows), 'whoop-zz' (50 rows)"))
    }
}
