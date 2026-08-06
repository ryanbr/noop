import XCTest
import WhoopProtocol
@testable import WhoopStore

/// #1073: R-R beats stamped in the FUTURE (a corrupt/misaligned Oura ring timestamp) are quarantined by
/// `v35-rr-future-quarantine` — MARKED, never deleted, so they stay inspectable and recoverable — and
/// excluded from the scoring read. The ingest-side gate (`OuraDriver.unixSeconds`) stops new ones; this
/// covers the stored-row half. Mirrors the Android `RrFutureQuarantineMigrationTest`.
final class RrFutureQuarantineTests: XCTestCase {

    /// v35 adds the nullable `tsSuspect` column without touching the primary key (the v32 srcChannel form).
    func testV35AddsTsSuspectAndKeepsThePrimaryKey() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("tsSuspect"), "rrInterval missing v35 tsSuspect column")
        let pk = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(pk, ["deviceId", "ts", "rrMs", "seq"], "tsSuspect must not enter the primary key")
    }

    /// The whole shape of the fix in one test: future-stamped beats are MARKED (not deleted), remain on
    /// disk, and drop out of the scoring read; historical beats are untouched and still scored.
    func testFutureBeatsAreQuarantinedAndExcludedFromScoringButKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        let now = 1_700_000_000
        let rows = [
            RRInterval(ts: now - 20, rrMs: 800),                 // historical
            RRInterval(ts: now - 10, rrMs: 810),                 // historical
            RRInterval(ts: now + 86_400, rrMs: 820),             // a day ahead (corrupt)
            RRInterval(ts: now + 315_360_000, rrMs: 830),        // a year ahead (corrupt)
        ]
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        // What v35 does, with a fixed `now` so the test does not depend on the wall clock.
        try await store.markFutureRrSuspectForTest(nowSeconds: now)

        // Nothing deleted — all four beats remain on disk; exactly the future ones are marked.
        let onDisk = try await store.rrSuspectRowsForTest(deviceId: "ring")
        XCTAssertEqual(onDisk.count, 4, "quarantine MARKS, never deletes (count preserved)")
        XCTAssertEqual(onDisk.filter { $0.tsSuspect == 1 }.map(\.ts), [now + 86_400, now + 315_360_000],
                       "exactly the future-stamped beats are marked suspect")
        XCTAssertNil(onDisk.first(where: { $0.ts == now - 20 })?.tsSuspect, "historical beats stay unmarked")

        // Scoring reads exclude the quarantined beats.
        let scored = try await store.rrIntervals(deviceId: "ring", from: 0, to: now + 400_000_000, limit: 1_000)
        XCTAssertEqual(scored.map(\.rrMs), [800, 810], "only the two historical beats reach scoring")
    }
}
