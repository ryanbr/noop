import XCTest
import WhoopProtocol
@testable import WhoopStore

/// The contract the steps-calibration motion cache rests on.
///
/// `StepsEstimateEngine.dayMotionIntensity` sums the distance between CONSECUTIVE gravity samples, so it
/// depends on the set of x/y/z values in a day AND on their order. The cache re-folds a day only when
/// `gravityFingerprint` moves, which is sound only while a day's gravity cannot change underneath an
/// unchanged `(count, maxTs)`. These pin the parts of that a test can reach; the rest is structural (the
/// reads are `ORDER BY ts ASC`, and nothing anywhere rewrites a `ts` or a vector in place).
final class GravityWitnessTests: XCTestCase {

    private func store() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await s.upsertDevice(id: "other", mac: nil, name: nil)
        return s
    }

    private func grav(_ ts: Int, _ v: Double) -> GravitySample {
        GravitySample(ts: ts, x: v, y: v, z: v, dynAccel: nil)
    }

    /// The load-bearing one. Re-offloading a second that is already banked is absorbed by
    /// `ON CONFLICT(deviceId, ts) DO NOTHING`: the stored vector is the FIRST one, not the newest. That is
    /// what makes an unchanged witness mean an unchanged fold. Were this ever flipped to a REPLACE, the
    /// values under a day would change while its count and newest timestamp held still, and the cache would
    /// serve a motion volume for data it no longer describes — silently, with no failing read.
    func testReinsertingAnExistingSecondChangesNeitherTheWitnessNorTheValues() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(gravity: [grav(100, 1), grav(200, 2)]), deviceId: "dev1")
        let before = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 1000)

        _ = try await s.insert(Streams(gravity: [grav(100, 99), grav(200, 99)]), deviceId: "dev1")
        let after = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(before.maxTs, after.maxTs)

        let rows = try await s.gravitySamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(rows.map { $0.x }, [1, 2], "conflict-ignore must keep the first vector, not the newest")
    }

    /// A new second moves both halves, so the day re-folds. Both are asserted: a witness that moved only
    /// its count would miss an append that replaced nothing, and one that moved only its newest timestamp
    /// would miss a backfilled second older than the day's last.
    func testAnAppendMovesTheWitnessAndABackfillMovesTheCount() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(gravity: [grav(200, 1)]), deviceId: "dev1")
        let one = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.maxTs, 200)

        _ = try await s.insert(Streams(gravity: [grav(300, 1)]), deviceId: "dev1")
        let appended = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(appended.count, 2)
        XCTAssertEqual(appended.maxTs, 300)

        // A second that lands BEFORE the day's newest: the timestamp holds, the count is the only witness
        // that moves. An offload does not commit its channels in order, so this is the ordinary case.
        _ = try await s.insert(Streams(gravity: [grav(100, 1)]), deviceId: "dev1")
        let backfilled = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(backfilled.count, 3)
        XCTAssertEqual(backfilled.maxTs, 300, "a backfill leaves the newest timestamp alone")
    }

    /// Scoped to one device and one window, because the cache key pairs the witness with a resolved owner
    /// and a day. Another strap's gravity, or the same strap's gravity on another day, must not move it.
    func testTheWitnessIsScopedToOneDeviceAndOneWindow() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(gravity: [grav(100, 1), grav(200, 1)]), deviceId: "dev1")
        let base = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 250)

        _ = try await s.insert(Streams(gravity: [grav(150, 1)]), deviceId: "other")
        _ = try await s.insert(Streams(gravity: [grav(900, 1)]), deviceId: "dev1")
        let after = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 250)
        XCTAssertEqual(base.count, after.count)
        XCTAssertEqual(base.maxTs, after.maxTs)
    }

    /// An empty window is a real answer, not a missing one: `(0, 0)`. The cache stores zero folds under it
    /// so an unworn gap stops re-reading its whole stream to rediscover that it is empty.
    func testAnEmptyWindowReportsZeroRatherThanFailing() async throws {
        let s = try await store()
        let fp = try await s.gravityFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(fp.count, 0)
        XCTAssertEqual(fp.maxTs, 0)
    }
}
