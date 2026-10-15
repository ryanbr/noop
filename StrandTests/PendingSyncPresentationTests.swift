import AppKit
import SwiftUI
import XCTest
@testable import Strand

@MainActor
final class PendingSyncPresentationTests: XCTestCase {
    func testChunkGapsKeepTheHintWhileRawBackfillAndPulseUpdatesRemainIndependent() async throws {
        let live = LiveState()
        var rawBackfill = false
        var pending = false
        var pendingChanges: [Bool] = []
        let view = BackfillFlagBridge(
            flag: Binding(get: { rawBackfill }, set: { rawBackfill = $0 }),
            pendingSyncFlag: Binding(get: { pending }, set: {
                pending = $0
                pendingChanges.append($0)
            }))
            .environmentObject(live)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(pending)

        live.backfilling = true
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(rawBackfill)
        XCTAssertTrue(pending)

        live.backfilling = false
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(rawBackfill, "Data-read scheduling must see the raw end immediately")
        XCTAssertTrue(pending, "A short inter-chunk gap must not hide the presentation")
        live.historyPendingSync = true
        for pulse in 70...80 { live.heartRate = pulse }
        try await Task.sleep(nanoseconds: 3_150_000_000)
        XCTAssertTrue(pending, "A new pending-history signal must cancel the scheduled hide")
        XCTAssertEqual(pendingChanges, [true], "Repeated pending signals and pulses must publish only visibility edges")

        live.historyPendingSync = false
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertFalse(pending)
        XCTAssertEqual(pendingChanges, [true, false])
    }
}
