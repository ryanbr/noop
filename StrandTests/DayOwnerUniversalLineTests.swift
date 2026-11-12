import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// CAPTURE-B (#814/#799): the universal `dayOwner …` self-diagnostic line that rides EVERY Test Centre
/// export. The export parser depends on the EXACT shape, so these tests pin the verbatim format and the
/// provenance resolution (imported:whoop > imported:apple > measured > none).
final class DayOwnerUniversalLineTests: XCTestCase {

    /// A strap-measured day where the read owner == the write active id (the healthy single-device case):
    /// readId == writeActiveId, provenance = measured.
    func testMeasuredDayMatchingIds() {
        let line = IntelligenceEngine.dayOwnerLine(
            day: "2026-06-15", readId: "my-whoop", writeActiveId: "my-whoop",
            hrRows: 4200, importedWhoop: false, importedApple: false)
        XCTAssertEqual(line, "dayOwner day=2026-06-15 readId=my-whoop writeActiveId=my-whoop hrRows=4200 provenance=measured")
    }

    /// #814 split made visible: after a remove+re-add the read owner is the new strap id while the daily
    /// row still has data, readId and writeActiveId AGREE on the new id (both followed the registry), and
    /// the day reads measured. The line carries both ids so a divergence (the bug) would be obvious.
    func testReAddedStrapIdsAgreeOnNewId() {
        let line = IntelligenceEngine.dayOwnerLine(
            day: "2026-06-28", readId: "whoop-ABC123", writeActiveId: "whoop-ABC123",
            hrRows: 3600, importedWhoop: false, importedApple: false)
        XCTAssertTrue(line.contains("readId=whoop-ABC123"))
        XCTAssertTrue(line.contains("writeActiveId=whoop-ABC123"))
        XCTAssertTrue(line.hasSuffix("provenance=measured"))
    }

    /// A WHOOP-import day: provenance = imported:whoop (wins over Apple even if both set).
    func testWhoopImportProvenanceWins() {
        let line = IntelligenceEngine.dayOwnerLine(
            day: "2025-01-01", readId: "my-whoop", writeActiveId: "my-whoop",
            hrRows: 0, importedWhoop: true, importedApple: true)
        XCTAssertTrue(line.hasSuffix("provenance=imported:whoop"))
    }

    /// An Apple-only import day: provenance = imported:apple.
    func testAppleImportProvenance() {
        let line = IntelligenceEngine.dayOwnerLine(
            day: "2025-01-02", readId: "apple-health", writeActiveId: "my-whoop",
            hrRows: 0, importedWhoop: false, importedApple: true)
        XCTAssertTrue(line.hasSuffix("provenance=imported:apple"))
    }

    /// No data, no import → provenance = none.
    func testNoneProvenance() {
        let line = IntelligenceEngine.dayOwnerLine(
            day: "2025-01-03", readId: "my-whoop", writeActiveId: "my-whoop",
            hrRows: 0, importedWhoop: false, importedApple: false)
        XCTAssertTrue(line.hasSuffix("provenance=none"))
    }

    /// The token order is fixed and there are no em-dashes (project hard rule + parser stability).
    func testTokenOrderAndNoEmDash() {
        let line = IntelligenceEngine.dayOwnerLine(
            day: "2026-06-15", readId: "r", writeActiveId: "w",
            hrRows: 1, importedWhoop: false, importedApple: false)
        let tokens = line.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.first, "dayOwner")
        XCTAssertEqual(tokens[1], "day=2026-06-15")
        XCTAssertEqual(tokens[2], "readId=r")
        XCTAssertEqual(tokens[3], "writeActiveId=w")
        XCTAssertEqual(tokens[4], "hrRows=1")
        XCTAssertEqual(tokens[5], "provenance=measured")
        XCTAssertFalse(line.contains("\u{2014}"), "no em-dashes anywhere (project hard rule)")
    }

    /// #2026: the production resolver must probe archived history even when the current strap is the
    /// only live registry row, then prefer the current strap whenever it also covers the day.
    func testArchivedHistoryIsLastResortDayOwner() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "old-whoop", brand: "WHOOP", model: "WHOOP 4.0",
                                      sourceKind: .liveBLE, capabilities: [.hr],
                                      status: .archived, addedAt: 1, lastSeenAt: 1))
        let dayStart = 1_781_481_600
        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let base = dayStart + 3 * 3_600
        _ = try await store.insert(Streams(hr: [HRSample(ts: base, bpm: 65)]), deviceId: "old-whoop")

        let devices = try registry.all()
        let archivedOwner = await IntelligenceEngine.resolveDayOwner(
            day: "2026-06-15", from: from, to: to, store: store, devices: devices,
            activeId: "my-whoop", registry: registry, fallbackDeviceId: "my-whoop")
        XCTAssertEqual(archivedOwner, "old-whoop")

        _ = try await store.insert(Streams(hr: [HRSample(ts: base + 3_600, bpm: 55)]), deviceId: "my-whoop")
        let activeOwner = await IntelligenceEngine.resolveDayOwner(
            day: "2026-06-15", from: from, to: to, store: store, devices: devices,
            activeId: "my-whoop", registry: registry, fallbackDeviceId: "my-whoop")
        XCTAssertEqual(activeOwner, "my-whoop")
    }

    /// #2880: Remove + re-add left the night under an archived row for the SAME strap while the active row
    /// holds a few minutes of live HR. The night owns the day; an archived row for a different strap does not.
    func testArchivedRowForTheSameStrapOwnsTheNightItHolds() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "my-whoop", brand: "WHOOP", model: "WHOOP 4.0", peripheralId: "P1",
                                      sourceKind: .liveBLE, capabilities: [.hr], status: .archived,
                                      addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: "other-old", brand: "WHOOP", model: "WHOOP 4.0", peripheralId: "P2",
                                      sourceKind: .liveBLE, capabilities: [.hr], status: .archived,
                                      addedAt: 2, lastSeenAt: 2))
        try registry.add(PairedDevice(id: "whoop-new", brand: "WHOOP", model: "5.0 MG", peripheralId: "P1",
                                      sourceKind: .liveBLE, capabilities: [.hr], status: .active,
                                      addedAt: 3, lastSeenAt: 3))
        let dayStart = 1_781_481_600
        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let night = (0..<50).map { HRSample(ts: dayStart + $0 * 60, bpm: 55) }
        let live = (0..<3).map { HRSample(ts: dayStart + 9 * 3_600 + $0, bpm: 70) }
        _ = try await store.insert(Streams(hr: Array(night.prefix(10))), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: night), deviceId: "other-old")
        _ = try await store.insert(Streams(hr: live), deviceId: "whoop-new")

        func owner() async throws -> String {
            await IntelligenceEngine.resolveDayOwner(
                day: "2026-06-15", from: from, to: to, store: store, devices: try registry.all(),
                activeId: "whoop-new", registry: registry, fallbackDeviceId: "whoop-new")
        }
        let first = try await owner()
        XCTAssertEqual(first, "my-whoop")   // 10 rows beat 3; other-old (P2) is not this strap

        let more = (0..<20).map { HRSample(ts: dayStart + 10 * 3_600 + $0, bpm: 70) }
        _ = try await store.insert(Streams(hr: more), deviceId: "whoop-new")
        let second = try await owner()
        XCTAssertEqual(second, "whoop-new")
    }
}
