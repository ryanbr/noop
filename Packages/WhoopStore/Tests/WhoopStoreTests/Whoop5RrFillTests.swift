import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// #2371: a WHOOP 5/MG sends an exact 500 ms R-R interval as a filler at rest, on v18 history (5) and
/// standard BLE (7). A stored one is MARKED `tsSuspect = 1` when the strap's own heart rate in that second
/// is under 100 bpm: at ingest by `insert`, and for rows already on disk by `v47-rr-whoop5-fill`. Marked,
/// never deleted, so scoring skips it and the raw row stays. Mirrors the Android `Whoop5RrFillTest`.
final class Whoop5RrFillTests: XCTestCase {

    private let device = "my-whoop"
    private let t0 = 1_790_000_000

    /// The statement text is the cross-platform contract: Android runs the same strings, pinned by the
    /// same literals in `Whoop5RrFillTest`, so the two stores mark exactly the same rows.
    func testTheFillStatementsArePinned() {
        let condition = "rrMs = 500 AND srcChannel IN (5, 7) AND tsSuspect IS NULL AND EXISTS (SELECT 1 FROM "
            + "hrSample h WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)"
        XCTAssertEqual(WhoopStore.whoop5RrFillFlagSQL, "UPDATE rrInterval SET tsSuspect = 1 WHERE deviceId = "
            + ":deviceId AND ts >= :fromTs AND ts <= :toTs AND " + condition)
        XCTAssertEqual(WhoopStore.whoop5RrFillMigrationSQL, "UPDATE rrInterval SET tsSuspect = 1 WHERE " + condition)
    }

    /// The whole rule at ingest, one second per case. Only the 500 ms beats on a scored WHOOP 5 transport,
    /// in a second whose strap heart rate is under 100, are marked; each neighbour on the other side of
    /// one condition is not.
    func testIngestMarksOnlyAFillAtRest() async throws {
        let store = try await WhoopStore.inMemory()
        let hr = [HRSample(ts: t0, bpm: 80), HRSample(ts: t0 + 1, bpm: 99), HRSample(ts: t0 + 2, bpm: 100),
                  HRSample(ts: t0 + 3, bpm: 80), HRSample(ts: t0 + 4, bpm: 80), HRSample(ts: t0 + 5, bpm: 80),
                  HRSample(ts: t0 + 6, bpm: 80), HRSample(ts: t0 + 7, bpm: 80)]
        let rr = [
            RRInterval(ts: t0, rrMs: 500, srcChannel: .whoop5Historical),      // fill: marked
            RRInterval(ts: t0, rrMs: 820, srcChannel: .whoop5Historical),      // real beat, same second
            RRInterval(ts: t0 + 1, rrMs: 500, srcChannel: .whoop5Standard),    // fill at 99 bpm: marked
            RRInterval(ts: t0 + 2, rrMs: 500, srcChannel: .whoop5Standard),    // 100 bpm: a beat, kept
            RRInterval(ts: t0 + 3, rrMs: 501, srcChannel: .whoop5Historical),  // not 500
            RRInterval(ts: t0 + 4, rrMs: 500, srcChannel: .whoop5Realtime),    // channel 6 is never scored
            RRInterval(ts: t0 + 5, rrMs: 500, srcChannel: .whoop4Historical),  // a WHOOP 4.0
            RRInterval(ts: t0 + 6, rrMs: 500),                                 // no transport label
            RRInterval(ts: t0 + 8, rrMs: 500, srcChannel: .whoop5Historical),  // no heart rate that second
        ]
        _ = try await store.insert(Streams(hr: hr, rr: rr), deviceId: device)

        let rows = try await store.fillMarksInTest(deviceId: device)
        XCTAssertEqual(rows.count, rr.count, "nothing deleted")
        XCTAssertEqual(rows.filter { $0.tsSuspect == 1 }.map { [$0.ts - t0, $0.rrMs] }, [[0, 500], [1, 500]])
    }

    /// A marked fill drops out of the scoring read like any suspect beat, and stays on disk.
    func testAMarkedFillIsNotScoredButStaysOnDisk() async throws {
        let store = try await WhoopStore.inMemory()
        let hr = (0..<3).map { HRSample(ts: t0 + $0, bpm: 75) }
        let rr = [RRInterval(ts: t0, rrMs: 800, srcChannel: .whoop5Historical),
                  RRInterval(ts: t0 + 1, rrMs: 500, srcChannel: .whoop5Historical),
                  RRInterval(ts: t0 + 2, rrMs: 790, srcChannel: .whoop5Historical)]
        _ = try await store.insert(Streams(hr: hr, rr: rr), deviceId: device)

        let scored = try await store.rrIntervals(deviceId: device, from: t0 - 10, to: t0 + 10, limit: 100)
        XCTAssertEqual(scored.map(\.rrMs), [800, 790])
        let raw = try await store.fillMarksInTest(deviceId: device)
        XCTAssertEqual(raw.map(\.rrMs), [800, 500, 790])
    }

    /// The same beat arriving again (a re-sync) inserts nothing and leaves the mark where it is.
    func testAResyncKeepsTheMark() async throws {
        let store = try await WhoopStore.inMemory()
        let batch = Streams(hr: [HRSample(ts: t0, bpm: 70)],
                            rr: [RRInterval(ts: t0, rrMs: 500, srcChannel: .whoop5Historical)])
        _ = try await store.insert(batch, deviceId: device)
        let again = try await store.insert(batch, deviceId: device)
        XCTAssertEqual(again.rr, 0)
        let marks = try await store.fillMarksInTest(deviceId: device)
        XCTAssertEqual(marks.map(\.tsSuspect), [1])
    }

    /// Rows banked before v47 carry no mark. The migration marks exactly the rows the ingest rule would
    /// have, and leaves a future-stamped mark (v35) and every other row alone.
    func testV47MarksTheFillsAlreadyStored() async throws {
        let t0 = self.t0
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v46-lift-log")
        try await dbQueue.write { db in
            for (ts, bpm) in [(0, 80), (1, 120), (2, 80), (3, 80)] {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', ?, ?)",
                               arguments: [t0 + ts, bpm])
            }
            for (ts, rrMs, channel, suspect) in [(0, 500, 5, nil), (1, 500, 7, nil), (2, 500, 7, nil),
                                                (2, 760, 7, nil), (3, 500, 8, nil), (9, 500, 5, 1)] as [(Int, Int, Int, Int?)] {
                try db.execute(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel, tsSuspect)
                    VALUES ('my-whoop', ?, ?, 0, 0, ?, ?)
                    """, arguments: [t0 + ts, rrMs, channel, suspect])
            }
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        let marks = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, rrMs, tsSuspect FROM rrInterval ORDER BY ts, rrMs")
                .map { [($0["ts"] as Int) - t0, $0["rrMs"] as Int, ($0["tsSuspect"] as Int?) ?? 0] }
        }
        XCTAssertEqual(marks, [[0, 500, 1], [1, 500, 0], [2, 500, 1], [2, 760, 0], [3, 500, 0], [9, 500, 1]])
    }
}

extension WhoopStore {
    /// Every stored R-R row for a device with its mark, bypassing the scoring read's filters. Test-only.
    func fillMarksInTest(deviceId: String) throws -> [(ts: Int, rrMs: Int, tsSuspect: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs, tsSuspect FROM rrInterval WHERE deviceId = ? ORDER BY ts, ord, rrMs, seq
                """, arguments: [deviceId]).map { (ts: $0["ts"], rrMs: $0["rrMs"], tsSuspect: $0["tsSuspect"]) }
        }
    }
}
