import XCTest
@testable import Strand

/// #2012: the Rest "Pending sync" state is `backfilling || historyPendingSync`, and only the first half
/// left a trace. A reporter's log arrived showing the note in the afternoon, and it could only be read by
/// inferring from what else was happening at that timestamp, which settles nothing.
///
/// These pin that the line names the DECIDING input, because the four things that can decide it mean four
/// different bugs. Mirrors Android `PendingSyncDiagnosticTest` case-for-case.
final class PendingSyncDiagnosticTests: XCTestCase {
    private let threshold = 300

    func testBehindTheStrapNamesTheGapAndTheThreshold() {
        let s = PendingSyncDiagnostic.line(
            pending: true, site: PendingSyncDiagnostic.sitePostOffload,
            newestUnix: 1_788_896_010, frontierUnix: 1_788_861_800,
            futureDated: false, persistedRows: true, thresholdSec: threshold)
        XCTAssertTrue(s.hasPrefix("pending-sync ON (post-offload):"), s)
        XCTAssertTrue(s.contains("34210s ahead of our frontier"), s)
        XCTAssertTrue(s.contains("over the 300s threshold"), s)
        XCTAssertTrue(s.contains("gap=34210s"), s)
    }

    func testCaughtUpSaysSoRatherThanJustOff() {
        let s = PendingSyncDiagnostic.line(
            pending: false, site: PendingSyncDiagnostic.sitePostOffload,
            newestUnix: 1_788_896_010, frontierUnix: 1_788_896_000,
            futureDated: false, persistedRows: true, thresholdSec: threshold)
        XCTAssertTrue(s.hasPrefix("pending-sync OFF (post-offload):"), s)
        XCTAssertTrue(s.contains("caught up"), s)
    }

    func testAFutureDatedStrapClockOutranksTheGap() {
        // #928/#1012: this latches the flag on forever, so it must be named and not read as "behind".
        let s = PendingSyncDiagnostic.line(
            pending: false, site: PendingSyncDiagnostic.sitePostOffload,
            newestUnix: 2_000_000_000, frontierUnix: 1_788_896_000,
            futureDated: true, persistedRows: true, thresholdSec: threshold)
        XCTAssertTrue(s.contains("clock reads ahead of now"), s)
        XCTAssertFalse(s.contains("ahead of our frontier"), s)
    }

    func testAPhantomGapIsNamedAsSuchNotAsBeingBehind() {
        // #1144: the strap advertises newer records and banks none, so the frontier cannot advance.
        // Reading that as "behind" would send the next reader chasing an offload that will never help.
        let s = PendingSyncDiagnostic.line(
            pending: false, site: PendingSyncDiagnostic.sitePostOffload,
            newestUnix: 1_788_896_010, frontierUnix: 1_788_861_800,
            futureDated: false, persistedRows: false, thresholdSec: threshold)
        XCTAssertTrue(s.contains("phantom gap"), s)
        XCTAssertTrue(s.contains("rowsBanked=no"), s)
    }

    func testAMissingRangeStillProducesALineRatherThanASilentFlip() {
        // The Android twin flips the flag to false when either input is missing, and an unanswered
        // GET_DATA_RANGE is a real way to get there. Guarding the log on non-nil inputs would have left
        // exactly that transition silent, which is the hole this closes.
        let s = PendingSyncDiagnostic.line(
            pending: false, site: PendingSyncDiagnostic.sitePostOffload,
            newestUnix: nil, frontierUnix: 1_788_861_800,
            futureDated: false, persistedRows: true, thresholdSec: threshold)
        XCTAssertTrue(s.hasPrefix("pending-sync OFF (post-offload):"), s)
        XCTAssertTrue(s.contains("no range to compare"), s)
        XCTAssertTrue(s.contains("newest=unknown"), s)
    }

    func testTheConnectSiteSaysRowEvidenceIsUnavailableRatherThanAbsent() {
        // No offload has run there, so "no" would be a lie that reads as a phantom gap.
        let s = PendingSyncDiagnostic.line(
            pending: true, site: PendingSyncDiagnostic.siteConnect,
            newestUnix: 1_788_896_010, frontierUnix: 1_788_861_800,
            futureDated: false, persistedRows: nil, thresholdSec: threshold)
        XCTAssertTrue(s.contains("(connect)"), s)
        XCTAssertTrue(s.contains("rowsBanked=n/a at connect"), s)
        XCTAssertFalse(s.contains("phantom gap"), s)
    }
}
