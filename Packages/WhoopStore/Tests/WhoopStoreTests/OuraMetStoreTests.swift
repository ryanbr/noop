import XCTest
import GRDB
@testable import WhoopStore

/// v47 migration (#2242): the Oura ring's OWN per-minute MET series (0x50), which until now lived only in
/// the diagnostic JSONL sidecar. Proves the table exists, keys by (deviceId, ts), round-trips + dedupes
/// like every stream table, and is cleared by "delete all of this device's data".
final class OuraMetStoreTests: XCTestCase {
    func testV47CreatesOuraMetSampleTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ouraMetSample"))
        let pk = try await store.primaryKeyColumns("ouraMetSample")
        XCTAssertEqual(pk, ["deviceId", "ts"])
        let cols = try await store.columnNamesForTest(table: "ouraMetSample")
        XCTAssertEqual(cols, ["deviceId", "ts", "met", "state", "epochS"])
    }

    func testInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = [
            OuraMetSample(ts: 1_755_208_800, met: 0.9, state: 2),
            OuraMetSample(ts: 1_755_208_860, met: 1.5, state: 2),
            OuraMetSample(ts: 1_755_208_920, met: 12.8, state: 3),   // the 0x80 slope
        ]
        let first = try await store.insertOuraMetSamples(rows, deviceId: "oura-A")
        XCTAssertEqual(first, 3)
        // A re-served record (same deviceId, ts) is a no-op — the ring re-serves under churn.
        let again = try await store.insertOuraMetSamples(rows, deviceId: "oura-A")
        XCTAssertEqual(again, 0)
        let none = try await store.insertOuraMetSamples([], deviceId: "oura-A")
        XCTAssertEqual(none, 0)
        let count = try await store.ouraMetSampleCount(deviceId: "oura-A")
        XCTAssertEqual(count, 3)

        let read = try await store.ouraMetSamples(deviceId: "oura-A", from: 1_755_208_800,
                                                  to: 1_755_208_920, limit: 10)
        XCTAssertEqual(read, rows, "ts ascending, value/state/epochS verbatim")
        // Inclusive bounds and a limit, like the other stream reads.
        let bounded = try await store.ouraMetSamples(deviceId: "oura-A", from: 1_755_208_860,
                                                     to: 1_755_208_919, limit: 10)
        XCTAssertEqual(bounded, [rows[1]])
        let limited = try await store.ouraMetSamples(deviceId: "oura-A", from: 0, to: .max, limit: 2)
        XCTAssertEqual(limited.count, 2)
        // Another device's rows are invisible.
        let other = try await store.ouraMetSamples(deviceId: "oura-B", from: 0, to: .max, limit: 10)
        XCTAssertTrue(other.isEmpty)
    }

    func testDeleteAllDataClearsTheRingsMetRows() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insertOuraMetSamples([OuraMetSample(ts: 1, met: 1.0, state: 0)], deviceId: "oura-A")
        _ = try await store.insertOuraMetSamples([OuraMetSample(ts: 1, met: 1.0, state: 0)], deviceId: "oura-B")
        try await store.deleteAllData(deviceId: "oura-A")
        let a = try await store.ouraMetSampleCount(deviceId: "oura-A")
        let b = try await store.ouraMetSampleCount(deviceId: "oura-B")
        XCTAssertEqual(a, 0)
        XCTAssertEqual(b, 1)
    }
}
