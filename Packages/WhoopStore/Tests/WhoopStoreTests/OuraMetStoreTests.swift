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

    /// 2026-09-17, first hardware day: `ts` is anchored ring time and the `0x13` anchor is per session, so
    /// the same ring record re-served under a second session (an Oura-app replay from the app's older
    /// cursor) landed 3–4 s off its first copy and the (deviceId, ts) key kept both — 157 twins in 1,035
    /// rows, +8 % on the day. The insert now judges by interval overlap: the first copy stays.
    func testReserveUnderAnotherSessionAnchorIsTheSameMinute() async throws {
        let store = try await WhoopStore.inMemory()
        let t = 1_755_208_800
        let first = try await store.insertOuraMetSamples(
            [OuraMetSample(ts: t, met: 1.1, state: 2), OuraMetSample(ts: t + 60, met: 3.0, state: 2)],
            deviceId: "oura-A")
        XCTAssertEqual(first, 2)
        // The same two minutes served again 4 s later, plus a genuinely new third minute.
        let replay = try await store.insertOuraMetSamples(
            [OuraMetSample(ts: t + 4, met: 1.1, state: 2), OuraMetSample(ts: t + 64, met: 3.0, state: 2),
             OuraMetSample(ts: t + 124, met: 0.9, state: 2)],
            deviceId: "oura-A")
        XCTAssertEqual(replay, 1, "only the new minute lands; the two 4-s twins are the stored minutes again")
        let read = try await store.ouraMetSamples(deviceId: "oura-A", from: t, to: t + 200, limit: 10)
        XCTAssertEqual(read.map(\.ts), [t, t + 60, t + 124])
        // Twins INSIDE one batch collapse the same way (earlier start wins, lower MET on an exact tie).
        let batch = try await store.insertOuraMetSamples(
            [OuraMetSample(ts: t + 300, met: 5.0, state: 2), OuraMetSample(ts: t + 303, met: 2.0, state: 2),
             OuraMetSample(ts: t + 300, met: 4.0, state: 2)],
            deviceId: "oura-A")
        XCTAssertEqual(batch, 1)
        let kept = try await store.ouraMetSamples(deviceId: "oura-A", from: t + 300, to: t + 400, limit: 10)
        XCTAssertEqual(kept, [OuraMetSample(ts: t + 300, met: 4.0, state: 2)])
        // Another device is its own namespace.
        let other = try await store.insertOuraMetSamples([OuraMetSample(ts: t + 4, met: 1.1, state: 2)],
                                                         deviceId: "oura-B")
        XCTAssertEqual(other, 1)
    }

    /// The pure rule behind the insert (twin: Kotlin `OuraMetSampleEntity.droppingOverlaps`).
    func testDroppingOverlapsIsPureAndOrderIndependent() {
        let t = 1_000
        let existing = [OuraMetSample(ts: t, met: 1.0, state: 0), OuraMetSample(ts: t + 120, met: 1.0, state: 0, epochS: 120)]
        let incoming = [OuraMetSample(ts: t + 230, met: 2.0, state: 0),   // overlaps the 120-s row [t+120, t+240)
                        OuraMetSample(ts: t + 60, met: 2.0, state: 0),    // free minute
                        OuraMetSample(ts: t + 59, met: 9.0, state: 0),    // overlaps [t, t+60) by one second
                        OuraMetSample(ts: t + 240, met: 2.0, state: 0),   // touches, does not overlap
                        OuraMetSample(ts: t + 241, met: 2.0, state: 0)]   // overlaps the accepted t+240
        let out = OuraMetSample.droppingOverlaps(incoming, existing: existing)
        XCTAssertEqual(out.map(\.ts), [t + 60, t + 240])
        XCTAssertEqual(OuraMetSample.droppingOverlaps(incoming.reversed(), existing: existing).map(\.ts), [t + 60, t + 240])
        XCTAssertEqual(OuraMetSample.droppingOverlaps([], existing: existing), [])
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
