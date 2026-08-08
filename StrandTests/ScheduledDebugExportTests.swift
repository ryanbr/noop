import XCTest
@testable import Strand

/// Pure retention logic behind the scheduled debug export's "Clear scheduled exports" / keep-count
/// pruning (#650). Mirror of `LogExportRetentionTest` on Android — same shape (stamp extraction,
/// keep-N, oldest-first) applied to the `noop-strap-log-<stamp>.txt` / `noop-raw-capture-<stamp>.json`
/// pair NOOP drops into Documents instead of a `.noopbak` snapshot.
///
/// `ScheduledDebugExport` is @MainActor (mirrors `WindDownNudge`), so this test class is too.
@MainActor
final class ScheduledDebugExportTests: XCTestCase {

    func testStampExtractedFromLogAndRawFilenames() {
        XCTAssertEqual(ScheduledDebugExport.exportStamp(fromFilename: "noop-strap-log-260617-0700.txt"), "260617-0700")
        XCTAssertEqual(ScheduledDebugExport.exportStamp(fromFilename: "noop-raw-capture-260617-0700.json"), "260617-0700")
    }

    func testStampRejectsUnrelatedFilenames() {
        XCTAssertNil(ScheduledDebugExport.exportStamp(fromFilename: "random.txt"))
        XCTAssertNil(ScheduledDebugExport.exportStamp(fromFilename: "noop-strap-log-260617-0700.json")) // wrong ext for this prefix
        XCTAssertNil(ScheduledDebugExport.exportStamp(fromFilename: "noop-raw-capture-260617-0700.txt")) // wrong ext for this prefix
        XCTAssertNil(ScheduledDebugExport.exportStamp(fromFilename: "noop-backup-20260617-070000.noopbak")) // unrelated feature
    }

    func testPruneKeepsNewestNGenerations() {
        // Five generations, each with a log+raw pair sharing one stamp — a pair must count as ONE
        // generation, not two, when measured against `keep`.
        let stamps = (10...14).map { "26061\($0 % 10)-0700" }
        let names = stamps.flatMap { ["noop-strap-log-\($0).txt", "noop-raw-capture-\($0).json"] }
        let pruned = ScheduledDebugExport.exportStampsToPrune(names, keep: 2)
        XCTAssertEqual(pruned.count, 3)
        XCTAssertTrue(pruned.contains(stamps[0]))    // oldest generations pruned
        XCTAssertTrue(pruned.contains(stamps[1]))
        XCTAssertTrue(pruned.contains(stamps[2]))
        XCTAssertFalse(pruned.contains(stamps[3]))   // two newest kept
        XCTAssertFalse(pruned.contains(stamps[4]))
    }

    func testPruneNoOpWithinBudget() {
        let names = ["noop-strap-log-260617-0700.txt", "noop-raw-capture-260617-0700.json"]
        XCTAssertTrue(ScheduledDebugExport.exportStampsToPrune(names, keep: 10).isEmpty)
    }

    func testPruneIgnoresUnrelatedFiles() {
        let names = [
            "noop-strap-log-260610-0700.txt", "noop-raw-capture-260610-0700.json",
            "noop-strap-log-260617-0700.txt", "noop-raw-capture-260617-0700.json",
            "noop-backup-20260617-070000.noopbak", // Backup & Sync file — never a prune candidate here
        ]
        let pruned = ScheduledDebugExport.exportStampsToPrune(names, keep: 1)
        XCTAssertEqual(pruned, ["260610-0700"])
    }

    func testDefaultKeepOptionsIncludeTheDefault() {
        // The default (14) must be one of the choices the picker actually offers.
        XCTAssertTrue(ScheduledDebugExport.keepOptions.contains(14))
    }

    /// A stale BGTask delivery must not re-arm tomorrow's wake once the user has disabled the feature.
    func testBackgroundTaskResubmitsOnlyWhileEnabled() {
        XCTAssertTrue(ScheduledDebugExport.backgroundTaskShouldResubmit(enabled: true))
        XCTAssertFalse(ScheduledDebugExport.backgroundTaskShouldResubmit(enabled: false))
    }
}
