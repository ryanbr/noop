import Foundation

// MARK: - On-device activity-file import (GPX / TCX / FIT) — source "activity-file"
//
// Lets a user bring in a single exported activity FILE from ANY brand — Garmin, Coros, Suunto,
// Wahoo, Polar, Strava, WHOOP, Apple, etc. — fully offline. The three universal interchange formats
// are covered:
//
//   • GPX  (XML)    — the universal GPS-track format. <trk><trkseg><trkpt lat lon> with optional
//                     <ele>, <time>, and Garmin TrackPointExtension HR/cadence. Every brand exports it.
//   • TCX  (XML)    — Garmin Training Center XML. <Activities><Activity><Lap><Track><Trackpoint> with
//                     HeartRateBpm, DistanceMeters, AltitudeMeters, Cadence, plus per-Lap summaries.
//   • FIT  (binary) — the Garmin/ANT native format. A 12/14-byte header, then definition + data
//                     records (little-endian). We decode the common activity/record/lap/session
//                     messages; rarer developer/message types are skipped (see ActivityFileImporter
//                     follow-up notes), never fatal.
//
// This is PARSING ONLY — exactly like LiftingImporter / WhoopExportImporter, it produces a normalized
// `ActivityFile` that the app layer maps 1:1 onto the existing `WorkoutRow` store path (the same one
// the WHOOP-CSV and manual-workout imports use). It never touches live data, scoring, or the WHOOP
// import paths.
//
// SECURITY: every byte here is UNTRUSTED. The XML parsers cap element depth and total trackpoints; the
// FIT decoder bounds every field read against the buffer, caps record/field counts, and rejects an
// implausible declared size — mirroring the StrandImport DoS guards (a crafted file must be rejected,
// never crash or OOM). Numeric → Int conversions are finite/range-checked (no trapping `Int(Double)`).

// MARK: - Normalized model

/// Shared display formatter for imported-activity distance. Distances are nonnegative, so explicit
/// ties-away-from-zero is the same half-up policy as Kotlin's `roundToInt()` (10.5 km → 11 km).
/// Keep the sub-10 km two-decimal path unchanged; this formats text only and never mutates `distanceM`.
private func activityDistanceText(_ distanceM: Double) -> String {
    let km = distanceM / 1000.0
    return km >= 10
        ? String(format: "%.0f km", km.rounded(.toNearestOrAwayFromZero))
        : String(format: "%.2f km", km)
}

/// One imported activity (the shape the app layer maps onto a `WorkoutRow`, plus optional
/// activity-file daily metrics when present). Distances are metres, HR is bpm, energy is kcal.
/// Times are UTC `Date`s. A field is `nil` when the file didn't carry it — never fabricated.
public struct ActivityFile: Sendable, Equatable {
    /// Which interchange format the file was.
    public enum Kind: String, Sendable, Equatable { case gpx, tcx, fit }

    public var kind: Kind
    /// Activity start (UTC) — the earliest trackpoint/record time, or a header start time.
    public var start: Date
    /// Activity end (UTC) — the latest trackpoint/record time. Falls back to `start`.
    public var end: Date
    /// Brand/sport label as the file named it (e.g. "running", "Biking"). Normalized to a NOOP sport
    /// string by the app layer; `nil` → a neutral "Activity".
    public var sport: String?
    /// Total distance in metres, when present (a file summary value, else summed from the track).
    public var distanceM: Double?
    /// Total active energy in kilocalories, when present.
    public var energyKcal: Double?
    /// Activity step count when the file carries one.
    public var steps: Int?
    /// Average heart rate (bpm), when present (a summary value, else the mean of sampled HR).
    public var avgHr: Int?
    /// Maximum heart rate (bpm), when present.
    public var maxHr: Int?
    /// Total ascent in metres, when present (summed positive elevation deltas, else a summary value).
    public var ascentM: Double?
    /// Number of GPS points carrying a lat/lon, for an honest "N GPS points" note. 0 = no route.
    public var gpsPointCount: Int
    /// Number of heart-rate samples seen, for an honest note. 0 = no HR in the file.
    public var hrSampleCount: Int
    /// The route as (lat, lon) pairs in order, for the platforms that store a polyline (Android's
    /// `routePolyline`). macOS's shared WorkoutRow has no route column, so it keeps only the summary.
    public var route: [RoutePoint]
    /// #137: the REAL per-sample HR time series — the (unix-second, bpm) pairs the file actually
    /// carried. Historically the importer folded these into `avgHr`/`maxHr`/`hrSampleCount` and then
    /// THREW THE SAMPLES AWAY (deliberately: an imported file never fed the HR-based Effort). We now
    /// keep them so the app layer can persist them under the `activity-file` source; on a strap-less
    /// day that lets the imported ride's measured HR light the day Effort ring (the day-owner resolver
    /// picks `activity-file` as the sole source with HR that day — see IntelligenceEngine.resolveDayOwner).
    /// This is measured data, not a fabricated strain, so it does not reintroduce the "fabricated
    /// cardiovascular strain" the WorkoutRow `strain = nil` guard exists to avoid. Only samples that
    /// carried BOTH a timestamp and a valid HR appear here (a sample with no time can't key into the
    /// (deviceId, ts) HR store), so `hrSamples.count <= hrSampleCount` in general.
    public var hrSamples: [ActivityHRSample]

    public init(
        kind: Kind,
        start: Date,
        end: Date,
        sport: String? = nil,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        steps: Int? = nil,
        avgHr: Int? = nil,
        maxHr: Int? = nil,
        ascentM: Double? = nil,
        gpsPointCount: Int = 0,
        hrSampleCount: Int = 0,
        route: [RoutePoint] = [],
        hrSamples: [ActivityHRSample] = []
    ) {
        self.kind = kind
        self.start = start
        self.end = end
        self.sport = sport
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.steps = steps
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.ascentM = ascentM
        self.gpsPointCount = gpsPointCount
        self.hrSampleCount = hrSampleCount
        self.route = route
        self.hrSamples = hrSamples
    }

    /// Duration in seconds, or nil when start == end (no real interval to claim).
    public var durationS: Double? {
        let d = end.timeIntervalSince(start)
        return d > 0 ? d : nil
    }

    /// Honest one-line note for the workout row, e.g.
    /// "Imported GPX · 8.2 km · 412 GPS points · 1,840 HR samples". Only states what's actually present.
    public func importNote() -> String {
        var parts: [String] = ["Imported \(kind.rawValue.uppercased())"]
        if let d = distanceM, d > 0 {
            parts.append(activityDistanceText(d))
        }
        if gpsPointCount > 0 { parts.append("\(gpsPointCount) GPS points") }
        if hrSampleCount > 0 { parts.append("\(hrSampleCount) HR samples") }
        if let steps, steps > 0 { parts.append("\(steps) steps") }
        return parts.joined(separator: " · ")
    }
}

/// One GPS fix: latitude/longitude in degrees (route polyline source).
public struct RoutePoint: Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var time: Date?
    public init(lat: Double, lon: Double, time: Date? = nil) {
        self.lat = lat
        self.lon = lon
        self.time = time
    }
}

/// #137: one persisted HR sample — unix-second timestamp + bpm. Deliberately a LOCAL type (not
/// WhoopProtocol's `HRSample`) so the pure StrandImport package stays dependency-free; the app layer
/// maps this 1:1 onto `HRSample` when writing to the HR store. Keep the (ts, bpm) shape in parity with
/// the Kotlin `ActivityFileImporter.HrSample` twin.
public struct ActivityHRSample: Sendable, Equatable {
    /// Wall-clock unix seconds (the sample's own time, from the file).
    public var ts: Int
    /// Heart rate in bpm (already range-validated by `validHr` upstream).
    public var bpm: Int
    public init(ts: Int, bpm: Int) {
        self.ts = ts
        self.bpm = bpm
    }
}

/// Result of parsing an activity file: the activity (when one was found), the format, plus how many
/// trackpoints/records were skipped. Mirrors the tolerant-summary ethos of the other importers.
public struct ActivityFileImportResult: Sendable, Equatable {
    /// The parsed activity, or nil when the file held no usable track/records.
    public var activity: ActivityFile?
    /// The detected format (best-effort, even when `activity` is nil).
    public var kind: ActivityFile.Kind
    /// Trackpoints / records dropped: missing time, malformed coordinate, out-of-range value.
    public var skipped: Int

    public init(activity: ActivityFile?, kind: ActivityFile.Kind, skipped: Int) {
        self.activity = activity
        self.kind = kind
        self.skipped = skipped
    }

    public var hasActivity: Bool { activity != nil }
}

// MARK: - Importer

public enum ActivityFileImporter {

    /// Provenance/source id the app writes as the workout `source` column — classified as
    /// `.activityFile` so the Workouts list shows an honest "File import" badge distinct from
    /// WHOOP/Apple/manual/lifting.
    public static let sourceId = "activity-file"

    /// Hard ceilings (DoS guards, mirroring StrandImport's `maxEntryBytes` ethos).
    /// A real GPX/TCX is a few MB; a FIT is tens–hundreds of KB. 128 MB is already absurdly generous,
    /// and the per-collection caps stop a crafted file from inflating RAM even within that byte budget.
    /// Public so the app layer can pre-reject an oversized read before parsing.
    public static let maxBytes = 128 << 20
    /// Max trackpoints/records we retain. ~16h at 1 Hz is ~58k; 1,000,000 is a wide safety margin that
    /// still bounds memory hard against a file claiming hundreds of millions of points.
    static let maxPoints = 1_000_000

    // MARK: - Format detection

    public enum Format: Sendable, Equatable { case gpx, tcx, fit, unknown }

    /// Detect the format from the filename extension first, then content magic bytes. FIT has a
    /// definitive ".FIT" signature at offset 8; GPX/TCX are sniffed from their root XML element.
    public static func detectFormat(filename: String?, data: Data) -> Format {
        // Match Kotlin substringAfterLast('.', "") exactly: only text after a literal final dot is
        // an extension. A missing or trailing dot therefore has no usable extension and falls through
        // to content detection instead of reusing an earlier non-empty token.
        if let filename, let dot = filename.lastIndex(of: ".") {
            let ext = filename[filename.index(after: dot)...].lowercased()
            switch ext {
            case "gpx": return .gpx
            case "tcx": return .tcx
            case "fit": return .fit
            default: break
            }
        }
        return detectFormat(data: data)
    }

    /// Content-only detection (magic bytes / root element). Used when there's no usable extension.
    public static func detectFormat(data: Data) -> Format {
        // FIT: header is >=12 bytes; bytes 8..11 are the ASCII signature ".FIT".
        if data.count >= 12 {
            let sigStart = data.startIndex + 8
            if data[sigStart] == UInt8(ascii: ".") ,
               data[sigStart + 1] == UInt8(ascii: "F"),
               data[sigStart + 2] == UInt8(ascii: "I"),
               data[sigStart + 3] == UInt8(ascii: "T") {
                return .fit
            }
        }
        // XML: sniff the first ~512 bytes (BOM-stripped) for the root element.
        let head = BOM.stripUTF8(data).prefix(512)
        if let s = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) {
            let lower = s.lowercased()
            if lower.contains("<gpx") { return .gpx }
            if lower.contains("<trainingcenterdatabase") || lower.contains("<tcx") { return .tcx }
        }
        return .unknown
    }

    /// Parse raw file bytes, auto-detecting the format from the filename (preferred) then content.
    /// Never throws — a malformed/unknown file yields a result with `activity == nil`.
    public static func parse(data: Data, filename: String? = nil) -> ActivityFileImportResult {
        // DoS guard: refuse an implausibly large buffer outright (the picker already copies to a local
        // file, so we only ever hold one activity's bytes — still, cap it).
        if data.count > maxBytes {
            return ActivityFileImportResult(activity: nil, kind: .gpx, skipped: 0)
        }
        switch detectFormat(filename: filename, data: data) {
        case .gpx:     return GpxParser.parse(data: data)
        case .tcx:     return TcxParser.parse(data: data)
        case .fit:     return FitParser.parse(data: data)
        case .unknown:
            // Last-ditch: try each XML parser, then FIT, picking the first that yields an activity.
            let g = GpxParser.parse(data: data); if g.hasActivity { return g }
            let t = TcxParser.parse(data: data); if t.hasActivity { return t }
            return FitParser.parse(data: data)
        }
    }

    // MARK: - Shared post-processing

    /// Fold an ordered list of timestamped/located/HR-bearing samples into a normalized `ActivityFile`,
    /// computing distance/ascent/HR summaries that the file didn't already provide. Pure + shared by
    /// the GPX and TCX paths (FIT builds its own from message fields but reuses the math helpers).
    static func build(
        kind: ActivityFile.Kind,
        samples: [TrackSample],
        sportHint: String?,
        summaryDistanceM: Double?,
        summaryEnergyKcal: Double?,
        summaryAvgHr: Int?,
        summaryMaxHr: Int?,
        summaryAscentM: Double?,
        skipped: Int
    ) -> ActivityFileImportResult {
        guard !samples.isEmpty else {
            return ActivityFileImportResult(activity: nil, kind: kind, skipped: skipped)
        }
        // Times: prefer real per-sample times; if none carried a time, the activity has no honest
        // interval — fall back to a zero-length window at the epoch is wrong, so require at least one.
        let times = samples.compactMap { $0.time }
        guard let start = times.min(), let end = times.max() else {
            // No timestamps anywhere: a pure coordinate track (rare). Keep it but with no interval.
            let route = samples.compactMap { sample -> RoutePoint? in
                guard let point = sample.point else { return nil }
                return RoutePoint(lat: point.lat, lon: point.lon, time: sample.time)
            }
            guard !route.isEmpty else {
                return ActivityFileImportResult(activity: nil, kind: kind, skipped: skipped)
            }
            let dist = summaryDistanceM ?? (route.count >= 2 ? routeDistanceM(route) : nil)
            let now = Date(timeIntervalSince1970: 0)
            let a = ActivityFile(
                kind: kind, start: now, end: now, sport: sportHint,
                distanceM: dist, energyKcal: summaryEnergyKcal,
                steps: nil, avgHr: summaryAvgHr, maxHr: summaryMaxHr,
                ascentM: summaryAscentM, gpsPointCount: route.count,
                hrSampleCount: 0, route: cappedRoute(route)
            )
            return ActivityFileImportResult(activity: a, kind: kind, skipped: skipped)
        }

        let route = samples.compactMap { sample -> RoutePoint? in
                guard let point = sample.point else { return nil }
                return RoutePoint(lat: point.lat, lon: point.lon, time: sample.time)
            }
        let hrs = samples.compactMap { $0.hr }

        let distance = summaryDistanceM ?? (route.count >= 2 ? routeDistanceM(route) : nil)
        let ascent = summaryAscentM ?? ascentM(from: samples)
        let avg = summaryAvgHr ?? (hrs.isEmpty ? nil : Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded()))
        let mx = summaryMaxHr ?? hrs.max()

        let a = ActivityFile(
            kind: kind,
            start: start,
            end: max(end, start),
            sport: sportHint,
            distanceM: distance,
            energyKcal: summaryEnergyKcal,
            steps: nil,
            avgHr: avg,
            maxHr: mx,
            ascentM: ascent,
            gpsPointCount: route.count,
            hrSampleCount: hrs.count,
            route: cappedRoute(route),
            // #137: carry the real per-sample HR through (only timestamped+HR samples survive). The
            // no-timestamp fallback path above intentionally leaves this empty — those samples have no
            // epoch to key into the HR store.
            hrSamples: hrSamples(from: samples)
        )
        return ActivityFileImportResult(activity: a, kind: kind, skipped: skipped)
    }

    /// One parsed track sample. Any field may be nil — only what the point carried.
    struct TrackSample: Equatable {
        var time: Date?
        var point: RoutePoint?
        var elevationM: Double?
        var hr: Int?
    }

    /// #137: fold the parsed track samples into the persisted HR series. SHARED by every format path
    /// (GPX/TCX via `build`, FIT via `FitParser.buildResult`) so the three decode to a byte-identical
    /// HR stream and stay in parity with the Kotlin twin. A sample is kept only when it carried BOTH a
    /// timestamp and a valid HR: without a time it can't key into the (deviceId, ts) HR store, and
    /// without HR there's nothing to store. The epoch is finite/range-checked BEFORE the `Int(Double)`
    /// conversion (never a trapping cast — mirrors the importer's other numeric guards); the upper
    /// bound is the same 2100-01-01 sanity ceiling `FitParser`/`fitDate` uses, so a crafted file with
    /// an absurd timestamp is dropped, not stored.
    ///
    /// `ts` is `Int(secs)` — a TRUNCATION toward the whole second, not `.rounded()`. This is a
    /// byte-parity requirement, not a stylistic choice: `ts` is the `(deviceId, ts)` store key, and the
    /// Kotlin twin derives its timestamp from `OffsetDateTime.toEpochSecond()`, which floors a
    /// fractional-second timestamp. A GPX/TCX trackpoint like `…T08:00:00.500Z` keeps its fraction in the
    /// Swift `Date` (parsed via `WhoopTime`'s fractional formatter); rounding it here would store `ts+1`
    /// on Apple while Android stored `ts` — a 1-second divergence in a stored key. The guard above
    /// pins `secs > 0`, so truncation-toward-zero equals the floor Kotlin uses. (FIT epochs are already
    /// whole seconds, so this is a no-op there and only the sub-second XML formats were ever at risk.)
    static func hrSamples(from samples: [TrackSample]) -> [ActivityHRSample] {
        samples.compactMap { s in
            guard let time = s.time, let hr = s.hr else { return nil }
            let secs = time.timeIntervalSince1970
            guard secs.isFinite, secs > 0, secs < 4_102_444_800 else { return nil }
            return ActivityHRSample(ts: Int(secs), bpm: hr)
        }
    }

    // MARK: - Geo / summary math

    /// Haversine total distance (metres) along an ordered route. Mirrors Android RouteMath.totalMeters.
    static func routeDistanceM(_ points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count { sum += haversineMeters(points[i - 1], points[i]) }
        return sum
    }

    static func haversineMeters(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let earthR = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return earthR * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Total positive elevation gain (metres) from consecutive elevation deltas. A small 1 m hysteresis
    /// floor drops GPS jitter so a flat run doesn't accrue phantom ascent.
    static func ascentM(from samples: [TrackSample]) -> Double? {
        let elevs = samples.compactMap { $0.elevationM }
        guard elevs.count >= 2 else { return nil }
        var gain = 0.0
        for i in 1..<elevs.count {
            let d = elevs[i] - elevs[i - 1]
            if d > 1.0 { gain += d }
        }
        return gain
    }

    /// Cap the retained route length (memory guard). A real route is well under the cap; this only
    /// bites a crafted file. We keep the FIRST N points (the start of the activity) deterministically.
    static func cappedRoute(_ route: [RoutePoint]) -> [RoutePoint] {
        route.count <= maxPoints ? route : Array(route.prefix(maxPoints))
    }

    // MARK: - Coordinate / value validation (shared)

    /// Validate a latitude/longitude pair. Rejects out-of-range or non-finite coordinates and the
    /// 0,0 "null island" fix that some devices emit before a GPS lock (a common dirty-data value).
    static func validCoordinate(lat: Double?, lon: Double?) -> RoutePoint? {
        guard let lat, let lon, lat.isFinite, lon.isFinite,
              lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
        if lat == 0 && lon == 0 { return nil }
        return RoutePoint(lat: lat, lon: lon)
    }

    /// Clamp a heart-rate value to a plausible bpm range, dropping garbage. Returns nil for nonsense.
    static func validHr(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v >= 1, v <= 300 else { return nil }
        return Int(v.rounded())
    }

    // MARK: - App-layer mapping helpers (shared so Swift + Kotlin agree)

    /// The sport name the imported workout is filed under. A file's free-text/enum sport is mapped to a
    /// NOOP-style Title-Cased label; an unknown/absent sport becomes the neutral "Activity" (we never
    /// claim a sport the file didn't state). Keep parity with the Kotlin `workoutSport`.
    public static func workoutSport(from raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Activity"
        }
        let lower = raw.lowercased()
        switch lower {
        case "run", "running", "treadmill_running", "trail_running": return "Running"
        case "ride", "bike", "biking", "cycling", "road_biking", "mountain_biking", "virtual_cycling", "indoor_cycling":
            return "Cycling"
        case "swim", "swimming", "lap_swimming", "open_water_swimming": return "Swimming"
        case "walk", "walking": return "Walking"
        case "hike", "hiking": return "Hiking"
        case "strength_training", "strength", "weight_training": return "Strength Training"
        case "cardio": return "Cardio"
        case "rowing", "row": return "Rowing"
        case "generic", "other", "fitness_equipment", "training": return "Activity"
        default:
            // Title-case a clean word/phrase; otherwise keep the file's label verbatim (already cased).
            return raw.contains(" ") ? raw : raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// A one-line status string for the import UI, e.g.
    /// "Imported a 8.21 km Running activity · 412 GPS points · 1,840 HR samples · 2026-06-01". Only
    /// states what the file actually carried. Keep parity with the Kotlin `summaryText`.
    public static func summaryText(_ a: ActivityFile) -> String {
        var head = "Imported"
        if let d = a.distanceM, d > 0 {
            head += " a \(activityDistanceText(d))"
        } else {
            head += " an"
        }
        let sport = workoutSport(from: a.sport)
        head += " \(sport) activity"

        var parts: [String] = [head]
        if a.gpsPointCount > 0 { parts.append("\(a.gpsPointCount) GPS points") }
        if a.hrSampleCount > 0 { parts.append("\(a.hrSampleCount) HR samples") }
        if let avg = a.avgHr { parts.append("avg \(avg) bpm") }
        if let steps = a.steps, steps > 0 { parts.append("\(steps) steps") }
        return parts.joined(separator: " · ")
    }
}
