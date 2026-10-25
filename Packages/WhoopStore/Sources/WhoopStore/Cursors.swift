import Foundation
import GRDB

extension WhoopStore {
    public func setCursor(_ name: String, _ value: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO cursors (name, value) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET value = excluded.value
                """, arguments: [name, value])
        }
    }
    public nonisolated func cursor(_ name: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [name])
        }
    }
    public func setHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("highwater:" + stream, ts) }
    public func highwater(_ stream: String) async throws -> Int? { try await cursor("highwater:" + stream) }

    // MARK: - Read highwater (server-pull cursor)
    // A DISTINCT "read:" prefix so the pull cursor never collides with the upload "highwater:"
    // cursor for the same stream. Tracks the max server ts pulled-and-upserted per stream so
    // pulls are incremental.
    public func setReadHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("read:" + stream, ts) }
    public func readHighwater(_ stream: String) async throws -> Int? { try await cursor("read:" + stream) }
}
