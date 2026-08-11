import Foundation

/// Export a recorded GPS workout route to a standard interchange file (GPX 1.1 or FIT) — the sibling of
/// ``ActivityFileImporter`` and the byte-for-byte twin of the Kotlin `RouteExport`. Pure Swift + Foundation
/// (no CoreLocation/UIKit), so it lives in this package, unit-tests without an app, and is covered by
/// `swift-packages.yml`.
///
/// FIDELITY NOTE: the stored route (`RouteMath` polyline) is lat/lon ONLY — no per-point timestamp,
/// elevation, speed, or HR is persisted. So an export carries the lat/lon track plus per-point timestamps
/// INTERPOLATED evenly across the workout window `[startTs, endTs]` (total duration is exact; instantaneous
/// pace is not), and workout-level metadata (sport, distance, calories, avg/max HR). That's the honest
/// maximum from what's stored, and what Strava / Garmin Connect need to read the track as a timed activity.
public enum RouteExporter {

    public enum Format: String, Sendable, Equatable {
        case gpx, fit
        public var ext: String { rawValue }
        public var label: String { self == .gpx ? "GPX" : "FIT" }
    }

    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z).
    static let fitEpoch = 631_065_600

    /// Semicircles per degree — the FIT position unit: `semicircles = degrees × 2^31 / 180`.
    static let semiPerDeg = 2_147_483_648.0 / 180.0

    // MARK: - Public API

    public static func render(
        _ format: Format,
        route: [RoutePoint],
        startTs: Int,
        endTs: Int,
        sport: String?,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        avgHr: Int? = nil,
        maxHr: Int? = nil
    ) -> Data {
        switch format {
        case .gpx:
            return Data(buildGpx(route: route, startTs: startTs, endTs: endTs, sport: sport,
                                 distanceM: distanceM).utf8)
        case .fit:
            return buildFit(route: route, startTs: startTs, endTs: endTs, sport: sport,
                            distanceM: distanceM, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr)
        }
    }

    /// GPX 1.1 track. Each `trkpt` carries lat/lon + an interpolated `time`; no `ele`/HR (none stored).
    public static func buildGpx(
        route: [RoutePoint],
        startTs: Int,
        endTs: Int,
        sport: String?,
        distanceM: Double? = nil
    ) -> String {
        let canon = canonicalSport(sport)
        let times = interpolatedTimes(route.count, startTs, endTs)
        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"NOOP\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        s += "  <metadata>\n    <time>\(iso(startTs))</time>\n  </metadata>\n"
        s += "  <trk>\n"
        s += "    <name>\(xmlEscape(displaySport(canon)))</name>\n"
        s += "    <type>\(xmlEscape(canon))</type>\n"
        s += "    <trkseg>\n"
        for i in route.indices {
            let p = route[i]
            s += "      <trkpt lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lon))\">"
            s += "<time>\(iso(times[i]))</time></trkpt>\n"
        }
        s += "    </trkseg>\n  </trk>\n</gpx>\n"
        return s
    }

    /// A minimal but well-formed FIT activity file: file_id, one record per point, lap, session, activity,
    /// and the trailing CRC-16. Decodes back through ``ActivityFileImporter`` and imports into Strava /
    /// Garmin Connect.
    public static func buildFit(
        route: [RoutePoint],
        startTs: Int,
        endTs: Int,
        sport: String?,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        avgHr: Int? = nil,
        maxHr: Int? = nil
    ) -> Data {
        let canon = canonicalSport(sport)
        let times = interpolatedTimes(route.count, startTs, endTs)
        var body: [UInt8] = []

        // file_id (global 0): type=activity, manufacturer=development, time_created.
        defn(&body, local: 0, global: 0, fields: [(0, 1, 0x00), (1, 2, 0x84), (4, 4, 0x86)])
        body.append(0)
        u8(&body, 4); u16(&body, 255); u32(&body, fitTime(startTs))

        // record (global 20): timestamp + position.
        defn(&body, local: 1, global: 20, fields: [(253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85)])
        for i in route.indices {
            body.append(1)
            u32(&body, fitTime(times[i]))
            s32(&body, semicircles(route[i].lat))
            s32(&body, semicircles(route[i].lon))
        }

        let elapsedMs = UInt32(max(0, endTs - startTs)) &* 1000
        let distCenti: UInt32? = distanceM.map { UInt32(max(0, ($0 * 100.0).rounded())) }

        // lap (global 19): external tools expect at least one; our decoder folds it under session.
        // Distance uses the FIT 0xFFFFFFFF "invalid" value when absent — the decoder special-cases it.
        defn(&body, local: 2, global: 19, fields: [(253, 4, 0x86), (2, 4, 0x86), (7, 4, 0x86), (9, 4, 0x86)])
        body.append(2)
        u32(&body, fitTime(endTs)); u32(&body, fitTime(startTs)); u32(&body, elapsedMs)
        u32(&body, distCenti ?? 0xFFFF_FFFF)

        // session (global 18): only the fields we actually have. An absent HR must be truly absent — the
        // importer's validHr accepts 1..300 and would misread a 0xFF sentinel as a real HR of 255.
        var sf: [(Int, Int, Int)] = []
        var sd: [UInt8] = []
        sf.append((253, 4, 0x86)); u32(&sd, fitTime(endTs))
        sf.append((2, 4, 0x86)); u32(&sd, fitTime(startTs))
        sf.append((7, 4, 0x86)); u32(&sd, elapsedMs)
        sf.append((5, 1, 0x00)); u8(&sd, fitSport(canon))
        if let distCenti { sf.append((9, 4, 0x86)); u32(&sd, distCenti) }
        if let energyKcal { sf.append((11, 2, 0x84)); u16(&sd, UInt16(min(max(0, energyKcal.rounded()), 65534))) }
        if let avgHr { sf.append((16, 1, 0x02)); u8(&sd, min(max(avgHr, 0), 254)) }
        if let maxHr { sf.append((17, 1, 0x02)); u8(&sd, min(max(maxHr, 0), 254)) }
        defn(&body, local: 3, global: 18, fields: sf)
        body.append(3)
        body.append(contentsOf: sd)

        // activity (global 34): one session.
        defn(&body, local: 4, global: 34, fields: [(253, 4, 0x86), (1, 2, 0x84), (2, 1, 0x00)])
        body.append(4)
        u32(&body, fitTime(endTs)); u16(&body, 1); u8(&body, 0)

        // 12-byte header + body + CRC-16 over header+body.
        var out: [UInt8] = []
        u8(&out, 12); u8(&out, 0x20); u16(&out, 2140); u32(&out, UInt32(body.count))
        out.append(contentsOf: Array(".FIT".utf8))
        out.append(contentsOf: body)
        let crc = fitCrc(out)
        u16(&out, UInt16(crc))
        return Data(out)
    }

    // MARK: - Timing / units

    /// Per-point Unix seconds, spread evenly across `[startTs, endTs]` (start for a single point).
    static func interpolatedTimes(_ n: Int, _ startTs: Int, _ endTs: Int) -> [Int] {
        if n <= 0 { return [] }
        if n == 1 { return [startTs] }
        let span = Double(max(0, endTs - startTs))
        return (0..<n).map { i in startTs + Int((span * Double(i) / Double(n - 1)).rounded()) }
    }

    private static func fitTime(_ unix: Int) -> UInt32 {
        UInt32(min(max(0, unix - fitEpoch), 0xFFFF_FFFF))
    }

    private static func semicircles(_ deg: Double) -> Int32 {
        let v = (deg * semiPerDeg).rounded()
        if v >= Double(Int32.max) { return Int32.max }
        if v <= Double(Int32.min) { return Int32.min }
        return Int32(v)
    }

    /// ISO-8601 UTC to whole seconds, e.g. `2026-08-11T04:47:38Z`. Computed by hand (civil-from-days) so
    /// it is deterministic and matches the Kotlin `Instant.toString()` twin exactly, with no shared
    /// mutable `DateFormatter`.
    static func iso(_ unix: Int) -> String {
        let days = Int(floor(Double(unix) / 86400.0))
        let secOfDay = unix - days * 86400
        let hh = secOfDay / 3600, mm = (secOfDay % 3600) / 60, ss = secOfDay % 60
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y0 = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = m <= 2 ? y0 + 1 : y0
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hh, mm, ss)
    }

    /// Fixed 6-dp coordinate — well beyond the polyline's ~1 m (precision-5) resolution.
    private static func coord(_ v: Double) -> String { String(format: "%.6f", v) }

    // MARK: - Sport mapping

    /// Collapse a free-form sport string to one canonical key (the GPS-relevant families).
    static func canonicalSport(_ sport: String?) -> String {
        let s = (sport ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "", "other": return "other"
        case "run", "running", "jog", "jogging", "treadmill": return "run"
        case "cycle", "cycling", "bike", "biking", "ride", "spinning": return "cycle"
        case "walk", "walking", "rucking": return "walk"
        case "hike", "hiking": return "hike"
        case "swim", "swimming": return "swim"
        default: return s
        }
    }

    private static func displaySport(_ canon: String) -> String {
        canon.isEmpty ? canon : canon.prefix(1).uppercased() + canon.dropFirst()
    }

    /// FIT `sport` enum (session field 5). Round-trips through the importer's sport-name map.
    private static func fitSport(_ canon: String) -> Int {
        switch canon {
        case "run": return 1
        case "cycle": return 2
        case "swim": return 5
        case "walk": return 11
        case "hike": return 15
        default: return 0
        }
    }

    // MARK: - XML / byte helpers

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Emit a FIT definition message for `local`/`global` with `fields` (field num, size, base-type),
    /// little-endian.
    private static func defn(_ b: inout [UInt8], local: Int, global: Int,
                             fields: [(Int, Int, Int)]) {
        u8(&b, 0x40 | (local & 0x0F)) // definition record header
        u8(&b, 0)                     // reserved
        u8(&b, 0)                     // architecture: 0 = little-endian
        u16(&b, UInt16(global))
        u8(&b, fields.count)
        for f in fields { u8(&b, f.0); u8(&b, f.1); u8(&b, f.2) }
    }

    private static func u8(_ b: inout [UInt8], _ v: Int) { b.append(UInt8(v & 0xFF)) }
    private static func u16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
    }
    private static func u32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
        b.append(UInt8((v >> 16) & 0xFF)); b.append(UInt8((v >> 24) & 0xFF))
    }
    private static func s32(_ b: inout [UInt8], _ v: Int32) { u32(&b, UInt32(bitPattern: v)) }

    /// The standard FIT CRC-16 (nibble-table variant), computed over `data`.
    static func fitCrc(_ data: [UInt8]) -> Int {
        let table = [
            0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
            0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
        ]
        var crc = 0
        for byte in data {
            let b = Int(byte)
            var tmp = table[crc & 0xF]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[b & 0xF]
            tmp = table[crc & 0xF]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[(b >> 4) & 0xF]
        }
        return crc & 0xFFFF
    }
}
