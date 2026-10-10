import XCTest
import GRDB
@testable import WhoopStore

/// #814: one physical strap, two device ids. A legacy single-WHOOP install that later paired the
/// same strap in the multi-device registry holds rows under BOTH the v15 seed id "my-whoop"
/// (sessions launched while the seed was the active row) and the registry's `whoop-…` id, and the
/// per-day single-owner scoring reads can only ever see one side. `rehomeLegacyWhoopAlias` merges
/// the seed's rows onto the active WHOOP id — under guards that keep it a no-op for every other
/// install shape.
final class LegacyWhoopAliasRehomeTests: XCTestCase {
    private let serial = "whoop-MGB123456"

    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // seeds 'my-whoop' active
        return dbq
    }

    /// Pair the same strap in the registry and make it active, as the Add-Device wizard does.
    private func pairSerialWhoop(_ store: DeviceRegistryStore, peripheralId: String? = "CB-UUID-1") throws {
        try store.add(PairedDevice(id: serial, brand: "WHOOP", model: "5.0 MG",
                                   peripheralId: peripheralId, sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 2, lastSeenAt: 2))
        try store.setActive(serial)
    }

    private func count(_ dbq: DatabaseQueue, _ table: String, _ id: String) throws -> Int {
        try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?", arguments: [id]) ?? 0 }
    }

    private func seedSplitRows(_ dbq: DatabaseQueue) throws {
        try dbq.write { db in
            // The seed era: full nights under 'my-whoop' (HR + gravity + beats), scored days under
            // its computed sibling.
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 10, 55)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 11, 56)")
            try db.execute(sql: "INSERT INTO gravitySample (deviceId, ts, x, y, z) VALUES ('my-whoop', 10, 0, 0, 1000)")
            try db.execute(sql: "INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel, tsSuspect) VALUES ('my-whoop', 10, 900, 0, 0, 5, NULL)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop-noop', 12, 57)")
            // The registry era: a partial slice under the serial id, including one clashing ts.
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('\(serial)', 10, 99)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('\(serial)', 20, 60)")
        }
    }

    func testRehomeMergesSeedRowsOntoActiveSerialId() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        try pairSerialWhoop(store)
        try seedSplitRows(dbq)

        XCTAssertTrue(try store.rehomeLegacyWhoopAliasIfNeeded())

        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop"), 0)
        XCTAssertEqual(try count(dbq, "gravitySample", "my-whoop"), 0)
        XCTAssertEqual(try count(dbq, "rrInterval", "my-whoop"), 0)
        XCTAssertEqual(try count(dbq, "hrSample", serial), 3)          // 2 moved + its own, clash not duplicated
        XCTAssertEqual(try count(dbq, "gravitySample", serial), 1)
        XCTAssertEqual(try count(dbq, "rrInterval", serial), 1)
        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop-noop"), 0)
        XCTAssertEqual(try count(dbq, "hrSample", serial + "-noop"), 1) // computed sibling travelled
        // On the clashing ts the ACTIVE id's row wins (UPDATE OR IGNORE), like adoptSerialIdentity.
        let clashBpm = try dbq.read { try Int.fetchOne($0, sql: "SELECT bpm FROM hrSample WHERE deviceId = ? AND ts = 10", arguments: [serial]) }
        XCTAssertEqual(clashBpm, 99)
        // Registry end state: seed row dropped, serial row still the single active device.
        XCTAssertEqual(try store.all().map(\.id), [serial])
        XCTAssertEqual(try store.activeDeviceId(), serial)
        // Idempotent: nothing left to heal.
        XCTAssertFalse(try store.rehomeLegacyWhoopAliasIfNeeded())
    }

    func testRehomeIsNoOpWhenSeedIsTheActiveDevice() throws {
        // The plain legacy install (never paired in the registry): migration + bootstrap must not
        // touch it — 'my-whoop' IS the strap, there is no second id.
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        try dbq.write { try $0.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 10, 55)") }
        XCTAssertFalse(try store.rehomeLegacyWhoopAliasIfNeeded())
        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop"), 1)
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    func testRehomeIsNoOpWhenAnotherDeviceIsActive() throws {
        // A ring is active; the WHOOP pair exists but is not the write/read spine's device.
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        try pairSerialWhoop(store)
        try store.add(PairedDevice(id: "oura-1", brand: "Oura", model: "Ring 4", sourceKind: .oura,
                                   capabilities: [.hr], status: .paired, addedAt: 3, lastSeenAt: 3))
        try store.setActive("oura-1")
        try seedSplitRows(dbq)
        XCTAssertFalse(try store.rehomeLegacyWhoopAliasIfNeeded())
        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop"), 2)
    }

    func testRehomeRefusesWhenSeedAdoptedADifferentPeripheral() throws {
        // The seed carries a DIFFERENT adopted peripheralId than the active row: positive evidence
        // the two ids are two physical straps, so the seed's history must not be blended in.
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        try pairSerialWhoop(store, peripheralId: "CB-UUID-1")
        try store.setPeripheralId("my-whoop", peripheralId: "CB-UUID-OTHER")
        try seedSplitRows(dbq)
        XCTAssertFalse(try store.rehomeLegacyWhoopAliasIfNeeded())
        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop"), 2)
        XCTAssertEqual(try count(dbq, "hrSample", serial), 2)
    }

    func testRehomeRefusesWithAThirdWhoopRow() throws {
        // A second registry WHOOP (another strap, or a stale duplicate pairing) makes the pair
        // ambiguous: which strap owns the seed's history is unknowable, so nothing merges.
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        try pairSerialWhoop(store)
        try store.add(PairedDevice(id: "whoop-OTHER", brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
                                   capabilities: [.hr], status: .archived, addedAt: 3, lastSeenAt: 3))
        try seedSplitRows(dbq)
        XCTAssertFalse(try store.rehomeLegacyWhoopAliasIfNeeded())
        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop"), 2)
    }

    func testRehomeIsNoOpWhenSeedHoldsNoRows() throws {
        // Paired in the registry but the seed never banked anything (fresh install that went
        // straight to the wizard): nothing is split, and the seed row is left standing.
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        try pairSerialWhoop(store)
        XCTAssertFalse(try store.rehomeLegacyWhoopAliasIfNeeded())
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", serial])
    }

    /// The v48 migration itself, driven the way an upgrading install hits it: state seeded at v47,
    /// then the full migrator runs.
    func testV48MigrationRehomesASplitInstall() throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v47-rr-whoop5-fill")
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
                VALUES ('\(serial)', 'WHOOP', '5.0 MG', NULL, 'CB-UUID-1', 'liveBLE', 'hr,hrv', 'paired', 2, 2)
            """)
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE id = 'my-whoop'")
            try db.execute(sql: "UPDATE pairedDevice SET status = 'active' WHERE id = '\(serial)'")
        }
        try seedSplitRows(dbq)

        try WhoopStore.makeMigrator().migrate(dbq)

        XCTAssertEqual(try count(dbq, "hrSample", "my-whoop"), 0)
        XCTAssertEqual(try count(dbq, "hrSample", serial), 3)
        XCTAssertEqual(try count(dbq, "rrInterval", serial), 1)
        let store = DeviceRegistryStore(dbQueue: dbq)
        XCTAssertEqual(try store.all().map(\.id), [serial])
    }
}
