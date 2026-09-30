import Foundation
import GRDB

/// Timed workout position; integer microdegrees keep the stored value the same on Apple and Android.
public struct StoredWorkoutRoutePoint: Equatable, Sendable {
    public let latE6: Int
    public let lonE6: Int
    public let tMs: Int64
    public let activeElapsedMs: Int64?
    public let segment: Int

    public init(latE6: Int, lonE6: Int, tMs: Int64, activeElapsedMs: Int64? = nil, segment: Int = 0) {
        self.latE6 = latE6
        self.lonE6 = lonE6
        self.tMs = tMs
        self.activeElapsedMs = activeElapsedMs
        self.segment = segment
    }
}

extension WhoopStore {
    /// Replace the time series for one workout atomically. An empty series clears stale imported data.
    public func replaceWorkoutRoutePoints(_ points: [StoredWorkoutRoutePoint], deviceId: String,
                                          startTs: Int, sport: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workoutRoutePoint WHERE deviceId = ? AND startTs = ? AND sport = ?",
                           arguments: [deviceId, startTs, sport])
            for (seq, point) in points.enumerated() {
                try db.execute(sql: """
                    INSERT INTO workoutRoutePoint
                    (deviceId, startTs, sport, seq, latE6, lonE6, tMs, activeElapsedMs, segment)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, startTs, sport, seq, point.latE6, point.lonE6,
                                     point.tMs, point.activeElapsedMs, point.segment])
            }
        }
    }

    /// Copy route measurements when a manual workout is re-keyed. The destination is replaced atomically.
    public func copyWorkoutRoutePoints(fromDeviceId: String, fromStartTs: Int, fromSport: String,
                                       toDeviceId: String, toStartTs: Int, toSport: String) async throws {
        if fromDeviceId == toDeviceId && fromStartTs == toStartTs && fromSport == toSport { return }
        try syncWrite { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM workoutRoutePoint WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [fromDeviceId, fromStartTs, fromSport]) ?? 0
            guard count > 0 else { return }
            try db.execute(sql: "DELETE FROM workoutRoutePoint WHERE deviceId = ? AND startTs = ? AND sport = ?",
                           arguments: [toDeviceId, toStartTs, toSport])
            try db.execute(sql: """
                INSERT INTO workoutRoutePoint
                (deviceId, startTs, sport, seq, latE6, lonE6, tMs, activeElapsedMs, segment)
                SELECT ?, ?, ?, seq, latE6, lonE6, tMs, activeElapsedMs, segment
                FROM workoutRoutePoint WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [toDeviceId, toStartTs, toSport, fromDeviceId, fromStartTs, fromSport])
        }
    }

    public func deleteWorkoutRoutePoints(deviceId: String, startTs: Int, sport: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workoutRoutePoint WHERE deviceId = ? AND startTs = ? AND sport = ?",
                           arguments: [deviceId, startTs, sport])
        }
    }

    public func workoutRoutePoints(deviceId: String, startTs: Int, sport: String) async throws -> [StoredWorkoutRoutePoint] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT latE6, lonE6, tMs, activeElapsedMs, segment FROM workoutRoutePoint
                WHERE deviceId = ? AND startTs = ? AND sport = ? ORDER BY seq
                """, arguments: [deviceId, startTs, sport])
            return rows.map { row in
                StoredWorkoutRoutePoint(latE6: row["latE6"], lonE6: row["lonE6"],
                    tMs: row["tMs"], activeElapsedMs: row["activeElapsedMs"], segment: row["segment"])
            }
        }
    }
}
