import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// Bumped whenever the migrator gains a new migration.
    public static let schemaVersion = 17
}

/// WhoopStore is an `actor`: its public API is `async`, and all GRDB work runs on the
/// actor's serial executor rather than the caller's (the main actor). DatabaseQueue calls
/// are synchronous-blocking; the actor moves them off the main thread (it does not make them
/// non-blocking). That is the intended off-main win — DatabaseQueue kept, not DatabasePool.
public actor WhoopStore {
    let dbQueue: DatabaseQueue

    /// Read-only handle to the underlying GRDB queue for the synchronous `DeviceRegistryStore`.
    /// `nonisolated` because `DatabaseQueue` is `Sendable` and internally serialized — concurrent
    /// access alongside the actor's own DB work is safe (GRDB queues calls onto one serial executor).
    public nonisolated var registryQueue: DatabaseQueue { dbQueue }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try WhoopStore.makeMigrator().migrate(dbQueue)
    }

    /// Open (creating if needed) a database at `path` and run migrations.
    /// Enables WAL journal mode and a 5-second busy timeout so two handles to the same
    /// file (BLEManager + MetricsRepository) don't deadlock on write contention.
    public init(path: String) async throws {
        // Self-heal a foreign DB left in place by a bad cross-platform restore (#222): an Android
        // (Room) backup that slipped past the import guard replaces our file with one that has our
        // data tables but NO `grdb_migrations` bookkeeping. The migrator then thinks nothing is
        // applied, re-runs v1, and crashes with `table "device" already exists` on every open — the
        // store never bootstraps. Quarantine such a file BEFORE opening so we start fresh instead of
        // looping forever. (A normal GRDB backup carries grdb_migrations and is left untouched.)
        WhoopStore.quarantineIncompatibleDatabase(at: path)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Bulk-write/read tuning. NORMAL is the durable, recommended pairing with WAL (only an
            // OS crash/power loss can lose the last transaction — acceptable here). Bigger page cache
            // + mmap + in-memory temp tables speed the multi-thousand-row import/backfill writes.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -16000")     // ~16 MB page cache
            try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB memory-mapped I/O
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        config.busyMode = .timeout(5)
        try self.init(dbQueue: try DatabaseQueue(path: path, configuration: config))
    }

    /// Move aside a database file that has our data tables but no GRDB migration bookkeeping — the
    /// signature of a foreign (Android/Room) DB dropped over ours by a bad restore (#222). Opening it
    /// would make the migrator re-run v1 and throw `table "device" already exists` forever. Moving it
    /// to a `.incompatible-<ts>` sidecar lets the next open create a clean store. A valid GRDB DB
    /// (has `grdb_migrations`) and a fresh/empty file are both left untouched. Best-effort + silent.
    static func quarantineIncompatibleDatabase(at path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let names: Set<String>
        do {
            // Read-only probe of sqlite_master; a raw queue does NOT run migrations.
            let probe = try DatabaseQueue(path: path)
            names = try probe.read { db in
                try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            }
        } catch {
            return // unreadable/locked → let the real open + migrator deal with it
        }
        let isForeign = !names.contains("grdb_migrations")
            && (names.contains("device") || names.contains("hrSample"))
        guard isForeign else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let quarantine = "\(path).incompatible-\(stamp)"
        try? fm.removeItem(atPath: quarantine)
        do { try fm.moveItem(atPath: path, toPath: quarantine) } catch { return }
        // Drop the now-orphaned WAL/SHM sidecars so the fresh DB starts clean.
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
    }

    /// An in-memory store (migrations applied). For tests.
    public static func inMemory() async throws -> WhoopStore {
        try WhoopStore(dbQueue: try DatabaseQueue())
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync read/write overloads @_disfavoredOverload so that in an async
    // context Swift would otherwise pick the async overloads. These thin wrappers are
    // regular (non-async) functions, so overload resolution always selects the synchronous
    // GRDB API — which then blocks on the actor's serial executor (off main thread).

    @inline(__always)
    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    @inline(__always)
    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    // MARK: - Maintenance

    /// Fully checkpoint the WAL into the main database file and truncate the -wal file.
    /// Used before a file-level backup so the single `whoop.sqlite` carries all committed data
    /// (the -wal/-shm siblings can then be ignored). Runs outside a transaction — `wal_checkpoint`
    /// must. Best-effort: throws on a hard SQLite error so callers can fall back to a plain copy.
    public func checkpointWAL() async throws {
        try checkpointWALImpl()
    }

    /// Non-async so GRDB's synchronous `writeWithoutTransaction` overload is chosen (mirrors the
    /// syncRead/syncWrite pattern). Runs on the actor's executor, off the main thread.
    private func checkpointWALImpl() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Introspection (used by tests)

    public func tableNames() async throws -> Set<String> {
        try syncRead { db in
            try Set(String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    public func primaryKeyColumns(_ table: String) async throws -> [String] {
        try syncRead { db in
            try db.primaryKey(table).columns
        }
    }

    public func columnNamesForTest(table: String) async throws -> [String] {
        try syncRead { db in
            try db.columns(in: table).map(\.name)
        }
    }

    public func indexNamesForTest(table: String) async throws -> Set<String> {
        try syncRead { db in
            try Set(db.indexes(on: table).map(\.name))
        }
    }
}
