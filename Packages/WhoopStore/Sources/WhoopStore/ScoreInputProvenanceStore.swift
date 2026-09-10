import Foundation
import GRDB

public struct SourcedMetricPoint: Sendable {
    public let deviceId: String
    public let point: MetricPoint
    public init(deviceId: String, point: MetricPoint) { self.deviceId = deviceId; self.point = point }
}

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

extension WhoopStore {
    /// Persist computed daily/series scores and their input provenance in one SQLite transaction.
    /// Replacing daily-score provenance in the scoring window prevents stale attribution when a metric
    /// disappears or changes provider; independently-owned weekly VO₂max method tags survive. Any write
    /// failure rolls back both scores and metadata.
    public func persistComputedScores(
        dailyMetrics: [DailyMetric],
        metricPoints: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
        deviceId: String,
        from: String,
        to: String,
        replaceMetricKeys: [String] = [],
        additionalMetricPoints: [SourcedMetricPoint] = [],
        replaceMetricSourceIds: [String] = []
    ) async throws {
        // #1196: an empty scoring pass must not destructively rewrite the window — with no daily rows to
        // write, the provenance wide-delete below would blank the window's attribution while a degenerate
        // pass (a transient read over an incomplete raw store during a reconnect/offload storm) produced
        // nothing. A real pass always carries the days it scored, so this guard never fires in steady state.
        // Twin of the Android WhoopDao.replaceComputedScoreWindow empty guard.
        guard !dailyMetrics.isEmpty else { return }
        try syncWrite { db in
            _ = try Self.upsertDailyMetrics(dailyMetrics, deviceId: deviceId, in: db)
            for source in Set(replaceMetricSourceIds + [deviceId]) {
                for key in replaceMetricKeys {
                    try db.execute(sql: "DELETE FROM metricSeries WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?",
                                   arguments: [source, key, from, to])
                }
            }
            _ = try Self.upsertMetricSeries(metricPoints, deviceId: deviceId, in: db)
            for group in Dictionary(grouping: additionalMetricPoints, by: \.deviceId) {
                _ = try Self.upsertMetricSeries(group.value.map(\.point), deviceId: group.key, in: db)
            }

            // Weekly VO₂max provenance is owned by `persistMetricSeriesWithProvenance` below, not this
            // daily scoring window. Preserve it or every normal 21-day re-score erases the prior two
            // Saturdays' method tags while leaving their metricSeries values in place.
            try db.execute(sql: """
                DELETE FROM scoreInputProvenance
                WHERE deviceId = ? AND day >= ? AND day <= ? AND key != 'vo2max_est'
                """, arguments: [deviceId, from, to])
            for row in provenance {
                try db.execute(sql: """
                    INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day,key) DO UPDATE SET sourceId = excluded.sourceId
                    """, arguments: [deviceId, row.day, row.key, row.sourceId])
            }
        }
    }

    /// Persist a metric-series batch and its specialized provenance in one SQLite transaction. Used by
    /// weekly VO₂max so a method label can never describe an older/newer value after a partial write.
    public func persistMetricSeriesWithProvenance(
        points: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
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
        }
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
