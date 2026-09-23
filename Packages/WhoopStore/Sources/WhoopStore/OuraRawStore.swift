import Foundation
import GRDB

// MARK: - v25 store: lossless Oura live-API payload archive
// Mirrors MetricSeriesStore exactly: a Codable row struct, an idempotent ON CONFLICT upsert keyed by the
// natural key (deviceId, endpoint, documentId), and range reads — all GRDB work via syncWrite/syncRead.
// This is the "as much as we can get" backstop: the verbatim payload is kept so a future metric can be
// derived without re-hitting the Oura API.

/// One archived Oura API payload. Natural key (deviceId, endpoint, documentId).
public struct OuraRawRow: Equatable, Codable, Sendable {
    public let endpoint: String     // "sleep" | "daily_readiness" | "heartrate" | …
    public let documentId: String   // Oura `id`; for heartrate pages, a synthesized window key
    public let day: String?         // Optional YYYY-MM-DD; page archives that span dates leave this nil
    public let payloadJSON: String  // verbatim object
    public let fetchedAt: Int       // unix seconds
    public init(endpoint: String, documentId: String, day: String?, payloadJSON: String, fetchedAt: Int) {
        self.endpoint = endpoint; self.documentId = documentId
        self.day = day; self.payloadJSON = payloadJSON; self.fetchedAt = fetchedAt
    }
}

extension WhoopStore {

    /// Upsert raw Oura payloads. Idempotent by (deviceId, endpoint, documentId): re-pulling the same
    /// document overwrites its payload/day/fetchedAt rather than duplicating. Returns rows changed.
    @discardableResult
    public func upsertOuraRaw(_ rows: [OuraRawRow], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO ouraRaw (deviceId, endpoint, documentId, day, payloadJSON, fetchedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, endpoint, documentId) DO UPDATE SET
                        day = excluded.day,
                        payloadJSON = excluded.payloadJSON,
                        fetchedAt = excluded.fetchedAt
                    """, arguments: [deviceId, r.endpoint, r.documentId, r.day, r.payloadJSON, r.fetchedAt])
                n += db.changesCount
            }
            return n
        }
    }

    /// Archived payloads for a device + endpoint, oldest fetch first.
    public func ouraRaw(deviceId: String, endpoint: String) async throws -> [OuraRawRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT endpoint, documentId, day, payloadJSON, fetchedAt FROM ouraRaw
                WHERE deviceId = ? AND endpoint = ?
                ORDER BY fetchedAt ASC
                """, arguments: [deviceId, endpoint])
                .map { OuraRawRow(endpoint: $0["endpoint"], documentId: $0["documentId"],
                                  day: $0["day"], payloadJSON: $0["payloadJSON"], fetchedAt: $0["fetchedAt"]) }
        }
    }

    /// Count archived payloads for a device + endpoint (diagnostics / import summary).
    public func ouraRawCount(deviceId: String, endpoint: String) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM ouraRaw WHERE deviceId = ? AND endpoint = ?",
                arguments: [deviceId, endpoint]) ?? 0
        }
    }

    /// Remove every archived Oura payload for a device (used by Disconnect — `deleteAllData` does not
    /// cover `ouraRaw`). Returns rows deleted.
    @discardableResult
    public func deleteOuraRaw(deviceId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM ouraRaw WHERE deviceId = ?", arguments: [deviceId])
            return db.changesCount
        }
    }
}
