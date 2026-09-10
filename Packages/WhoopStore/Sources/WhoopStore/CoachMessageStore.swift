import Foundation
import GRDB

// MARK: - v39 store: persisted Coach conversation (PRD-K2)
//
// CoachMessageStore.swift — GRDB CRUD over the `coachMessage` table (migration v39), so the AI
// Coach's chat survives relaunch. Mirrors the established `LabMarkerStore` idiom: a plain Codable
// row struct, raw `Row` fetch + manual decode, all GRDB work via the actor's `syncWrite`/`syncRead`.
//
// Stores only the coach's text replies + the user's questions — no raw biometric readings were ever
// in the chat (only the derived summary text sent with the request), so this carries the same
// no-raw-egress posture as the network call itself. NOT part of the `.noopbak` backup whitelist.

/// One persisted turn in the Coach conversation.
public struct CoachMessageRow: Equatable, Codable, Sendable {
    public var id: String
    public var role: String          // "user" | "assistant"
    public var text: String
    public var provider: String
    public var createdAt: Int        // epoch seconds
    public var orderIndex: Int       // monotonic replay order (two streamed turns can share createdAt)

    public init(id: String, role: String, text: String, provider: String, createdAt: Int, orderIndex: Int) {
        self.id = id
        self.role = role
        self.text = text
        self.provider = provider
        self.createdAt = createdAt
        self.orderIndex = orderIndex
    }

    static func decode(_ row: Row) -> CoachMessageRow {
        CoachMessageRow(
            id: row["id"], role: row["role"], text: row["text"], provider: row["provider"],
            createdAt: row["createdAt"], orderIndex: row["orderIndex"]
        )
    }
}

extension WhoopStore {

    /// The full stored conversation, oldest first (by `orderIndex`).
    public func coachMessages() async throws -> [CoachMessageRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM coachMessage ORDER BY orderIndex ASC")
                .map(CoachMessageRow.decode)
        }
    }

    /// Replace the ENTIRE stored conversation with `rows` in one transaction. Simpler and safer than
    /// incremental insert/update/delete bookkeeping across the engine's several streaming-finalization
    /// call sites (a streamed reply mutates the same message's text repeatedly before settling); the
    /// table is capped at the caller's `maxStoredMessages`, so a full replace is always cheap. Called
    /// once per completed send/brief, never per streamed chunk.
    public func replaceCoachMessages(_ rows: [CoachMessageRow]) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachMessage")
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO coachMessage (id, role, text, provider, createdAt, orderIndex)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [row.id, row.role, row.text, row.provider, row.createdAt, row.orderIndex])
            }
        }
    }

    /// Wipe the entire stored conversation (the Coach toolbar's "Clear conversation" action).
    public func clearCoachMessages() async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachMessage")
        }
    }
}
