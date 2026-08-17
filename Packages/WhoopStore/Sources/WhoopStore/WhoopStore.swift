import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// The store schema-version marker, bumped per migration. Surfaced in the backup manifest (#1410) so an
    /// export records the platform's schema version (a platform-scoped indicator — Android reports its Room
    /// version independently; the two numbering schemes are not expected to match).
    public static let schemaVersion = 18
}

/// Serializes `DatabasePool` creation + migration so two concurrent opens of the SAME file can never
/// run their GRDB migrators at once (#261).
///
/// `WhoopStore(path:)` is opened from more than one place on the same file — the BLEManager's backfill
/// store and the app's MetricsRepository (see the `init(path:)` note). On the first launch after an
/// update that adds a migration, a cold *background* relaunch (iOS CoreBluetooth state restoration) can
/// fire both opens at once. Each `DatabaseMigrator` reads "migration N unapplied", both apply it, and
/// the loser's bookkeeping `INSERT` collides: `UNIQUE constraint failed: grdb_migrations.identifier`
/// (SQLITE_CONSTRAINT). That open throws — on iOS the backfill sees "store not ready" and the offload
/// is deferred to the next tick. It self-heals once one migrator commits, but the failed open is a
/// real, user-visible sync stall.
///
/// `openAndMigrate` is actor-isolated and fully synchronous (no `await` inside), so the actor's serial
/// executor runs exactly one open+migrate to completion before starting the next — closing the race at
/// the source, for every opener present and future, not just the two we know about. Opens are
/// launch-time-rare and a fully-migrated DB migrates nothing, so the serial gate costs nothing in
/// practice. Each caller still gets its OWN pool; only the open+migrate step is serialized.
private actor StoreOpenGate {
    static let shared = StoreOpenGate()

    func openAndMigrate(path: String, configuration config: Configuration) throws -> DatabasePool {
        // Self-heal a foreign DB left in place by a bad cross-platform restore (#222): an Android
        // (Room) backup that slipped past the import guard replaces our file with one that has our
        // data tables but NO `grdb_migrations` bookkeeping. The migrator then thinks nothing is
        // applied, re-runs v1, and crashes with `table "device" already exists` on every open — the
        // store never bootstraps. Quarantine such a file BEFORE opening so we start fresh instead of
        // looping forever. (A normal GRDB backup carries grdb_migrations and is left untouched.)
        WhoopStore.quarantineIncompatibleDatabase(at: path)
        let pool = try DatabasePool(path: path, configuration: config)
        try WhoopStore.makeMigrator().migrate(pool)
        return pool
    }
}

/// WhoopStore is an `actor`: its public API is `async`, and all GRDB work runs on the
/// actor's serial executor rather than the caller's (the main actor).
///
/// The connection is a GRDB `DatabasePool` (WAL): reads (`.read`) run CONCURRENTLY with the
/// backfill's bulk writes (`.write`) instead of serializing behind them (#755). A `DatabaseQueue`
/// funnels every read AND write through one serial executor, so the dashboard's ~40-55 reads
/// queued behind a multi-thousand-row import and froze Today for seconds. A Pool keeps a single
/// writer (writes still serialize, exactly as before, so every read-modify-write inside one
/// `.write` stays atomic) but serves reads from WAL snapshots in parallel (committed data only,
/// never a partial write). The actor still moves the synchronous-blocking GRDB calls off the
/// caller's (main) thread; what changed is read/write CONCURRENCY at the SQLite layer, not the
/// data or the query results.
public actor WhoopStore {

    /// v18 aux rows banked since the retention sweep last ran, PER DEVICE — the sweep is per device too,
    /// so a shared counter would let one strap spend another's budget. See `StreamStore`.
    var v18AuxRowsSincePrune: [String: Int] = [:]
    let dbWriter: any DatabaseWriter

    /// Read-only handle to the underlying GRDB writer for the synchronous `DeviceRegistryStore`.
    /// `nonisolated` because a GRDB `DatabaseWriter` (here a `DatabasePool`) is `Sendable` and
    /// manages its own concurrency, so concurrent access alongside the actor's own DB work is safe
    /// (the Pool serializes writes and runs reads in parallel under WAL).
    public nonisolated var registryWriter: any DatabaseWriter { dbWriter }

    private init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try WhoopStore.makeMigrator().migrate(dbWriter)
    }

    /// Store an already-open, already-migrated writer WITHOUT re-running the migrator: the
    /// `StoreOpenGate` (below) opened the pool and migrated it under the process-wide open lock, so
    /// re-migrating here would be a redundant (and, if it raced a sibling opener, failing) second run.
    /// (#261)
    private init(preMigrated dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Open (creating if needed) a database at `path` and run migrations.
    /// Uses a `DatabasePool`, which enables WAL automatically, plus a 5-second busy timeout so two
    /// handles to the same file (BLEManager + MetricsRepository) don't deadlock on write contention.
    ///
    /// Open + migrate runs through `StoreOpenGate` so two concurrent openers of the SAME file never
    /// run their GRDB migrators at once (#261) — see that actor's note for the failure it prevents.
    public init(path: String) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // `DatabasePool` puts the database in WAL mode itself (reads run as concurrent snapshots
            // alongside the single writer, #755), so there is no explicit `PRAGMA journal_mode = WAL`.
            // Bulk-write/read tuning. NORMAL is the durable, recommended pairing with WAL (only an
            // OS crash/power loss can lose the last transaction — acceptable here). Bigger page cache
            // + mmap + in-memory temp tables speed the multi-thousand-row import/backfill writes.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -16000")     // ~16 MB page cache
            try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB memory-mapped I/O
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        config.busyMode = .timeout(5)
        let pool = try await StoreOpenGate.shared.openAndMigrate(path: path, configuration: config)
        self.init(preMigrated: pool)
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
    ///
    /// Backed by a `DatabaseQueue`, not a `DatabasePool`: GRDB has no in-memory `DatabasePool`
    /// (a Pool needs a real file so its reader connections can open WAL snapshots of it). A
    /// `DatabaseQueue` is also a `DatabaseWriter`, so this is API-identical; only the concurrency
    /// differs, which an in-memory test store doesn't exercise. The production `init(path:)` path
    /// is the one that gets the Pool (#755). Tests that need real read/write concurrency open a
    /// file-backed Pool directly.
    public static func inMemory() async throws -> WhoopStore {
        try WhoopStore(dbWriter: try DatabaseQueue())
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync read/write overloads @_disfavoredOverload so that in an async
    // context Swift would otherwise pick the async overloads. These thin wrappers are
    // regular (non-async) functions, so overload resolution always selects the synchronous
    // GRDB API — which then blocks on the actor's serial executor (off main thread).

    @inline(__always)
    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    @inline(__always)
    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    // MARK: - Maintenance

    /// Fully checkpoint the WAL into the main database file and truncate the -wal file.
    /// Used before a file-level backup so the single `whoop.sqlite` carries all committed data
    /// (the -wal/-shm siblings can then be ignored). Runs outside a transaction — `wal_checkpoint`
    /// must. Best-effort: throws on a hard SQLite error so callers can fall back to a plain copy.
    public func checkpointWAL() async throws {
        try checkpointWALImpl()
    }

    /// #1410: append one app-level event (e.g. `APP_VERSION_CHANGED`) onto the event table. Idempotent on
    /// the `(deviceId, ts, kind)` primary key. Twin of Android `WhoopRepository.recordEvent`.
    public func recordEvent(deviceId: String, ts: Int, kind: String, payloadJSON: String) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, ts, kind) DO NOTHING
                """, arguments: [deviceId, ts, kind, payloadJSON])
        }
    }

    /// Non-async so GRDB's synchronous `writeWithoutTransaction` overload is chosen (mirrors the
    /// syncRead/syncWrite pattern). Runs on the actor's executor, off the main thread.
    private func checkpointWALImpl() throws {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Permanently delete every recorded sample/derived row for one device across all `deviceId`-keyed
    /// tables (16+ `DELETE FROM <table> WHERE deviceId = ?` in one GRDB transaction). Wraps the
    /// synchronous `DeviceRegistryStore.deleteAllData` so the heavy multi-table write runs on the actor's
    /// own serial executor, OFF the main thread. The "Delete all of this device's data" and "Remove
    /// Apple Health data" actions previously ran this same store write synchronously on the main actor and
    /// froze the UI on a large dataset. The `pairedDevice` registry row is left intact (archiving/removing
    /// it is a separate op). Async entry point; the actual write is on `deleteAllDataImpl`.
    public func deleteAllData(deviceId: String) async throws {
        try deleteAllDataImpl(deviceId: deviceId)
    }

    /// Non-async so the synchronous `DeviceRegistryStore.deleteAllData` (a blocking GRDB write) is called
    /// directly (mirrors the syncRead/syncWrite pattern). Runs on the actor's executor, off the main
    /// thread. Builds the synchronous registry wrapper over the same GRDB writer the store owns.
    private func deleteAllDataImpl(deviceId: String) throws {
        try DeviceRegistryStore(dbQueue: dbWriter).deleteAllData(deviceId: deviceId)
    }

    /// Total on-disk size of the database — the main file plus its `-wal`/`-shm` siblings — in bytes.
    /// Drives the iOS Storage diagnostics screen (#590). `nil` for an in-memory store (no path). Runs
    /// on the actor's executor, off the main thread. Note (#755): under the `DatabasePool` the `-wal`
    /// component can stay non-zero while a reader connection holds an open snapshot, so a `checkpointWAL`
    /// may not fully truncate it; this total stays correct (it always includes the sidecars) but can
    /// read a little higher than the old single-connection `DatabaseQueue` did right after a checkpoint.
    public func databaseFileSizeBytes() async -> Int64? {
        let base = dbWriter.path
        guard base != ":memory:", !base.isEmpty else { return nil }
        let fm = FileManager.default
        var total: Int64 = 0
        var found = false
        for suffix in ["", "-wal", "-shm"] {
            let path = base + suffix
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
                found = true
            }
        }
        return found ? total : nil
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

    /// True when `column` is NULLABLE and carries NO SQL DEFAULT; nil when the column does not exist.
    /// Migration tests use this to prove an added column is genuinely additive: a NOT NULL or a DEFAULT
    /// would turn "the strap never reported this" into a fabricated value that reads identically to a
    /// real one.
    public func columnIsNullableWithoutDefaultForTest(table: String, column: String) async throws -> Bool? {
        try syncRead { db in
            guard let c = try db.columns(in: table).first(where: { $0.name == column }) else { return nil }
            return !c.isNotNull && c.defaultValueSQL == nil
        }
    }

    public func indexNamesForTest(table: String) async throws -> Set<String> {
        try syncRead { db in
            try Set(db.indexes(on: table).map(\.name))
        }
    }
}
