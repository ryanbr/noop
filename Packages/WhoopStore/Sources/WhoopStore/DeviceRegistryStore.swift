import Foundation
import GRDB

/// Synchronous GRDB access to the device registry + day-ownership tables. Kept synchronous (its own
/// queue) to mirror the existing store helpers; the app wraps it behind the WhoopStore actor / a
/// @MainActor cache. Enforces invariant I1 (at most one .active) inside setActive's transaction.
///
/// `Sendable`: the only stored property is a GRDB `DatabaseWriter` (a `DatabasePool` in production;
/// the protocol refines `Sendable` and manages its own concurrency), so this thin synchronous wrapper
/// is safe to hand across actor boundaries, e.g. the off-main `IntelligenceEngine.analyzeRecent` scan
/// loop (FIX 1). A cross-module `public` struct doesn't auto-infer `Sendable`, so it's declared here.
///
/// Takes `any DatabaseWriter` (not the concrete `DatabaseQueue`) so it works with the store's
/// `DatabasePool` (#755) AND a plain `DatabaseQueue` (in-memory tests) unchanged: both expose the
/// same synchronous `.read`/`.write` API used below.
public struct DeviceRegistryStore: Sendable {
    let dbQueue: any DatabaseWriter
    public init(dbQueue: any DatabaseWriter) { self.dbQueue = dbQueue }

    public func all() throws -> [PairedDevice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pairedDevice ORDER BY addedAt ASC").map(Self.decode)
        }
    }

    public func activeDeviceId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1")
        }
    }

    public func add(_ d: PairedDevice) throws {
        try dbQueue.write { db in try Self.upsert(db, d) }
    }

    /// I1: promoting one device demotes whatever was active, atomically (single write transaction).
    public func setActive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
            try db.execute(sql: "UPDATE pairedDevice SET status = 'active', lastSeenAt = ? WHERE id = ?",
                           arguments: [Int(Date().timeIntervalSince1970), id])
        }
    }

    public func archive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'archived' WHERE id = ?", arguments: [id])
        }
    }

    /// Permanently remove a device's REGISTRY entry — both the `pairedDevice` row the Devices screen
    /// lists and its `device` provenance row — so a duplicate/stale strap can be purged entirely
    /// instead of lingering in the archived "Removed" list forever (issue #1193: today the only
    /// removal is the soft `archive`, and `deleteAllData` empties recordings but leaves the row). The
    /// device's recorded SAMPLES are NOT touched here — the caller wipes those first via
    /// `deleteAllData(deviceId:)` (registry entry vs. recordings are separate ops, exactly as
    /// `adoptSerialIdentity` treats them). Idempotent: removing an absent id is a no-op.
    public func remove(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pairedDevice WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [id])
        }
    }

    public func rename(_ id: String, nickname: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET nickname = ? WHERE id = ?", arguments: [nickname, id])
        }
    }

    /// Update the model label for an existing device (e.g. seeded "WHOOP" → "WHOOP 4.0" once the
    /// strap's service family is known from a live BLE connect).
    public func setModel(_ id: String, model: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET model = ? WHERE id = ?", arguments: [model, id])
        }
    }

    /// Stamp a row as seen right now. Called when a strap actually connects or drops, because nothing
    /// else in the BLE path writes `lastSeenAt` — before #1527 it was only ever set when the row was
    /// created or promoted to active, so the Devices card reported time-since-ADDED and a strap syncing
    /// every day could read "Last seen 45 d ago".
    ///
    /// Archived rows are excluded: "Removed - data kept" is a deliberate resting state, and a stray
    /// connect must not quietly resurrect one into looking live.
    public func touchLastSeen(_ id: String, at ts: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET lastSeenAt = ? WHERE id = ? AND status != 'archived'",
                           arguments: [ts, id])
        }
    }

    /// Adopt (or clear) the stable BLE identity for a registry row. `peripheralId` is the
    /// CBPeripheral.identifier.uuidString on iOS/Mac; passing nil un-adopts it.
    public func setPeripheralId(_ id: String, peripheralId: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ? WHERE id = ?",
                           arguments: [peripheralId, id])
        }
    }

    /// Find the registry row that has adopted a given BLE peripheral, if any. Used to map a
    /// connected CBPeripheral back to its `PairedDevice` so multiple straps stay distinct.
    public func device(forPeripheralId peripheralId: String) throws -> PairedDevice? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pairedDevice WHERE peripheralId = ? LIMIT 1",
                             arguments: [peripheralId]).map(Self.decode)
        }
    }

    /// Every table whose rows are keyed by `deviceId` (the per-device sample/derived tables). This is
    /// the authoritative list `deleteAllData` clears — kept in sync with the `deviceId`-keyed tables in
    /// `Database.swift`. The `pairedDevice` registry row itself is NOT here (a delete-data operation
    /// empties the device's recordings; archiving/removing the registry entry is a separate op).
    static let deviceScopedTables = [
        "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        "stepSample", "ppgHrSample", "event", "battery", "dailyMetric", "sleepSession",
        "journal", "workout", "appleDaily", "metricSeries", "dayOwnership",
        "scoreInputProvenance",
        // Added: device-keyed tables introduced by later migrations that the list previously missed, so a
        // "delete all of this device's data" left raw captures (rawBatch), user-entered lab/blood markers
        // (labMarker), banked band sleep-state (sleepStateSample) and live coaching sessions
        // (liveSession) behind — a privacy defect for a delete-means-gone app. `DeviceRegistryStoreTests`
        // asserts this list covers every deviceId-keyed table in Database.swift so future migrations
        // can't reintroduce the gap.
        "rawBatch", "labMarker", "sleepStateSample", "liveSession",
        // v25-oura-raw: the opt-in Oura cloud-import raw archive is deviceId-keyed too, so "delete this
        // device's data" must clear it — else an imported Oura source's payloads would survive deletion.
        "ouraRaw",
        // v27-ppg-waveform (issue #156 follow-up): the durable raw v26 optical PPG waveform is
        // deviceId-keyed exactly like every other per-second stream above — must be cleared too, or a
        // "delete all of this device's data" leaves the raw waveform behind (the same privacy defect
        // this list exists to close).
        "ppgWaveformSample",
        // v28-raw-imu (#423): the opt-in 5/MG raw-IMU offload capture is deviceId-keyed too — "delete all
        // of this device's data" must clear it, or the raw inertial samples survive deletion (same defect).
        "rawImuSample",
        // v31-deep-capture-channels: the banked 5/MG v18 auxiliary fields are deviceId-keyed per-second
        // rows like every stream above, so a "delete all of this device's data" must clear them too.
        "v18AuxSample",
        // v38-apple-step-hour: the hourly Apple Health step buckets are deviceId-keyed ("apple-health"),
        // so forgetting that source must clear them — otherwise an imported phone's hour-by-hour step
        // history survives the delete (the same privacy defect this list exists to close).
        "appleStepHour",
    ]

    /// Permanently delete every recorded sample/derived row belonging to one device, across all
    /// `deviceId`-keyed tables, in a single transaction (all-or-nothing). The `pairedDevice` registry
    /// row is left intact — the caller archives/removes that separately. Tables are deleted defensively
    /// with `DELETE FROM <table> WHERE deviceId = ?`; a missing table would throw, but every table here
    /// is created unconditionally by the migrator, so the set is stable.
    public func deleteAllData(deviceId: String) throws {
        try dbQueue.write { db in
            for table in Self.deviceScopedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [deviceId])
            }
            // Provenance also references the physical/import source separately from its computed
            // namespace. Forgetting a provider must remove those associations too.
            try db.execute(sql: "DELETE FROM scoreInputProvenance WHERE sourceId = ?",
                           arguments: [deviceId])
        }
    }

    /// #771: re-point the ACTIVE Oura device from its CoreBluetooth-UUID id (`activeId`, e.g.
    /// "oura-4DD70E24-…") onto its STABLE serial id (`serialId`, e.g. "oura-2H3B2405003655"), so a re-pair —
    /// which mints a fresh CB UUID — never orphans the ring's history again. The serial is read from the ring
    /// on connect, so it is the one identity that survives a factory-reset-and-adopt.
    ///
    /// SCOPE (agreed with the user): moves ONLY `activeId`'s data + registry row onto `serialId` — a plain
    /// rename when `serialId` is new, a merge (`UPDATE OR IGNORE`, canonical wins a PK clash) when it already
    /// exists from a prior pairing. Any OTHER `oura-*` rows (older pairings) are DELIBERATELY left untouched;
    /// consolidating those is a separate, explicit operation. One all-or-nothing transaction; idempotent
    /// (no-op when `activeId == serialId` or `activeId` is absent). Returns true when a re-point happened; the
    /// caller then `setActive(serialId)` so the read/write spine follows onto the serial id.
    @discardableResult
    public func adoptSerialIdentity(from activeId: String, to serialId: String) throws -> Bool {
        guard activeId != serialId else { return false }
        return try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ?", arguments: [activeId]) ?? false
            else { return false }   // nothing to re-point
            let serialExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ?", arguments: [serialId]) ?? false
            if serialExists {
                // A prior pairing already established the serial id: carry THIS pairing's fresh BLE identity +
                // model onto it so the coordinator reconnects to the right peripheral, keep it active.
                try db.execute(sql: """
                    UPDATE pairedDevice SET
                        peripheralId = (SELECT peripheralId FROM pairedDevice WHERE id = :a),
                        model        = (SELECT model        FROM pairedDevice WHERE id = :a),
                        status = 'active',
                        lastSeenAt   = (SELECT lastSeenAt   FROM pairedDevice WHERE id = :a)
                    WHERE id = :s
                """, arguments: ["a": activeId, "s": serialId])
            } else {
                // First time this serial is seen: clone the active (provisional) row under the serial id.
                try db.execute(sql: """
                    INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
                    SELECT ?, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt
                    FROM pairedDevice WHERE id = ?
                """, arguments: [serialId, activeId])
            }
            // Move the active id's recordings onto the serial id (canonical wins a PK clash), then clear it.
            for table in Self.deviceScopedTables {
                try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ?", arguments: [serialId, activeId])
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [activeId])
            }
            // Drop ONLY the provisional CB-UUID registry rows; other oura-* pairings are left as-is.
            try db.execute(sql: "DELETE FROM pairedDevice WHERE id = ?", arguments: [activeId])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [activeId])
            return true
        }
    }

    // MARK: day ownership
    public struct DayOwner: Equatable { public let deviceId: String; public let locked: Bool }

    public func setDayOwner(day: String, deviceId: String, locked: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET deviceId = excluded.deviceId, locked = excluded.locked
            """, arguments: [day, deviceId, locked ? 1 : 0])
        }
    }

    public func dayOwner(_ day: String) throws -> DayOwner? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceId, locked FROM dayOwnership WHERE day = ?", arguments: [day])
            else { return nil }
            return DayOwner(deviceId: row["deviceId"], locked: (row["locked"] as Int) == 1)
        }
    }

    // MARK: mapping
    private static func upsert(_ db: Database, _ d: PairedDevice) throws {
        try db.execute(sql: """
            INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET brand=excluded.brand, model=excluded.model, nickname=excluded.nickname,
                peripheralId=excluded.peripheralId, sourceKind=excluded.sourceKind, capabilities=excluded.capabilities,
                status=excluded.status, lastSeenAt=excluded.lastSeenAt
        """, arguments: [d.id, d.brand, d.model, d.nickname, d.peripheralId, d.sourceKind.rawValue,
                         d.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                         d.status.rawValue, d.addedAt, d.lastSeenAt])
    }

    private static func decode(_ row: Row) -> PairedDevice {
        // #1518: TRIM before matching. `Metric(rawValue:)` is exact, so a stored `"hr, hrv"` decoded to
        // `{hr}` — the whitespace-bearing token simply failed to parse and `compactMap` dropped it, losing
        // a real capability with nothing reporting it. Writes here are always canonical
        // (`map(\.rawValue).sorted().joined`), so a spaced token can only arrive from history: rows the
        // v36 migration rewrote before #1495 taught it to trim, or a restored backup.
        //
        // Fixing it on READ rather than with another migration is deliberate. A migration repairs the rows
        // that exist when it runs, once; trimming here self-heals every row every time it is read, including
        // any that arrive later from a restore. Kotlin never needed this — it keeps `capabilities` as a
        // String and normalises it at the registry layer, so it has no typed decode to lose anything in.
        var caps = Set(
            (row["capabilities"] as String)
                .split(separator: ",")
                .compactMap { Metric(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
        // #548: calibrated SpO₂ % is never produced from a live WHOOP path — drop a stale registry bit
        // so Devices / day-owner UI never advertise a capability AnalyticsEngine will not fill.
        let brand = row["brand"] as String
        let id = row["id"] as String
        if brand.caseInsensitiveCompare("WHOOP") == .orderedSame
            || id == "my-whoop"
            || id.hasPrefix("whoop-") {
            caps = WhoopLiveCapabilities.withoutCalibratedSpo2(caps)
        }
        return PairedDevice(id: id, brand: brand, model: row["model"], nickname: row["nickname"],
                            peripheralId: row["peripheralId"],
                            sourceKind: SourceKind(rawValue: row["sourceKind"]) ?? .liveBLE,
                            capabilities: caps, status: DeviceStatus(rawValue: row["status"]) ?? .paired,
                            addedAt: row["addedAt"], lastSeenAt: row["lastSeenAt"])
    }
}
