import Foundation
import GRDB

public enum LocalAccessError: Error, CustomStringConvertible, Equatable {
    case invalidParams(String)
    case methodNotFound(String)
    case toolNotFound(String)
    case resourceNotFound(String)
    case promptNotFound(String)
    case databaseUnavailable(String)

    public var description: String {
        switch self {
        case .invalidParams(let message),
             .databaseUnavailable(let message):
            return message
        case .methodNotFound(let method):
            return "Unsupported MCP method: \(method)"
        case .toolNotFound(let tool):
            return "Unknown NOOP tool: \(tool)"
        case .resourceNotFound(let uri):
            return "Unknown NOOP resource: \(uri)"
        case .promptNotFound(let name):
            return "Unknown NOOP prompt: \(name)"
        }
    }

    public var rpcCode: Int {
        switch self {
        case .methodNotFound:
            return -32601
        case .invalidParams, .toolNotFound, .resourceNotFound, .promptNotFound:
            return -32602
        case .databaseUnavailable:
            return -32603
        }
    }
}

public struct LocalAccessConfiguration: Equatable, Sendable {
    public var databasePath: String?
    public var bundleID: String?
    public var deviceID: String

    public init(databasePath: String? = nil, bundleID: String? = nil, deviceID: String = "my-whoop") {
        self.databasePath = databasePath
        self.bundleID = bundleID
        self.deviceID = deviceID
    }

    public static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LocalAccessConfiguration {
        LocalAccessConfiguration(
            databasePath: nonEmpty(env["NOOP_DB_PATH"]),
            bundleID: nonEmpty(env["NOOP_BUNDLE_ID"]),
            deviceID: nonEmpty(env["NOOP_DEVICE_ID"]) ?? "my-whoop"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum DatabasePathResolver {
    public static let productionBundleID = "com.noopapp.noop"

    public static func resolve(configuration: LocalAccessConfiguration) throws -> String {
        let fm = FileManager.default
        if let explicit = configuration.databasePath {
            let expanded = expandHome(explicit)
            guard fm.fileExists(atPath: expanded) else {
                throw LocalAccessError.databaseUnavailable("NOOP database not found at NOOP_DB_PATH.")
            }
            return expanded
        }

        for candidate in candidates(bundleID: configuration.bundleID) where fm.fileExists(atPath: candidate) {
            return candidate
        }

        throw LocalAccessError.databaseUnavailable(
            "No official NOOP database was found. Start NOOP once, or set NOOP_DB_PATH explicitly."
        )
    }

    public static func candidates(bundleID: String? = nil, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var ids = [productionBundleID]
        if let bundleID, bundleID != productionBundleID {
            ids.insert(bundleID, at: 0)
        }

        var paths: [String] = ids.map {
            "\(home)/Library/Containers/\($0)/Data/Library/Application Support/OpenWhoop/whoop.sqlite"
        }
        paths.append("\(home)/Library/Application Support/OpenWhoop/whoop.sqlite")
        return orderedUnique(paths)
    }

    public static func expandHome(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + String(path.dropFirst())
    }
}

public struct DailyMetricRow: Equatable, Sendable {
    public let day: String
    public let totalSleepMin: Double?
    public let efficiency: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let lightMin: Double?
    public let disturbances: Int?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let recovery: Double?
    public let strain: Double?
    public let exerciseCount: Int?
    public let spo2Pct: Double?
    public let skinTempDevC: Double?
    public let respRateBpm: Double?
    public let steps: Int?
    public let activeKcalEst: Double?
}

public struct SleepSessionRow: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let efficiency: Double?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let stagesJSON: String?
    // NOTE (#318): this local-access read intentionally does NOT surface the user's `startTsAdjusted`
    // onset correction — its SELECT must stay readable against pre-v14 / foreign sleepSession tables
    // (see the `tableNames` guard), so adding the column would regress those. The MCP read therefore
    // reports the DETECTED onset for a hand-edited night; the app's own screens use the corrected one.
}

public struct MetricPointRow: Equatable, Sendable {
    public let day: String
    public let key: String
    public let value: Double
}

public struct AppleDailyRow: Equatable, Sendable {
    public let day: String
    public let steps: Int?
    public let activeKcal: Double?
    public let basalKcal: Double?
    public let vo2max: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let walkingHr: Int?
    public let weightKg: Double?
}

public struct WorkoutRow: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let sport: String
    public let source: String
    public let durationS: Double?
    public let energyKcal: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let strain: Double?
    public let distanceM: Double?
    public let zonesJSON: String?
    public let notes: String?
}

public struct StorageStats: Equatable, Sendable {
    public let decodedRows: Int
    public let rawBatches: Int
    public let rawBytes: Int
}

public final class ReadonlyNoopStore {
    private let dbQueue: DatabaseQueue
    private let tableNames: Set<String>

    public init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        tableNames = try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        try validateSchema()
    }

    public func dailyMetrics(deviceId: String, from: String, to: String) throws -> [DailyMetricRow] {
        guard tableNames.contains("dailyMetric") else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                       restingHr, avgHrv, recovery, strain, exerciseCount,
                       spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst
                FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map {
                    DailyMetricRow(day: $0["day"], totalSleepMin: $0["totalSleepMin"],
                                   efficiency: $0["efficiency"], deepMin: $0["deepMin"],
                                   remMin: $0["remMin"], lightMin: $0["lightMin"],
                                   disturbances: $0["disturbances"], restingHr: $0["restingHr"],
                                   avgHrv: $0["avgHrv"], recovery: $0["recovery"],
                                   strain: $0["strain"], exerciseCount: $0["exerciseCount"],
                                   spo2Pct: $0["spo2Pct"], skinTempDevC: $0["skinTempDevC"],
                                   respRateBpm: $0["respRateBpm"], steps: $0["steps"],
                                   activeKcalEst: $0["activeKcalEst"])
                }
        }
    }

    public func sleepSessions(deviceId: String, from: Int, to: Int, limit: Int) throws -> [SleepSessionRow] {
        guard tableNames.contains("sleepSession") else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON
                FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    SleepSessionRow(startTs: $0["startTs"], endTs: $0["endTs"],
                                    efficiency: $0["efficiency"], restingHr: $0["restingHr"],
                                    avgHrv: $0["avgHrv"], stagesJSON: $0["stagesJSON"])
                }
        }
    }

    public func metricSeries(deviceId: String, key: String, from: String, to: String) throws -> [MetricPointRow] {
        guard tableNames.contains("metricSeries") else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, key, from, to])
                .map { MetricPointRow(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    public func metricKeys(deviceId: String) throws -> [String] {
        guard tableNames.contains("metricSeries") else { return [] }
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT key FROM metricSeries
                WHERE deviceId = ?
                ORDER BY key ASC
                """, arguments: [deviceId])
        }
    }

    public func appleDaily(deviceId: String, from: String, to: String) throws -> [AppleDailyRow] {
        guard tableNames.contains("appleDaily") else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, steps, activeKcal, basalKcal, vo2max, avgHr, maxHr, walkingHr, weightKg
                FROM appleDaily
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map {
                    AppleDailyRow(day: $0["day"], steps: $0["steps"], activeKcal: $0["activeKcal"],
                                  basalKcal: $0["basalKcal"], vo2max: $0["vo2max"],
                                  avgHr: $0["avgHr"], maxHr: $0["maxHr"],
                                  walkingHr: $0["walkingHr"], weightKg: $0["weightKg"])
                }
        }
    }

    public func workouts(deviceId: String, from: Int, to: Int, limit: Int) throws -> [WorkoutRow] {
        guard tableNames.contains("workout") else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes
                FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                               source: $0["source"], durationS: $0["durationS"],
                               energyKcal: $0["energyKcal"], avgHr: $0["avgHr"],
                               maxHr: $0["maxHr"], strain: $0["strain"],
                               distanceM: $0["distanceM"], zonesJSON: $0["zonesJSON"],
                               notes: $0["notes"])
                }
        }
    }

    public func latestHRSampleTs(deviceId: String) throws -> Int? {
        let hasHr = tableNames.contains("hrSample")
        let hasPpg = tableNames.contains("ppgHrSample")
        guard hasHr || hasPpg else { return nil }

        return try dbQueue.read { db in
            switch (hasHr, hasPpg) {
            case (true, true):
                return try Int.fetchOne(db, sql: """
                    SELECT MAX(ts) FROM (
                        SELECT ts FROM hrSample WHERE deviceId = ?
                        UNION ALL
                        SELECT ts FROM ppgHrSample WHERE deviceId = ?
                    )
                    """, arguments: [deviceId, deviceId])
            case (true, false):
                return try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
            case (false, true):
                return try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM ppgHrSample WHERE deviceId = ?", arguments: [deviceId])
            case (false, false):
                return nil
            }
        }
    }

    public func storageStats() throws -> StorageStats {
        try dbQueue.read { db in
            // Every durable decoded per-second table. The four below the first line were landed as
            // instrumentation and then left OUT of this count, which is how an unbounded, unpruned table
            // became invisible: `ppgWaveformSample` banks a ~48-byte BLOB per v26 strap-second and
            // `v18AuxSample` ~30 bytes per v18 strap-second, neither is pruned (deliberately — this is
            // decoded biometric history, not the transient raw outbox), and until now neither showed up in
            // the only readout a user has for "what is the store spending space on". Growth that nothing
            // reads still has to be growth somebody can SEE. Guarded by `tableNames.contains` so a store
            // predating any of these migrations still reports.
            let decodedTables = [
                "hrSample", "rrInterval", "event", "battery", "spo2Sample",
                "skinTempSample", "respSample", "gravitySample", "ppgHrSample", "stepSample",
                "sleepStateSample", "ppgWaveformSample", "rawImuSample", "v18AuxSample",
            ]
            var decodedRows = 0
            for table in decodedTables where tableNames.contains(table) {
                decodedRows += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            let rawBatches = tableNames.contains("rawBatch")
                ? (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0)
                : 0
            let rawBytes = tableNames.contains("rawBatch")
                ? (try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0)
                : 0
            return StorageStats(decodedRows: decodedRows, rawBatches: rawBatches, rawBytes: rawBytes)
        }
    }

    internal func writeProbeForTest() throws {
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE __noop_local_access_write_probe(id INTEGER)")
        }
    }

    internal func isReadOnlyForTest() throws -> Bool {
        try dbQueue.read { db in db.configuration.readonly }
    }

    private func validateSchema() throws {
        if !tableNames.contains("grdb_migrations"),
           tableNames.contains("device") || tableNames.contains("hrSample") {
            throw LocalAccessError.databaseUnavailable(
                "This looks like a NOOP-like SQLite file without GRDB migration metadata. Open NOOP to repair it before using local access."
            )
        }
    }
}

public final class NoopDataAccess {
    private let store: ReadonlyNoopStore
    private let deviceId: String
    private var computedDeviceId: String { deviceId + "-noop" }

    public init(store: ReadonlyNoopStore, deviceId: String = "my-whoop") {
        self.store = store
        self.deviceId = deviceId
    }

    public static func open(configuration: LocalAccessConfiguration = .environment()) throws -> NoopDataAccess {
        let path = try DatabasePathResolver.resolve(configuration: configuration)
        return try NoopDataAccess(store: ReadonlyNoopStore(path: path), deviceId: configuration.deviceID)
    }

    public func healthSnapshot(days: Int) throws -> JSONValue {
        let (fromDay, toDay) = dayRange(days: days)
        let daily = try mergedDaily(from: fromDay, to: toDay)
        let apple = try store.appleDaily(deviceId: "apple-health", from: fromDay, to: toDay)
        let latestHR = try store.latestHRSampleTs(deviceId: deviceId)

        let logical = logicalDayKey(Date())
        let displayed = daily.last(where: { $0.row.day == logical }) ?? daily.last

        return .object([
            "generatedAt": .string(iso(Date())),
            "logicalToday": .string(logical),
            "sources": Self.sources(),
            "freshness": freshnessPayload(latestHR: latestHR, apple: apple, daily: daily),
            "today": displayed.map { dailyJSON($0.row, source: $0.source) } ?? .null,
            "recentDays": .array(daily.suffix(days).map { dailyJSON($0.row, source: $0.source) }),
            "appleDaily": .array(apple.map(appleDailyJSON)),
        ])
    }

    public func metricSeries(
        key: String,
        source: String,
        days: Int,
        fromDay explicitFrom: String?,
        toDay explicitTo: String?,
        limit: Int
    ) throws -> JSONValue {
        let defaultRange = dayRange(days: days)
        let fromDay = explicitFrom ?? defaultRange.from
        let toDay = explicitTo ?? defaultRange.to
        let candidates = Self.sourceCandidates(forKey: key, preferredSource: source, actualWhoopSource: deviceId)
        var mergedByDay: [String: JSONValue] = [:]
        var usedSources: [String] = []

        for candidate in candidates {
            let rows = try store.metricSeries(deviceId: candidate.source, key: candidate.key, from: fromDay, to: toDay)
            if !rows.isEmpty { usedSources.append(candidate.source) }
            for row in rows where mergedByDay[row.day] == nil {
                mergedByDay[row.day] = .object([
                    "day": .string(row.day),
                    "key": .string(row.key),
                    "value": .double(row.value),
                    "source": .string(candidate.source),
                    "sourceKey": .string(candidate.key),
                ])
            }
        }

        let points = mergedByDay.keys.sorted().compactMap { mergedByDay[$0] }
        let boundedPoints = Array(points.suffix(limit))
        return .object([
            "key": .string(key),
            "requestedSource": .string(source),
            "range": .object(["from": .string(fromDay), "to": .string(toDay)]),
            "resolution": .object([
                "candidates": .array(candidates.map { .object(["source": .string($0.source), "key": .string($0.key)]) }),
                "usedSources": .array(orderedUnique(usedSources).map { .string($0) }),
            ]),
            "returned": .int(boundedPoints.count),
            "points": .array(boundedPoints),
        ])
    }

    public func freshness() throws -> JSONValue {
        let latestHR = try store.latestHRSampleTs(deviceId: deviceId)
        let stats = try store.storageStats()
        let now = Date()
        let (fromDay, toDay) = dayRange(days: 4000)
        let importedDaily = try store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
        let computedDaily = try store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)
        let appleDaily = try store.appleDaily(deviceId: "apple-health", from: fromDay, to: toDay)
        let importedKeys = try store.metricKeys(deviceId: deviceId)
        let computedKeys = try store.metricKeys(deviceId: computedDeviceId)
        let appleKeys = try store.metricKeys(deviceId: "apple-health")

        return .object([
            "generatedAt": .string(iso(now)),
            "deviceId": .string(deviceId),
            "computedDeviceId": .string(computedDeviceId),
            "latestHeartRateSample": timestampJSON(latestHR, now: now),
            "storage": .object([
                "decodedRows": .int(stats.decodedRows),
                "rawBatches": .int(stats.rawBatches),
                "rawBytes": .int(stats.rawBytes),
            ]),
            "coverage": .object([
                "dailyImported": coverageJSON(importedDaily.map(\.day)),
                "dailyComputed": coverageJSON(computedDaily.map(\.day)),
                "appleDaily": coverageJSON(appleDaily.map(\.day)),
            ]),
            "metricKeys": .object([
                deviceId: .array(importedKeys.map { .string($0) }),
                computedDeviceId: .array(computedKeys.map { .string($0) }),
                "apple-health": .array(appleKeys.map { .string($0) }),
            ]),
        ])
    }

    public func sleepSummary(days: Int) throws -> JSONValue {
        let (fromTs, toTs) = timestampRange(days: days)
        let imported = try store.sleepSessions(deviceId: deviceId, from: fromTs, to: toTs, limit: 5000)
        let computed = try store.sleepSessions(deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 5000)
        let merged = mergeSleep(imported: imported, computed: computed)
        let durations = merged.map { Double(max(0, $0.endTs - $0.startTs)) / 60.0 }
        let efficiencies = merged.compactMap(\.efficiency)

        return .object([
            "range": .object(["fromTs": .int(fromTs), "toTs": .int(toTs), "days": .int(days)]),
            "count": .int(merged.count),
            "averageDurationMin": optionalDouble(mean(durations)),
            "averageEfficiency": optionalDouble(mean(efficiencies)),
            "sessions": .array(merged.suffix(200).map(sleepJSON)),
        ])
    }

    public func workoutSummary(days: Int) throws -> JSONValue {
        let (fromTs, toTs) = timestampRange(days: days)
        let imported = try store.workouts(deviceId: deviceId, from: fromTs, to: toTs, limit: 5000)
        let apple = try store.workouts(deviceId: "apple-health", from: fromTs, to: toTs, limit: 5000)
        let computed = try store.workouts(deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 5000)
        let rows = (imported + apple + computed).sorted { $0.startTs < $1.startTs }
        let durationMin = rows.reduce(0.0) { total, row in
            total + ((row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60.0)
        }
        let calories = rows.compactMap(\.energyKcal).reduce(0, +)
        let strain = rows.compactMap(\.strain).reduce(0, +)

        return .object([
            "range": .object(["fromTs": .int(fromTs), "toTs": .int(toTs), "days": .int(days)]),
            "count": .int(rows.count),
            "totalDurationMin": .double(durationMin),
            "totalEnergyKcal": .double(calories),
            "totalStrain": .double(strain),
            "workouts": .array(rows.suffix(300).map(workoutJSON)),
        ])
    }

    public static func metricCatalog() -> JSONValue {
        .object([
            "sources": sources(),
            "keys": .array([
                "avg_hr", "max_hr", "energy_kcal", "recovery", "hrv", "rhr", "resp_rate",
                "spo2", "skin_temp", "sleep_performance", "sleep_total_min", "sleep_efficiency",
                "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "sleep_need_min",
                "sleep_debt_min", "strain", "steps", "active_kcal", "weight", "vo2max",
                "body_fat", "lean_mass", "bmi", "stress", "mood", "calories_in",
                "protein_g", "carbs_g", "fat_g",
            ].map { .string($0) }),
            "resolutionRule": .string("my-whoop resolves imported my-whoop first, then my-whoop-noop computed rows, then compatible Apple Health fill-ins for rhr/hrv/spo2/resp_rate."),
        ])
    }

    public static func sources() -> JSONValue {
        .object([
            "whoopImported": .string("my-whoop"),
            "noopComputed": .string("my-whoop-noop"),
            "appleHealth": .string("apple-health"),
            "nutrition": .string("nutrition-csv"),
            "mood": .string("noop-mood"),
            "journal": .string("noop-journal"),
        ])
    }

    private func mergedDaily(from: String, to: String) throws -> [(row: DailyMetricRow, source: String)] {
        var byDay: [String: (DailyMetricRow, String)] = [:]
        for row in try store.dailyMetrics(deviceId: computedDeviceId, from: from, to: to) {
            byDay[row.day] = (row, computedDeviceId)
        }
        for row in try store.dailyMetrics(deviceId: deviceId, from: from, to: to) {
            byDay[row.day] = (row, deviceId)
        }
        return byDay.values.sorted { $0.0.day < $1.0.day }
    }

    private func mergeSleep(imported: [SleepSessionRow], computed: [SleepSessionRow]) -> [SleepSessionRow] {
        var importedDays = Set<String>()
        for session in imported {
            importedDays.insert(dayString(Date(timeIntervalSince1970: TimeInterval(session.endTs))))
        }
        let computedKept = computed.filter {
            !importedDays.contains(dayString(Date(timeIntervalSince1970: TimeInterval($0.endTs))))
        }
        return (imported + computedKept).sorted { $0.startTs < $1.startTs }
    }

    private func freshnessPayload(latestHR: Int?, apple: [AppleDailyRow], daily: [(row: DailyMetricRow, source: String)]) -> JSONValue {
        .object([
            "latestHeartRateSample": timestampJSON(latestHR, now: Date()),
            "latestDailyMetricDay": daily.last.map { .string($0.row.day) } ?? .null,
            "latestAppleHealthDay": apple.last.map { .string($0.day) } ?? .null,
            "dailyRows": .int(daily.count),
            "appleDailyRows": .int(apple.count),
        ])
    }

    private static func sourceCandidates(forKey key: String, preferredSource: String, actualWhoopSource: String) -> [MetricSourceCandidate] {
        if preferredSource == "my-whoop" || preferredSource == actualWhoopSource {
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: actualWhoopSource + "-noop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: "apple-health", key: appleKey))
            }
            return orderedUnique(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    private static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":
            return "resting_hr"
        case "hrv", "spo2", "resp_rate":
            return key
        default:
            return nil
        }
    }
}

private struct MetricSourceCandidate: Hashable {
    let source: String
    let key: String
}

private func dailyJSON(_ row: DailyMetricRow, source: String) -> JSONValue {
    .object([
        "day": .string(row.day),
        "source": .string(source),
        "totalSleepMin": optionalDouble(row.totalSleepMin),
        "efficiency": optionalDouble(row.efficiency),
        "deepMin": optionalDouble(row.deepMin),
        "remMin": optionalDouble(row.remMin),
        "lightMin": optionalDouble(row.lightMin),
        "disturbances": optionalInt(row.disturbances),
        "restingHr": optionalInt(row.restingHr),
        "avgHrv": optionalDouble(row.avgHrv),
        "recovery": optionalDouble(row.recovery),
        "strain": optionalDouble(row.strain),
        "exerciseCount": optionalInt(row.exerciseCount),
        "spo2Pct": optionalDouble(row.spo2Pct),
        "skinTempDevC": optionalDouble(row.skinTempDevC),
        "respRateBpm": optionalDouble(row.respRateBpm),
        "steps": optionalInt(row.steps),
        "activeKcalEst": optionalDouble(row.activeKcalEst),
    ])
}

private func appleDailyJSON(_ row: AppleDailyRow) -> JSONValue {
    .object([
        "day": .string(row.day),
        "steps": optionalInt(row.steps),
        "activeKcal": optionalDouble(row.activeKcal),
        "basalKcal": optionalDouble(row.basalKcal),
        "vo2max": optionalDouble(row.vo2max),
        "avgHr": optionalInt(row.avgHr),
        "maxHr": optionalInt(row.maxHr),
        "walkingHr": optionalInt(row.walkingHr),
        "weightKg": optionalDouble(row.weightKg),
    ])
}

private func sleepJSON(_ row: SleepSessionRow) -> JSONValue {
    .object([
        "startTs": .int(row.startTs),
        "endTs": .int(row.endTs),
        "start": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.startTs)))),
        "end": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.endTs)))),
        "durationMin": .double(Double(max(0, row.endTs - row.startTs)) / 60.0),
        "efficiency": optionalDouble(row.efficiency),
        "restingHr": optionalInt(row.restingHr),
        "avgHrv": optionalDouble(row.avgHrv),
        "hasStages": .bool(row.stagesJSON != nil),
    ])
}

private func workoutJSON(_ row: WorkoutRow) -> JSONValue {
    .object([
        "startTs": .int(row.startTs),
        "endTs": .int(row.endTs),
        "start": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.startTs)))),
        "end": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.endTs)))),
        "sport": .string(row.sport),
        "source": .string(row.source),
        "durationS": optionalDouble(row.durationS),
        "energyKcal": optionalDouble(row.energyKcal),
        "avgHr": optionalInt(row.avgHr),
        "maxHr": optionalInt(row.maxHr),
        "strain": optionalDouble(row.strain),
        "distanceM": optionalDouble(row.distanceM),
        "hasZones": .bool(row.zonesJSON != nil),
        "hasNotes": .bool(row.notes != nil),
    ])
}

private func timestampJSON(_ ts: Int?, now: Date) -> JSONValue {
    guard let ts else { return .null }
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    return .object([
        "ts": .int(ts),
        "iso": .string(iso(date)),
        "ageSeconds": .int(max(0, Int(now.timeIntervalSince(date)))),
    ])
}

private func coverageJSON(_ days: [String]) -> JSONValue {
    .object([
        "count": .int(days.count),
        "firstDay": days.min().map { .string($0) } ?? .null,
        "lastDay": days.max().map { .string($0) } ?? .null,
    ])
}

private func optionalDouble(_ value: Double?) -> JSONValue {
    value.map { .double($0) } ?? .null
}

private func optionalInt(_ value: Int?) -> JSONValue {
    value.map { .int($0) } ?? .null
}

func boundedDays(_ value: JSONValue?, default defaultValue: Int, max maxValue: Int) -> Int {
    guard let raw = value?.intValue else { return defaultValue }
    return min(max(raw, 1), maxValue)
}

func boundedLimit(_ value: JSONValue?, default defaultValue: Int, max maxValue: Int) -> Int {
    guard let raw = value?.intValue else { return defaultValue }
    return min(max(raw, 1), maxValue)
}

func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    var result: [T] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        result.append(value)
    }
    return result
}

private func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

private func dayRange(days: Int) -> (from: String, to: String) {
    let now = Date()
    return (
        from: dayString(now.addingTimeInterval(-Double(max(1, days) - 1) * 86_400)),
        to: dayString(now.addingTimeInterval(86_400))
    )
}

private func timestampRange(days: Int) -> (from: Int, to: Int) {
    let now = Int(Date().timeIntervalSince1970)
    return (now - max(1, days) * 86_400, now + 86_400)
}

private func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func logicalDayKey(_ now: Date) -> String {
    dayString(now.addingTimeInterval(-4 * 3_600))
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
