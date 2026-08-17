import XCTest
@testable import WhoopStore

/// Round-trips the `liveSession` table (migration v22): start (endTs nil) → end (upsert same key with final
/// totals) → read newest-first, device-scoped. Design: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
final class LiveSessionStoreTests: XCTestCase {

    private func started(_ startTs: Int) -> LiveSessionRow {
        LiveSessionRow(startTs: startTs, endTs: nil, chargeAtStart: 41, floorBpm: 128, ceilingBpm: 148,
                       inBandSec: 0, belowSec: 0, aboveSec: 0, pushCount: 0, easeCount: 0, hrSource: "whoop")
    }

    func test_start_then_end_upserts_same_row() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiveSession(started(1000), deviceId: "my-whoop")

        // End the session: same natural key, filled totals → an UPDATE, not a second row.
        let ended = LiveSessionRow(startTs: 1000, endTs: 3400, chargeAtStart: 41, floorBpm: 128, ceilingBpm: 148,
                                   inBandSec: 1800, belowSec: 300, aboveSec: 120, pushCount: 2, easeCount: 1,
                                   hrSource: "whoop")
        _ = try await store.upsertLiveSession(ended, deviceId: "my-whoop")

        let rows = try await store.recentLiveSessions(deviceId: "my-whoop", limit: 10)
        XCTAssertEqual(rows.count, 1, "same (deviceId, startTs) upserts one row")
        XCTAssertEqual(rows.first, ended)
        XCTAssertEqual(rows.first?.endTs, 3400)
        XCTAssertEqual(rows.first?.inBandSec, 1800)
    }

    func test_late_start_write_cannot_overwrite_an_ended_row() async throws {
        // The start/end persists race as independent tasks. If the start-write (endTs nil) lands AFTER the
        // end-write, the endTs-guard must refuse it — otherwise the session reverts to "in progress" and
        // the totals are lost. (@bhelm)
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiveSession(started(1000), deviceId: "my-whoop")
        let ended = LiveSessionRow(startTs: 1000, endTs: 3400, chargeAtStart: 41, floorBpm: 128, ceilingBpm: 148,
                                   inBandSec: 1800, belowSec: 300, aboveSec: 120, pushCount: 2, easeCount: 1,
                                   hrSource: "whoop")
        _ = try await store.upsertLiveSession(ended, deviceId: "my-whoop")

        // Replay the stale start-write against the already-ended row: the guard makes it a no-op.
        let changed = try await store.upsertLiveSession(started(1000), deviceId: "my-whoop")
        XCTAssertEqual(changed, 0, "a start-write against an ended row changes nothing")

        let rows = try await store.recentLiveSessions(deviceId: "my-whoop", limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first, ended, "the final row survives intact")
        XCTAssertEqual(rows.first?.endTs, 3400)
        XCTAssertEqual(rows.first?.inBandSec, 1800)
    }

    func test_in_progress_row_still_accepts_updates() async throws {
        // The guard must NOT block legitimate writes while the row is still open (endTs nil): a re-persisted
        // start row updates, and the end-write then fills the totals.
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiveSession(started(2000), deviceId: "my-whoop")
        _ = try await store.upsertLiveSession(started(2000), deviceId: "my-whoop")   // re-persist while open → OK
        let ended = LiveSessionRow(startTs: 2000, endTs: 4000, chargeAtStart: 41, floorBpm: 128, ceilingBpm: 148,
                                   inBandSec: 900, belowSec: 60, aboveSec: 30, pushCount: 1, easeCount: 0,
                                   hrSource: "whoop")
        _ = try await store.upsertLiveSession(ended, deviceId: "my-whoop")
        let rows = try await store.recentLiveSessions(deviceId: "my-whoop", limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.endTs, 4000)
        XCTAssertEqual(rows.first?.inBandSec, 900)
    }

    func test_recent_is_newest_first_and_device_scoped() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiveSession(started(1000), deviceId: "my-whoop")
        _ = try await store.upsertLiveSession(started(5000), deviceId: "my-whoop")
        _ = try await store.upsertLiveSession(started(9000), deviceId: "other")

        let mine = try await store.recentLiveSessions(deviceId: "my-whoop", limit: 10)
        XCTAssertEqual(mine.map { $0.startTs }, [5000, 1000], "newest first, other device excluded")
    }

    func test_charge_may_be_unknown() async throws {
        let store = try await WhoopStore.inMemory()
        let noCharge = LiveSessionRow(startTs: 2000, endTs: nil, chargeAtStart: nil, floorBpm: 120,
                                      ceilingBpm: 150, inBandSec: 0, belowSec: 0, aboveSec: 0,
                                      pushCount: 0, easeCount: 0, hrSource: "strap")
        _ = try await store.upsertLiveSession(noCharge, deviceId: "my-whoop")
        let rows = try await store.recentLiveSessions(deviceId: "my-whoop", limit: 1)
        XCTAssertNil(rows.first?.chargeAtStart)
        XCTAssertEqual(rows.first?.hrSource, "strap")
    }
}
