import Foundation
import GRDB
import ZIPFoundation

/// Parses a **Xiaomi Smart Band / Mi Band** export into normalized rows.
///
/// The input is the Mi Fitness iOS app's on-device data — the app sandbox folder
/// (shared via the iOS Files app), a `.zip` of it, or the bare `<user_id>.db`. The
/// health metrics live in `DataBase/<user_id>/de/<user_id>.db` as one row per sample
/// with a JSON `value` column; this importer opens that file **read-only** and folds
/// the daily-rollup tables and the per-session `sleep` table into NOOP's shapes.
///
/// This is **parse-only**: it never touches NOOP's own store, only the foreign file
/// the user already owns. No Bluetooth, no Xiaomi cloud, no account.
///
/// The table/field mapping and sleep-stage reconstruction are **re-derived** from the
/// public `artyomxx/xiaomi-band-ios-export` tool and verified against a real Mi Band 10
/// export — not copied from any GPL source.
public struct XiaomiBandImporter {

    public init() {}

    // Day-rollup tables, keyed by NOOP day. (`goal_day` is intentionally skipped —
    // it carries targets, not measurements.)
    static let dayTables = [
        "steps_day", "calories_day", "heart_rate_day", "sleep_day",
        "stress_day", "spo2_day", "intensity_day", "valid_stand_day", "vitality",
    ]

    /// Parse a Mi Fitness export at `url` (folder, `.zip`, or `.db`).
    public func `import`(from url: URL) throws -> XiaomiImportResult {
        let (dbURL, tempDir) = try Self.resolveDatabase(at: url)
        defer { if let tempDir { try? FileManager.default.removeItem(at: tempDir) } }

        var config = Configuration()
        config.readonly = true
        let dbq = try DatabaseQueue(path: dbURL.path, configuration: config)

        let (days, sleeps) = try dbq.read { db -> ([XiaomiDailyRow], [XiaomiSleepSession]) in
            (try Self.readDays(db), try Self.readSleeps(db))
        }

        if days.isEmpty && sleeps.isEmpty {
            throw ImportError.emptyExport("No Mi Fitness health rows found in \(dbURL.lastPathComponent)")
        }
        return XiaomiImportResult(days: days, sleeps: sleeps, summary: Self.summarize(days: days, sleeps: sleeps))
    }

    // MARK: - Locate the health DB

    /// Resolve the input to a concrete `.db` file. Returns the file plus an optional
    /// temp directory the caller must clean up (non-nil only when a zip was extracted).
    static func resolveDatabase(at url: URL) throws -> (db: URL, tempDir: URL?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.fileNotFound(url.path)
        }

        if isDir.boolValue {
            guard let db = bestHealthDB(under: url) else {
                throw ImportError.missingEntry("DataBase/<user_id>/de/<user_id>.db")
            }
            return (db, nil)
        }

        // A bare `.db` file → use directly.
        if url.pathExtension.lowercased() == "db" {
            return (url, nil)
        }

        // Otherwise treat it as a zip of the sandbox and extract to a temp dir.
        // Inside the app's own bundle-named scratch folder; see the note in AppleHealthImporter and #2446.
        let scratch = fm.temporaryDirectory.appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".scratch",
                                    isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let tempDir = scratch.appendingPathComponent("xiaomi-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try fm.unzipItem(at: url, to: tempDir)
        } catch {
            try? fm.removeItem(at: tempDir)
            throw ImportError.notAZipOrFolder(url.path)
        }
        guard let db = bestHealthDB(under: tempDir) else {
            try? fm.removeItem(at: tempDir)
            throw ImportError.missingEntry("DataBase/<user_id>/de/<user_id>.db")
        }
        return (db, tempDir)
    }

    /// Find every `*.db` under `root` that looks like a Mi Fitness health store and
    /// pick the richest (most `steps` rows), mirroring the reference tool's scoring.
    static func bestHealthDB(under root: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        var best: (url: URL, score: Int)?
        for case let u as URL in e where u.pathExtension.lowercased() == "db" {
            let score = healthDBScore(u)
            if score > 0, best == nil || score > best!.score {
                best = (u, score)
            }
        }
        return best?.url
    }

    /// `0` if the file isn't a Mi Fitness health DB; otherwise the `steps` row count
    /// (a richness proxy, so we prefer the populated store over `notlogin` stubs).
    private static func healthDBScore(_ url: URL) -> Int {
        var config = Configuration()
        config.readonly = true
        guard let dbq = try? DatabaseQueue(path: url.path, configuration: config) else { return 0 }
        return (try? dbq.read { db -> Int in
            guard try tableExists(db, "steps") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM steps") ?? 0
        }) ?? 0
    }

    // MARK: - Day rollups

    static func readDays(_ db: Database) throws -> [XiaomiDailyRow] {
        var byDay: [String: XiaomiDailyRow] = [:]

        func ensure(_ key: String, _ time: Int) -> XiaomiDailyRow {
            byDay[key] ?? XiaomiDailyRow(day: key, dayStart: Date(timeIntervalSince1970: TimeInterval(time)))
        }

        for table in dayTables where try tableExists(db, table) {
            for r in try rawRows(db, table: table) {
                let key = dayKey(time: r.time, zoneOffset: r.zoneOffset)
                var row = ensure(key, r.time)
                apply(table: table, value: r.value, into: &row)
                byDay[key] = row
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Fold one source table's JSON `value` into the day row. `0` heart-rate / SpO₂ /
    /// stress values mean "not measured" on the band, so they map to `nil` rather than
    /// a misleading zero.
    private static func apply(table: String, value v: [String: Any], into row: inout XiaomiDailyRow) {
        switch table {
        case "steps_day":
            row.steps = intVal(v, "steps") ?? row.steps
            row.distanceM = doubleVal(v, "distance") ?? row.distanceM
        case "calories_day":
            row.activeKcal = doubleVal(v, "calories") ?? row.activeKcal
        case "heart_rate_day":
            row.restingHr = positive(intVal(v, "avg_rhr")) ?? row.restingHr
            row.avgHr = positive(intVal(v, "avg_hr")) ?? row.avgHr
            row.minHr = positive(intVal(v, "min_hr")) ?? row.minHr
            row.maxHr = positive(intVal(v, "max_hr")) ?? row.maxHr
        case "sleep_day":
            row.totalSleepMin = doubleVal(v, "total_duration") ?? row.totalSleepMin
            row.deepMin = doubleVal(v, "sleep_deep_duration") ?? row.deepMin
            row.lightMin = doubleVal(v, "sleep_light_duration") ?? row.lightMin
            row.remMin = doubleVal(v, "sleep_rem_duration") ?? row.remMin
            row.awakeMin = doubleVal(v, "sleep_awake_duration") ?? row.awakeMin
            row.sleepScore = positive(intVal(v, "sleep_score")) ?? row.sleepScore
        case "stress_day":
            row.avgStress = positive(intVal(v, "avg_stress")) ?? row.avgStress
        case "spo2_day":
            row.avgSpo2 = positiveD(doubleVal(v, "avg_spo2")) ?? row.avgSpo2
        case "intensity_day":
            row.intensityMin = doubleVal(v, "duration") ?? row.intensityMin
        case "valid_stand_day":
            row.standCount = intVal(v, "count") ?? row.standCount
        case "vitality":
            row.vitality = positive(intVal(v, "latest_accumulated_vitality")) ?? row.vitality
        default:
            break
        }
    }

    // MARK: - Sleep sessions + hypnogram

    static func readSleeps(_ db: Database) throws -> [XiaomiSleepSession] {
        guard try tableExists(db, "sleep") else { return [] }
        var sessions: [XiaomiSleepSession] = []
        var seenBedtimes = Set<Int>()

        for r in try rawRows(db, table: "sleep") {
            let v = r.value
            guard let bed = intVal(v, "bedtime") ?? intVal(v, "device_bedtime") ?? intVal(v, "bed_timestamp")
            else { continue }
            let wake = intVal(v, "wake_up_time") ?? intVal(v, "device_wake_up_time")
                ?? intVal(v, "out_bed_timestamp") ?? r.time
            guard wake > bed, seenBedtimes.insert(bed).inserted else { continue }

            var stages: [XiaomiSleepStageInterval] = []
            if let items = v["items"] as? [[String: Any]] {
                for item in items {
                    guard let s = intVal(item, "start_time"), let e = intVal(item, "end_time"), e > s
                    else { continue }
                    stages.append(XiaomiSleepStageInterval(
                        stage: .from(state: intVal(item, "state") ?? 0),
                        start: Date(timeIntervalSince1970: TimeInterval(s)),
                        end: Date(timeIntervalSince1970: TimeInterval(e))))
                }
            }

            sessions.append(XiaomiSleepSession(
                bedtime: Date(timeIntervalSince1970: TimeInterval(bed)),
                wakeTime: Date(timeIntervalSince1970: TimeInterval(wake)),
                deepMin: doubleVal(v, "sleep_deep_duration"),
                lightMin: doubleVal(v, "sleep_light_duration"),
                remMin: doubleVal(v, "sleep_rem_duration"),
                awakeMin: doubleVal(v, "sleep_awake_duration"),
                avgHr: positive(intVal(v, "avg_hr")),
                minHr: positive(intVal(v, "min_hr")),
                maxHr: positive(intVal(v, "max_hr")),
                awakeCount: intVal(v, "awake_count"),
                sleepScore: positive(intVal(v, "sleep_score")),
                stages: stages.sorted { $0.start < $1.start }))
        }
        return sessions.sorted { $0.bedtime < $1.bedtime }
    }

    // MARK: - Summary

    static func summarize(days: [XiaomiDailyRow], sleeps: [XiaomiSleepSession]) -> ImportSummary {
        var dates: [Date] = days.map(\.dayStart)
        dates += sleeps.map(\.bedtime)
        return ImportSummary(
            sourceKind: .xiaomiBand,
            recordCount: days.count + sleeps.count,
            earliest: dates.min(),
            latest: dates.max(),
            countsByCategory: ["days": days.count, "sleepSessions": sleeps.count])
    }

    // MARK: - Low-level reads & helpers

    struct RawRow { var sid: String; var time: Int; var zoneOffset: Int; var value: [String: Any] }

    /// `SELECT` the non-deleted rows of a Mi Fitness table and parse the JSON `value`.
    /// `table` is always drawn from a fixed allow-list, never user input.
    static func rawRows(_ db: Database, table: String) throws -> [RawRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT sid, time, value, zone_offset FROM "\(table)" WHERE deleted = 0 ORDER BY time
            """)
        return rows.compactMap { row in
            guard let time: Int = row["time"] else { return nil }
            let json: String = row["value"] ?? ""
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return RawRow(sid: row["sid"] ?? "", time: time, zoneOffset: row["zone_offset"] ?? 0, value: obj)
        }
    }

    static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", arguments: [name]) ?? false
    }

    /// The band's local calendar day for a sample (`time + zone_offset`, formatted UTC).
    static func dayKey(time: Int, zoneOffset: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(time + zoneOffset)))
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // JSON value coercion — Mi Fitness stores numbers as either Int or Double.
    static func intVal(_ v: [String: Any], _ k: String) -> Int? {
        if let n = v[k] as? Int { return n }
        // Crafted-import-crash guard: Int(d) / NSNumber.intValue trap on non-finite
        // or out-of-range values (e.g. 1e308 / inf / nan in a hostile JSON). Drop-and-skip.
        if let d = v[k] as? Double { return safeInt(d) }
        if let n = v[k] as? NSNumber { return safeInt(n.doubleValue) }
        return nil
    }

    /// Finite + Int-range checked Double→Int conversion. Returns nil rather than
    /// trapping on attacker-supplied values (NaN/inf/|x|>Int.max).
    private static func safeInt(_ d: Double) -> Int? {
        guard d.isFinite, d >= -9e18, d <= 9e18 else { return nil }
        return Int(d)
    }

    static func doubleVal(_ v: [String: Any], _ k: String) -> Double? {
        if let d = v[k] as? Double { return d }
        if let n = v[k] as? Int { return Double(n) }
        if let n = v[k] as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func positive(_ n: Int?) -> Int? { (n ?? 0) > 0 ? n : nil }
    private static func positiveD(_ n: Double?) -> Double? { (n ?? 0) > 0 ? n : nil }
}
