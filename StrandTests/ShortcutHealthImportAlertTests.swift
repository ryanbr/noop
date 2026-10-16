import AppKit
import SwiftUI
import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class ShortcutHealthImportAlertTests: XCTestCase {
    // Build each test store before AppModel's startup task can open the default database.
    func testPulsesUpdateTheLeafWithoutRebuildingItsOwnerAndCancelKeepsTheStoreEmpty() async throws {
        let previousModel = AppModel.shared
        defer { AppModel.shared = previousModel }
        let store = try await WhoopStore.inMemory()
        let model = AppModel()
        model.repo.setStoreForTesting(store)
        let counts = Counts()
        let window = host(model, counts: counts)
        defer { window.orderOut(nil) }
        try await wait { counts.leaf > 0 }
        let ownerBefore = counts.owner
        for bpm in 70...81 {
            model.bpm = bpm
            try await wait { counts.bpm == bpm }
        }
        XCTAssertEqual(counts.owner, ownerBefore)
        XCTAssertGreaterThanOrEqual(counts.leaf, 12)
        XCTAssertNil(window.attachedSheet)

        model.handleHealthImportURL(importURL)
        try await wait { window.attachedSheet != nil }
        let rows = try await store.appleDaily(deviceId: "apple-health", from: "2026-06-01", to: "2026-06-01")
        XCTAssertTrue(rows.isEmpty, "Staging must not import before confirmation")
        try button("Cancel", in: window).performClick(nil)
        try await wait { window.attachedSheet == nil && model.pendingShortcutHealthImport == nil }
        let afterCancel = try await store.appleDaily(deviceId: "apple-health", from: "2026-06-01", to: "2026-06-01")
        XCTAssertTrue(afterCancel.isEmpty)
    }

    func testAlreadyStagedImportIsPresentedAndConfirmationWritesThePreparedPayload() async throws {
        let previousModel = AppModel.shared
        defer { AppModel.shared = previousModel }
        let store = try await WhoopStore.inMemory()
        let model = AppModel()
        model.repo.setStoreForTesting(store)
        model.handleHealthImportURL(importURL)
        let window = host(model, counts: Counts())
        defer { window.orderOut(nil) }
        try await wait { window.attachedSheet != nil }
        try button("Import", in: window).performClick(nil)
        try await wait { window.attachedSheet == nil && model.pendingShortcutHealthImport == nil }
        for _ in 0..<60 {
            let rows = try await store.appleDaily(deviceId: "apple-health", from: "2026-06-01", to: "2026-06-01")
            if !rows.isEmpty {
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows.first?.steps, 1_000)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The confirmed payload was not imported: \(model.appleHealthImportSummary ?? "no import started")")
    }

    private var importURL: URL {
        let payload = Data("D,2026-06-01,1000,,,,,,,".utf8).base64EncodedString()
        var url = URLComponents()
        url.scheme = "noop"
        url.host = "import-health"
        url.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: payload)]
        return url.url!
    }

    private func host(_ model: AppModel, counts: Counts) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Owner(model: model, counts: counts)
            .environment(\.locale, Locale(identifier: "en")))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("SwiftUI did not settle")
    }

    private func button(_ title: String, in window: NSWindow) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(window.attachedSheet?.contentView.flatMap(find), "Missing alert button: \(title)")
    }

    private final class Counts {
        var owner = 0
        var leaf = 0
        var bpm: Int?
    }

    private struct Owner: View {
        @State var model: AppModel
        let counts: Counts
        var body: some View {
            counts.owner += 1
            return Pulse(counts: counts).environmentObject(model)
                .modifier(ShortcutHealthImportAlert(model: model))
        }
    }

    private struct Pulse: View {
        @EnvironmentObject var model: AppModel
        let counts: Counts
        var body: some View {
            counts.leaf += 1
            counts.bpm = model.bpm
            return Text(model.bpm.map(String.init) ?? "—")
        }
    }
}
