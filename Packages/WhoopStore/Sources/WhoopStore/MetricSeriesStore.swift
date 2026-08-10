import Foundation
import GRDB

// MARK: - v9 cache: generic long-format metric store
// The substrate for a metric explorer. Where MetricsCache / JournalWorkoutAppleCache use a
// WIDE column-per-metric layout (one table per source, typed nullable columns), this is the
// TALL/EAV counterpart: one row per (deviceId, day, key) with a single REAL `value`. Any scalar
// metric — whatever its origin — can be projected into this one table and read back uniformly by
// key, so the explorer can list/compare metrics without knowing each source's schema.
// Mirrors the established pattern exactly: Codable struct, idempotent ON CONFLICT upsert keyed by
// natural key, range-read accessors, all GRDB work via the actor's syncWrite/syncRead helpers.

/// One point in the long-format metric store. Natural key (deviceId, day, key).
public struct MetricPoint: Equatable, Codable, Sendable {
    public let day: String           // YYYY-MM-DD
    public let key: String           // metric identifier, e.g. "restingHr", "steps", "recovery"
    public let value: Double
    public init(day: String, key: String, value: Double) {
        self.day = day; self.key = key; self.value = value
    }
}

extension WhoopStore {

    // MARK: - Upsert (idempotent by natural key; latest value wins on conflict)

    /// Upsert metric points. Natural key (deviceId, day, key). Returns rows changed.
    /// Idempotent: re-upserting the same (deviceId, day, key) updates `value` in place rather than
    /// creating a duplicate.
    @discardableResult
    public func upsertMetricSeries(_ rows: [MetricPoint], deviceId: String) async throws -> Int {
        try syncWrite { db in
            try Self.upsertMetricSeries(rows, deviceId: deviceId, in: db)
        }
    }

    /// Transaction-sharing primitive used by computed-score persistence.
    static func upsertMetricSeries(_ rows: [MetricPoint], deviceId: String, in db: Database) throws -> Int {
        var n = 0
        for r in rows {
            try db.execute(sql: """
                INSERT INTO metricSeries
                    (deviceId, day, key, value)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, day, key) DO UPDATE SET
                    value = excluded.value
                """, arguments: [deviceId, r.day, r.key, r.value])
            n += db.changesCount
        }
        return n
    }

    // MARK: - Reads

    /// Points for a single `key` on days in [from, to] (lexicographic YYYY-MM-DD compare),
    /// oldest day first. Served index-only by idx_metricSeries_device_key_day.
    public func metricSeries(deviceId: String, key: String, from: String, to: String) async throws -> [MetricPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, key, from, to])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    /// Distinct metric keys present for a device, sorted ascending.
    public func metricKeys(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT key FROM metricSeries
                WHERE deviceId = ?
                ORDER BY key ASC
                """, arguments: [deviceId])
        }
    }

    /// Earliest and latest day for a given metric `key`, or nil if the key has no points.
    public func metricDays(deviceId: String, key: String) async throws -> (earliest: String, latest: String)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT MIN(day) AS earliest, MAX(day) AS latest FROM metricSeries
                WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key]),
                let earliest: String = row["earliest"],
                let latest: String = row["latest"]
            else { return nil }
            return (earliest, latest)
        }
    }

    /// Delete one point identified by the metric-series natural key. User-entered local series use this
    /// to provide a real delete (rather than leaving a sentinel value behind). Returns the number of rows
    /// removed; deleting an absent point is an idempotent zero-row change.
    @discardableResult
    public func deleteMetricSeriesPoint(deviceId: String, day: String, key: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day = ? AND key = ?
                """, arguments: [deviceId, day, key])
            return db.changesCount
        }
    }

    /// Delete every point for one source/key pair in a single statement. Returns the number of rows
    /// removed; deleting an absent series is an idempotent zero-row change.
    @discardableResult
    public func deleteMetricSeries(deviceId: String, key: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key])
            return db.changesCount
        }
    }
}
