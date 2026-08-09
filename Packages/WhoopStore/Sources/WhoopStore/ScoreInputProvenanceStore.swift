import Foundation
import GRDB

/// The source whose inputs produced one persisted NOOP-computed score.
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

extension WhoopStore {
    /// Persist computed daily/series scores and their input provenance in one SQLite transaction.
    /// Replacing provenance for the whole scoring window prevents stale attribution when a metric
    /// disappears or changes provider. Any write failure rolls back both scores and metadata.
    public func persistComputedScores(
        dailyMetrics: [DailyMetric],
        metricPoints: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
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

            try db.execute(sql: """
                DELETE FROM scoreInputProvenance
                WHERE deviceId = ? AND day >= ? AND day <= ?
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
