import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v18 migration + read/write round-trip: per-epoch `motionJSON` (H8) and `sleepStateJSON` (H2) banked
/// on the existing sleepSession row beside `stagesJSON`. Twin of Android's MigrationRoundTripTest cases.
final class SleepMotionStateTests: XCTestCase {
    private let dev = "my-whoop"
    private let start = 1_780_000_000

    private func storeWithSession() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start, endTs: start + 8 * 3_600, efficiency: 0.9,
                               restingHr: 52, avgHrv: 70, stagesJSON: "[]")
        ], deviceId: dev)
        return store
    }

    func testV18AddsMotionAndStateColumns() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("motionJSON"))
        XCTAssertTrue(cols.contains("sleepStateJSON"))
    }

    func testSchemaVersionBumpedTo18() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 18)
    }

    // MARK: motionJSON

    func testMotionRoundTrip() async throws {
        let store = try await storeWithSession()
        let motion = [0.0, 1.5, 12.25, 3.0, 0.5]
        let n = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: motion)
        XCTAssertEqual(n, 1)
        let read = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertEqual(read, motion)
    }

    /// Absent stays absent — a never-written column reads back nil, NOT [] or a fabricated zero series.
    func testMotionAbsentReadsNil() async throws {
        let store = try await storeWithSession()
        let read = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertNil(read)
    }

    /// Persisting an EMPTY array clears the column to NULL (nil on read), never an empty `[]` as data.
    func testMotionEmptyClearsToNil() async throws {
        let store = try await storeWithSession()
        _ = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: [9.0])
        let present = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertNotNil(present)
        _ = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: [])
        let cleared = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertNil(cleared)
    }

    /// Writing motion to a non-existent session changes nothing and reads back nil.
    func testMotionNoSuchSessionNoOp() async throws {
        let store = try await storeWithSession()
        let n = try await store.persistSessionMotion(deviceId: dev, sessionStart: start + 999, motionEpochs: [1.0])
        XCTAssertEqual(n, 0)
        let none = try await store.sessionMotion(deviceId: dev, sessionStart: start + 999)
        XCTAssertNil(none)
    }

    // MARK: sleepStateJSON

    func testSleepStateRoundTrip() async throws {
        let store = try await storeWithSession()
        let states = [0, 1, 2, 3, 1, 0]   // decoded v18 band (sb>>4)&3
        let n = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: states)
        XCTAssertEqual(n, 1)
        let read = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertEqual(read, states)
    }

    func testSleepStateAbsentReadsNil() async throws {
        let store = try await storeWithSession()
        let read = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertNil(read)
    }

    func testSleepStateEmptyClearsToNil() async throws {
        let store = try await storeWithSession()
        _ = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: [2, 2])
        let present = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertNotNil(present)
        _ = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: [])
        let cleared = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertNil(cleared)
    }

    // MARK: batched aux-blob reads (one query, not N)

    private func upsertBareSession(_ store: WhoopStore, _ s: Int) async throws {
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: s, endTs: s + 8 * 3_600, efficiency: 0.9,
                               restingHr: 52, avgHrv: 70, stagesJSON: "[]")
        ], deviceId: dev)
    }

    /// The batched `sessionMotions` returns EXACTLY what N single `sessionMotion` calls would, keyed by
    /// start: only starts with a non-empty series appear; absent, empty, and non-existent starts are omitted.
    func testBatchedSessionMotionsMatchesSingles() async throws {
        let store = try await WhoopStore.inMemory()
        let starts = [start, start + 1_000, start + 2_000, start + 3_000]
        for s in starts { try await upsertBareSession(store, s) }
        try await store.persistSessionMotion(deviceId: dev, sessionStart: starts[0], motionEpochs: [1.0, 2.0])
        try await store.persistSessionMotion(deviceId: dev, sessionStart: starts[2], motionEpochs: [3.5])
        try await store.persistSessionMotion(deviceId: dev, sessionStart: starts[3], motionEpochs: [])  // empty → NULL
        // starts[1] never written; start+9_999 never a session at all.
        let query = starts + [start + 9_999]

        let batched = try await store.sessionMotions(deviceId: dev, sessionStarts: query)
        var singles: [Int: [Double]] = [:]
        for s in query {
            if let m = try await store.sessionMotion(deviceId: dev, sessionStart: s), !m.isEmpty { singles[s] = m }
        }
        XCTAssertEqual(batched, singles)
        XCTAssertEqual(batched, [starts[0]: [1.0, 2.0], starts[2]: [3.5]])
    }

    func testBatchedSessionMotionsEmptyInputNoQuery() async throws {
        let store = try await storeWithSession()
        let out = try await store.sessionMotions(deviceId: dev, sessionStarts: [])
        XCTAssertTrue(out.isEmpty)
    }

    /// The batched range `sessionSleepStates` returns EXACTLY what per-session `sessionSleepState` reads
    /// would for the in-window sessions, keyed by start; sessions outside `[from, to]` and NULL-state
    /// sessions are omitted.
    func testBatchedSessionSleepStatesMatchesSingles() async throws {
        let store = try await WhoopStore.inMemory()
        let inWindow = [start, start + 1_000, start + 2_000]
        let outside = start + 10 * 24 * 3_600
        for s in inWindow + [outside] { try await upsertBareSession(store, s) }
        try await store.persistSessionSleepState(deviceId: dev, sessionStart: inWindow[0], states: [0, 1, 2])
        try await store.persistSessionSleepState(deviceId: dev, sessionStart: inWindow[2], states: [3])
        try await store.persistSessionSleepState(deviceId: dev, sessionStart: outside, states: [1, 1])
        // inWindow[1] never written.

        let from = start, to = start + 5_000
        let batched = try await store.sessionSleepStates(deviceId: dev, from: from, to: to)
        var singles: [Int: [Int]] = [:]
        for s in inWindow {
            if let st = try await store.sessionSleepState(deviceId: dev, sessionStart: s), !st.isEmpty { singles[s] = st }
        }
        XCTAssertEqual(batched, singles)
        XCTAssertEqual(batched, [inWindow[0]: [0, 1, 2], inWindow[2]: [3]])
        XCTAssertNil(batched[outside])   // out of window is not returned
    }

    /// A later recompute/import upsert of the SAME session (which never names the two aux columns) must
    /// PRESERVE the banked motion/state — they are not in its column list, so ON CONFLICT leaves them.
    func testUpsertPreservesMotionAndState() async throws {
        let store = try await storeWithSession()
        _ = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: [1.0, 2.0])
        _ = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: [1, 2])
        // Re-upsert the session with fresh vitals (simulating a post-sync recompute).
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start, endTs: start + 8 * 3_600, efficiency: 0.95,
                               restingHr: 50, avgHrv: 72, stagesJSON: "[]")
        ], deviceId: dev)
        let motion = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertEqual(motion, [1.0, 2.0])
        let states = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertEqual(states, [1, 2])
    }

    // MARK: - session bounds

    /// The bounds read is device-scoped, window-scoped, and returns EVERY row in the window.
    ///
    /// It exists so a caller resolving which device owns a block does not have to pull `stagesJSON` for
    /// every night to compare two integers. The failure it can have is a partial map, which reads to the
    /// caller as "that device does not own this block" and silently sends it to the wrong motion source,
    /// so the count is asserted alongside the values.
    func testSleepSessionBoundsIsDeviceAndWindowScoped() async throws {
        let store = try await WhoopStore.inMemory()
        let starts = [start, start + 86_400, start + 2 * 86_400]
        try await store.upsertSleepSessions(starts.map {
            CachedSleepSession(startTs: $0, endTs: $0 + 7 * 3_600, efficiency: 0.9,
                               restingHr: 52, avgHrv: 70, stagesJSON: "[]")
        }, deviceId: dev)
        // A decoy on another device at the SAME starts: bounds must never blend the two.
        try await store.upsertSleepSessions(starts.map {
            CachedSleepSession(startTs: $0, endTs: $0 + 99, efficiency: 0.5,
                               restingHr: 60, avgHrv: 40, stagesJSON: "[]")
        }, deviceId: "other")

        let bounds = try await store.sleepSessionBounds(deviceId: dev, from: start,
                                                        to: start + 2 * 86_400)
        XCTAssertEqual(bounds.count, starts.count, "a dropped row reads as an unowned block")
        for s in starts {
            XCTAssertEqual(bounds[s], s + 7 * 3_600, "start \(s) got the other device's end")
        }

        // Window-scoped: a start past `to` is absent rather than clamped in.
        let narrow = try await store.sleepSessionBounds(deviceId: dev, from: start, to: start)
        XCTAssertEqual(narrow, [start: start + 7 * 3_600])
    }

    /// An empty window is an empty map, not a fabricated entry.
    func testSleepSessionBoundsOnAnEmptyWindowIsEmpty() async throws {
        let store = try await storeWithSession()
        let bounds = try await store.sleepSessionBounds(deviceId: dev, from: start + 10_000,
                                                        to: start + 20_000)
        XCTAssertTrue(bounds.isEmpty)
    }

    /// The read stamps each block with the device it queried, and a re-keyed copy keeps it.
    ///
    /// This is what lets a caller skip asking the store which device owns a block. `withStartTs` is
    /// included because it is the one place a session is rebuilt: dropping the field there would turn a
    /// known provenance silently back into a probe, which is a performance fault with no visible symptom.
    func testSleepSessionsCarryTheDeviceTheyWereReadFrom() async throws {
        let store = try await storeWithSession()
        let rows = try await store.sleepSessions(deviceId: dev, from: start - 1, to: start + 1, limit: 8)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.deviceId, dev)
        XCTAssertEqual(rows.first?.withStartTs(start + 60).deviceId, dev, "a re-keyed copy forgot its device")
    }

    /// A hand-built session says nothing rather than claiming a device it was never read from.
    func testAHandBuiltSessionHasNoProvenance() {
        let s = CachedSleepSession(startTs: start, endTs: start + 3_600, efficiency: nil,
                                   restingHr: nil, avgHrv: nil, stagesJSON: nil)
        XCTAssertNil(s.deviceId, "absent is the honest value; a default would be a wrong answer")
    }
}
