import Foundation
import GRDB

/// Provenance for one persisted NOOP-computed score. `sourceId` normally names the input provider;
/// `vo2max_est` uses the estimator id because the method is the provenance users need for that series.
/// Natural key: (computed device namespace, day, metric key).
public struct ScoreInputProvenanceRow: Equatable, Codable, Sendable {
    public let day: String
    public let key: String
    public let sourceId: String

    public init(day: String, key: String, sourceId: String) {
        self.day = day
        self.key = key
        self.sourceId = sourceId
    }
}

/// Estimator identity persisted beside a `vo2max_est` point in `ScoreInputProvenanceRow.sourceId`.
/// Existing points have no such row and therefore remain explicitly unknown; their method must never be
/// inferred from the current profile because a waist measurement may have changed since they were scored.
public enum Vo2MaxEstimator: String, Codable, Sendable {
    case nes
    case uth

    public static func forWaistCm(_ waistCm: Double) -> Self { waistCm > 0 ? .nes : .uth }
}

/// Which persistence transaction owns a computation stamp. The daily window replaces only its own rows,
/// so independently-written weekly/standalone metric-series provenance survives an ordinary re-score.
public enum ScoreComputationScope: String, Codable, Sendable {
    case scoreWindow = "score-window"
    case metricSeries = "metric-series"
}

/// Exact app identity and wall-clock instant captured for one computation pass. `computedBy` deliberately
/// includes platform, marketing version, and build number because a cross-platform backup may contain rows
/// produced by either app, and two staging builds may share a marketing version.
public struct ScoreComputationStamp: Equatable, Codable, Sendable {
    public let computedBy: String
    public let computedAt: Int64 // unix milliseconds

    public init(computedBy: String, computedAt: Int64) {
        self.computedBy = computedBy
        self.computedAt = computedAt
    }

    public static func buildIdentity(platform: String, appVersion: String, appBuild: String) -> String {
        "\(platform):\(appVersion)+\(appBuild)"
    }
}

/// Build provenance for one persisted computed score cell. Missing means the value predates tier 3 or the
/// metadata could not be committed; callers and export analysis must preserve that honest unknown state.
public struct ScoreComputationProvenanceRow: Equatable, Codable, Sendable {
    public let day: String
    public let key: String
    public let computedBy: String
    public let computedAt: Int64
    public let scope: ScoreComputationScope

    public init(day: String, key: String, computedBy: String, computedAt: Int64,
                scope: ScoreComputationScope) {
        self.day = day
        self.key = key
        self.computedBy = computedBy
        self.computedAt = computedAt
        self.scope = scope
    }
}

extension WhoopStore {
    /// Persist computed daily/series scores and their input provenance in one SQLite transaction.
    /// Replacing daily-score provenance in the scoring window prevents stale attribution when a metric
    /// disappears or changes provider; independently-owned weekly VO₂max method tags survive. Any write
    /// failure rolls back both scores and metadata.
    public func persistComputedScores(
        dailyMetrics: [DailyMetric],
        metricPoints: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
        computation: ScoreComputationStamp,
        deviceId: String,
        from: String,
        to: String
    ) async throws {
        // #1196: an empty scoring pass must not destructively rewrite the window — with no daily rows to
        // write, the provenance wide-delete below would blank the window's attribution while a degenerate
        // pass (a transient read over an incomplete raw store during a reconnect/offload storm) produced
        // nothing. A real pass always carries the days it scored, so this guard never fires in steady state.
        // Twin of the Android WhoopDao.replaceComputedScoreWindow empty guard.
        guard !dailyMetrics.isEmpty else { return }
        try syncWrite { db in
            _ = try Self.upsertDailyMetrics(dailyMetrics, deviceId: deviceId, in: db)
            _ = try Self.upsertMetricSeries(metricPoints, deviceId: deviceId, in: db)

            // Weekly VO₂max provenance is owned by `persistMetricSeriesWithProvenance` below, not this
            // daily scoring window. Preserve it or every normal 21-day re-score erases the prior two
            // Saturdays' method tags while leaving their metricSeries values in place.
            try db.execute(sql: """
                DELETE FROM scoreInputProvenance
                WHERE deviceId = ? AND day >= ? AND day <= ? AND key != 'vo2max_est'
                """, arguments: [deviceId, from, to])
            try db.execute(sql: """
                DELETE FROM scoreComputationProvenance
                WHERE deviceId = ? AND day >= ? AND day <= ? AND scope = ?
                """, arguments: [deviceId, from, to, ScoreComputationScope.scoreWindow.rawValue])
            for row in provenance {
                try db.execute(sql: """
                    INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day,key) DO UPDATE SET sourceId = excluded.sourceId
                    """, arguments: [deviceId, row.day, row.key, row.sourceId])
            }
            let cells = Set(provenance.map { "\($0.day)\u{1F}\($0.key)" })
                .union(metricPoints.map { "\($0.day)\u{1F}\($0.key)" })
            for cell in cells.sorted() {
                let parts = cell.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                try Self.upsertComputationProvenance(
                    day: parts[0], key: parts[1], stamp: computation, scope: .scoreWindow,
                    deviceId: deviceId, in: db)
            }
        }
    }

    /// Persist a metric-series batch and its specialized provenance in one SQLite transaction. Used by
    /// weekly VO₂max so a method label can never describe an older/newer value after a partial write.
    public func persistMetricSeriesWithProvenance(
        points: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
        computation: ScoreComputationStamp,
        deviceId: String
    ) async throws {
        try syncWrite { db in
            _ = try Self.upsertMetricSeries(points, deviceId: deviceId, in: db)
            for row in provenance {
                try db.execute(sql: """
                    INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day,key) DO UPDATE SET sourceId = excluded.sourceId
                    """, arguments: [deviceId, row.day, row.key, row.sourceId])
            }
            for point in points {
                try Self.upsertComputationProvenance(
                    day: point.day, key: point.key, stamp: computation, scope: .metricSeries,
                    deviceId: deviceId, in: db)
            }
        }
    }

    /// Which build last computed one stored score cell. Missing is the expected legacy state.
    public func scoreComputationProvenance(
        deviceId: String, day: String, key: String
    ) async throws -> ScoreComputationProvenanceRow? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT day, key, computedBy, computedAt, scope
                FROM scoreComputationProvenance
                WHERE deviceId = ? AND day = ? AND key = ?
                """, arguments: [deviceId, day, key]),
                  let scope = ScoreComputationScope(rawValue: row["scope"] as String)
            else { return nil }
            return ScoreComputationProvenanceRow(
                day: row["day"], key: row["key"], computedBy: row["computedBy"],
                computedAt: row["computedAt"], scope: scope)
        }
    }

    private static func upsertComputationProvenance(
        day: String, key: String, stamp: ScoreComputationStamp, scope: ScoreComputationScope,
        deviceId: String, in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO scoreComputationProvenance
                (deviceId, day, key, computedBy, computedAt, scope)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, day, key) DO UPDATE SET
                computedBy = excluded.computedBy,
                computedAt = excluded.computedAt,
                scope = excluded.scope
            """, arguments: [deviceId, day, key, stamp.computedBy, stamp.computedAt, scope.rawValue])
    }

    /// Input source for one computed score. Missing means the score predates provenance storage or its
    /// attribution could not be persisted; callers must omit the badge instead of guessing.
    public func scoreInputSource(deviceId: String, day: String, key: String) async throws -> String? {
        try syncRead { db in
            try String.fetchOne(db, sql: """
                SELECT sourceId FROM scoreInputProvenance
                WHERE deviceId = ? AND day = ? AND key = ?
                """, arguments: [deviceId, day, key])
        }
    }
}
