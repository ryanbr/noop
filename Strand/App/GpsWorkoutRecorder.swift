import Foundation
import CoreLocation
import StrandAnalytics   // WorkoutsTrace + TestCentre: the GPS-fix line for the Workouts test mode

// MARK: - GPS workout recording on Apple (#524)
//
// Android has recorded a GPS route for distance-type workouts (run / ride / walk / hike) since #215 via
// a process-level `GpsSession` + a foreground `LocationManager` stream; iOS and Mac never did, so a
// manually-started run banked HR + Effort but no route or GPS distance. This file is the Apple analogue,
// built ADDITIVELY alongside the existing manual-workout lifecycle — it never touches WHOOP, scoring,
// or the HR-window capture path.
//
// It splits into four pure-or-thin pieces so the geo math and the persist round-trip are unit-testable
// off any platform location stack:
//
//   • `RouteMath`   — pure Haversine distance, pace, and the Google "Encoded Polyline Algorithm Format"
//                     (precision 5). A byte-for-byte Swift port of Android `com.noop.analytics.RouteMath`
//                     so a route encoded on one platform decodes identically on the other (the polyline
//                     round-trips through the same local stores / exports as every other workout value).
//   • `TrackFilter` — pure, stateful fix gate: drops low-accuracy fixes and physically-impossible jumps,
//                     mirroring Android `TrackFilter` (50 m accuracy gate, ~12 m/s speed gate). Bounds the
//                     UNTRUSTED stream of OS location fixes before any of it reaches the stored route.
//   • `RouteStore`  — a tiny on-device side-store (UserDefaults) keyed by a workout's natural key
//                     (startTs + sport), holding the encoded polyline + distance for that session. The
//                     shared `WhoopStore.WorkoutRow` carries no route column on Apple, so the route lives
//                     here and is read back by WorkoutDetailView — exactly how `moments` / `sleepMarks` /
//                     the durable active-workout snapshot already persist on Apple. On-device only; never
//                     leaves the phone.
//   • `GpsWorkoutRecorder` — the thin CoreLocation wrapper. Requests When-In-Use, streams fixes through
//                     `TrackFilter` into an accumulating route, and exposes live distance/pace. FAILS
//                     SAFE everywhere: on a Mac with no location hardware, or when permission is denied /
//                     restricted, it simply records nothing rather than crashing, so the workout still
//                     banks HR + Effort without a route (parity with Android #101).

// MARK: - RouteMath (pure; Android parity)

/// Pure geo math for GPS workouts — no platform types, fully unit-testable. A Swift port of Android
/// `RouteMath`: Haversine distance, pace, and precision-5 encoded polylines, so a route is identical on
/// both platforms.
enum RouteMath {

    /// One geographic point. Plain `Double` lat/lon — not a `CLLocationCoordinate2D` — so the math stays
    /// platform-free and testable without CoreLocation.
    struct LatLng: Equatable {
        let lat: Double
        let lon: Double
        init(_ lat: Double, _ lon: Double) { self.lat = lat; self.lon = lon }
    }

    private static let earthR = 6_371_000.0 // metres

    /// Great-circle distance between two points, in metres (Haversine). Matches Android exactly.
    static func haversineMeters(_ a: LatLng, _ b: LatLng) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthR * 2 * atan2(sqrt(s), sqrt(1 - s))
    }

    /// Total route length in metres — the sum of consecutive Haversine legs. 0 for < 2 points.
    static func totalMeters(_ points: [LatLng]) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count { sum += haversineMeters(points[i - 1], points[i]) }
        return sum
    }

    /// Seconds per kilometre, or nil when distance is zero (pace undefined). Matches Android.
    static func paceSecPerKm(meters: Double, seconds: Double) -> Double? {
        meters <= 0 ? nil : seconds / (meters / 1000.0)
    }

    /// Wall-clock workout time minus completed pauses, in seconds. Kept pure so pause accounting used
    /// by the live GPS pace can be pinned without constructing a CoreLocation manager in tests.
    static func activeElapsedSeconds(startMs: Int64, nowMs: Int64, pausedDurationMs: Int64) -> Double {
        Double(nowMs - startMs - pausedDurationMs) / 1000.0
    }

    // MARK: Encoded Polyline Algorithm Format, precision 5

    /// Encode a route to a compact polyline string (Google precision-5 format). Identical output to
    /// Android `RouteMath.encode` for the same points, so the stored string is cross-platform.
    static func encode(_ points: [LatLng]) -> String {
        var out = ""
        var prevLat = 0, prevLon = 0
        for p in points {
            let lat = Int((p.lat * 1e5).rounded())
            let lon = Int((p.lon * 1e5).rounded())
            encodeSigned(lat - prevLat, into: &out)
            encodeSigned(lon - prevLon, into: &out)
            prevLat = lat
            prevLon = lon
        }
        return out
    }

    /// Decode a polyline string back to points. Bounds-checked: an untrusted / corrupt string yields the
    /// points it can parse and stops cleanly at the end (never reads past the buffer). Matches Android.
    static func decode(_ encoded: String) -> [LatLng] {
        var out: [LatLng] = []
        let chars = Array(encoded.unicodeScalars)
        var i = 0
        var lat = 0, lon = 0
        while i < chars.count {
            guard let dLat = decodeSigned(chars, &i) else { break }
            guard let dLon = decodeSigned(chars, &i) else { break }
            lat += dLat
            lon += dLon
            let p = LatLng(Double(lat) / 1e5, Double(lon) / 1e5)
            // Drop anything off the surface of the earth — a defensive gate on a decoded-from-disk value.
            if (-90...90).contains(p.lat) && (-180...180).contains(p.lon) { out.append(p) }
        }
        return out
    }

    private static func encodeSigned(_ v: Int, into out: inout String) {
        var value = v < 0 ? ~(v << 1) : (v << 1)
        while value >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar((0x20 | (value & 0x1f)) + 63)!)
            value >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(value + 63)!)
    }

    /// Decode one signed varint starting at `i`, advancing `i`. Returns nil if the buffer ends mid-value
    /// (a truncated / corrupt string) so the caller stops rather than over-reading.
    private static func decodeSigned(_ chars: [Unicode.Scalar], _ i: inout Int) -> Int? {
        var result = 0, shift = 0, b = 0
        repeat {
            guard i < chars.count else { return nil }
            b = Int(chars[i].value) - 63
            // A byte must be a valid polyline character (>= 63 once 63 is subtracted, i.e. >= 0).
            guard b >= 0 else { return nil }
            i += 1
            result |= (b & 0x1f) << shift
            shift += 5
            // Guard against a maliciously long run inflating `shift` past Int width.
            if shift > 35 { return nil }
        } while b >= 0x20
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}

// MARK: - TrackFilter (pure; Android parity)

/// A raw GPS reading before filtering. Mirrors Android `RawFix`.
struct RawFix: Equatable {
    let lat: Double
    let lon: Double
    let accuracyM: Double   // horizontal accuracy radius; < 0 from CoreLocation means "invalid"
    let tMs: Int64          // fix time, ms since epoch
}

/// Pure, stateful fix gate: drops low-accuracy fixes and physically-impossible jumps, returning the
/// accepted point or nil. Keeps the last accepted fix to gate the next. A direct port of Android
/// `TrackFilter` (so a weak-signal run admits the same legitimate fixes and rejects the same teleports).
final class TrackFilter {
    // 50 m is the realistic consumer-GPS gate during activity (Strava-class apps use ~50 m). The speed
    // gate below still rejects teleports, so the looser accuracy gate admits legitimate running fixes
    // without letting GPS jumps inflate the track. Identical thresholds to Android (#324).
    private let maxAccuracyM: Double
    private let maxSpeedMps: Double   // ~43 km/h; well above running, below GPS teleports
    private var last: RawFix?

    init(maxAccuracyM: Double = 50, maxSpeedMps: Double = 12) {
        self.maxAccuracyM = maxAccuracyM
        self.maxSpeedMps = maxSpeedMps
    }

    /// Accept a fix or reject it (nil). Rejects: an invalid / too-coarse accuracy, an out-of-range
    /// coordinate, or a jump from the last accepted fix faster than `maxSpeedMps`.
    func accept(_ fix: RawFix) -> RouteMath.LatLng? {
        // CoreLocation reports a negative horizontalAccuracy when the fix is invalid; treat that as a
        // drop, same as an over-coarse reading. (Android sees 0 for "no accuracy"; we treat < 0 as bad.)
        if fix.accuracyM < 0 || fix.accuracyM > maxAccuracyM { return nil }
        guard (-90...90).contains(fix.lat), (-180...180).contains(fix.lon) else { return nil }
        if let prev = last {
            let dt = Double(fix.tMs - prev.tMs) / 1000.0
            if dt > 0 {
                let d = RouteMath.haversineMeters(RouteMath.LatLng(prev.lat, prev.lon),
                                                  RouteMath.LatLng(fix.lat, fix.lon))
                if d / dt > maxSpeedMps { return nil }
            }
        }
        last = fix
        return RouteMath.LatLng(fix.lat, fix.lon)
    }
}

// MARK: - RouteStore (on-device side-store)

/// The route persisted for one finished workout: the encoded polyline + the GPS distance it implies.
/// A tiny `Codable` value, the unit a `RouteStore` keys by a workout's natural key.
struct WorkoutRoute: Equatable, Codable {
    /// Google precision-5 polyline of the captured route (`RouteMath.encode`).
    var polyline: String
    /// Total GPS distance in metres (`RouteMath.totalMeters` of the captured points).
    var distanceM: Double
}

/// On-device persistence for finished GPS routes, keyed by a workout's natural key (startTs + sport) so a
/// saved row can look its route back up. The shared `WhoopStore.WorkoutRow` carries no route column on
/// Apple, so the polyline lives here — mirroring how `moments` / `sleepMarks` / the active-workout
/// snapshot already persist to `UserDefaults`. Never leaves the device.
///
/// The codec (`encodeMap` / `decodeMap`) is pure (no `UserDefaults` dependency) so the persist round-trip
/// is unit-testable; `store` / `load` / `remove` just thread a `UserDefaults` through it. Bounded so a
/// long-lived install can't grow the blob without limit.
enum RouteStore {

    /// Single `UserDefaults` key holding a JSON `[key: WorkoutRoute]` map. Namespaced like `moments`.
    static let defaultsKey = "noop.workoutRoutes"

    /// Cap on stored routes — newest kept, oldest evicted (keys sort by the leading startTs). A route is
    /// a handful of bytes, but this keeps the map from growing unboundedly across an install's lifetime.
    static let maxRoutes = 400

    /// Natural key for a session's route: "<startTs>|<sport>". Stable across launches; matches the
    /// `WorkoutRow` natural key the detail screen reads. Sport is included so two sessions that share a
    /// start second (different sports) never collide.
    static func key(startTs: Int, sport: String) -> String { "\(startTs)|\(sport)" }

    /// Encode a route map to JSON. Drops any entry whose distance isn't a finite, non-negative number
    /// FIRST — JSON has no representation for NaN/Inf, so a single corrupt distance would otherwise make
    /// `JSONEncoder` throw and take the WHOLE map down with it (silently losing every valid route). We
    /// sanitise per-entry so one bad row can never poison the blob. Returns nil only if encoding the
    /// already-clean map fails (never expected for this shape).
    static func encodeMap(_ map: [String: WorkoutRoute]) -> Data? {
        let clean = map.filter { $0.value.distanceM.isFinite && $0.value.distanceM >= 0 }
        return try? JSONEncoder().encode(clean)
    }

    /// Decode a route map from JSON, dropping any entry whose distance isn't a finite, non-negative
    /// number — never trust the persisted blob to be clean (belt-and-braces with `encodeMap`'s sanitise).
    /// nil/garbage yields an empty map.
    static func decodeMap(_ data: Data?) -> [String: WorkoutRoute] {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode([String: WorkoutRoute].self, from: data) else { return [:] }
        return raw.filter { $0.value.distanceM.isFinite && $0.value.distanceM >= 0 }
    }

    /// Read the whole stored map (bound-checked).
    static func loadMap(from defaults: UserDefaults = .standard) -> [String: WorkoutRoute] {
        decodeMap(defaults.data(forKey: defaultsKey))
    }

    /// The route for a finished workout, or nil if none was recorded.
    static func load(startTs: Int, sport: String, from defaults: UserDefaults = .standard) -> WorkoutRoute? {
        loadMap(from: defaults)[key(startTs: startTs, sport: sport)]
    }

    /// Persist `route` for a workout, evicting the oldest entries if the cap is exceeded. A no-op when the
    /// route has no usable polyline (so we never store an empty placeholder — honest "no route").
    static func store(_ route: WorkoutRoute, startTs: Int, sport: String,
                      into defaults: UserDefaults = .standard) {
        guard !route.polyline.isEmpty else { return }
        var map = loadMap(from: defaults)
        map[key(startTs: startTs, sport: sport)] = route
        if map.count > maxRoutes {
            // Keys lead with the startTs, so a lexicographic sort by the numeric prefix evicts the oldest.
            let ordered = map.keys.sorted { lhs, rhs in
                (Int(lhs.split(separator: "|").first ?? "") ?? 0)
                    < (Int(rhs.split(separator: "|").first ?? "") ?? 0)
            }
            for k in ordered.prefix(map.count - maxRoutes) { map.removeValue(forKey: k) }
        }
        guard let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Remove a workout's route (used when a session is deleted; keeps the side-store from leaking).
    static func remove(startTs: Int, sport: String, from defaults: UserDefaults = .standard) {
        var map = loadMap(from: defaults)
        guard map.removeValue(forKey: key(startTs: startTs, sport: sport)) != nil,
              let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

// MARK: - GpsWorkoutRecorder (CoreLocation wrapper)

/// Records the route of an in-flight GPS workout from CoreLocation. Thin and fail-safe: requests
/// When-In-Use authorization, streams fixes through `TrackFilter`, and accumulates the route + live
/// distance/pace. The owning `AppModel` starts it when a distance-type sport is begun and reads the final
/// route on End.
///
/// Availability:
///   • iOS — full GPS. (The Info.plist must carry `NSLocationWhenInUseUsageDescription`, and the iOS
///     target's `UIBackgroundModes` should include `location` for the route to keep accruing while the
///     screen is off, mirroring Android's foreground service. See the lane's notes.)
///   • macOS — `CLLocationManager` exists but most Macs have no GPS; if no fixes arrive the route simply
///     stays empty. Either way nothing crashes.
///
/// `@MainActor` so its `@Published` live values drive SwiftUI directly. CoreLocation delivers its
/// delegate callbacks on the run loop the manager was created on — here the main thread — so MainActor
/// isolation is sound; the `@preconcurrency CLLocationManagerDelegate` extension below lets this
/// `@MainActor` type satisfy the nonisolated delegate requirements (the same idiom `StandardHRSource`
/// uses for its CoreBluetooth delegate).
@MainActor
final class GpsWorkoutRecorder: NSObject, ObservableObject {

    /// True while a route is being recorded. The active-workout card can show a "GPS" pill off this.
    @Published private(set) var isRecording = false
    /// Live route distance in metres (0 until two accepted fixes). Honest: 0 when nothing was captured.
    @Published private(set) var distanceM: Double = 0
    /// Live pace in seconds per kilometre, or nil when distance is still zero (pace undefined).
    @Published private(set) var paceSecPerKm: Double?
    /// Number of accepted route points so far (lets the UI distinguish "recording, no fix yet" from "off").
    @Published private(set) var pointCount = 0

    private let manager = CLLocationManager()
    private var filter = TrackFilter()
    private var track: [RouteMath.LatLng] = []
    private var startMs: Int64 = 0
    private var pausedAtMs: Int64?
    private var pausedDurationMs: Int64 = 0

    /// Workouts & GPS test mode (Test Centre): the tagged sink for the `.workouts` GPS-fix lines, wired by
    /// AppModel to `live.append(log:domain:)`. Default nil (inert). We ALWAYS check `TestCentre.active(.workouts)`
    /// BEFORE building any line, so the recorder pays nothing when the mode is off. Diagnostic only - it never
    /// changes the route. `rawFixCount` is the running count of raw fixes seen (accepted + rejected) so the
    /// line can show the filter's accept rate; reset on `start`.
    var workoutsLog: ((String) -> Void)?
    private var rawFixCount = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // ~5 m between callbacks; TrackFilter still gates on accuracy + speed. Matches the cadence intent
        // of Android's 2 s / 0 m platform request (let the filter, not the platform, do the gating).
        manager.distanceFilter = 5
        #if os(iOS)
        // Keep the route accruing while the screen is off, matching Android's foreground-service capture.
        // Safe only because the iOS target declares the `location` UIBackgroundMode (project.yml); setting
        // this without that mode would crash when updates start.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        #endif
    }

    /// Begin recording a fresh route for a workout started at `startMs` (unix milliseconds). Requests
    /// When-In-Use if not yet decided; fails safe (records nothing) if denied / restricted / unavailable.
    /// A re-arm resets the track. Returns immediately — fixes arrive asynchronously via the delegate.
    func start(startMs: Int64) {
        track.removeAll()
        filter = TrackFilter()
        self.startMs = startMs
        pausedAtMs = nil
        pausedDurationMs = 0
        distanceM = 0
        paceSecPerKm = nil
        pointCount = 0
        rawFixCount = 0
        isRecording = true

        switch manager.authorizationStatus {
        case .notDetermined:
            // Ask now; updates begin in `locationManagerDidChangeAuthorization` once the user answers.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            // Denied / restricted: stay armed but capture nothing. The workout still banks HR + Effort,
            // and the saved row carries no route (honest "—"), exactly like Android when permission is
            // refused (#101). We do NOT re-prompt — that's the user's Settings choice to reverse.
            break
        }
    }

    /// Re-arm a route after restoring an in-flight workout from disk. Route points themselves are not
    /// persisted mid-session, but the original clock and pause accounting must survive so subsequent
    /// live pace excludes all time the workout spent paused before and across the relaunch.
    func restore(startMs: Int64, pausedAtMs: Int64?, pausedDurationMs: Int64) {
        start(startMs: startMs)
        self.pausedDurationMs = max(0, pausedDurationMs)
        if let pausedAtMs {
            self.pausedAtMs = pausedAtMs
            manager.stopUpdatingLocation()
            isRecording = false
        }
    }

    /// Stop recording and return the final accumulated route. Safe to call when not recording (returns
    /// whatever was captured, possibly empty). Tears down location updates so no battery is spent after.
    @discardableResult
    func stop() -> [RouteMath.LatLng] {
        manager.stopUpdatingLocation()
        isRecording = false
        let final = track
        return final
    }

    func pause() {
        guard isRecording else { return }
        pausedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        manager.stopUpdatingLocation()
        isRecording = false
    }

    func resume() {
        guard startMs > 0 else { return }
        if let pausedAtMs {
            pausedDurationMs += Int64(Date().timeIntervalSince1970 * 1000) - pausedAtMs
            self.pausedAtMs = nil
        }
        isRecording = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    /// The encoded polyline + distance for the captured route, or nil when fewer than two points landed
    /// (honest: no route drawn unless points were actually captured). Used by `AppModel` to persist via
    /// `RouteStore` when the session ends.
    func capturedRoute() -> WorkoutRoute? {
        guard track.count >= 2 else { return nil }
        return WorkoutRoute(polyline: RouteMath.encode(track),
                            distanceM: RouteMath.totalMeters(track))
    }

    // MARK: Updates

    fileprivate func beginUpdates() {
        // Wrapped: a Mac with no location services, or an OEM quirk, must never crash the app — just
        // record nothing. Mirrors Android's try/catch around requestLocationUpdates (#101).
        guard CLLocationManager.locationServicesEnabled() else { return }
        manager.startUpdatingLocation()
    }

    /// Fold a batch of (already bound-checked at the source) fixes into the route, updating live
    /// distance/pace. No-op when not recording.
    fileprivate func ingest(_ fixes: [RawFix]) {
        guard isRecording else { return }
        rawFixCount += fixes.count
        var changed = false
        for fix in fixes {
            if let pt = filter.accept(fix) {
                track.append(pt)
                changed = true
            }
        }
        guard changed else { return }
        pointCount = track.count
        distanceM = RouteMath.totalMeters(track)
        let elapsed = RouteMath.activeElapsedSeconds(
            startMs: startMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            pausedDurationMs: pausedDurationMs
        )
        paceSecPerKm = RouteMath.paceSecPerKm(meters: distanceM, seconds: elapsed)
        // Workouts & GPS test mode: one GPS-fix-progress line tagged `.workouts` per batch that added a point,
        // showing raw fixes seen, how many the accuracy/speed filter accepted, and the running distance, so a
        // route that under-records (weak signal / denied permission) is visible. Zero-cost when off (the gate
        // is one UserDefaults bool read), and gated on a non-nil sink so non-prod recorders stay silent.
        if TestCentre.active(.workouts), let workoutsLog {
            workoutsLog(WorkoutsTrace.gpsLine(rawFixes: rawFixCount, acceptedPoints: pointCount,
                                              distanceM: distanceM))
        }
    }
}

// MARK: - CLLocationManagerDelegate
//
// The queue-less manager (created on main) delivers callbacks on the main thread, so MainActor isolation
// is sound; `@preconcurrency` lets this `@MainActor` type satisfy the nonisolated delegate requirements
// (same pattern as `StandardHRSource`'s CoreBluetooth delegate).

extension GpsWorkoutRecorder: @preconcurrency CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRecording else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            // Revoked mid-session: stop streaming but keep whatever route was captured so far (honest).
            manager.stopUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CoreLocation hands us an UNTRUSTED batch — map to RawFix and let TrackFilter bound-check every
        // field (accuracy, coordinate range, speed) before any of it reaches the stored route.
        let fixes: [RawFix] = locations.map {
            RawFix(lat: $0.coordinate.latitude,
                   lon: $0.coordinate.longitude,
                   accuracyM: $0.horizontalAccuracy,
                   tMs: Int64($0.timestamp.timeIntervalSince1970 * 1000))
        }
        ingest(fixes)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure (no fix yet) is normal and self-heals; we never tear down on it. A hard
        // denial arrives via the auth callback instead. Swallow so a GPS hiccup can't crash a workout.
    }
}
