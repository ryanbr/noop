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

    // MARK: - #1193 wording is for a genuine split — NOT for a second strap's night

    /// Both over-assertions this branch has carried. It must not call a second strap's night a read
    /// failure — `DayOwnerResolver` hands each day to whichever device holds its data, so samples under
    /// that id can be perfectly normal. And it must not call the silence expected either: with a 4.0 and
    /// a 5.0 worn together the active strap can bank nothing because its handshake never completed
    /// (#1635), which looks identical from here. The line states both halves; this pins that it keeps
    /// stating both.
    func testASecondRegisteredStrapsNightStatesTheForkNeverABareVerdict() {
        let line = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "whoop-FD:4A",
            othersWithSamples: [("my-whoop", 59_304)],
            otherLiveStrapIds: ["my-whoop"])
        XCTAssertTrue(line.contains("another registered strap"))
        XCTAssertTrue(line.contains("'my-whoop' (59304 rows)"))
        XCTAssertTrue(line.contains("dayOwner"), "must point at the line that settles it")
        XCTAssertFalse(line.contains("are not being read"), "must not claim a bug")
        XCTAssertFalse(line.contains("#1193"))
        // #1635 dual-wear: it may NOT declare the silence normal outright. Wearing a 4.0 and a 5.0
        // together, the other strap's rows are present while the ACTIVE one banked nothing because its
        // handshake never completed — and this function cannot tell that from a single-strap night.
        XCTAssertTrue(line.contains("If you wore BOTH"), "must state the both-straps half")
        XCTAssertTrue(line.contains("sync is what to check"), "and name the sync as what to check")
        XCTAssertFalse(line.contains("OWNED by that strap"), "must not assert one-strap ownership")
    }

    /// An id that is NOT a live registered strap is still the #1193 split — that wording must survive.
    func testAnUnregisteredIdHoldingTheSamplesIsStillReportedAsASplit() {
        let line = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "whoop-FD:4A",
            othersWithSamples: [("my-whoop", 59_304)],
            otherLiveStrapIds: ["whoop-OTHER"])
        XCTAssertTrue(line.contains("#1193"))
        XCTAssertTrue(line.contains("are not being read"))
    }

    /// No registry supplied (the default) keeps every existing caller byte-identical.
    func testWithoutARegistryTheWordingIsUnchanged() {
        let withDefault = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "whoop-FD:4A", othersWithSamples: [("my-whoop", 59_304)])
        let explicitEmpty = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "whoop-FD:4A", othersWithSamples: [("my-whoop", 59_304)], otherLiveStrapIds: [])
        XCTAssertEqual(withDefault, explicitEmpty)
        XCTAssertTrue(withDefault.contains("#1193"))
    }

    /// Mixed: one id is a live strap, one is not — the live strap explains it, so no bug is claimed.
    func testALiveStrapAmongTheIdsWinsOverTheSplitWording() {
        let line = DebugDataDiagnostics.orphanedSamplesLine(
            activeId: "whoop-FD:4A",
            othersWithSamples: [("orphan-id", 10), ("my-whoop", 59_304)],
            otherLiveStrapIds: ["my-whoop"])
        XCTAssertTrue(line.contains("another registered strap"))
        XCTAssertTrue(line.contains("'my-whoop' (59304 rows)"))
        XCTAssertFalse(line.contains("'orphan-id'"),
                       "the orphan id is not the story when a real strap owns the night")
    }
}
