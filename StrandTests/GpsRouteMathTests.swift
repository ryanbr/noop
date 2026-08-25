import XCTest
import Foundation
@testable import Strand

/// Pins the Apple GPS workout recorder's pure pieces (#524): distance accumulation, the precision-5
/// polyline codec (which must round-trip AND match Android `RouteMath` byte-for-byte so a route is
/// cross-platform), the untrusted-fix `TrackFilter` gate, and the on-device `RouteStore` round-trip.
/// All pure / UserDefaults-backed — no CoreLocation — so they run headless, mirroring the Android
/// `RouteMathTest` case for case.
final class GpsRouteMathTests: XCTestCase {

    // Two points ~451 m apart near the Thames (the SAME fixtures Android `RouteMathTest` uses).
    private let a = RouteMath.LatLng(51.5033, -0.1196)
    private let b = RouteMath.LatLng(51.5007, -0.1246)

    // MARK: - Distance + pace (Android parity)

    func testHaversineKnownDistance() {
        XCTAssertEqual(RouteMath.haversineMeters(a, b), 451.0, accuracy: 20.0)
    }

    func testTotalDistanceSumsSegments() {
        let total = RouteMath.totalMeters([a, b, a])
        XCTAssertEqual(total, RouteMath.haversineMeters(a, b) * 2, accuracy: 1.0)
    }

    func testTotalDistanceEmptyOrSingleIsZero() {
        XCTAssertEqual(RouteMath.totalMeters([]), 0.0, accuracy: 0.0)
        XCTAssertEqual(RouteMath.totalMeters([a]), 0.0, accuracy: 0.0)
    }

    /// Distance accumulation as the recorder folds in fixes: a 4-point track's total equals the sum of
    /// its consecutive legs (the exact thing `GpsWorkoutRecorder.ingest` recomputes per batch).
    func testDistanceAccumulatesAcrossGrowingTrack() {
        let c = RouteMath.LatLng(51.4995, -0.1357)
        let d = RouteMath.LatLng(51.4980, -0.1400)
        var track: [RouteMath.LatLng] = []
        var running = 0.0
        for p in [a, b, c, d] {
            if let prev = track.last { running += RouteMath.haversineMeters(prev, p) }
            track.append(p)
            // The running sum kept incrementally must always equal a fresh full recompute.
            XCTAssertEqual(RouteMath.totalMeters(track), running, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(running, 0)
    }

    func testPaceSecPerKm() {
        XCTAssertEqual(RouteMath.paceSecPerKm(meters: 1000, seconds: 300)!, 300.0, accuracy: 0.001)
        XCTAssertNil(RouteMath.paceSecPerKm(meters: 0, seconds: 300))
    }

    func testActiveElapsedSecondsExcludesCompletedPauses() {
        XCTAssertEqual(
            RouteMath.activeElapsedSeconds(startMs: 1_000, nowMs: 11_000, pausedDurationMs: 2_500),
            7.5,
            accuracy: 0.001
        )
    }

    // MARK: - Polyline codec (round-trip + cross-platform golden)

    func testPolylineRoundTrips() {
        let pts = [a, b, RouteMath.LatLng(51.4995, -0.1357)]
        let decoded = RouteMath.decode(RouteMath.encode(pts))
        XCTAssertEqual(decoded.count, pts.count)
        for i in pts.indices {
            XCTAssertEqual(decoded[i].lat, pts[i].lat, accuracy: 1e-5)
            XCTAssertEqual(decoded[i].lon, pts[i].lon, accuracy: 1e-5)
        }
    }

    func testEncodeEmptyIsEmptyString() {
        XCTAssertTrue(RouteMath.encode([]).isEmpty)
        XCTAssertTrue(RouteMath.decode("").isEmpty)
    }

    /// The canonical Google "Encoded Polyline Algorithm Format" reference example. Our encoder MUST
    /// produce this EXACT string — it's the contract that the Android encoder (same algorithm) and any
    /// external decoder agree on, so a route stored on one platform reads on the other.
    func testPolylineMatchesGoogleReferenceGolden() {
        let pts = [
            RouteMath.LatLng(38.5, -120.2),
            RouteMath.LatLng(40.7, -120.95),
            RouteMath.LatLng(43.252, -126.453),
        ]
        XCTAssertEqual(RouteMath.encode(pts), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let back = RouteMath.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].lat, 38.5, accuracy: 1e-5)
        XCTAssertEqual(back[2].lon, -126.453, accuracy: 1e-5)
    }

    /// A truncated / corrupt polyline must decode to whatever it can parse and stop cleanly — never crash
    /// or read past the buffer (the string is read back from disk, so it's untrusted).
    func testDecodeTruncatedStopsCleanly() {
        let good = RouteMath.encode([a, b])
        let truncated = String(good.dropLast())
        // Doesn't crash; yields at most the points it could fully parse.
        let decoded = RouteMath.decode(truncated)
        XCTAssertLessThanOrEqual(decoded.count, 2)
    }

    func testDecodeGarbageDoesNotCrash() {
        _ = RouteMath.decode("not-a-polyline-!!!")
        _ = RouteMath.decode("\u{0}\u{1}\u{2}")
    }

    // MARK: - TrackFilter (untrusted-fix gate; Android parity)

    private func fix(_ lat: Double, _ lon: Double, acc: Double, t: Int64) -> RawFix {
        RawFix(lat: lat, lon: lon, accuracyM: acc, tMs: t)
    }

    func testFilterDropsLowAccuracyFixes() {
        let f = TrackFilter()
        XCTAssertNil(f.accept(fix(51.50, -0.12, acc: 80, t: 0)))   // > 50 m gate
        XCTAssertNotNil(f.accept(fix(51.50, -0.12, acc: 10, t: 0))) // good
    }

    func testFilterDropsInvalidNegativeAccuracy() {
        // CoreLocation reports a negative horizontalAccuracy for an invalid fix — must be rejected.
        XCTAssertNil(TrackFilter().accept(fix(51.50, -0.12, acc: -1, t: 0)))
    }

    func testFilterDropsTeleportJumps() {
        let f = TrackFilter()
        XCTAssertNotNil(f.accept(fix(51.5000, -0.1200, acc: 5, t: 0)))
        // ~450 m in 1 s = 450 m/s — far above the ~12 m/s gate, so it's a GPS jump and is rejected.
        XCTAssertNil(f.accept(fix(51.5007, -0.1246, acc: 5, t: 1000)))
        // The same move over 60 s (~7.5 m/s) is a believable run pace and is accepted.
        XCTAssertNotNil(f.accept(fix(51.5007, -0.1246, acc: 5, t: 60_000)))
    }

    func testFilterRejectsOutOfRangeCoordinates() {
        XCTAssertNil(TrackFilter().accept(fix(120, 0, acc: 5, t: 0)))      // lat > 90
        XCTAssertNil(TrackFilter().accept(fix(0, 200, acc: 5, t: 0)))      // lon > 180
    }

    // MARK: - RouteStore (on-device side-store round-trip)

    private func freshDefaults() -> UserDefaults {
        let name = "test.workoutRoutes.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRouteStoreRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]),
                                 distanceM: RouteMath.totalMeters([a, b]))
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), route)
        // Removing it leaves no orphan.
        RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    func testRouteStoreKeysBySportAndStart() {
        let defaults = freshDefaults()
        let run = WorkoutRoute(polyline: RouteMath.encode([a, b]), distanceM: 1)
        let walk = WorkoutRoute(polyline: RouteMath.encode([b, a]), distanceM: 2)
        // Same start second, different sport — must NOT collide.
        RouteStore.store(run, startTs: 1_700_000_000, sport: "Running", into: defaults)
        RouteStore.store(walk, startTs: 1_700_000_000, sport: "Walking", into: defaults)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), run)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Walking", from: defaults), walk)
    }

    func testRouteStoreRejectsEmptyPolyline() {
        let defaults = freshDefaults()
        // An honest "no route" must never be stored as an empty placeholder.
        RouteStore.store(WorkoutRoute(polyline: "", distanceM: 0),
                         startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    func testRouteStoreDropsNonFiniteDistanceOnDecode() {
        // A corrupt blob with a non-finite distance is dropped on read — never trust the persisted value.
        let dirty: [String: WorkoutRoute] = [
            RouteStore.key(startTs: 1, sport: "Running"): WorkoutRoute(polyline: "abc", distanceM: .nan),
            RouteStore.key(startTs: 2, sport: "Cycling"): WorkoutRoute(polyline: "def", distanceM: 1234),
        ]
        let data = RouteStore.encodeMap(dirty)
        let decoded = RouteStore.decodeMap(data)
        XCTAssertNil(decoded[RouteStore.key(startTs: 1, sport: "Running")])
        XCTAssertNotNil(decoded[RouteStore.key(startTs: 2, sport: "Cycling")])
    }

    func testRouteStoreEvictsOldestPastCap() {
        let defaults = freshDefaults()
        // Store cap + 5 routes; the oldest 5 (lowest startTs) must be evicted, newest kept.
        let total = RouteStore.maxRoutes + 5
        for i in 0..<total {
            RouteStore.store(WorkoutRoute(polyline: "abc", distanceM: Double(i)),
                             startTs: 1_000_000 + i, sport: "Running", into: defaults)
        }
        let map = RouteStore.loadMap(from: defaults)
        XCTAssertEqual(map.count, RouteStore.maxRoutes)
        // The 5 oldest are gone; a recent one survives.
        XCTAssertNil(map[RouteStore.key(startTs: 1_000_000, sport: "Running")])
        XCTAssertNotNil(map[RouteStore.key(startTs: 1_000_000 + total - 1, sport: "Running")])
    }

    // MARK: - Re-key on edit (#10)

    /// #10: editing a GPS workout's sport or start re-keys its DB row, so its route must move to the new
    /// natural key too or the detail view loses the route + distance. This pins the exact re-key sequence
    /// Repository.saveManualWorkout runs in the changed-key branch (load old, store new, remove old): the
    /// route ends up under the NEW key only, byte-identical, with no orphan left behind.
    func testRouteStoreReKeyOnNaturalKeyChangePreservesRoute() {
        let defaults = freshDefaults()
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]),
                                 distanceM: RouteMath.totalMeters([a, b]))
        // The original session's route, keyed by its old (startTs, sport).
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)

        // Re-key to a new sport AND a new start, exactly as the save path does on an edit.
        if let old = RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults) {
            RouteStore.store(old, startTs: 1_700_000_500, sport: "Walking", into: defaults)
            RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        }

        // Route lives under the NEW key, unchanged; the OLD key is clear (no orphan, no distance ghost).
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_500, sport: "Walking", from: defaults), route)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        XCTAssertEqual(RouteStore.loadMap(from: defaults).count, 1)
    }

    /// #10 guard: a workout with NO recorded route stays a clean no-op on edit. The load returns nil, so
    /// the save path's `if let` never stores or removes anything, and the side-store stays empty.
    func testRouteStoreReKeyNoRouteIsNoOp() {
        let defaults = freshDefaults()
        if let old = RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults) {
            RouteStore.store(old, startTs: 1_700_000_500, sport: "Walking", into: defaults)
            RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        }
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_500, sport: "Walking", from: defaults))
        XCTAssertTrue(RouteStore.loadMap(from: defaults).isEmpty)
    }
}
