import XCTest
@testable import Strand

/// Guards that the strap's own console narration actually REACHES the log.
///
/// The bug this exists for was not a decode bug and not a key bug — both of those were right. Offload
/// frames are routed straight to the Backfiller and never reach `FrameRouter.handle`, and `CONSOLE_LOGS`
/// is an offload type, so the handler that mirrors the text only ever saw the rare console frame arriving
/// outside a sync. Every line worth having — `PullStats`, `History burst success`, `Historical Dump
/// Complete` — is emitted DURING a sync, and was routed past the code meant to surface it.
///
/// Nothing caught that, because nothing asserted the call site existed. Unit tests passed and app-build
/// was green on a feature that could not fire. So this test reads the source: the two offload branches
/// (WHOOP4 and 5/MG are separate paths) must each invoke the carve-out.
@MainActor
final class StrapConsoleMirrorTests: XCTestCase {

    private func bleManagerSource() throws -> String {
        // StrandTests/<this file> → repo root → Strand/BLE/BLEManager.swift
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Strand/BLE/BLEManager.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Both offload branches must mirror the console, or one family goes silent mid-sync — which is the
    /// exact shape of the original defect, just per-family instead of everywhere.
    func testBothOffloadBranchesMirrorTheStrapConsole() throws {
        let src = try bleManagerSource()
        let calls = src.components(separatedBy: "router.mirrorStrapConsoleIfPresent(frame: frame)").count - 1
        XCTAssertEqual(calls, 2,
                       "expected the console carve-out in BOTH offload branches (WHOOP4 + 5/MG); "
                       + "found \(calls). Without it the strap's narration is dropped for that family "
                       + "during exactly the sync it describes.")
    }

    /// The carve-out has to sit INSIDE the offload branch, beside the gesture one. If it drifted out to
    /// the live path it would compile, pass the count check above, and still never fire during a sync.
    func testTheCarveOutSitsBesideTheLiveGestureOne() throws {
        let src = try bleManagerSource()
        for part in src.components(separatedBy: "router.mirrorStrapConsoleIfPresent(frame: frame)").dropLast() {
            let tail = String(part.suffix(400))
            XCTAssertTrue(tail.contains("dispatchLiveGestureIfFresh"),
                          "each console carve-out must sit with the live-gesture carve-out inside the "
                          + "offload branch; one appears to have drifted to the live path, where it is "
                          + "redundant with `handle` and silent during a sync")
        }
    }
}
