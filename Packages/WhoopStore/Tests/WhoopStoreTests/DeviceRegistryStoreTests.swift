import XCTest
import GRDB
@testable import WhoopStore

final class DeviceRegistryStoreTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // applies through v15, seeds 'my-whoop' active
        return dbq
    }

    func testSeededWhoopIsActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let devices = try store.all()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "my-whoop")
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    func testSetActiveEnforcesSingleActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.add(PairedDevice(id: "polar-1", brand: "Polar", model: "H10", sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 1, lastSeenAt: 1))
        try store.setActive("polar-1")
        XCTAssertEqual(try store.activeDeviceId(), "polar-1")
        let statuses = Dictionary(uniqueKeysWithValues: try store.all().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses["polar-1"], .active)
        XCTAssertEqual(statuses["my-whoop"], .paired)   // the previously-active device was demoted
        XCTAssertEqual(try store.all().filter { $0.status == .active }.count, 1)  // I1
    }

    func testArchiveKeepsRowAndClearsActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.archive("my-whoop")
        XCTAssertEqual(try store.all().first?.status, .archived)   // I4: row kept
        XCTAssertNil(try store.activeDeviceId())
    }

    // #1193: unlike `archive` (which keeps the row so it lingers in "Removed"), `remove` hard-deletes the
    // registry entry so a duplicate/stale strap can be purged entirely — and touches only the given id.
    func testRemoveDeletesOnlyTheGivenRegistryRow() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.add(PairedDevice(id: "whoop-DEAD", brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
                                   capabilities: [.hr], status: .archived, addedAt: 2, lastSeenAt: 2))
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", "whoop-DEAD"])
        try store.remove("whoop-DEAD")
        XCTAssertEqual(try store.all().map(\.id), ["my-whoop"])     // duplicate purged, seed untouched
    }

    func testRemoveIsANoOpForAnAbsentId() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.remove("whoop-never-existed")                    // must not throw
        XCTAssertEqual(try store.all().map(\.id), ["my-whoop"])
    }

    func testSeededWhoopHasNilPeripheralId() throws {
        // v16 applies cleanly: the seeded my-whoop row exists with peripheralId nil (it connects to
        // "any WHOOP" today; it adopts its peripheral id later).
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let seeded = try store.all().first
        XCTAssertEqual(seeded?.id, "my-whoop")
        XCTAssertNil(seeded?.peripheralId)
    }

    func testPeripheralIdRoundTripsThroughAddAndAll() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let pid = "8E1A2B3C-4D5E-6F70-8192-A3B4C5D6E7F8"
        try store.add(PairedDevice(id: "whoop-\(pid)", brand: "WHOOP", model: "WHOOP 5.0",
                                   peripheralId: pid, sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 10, lastSeenAt: 10))
        let fetched = try store.all().first { $0.id == "whoop-\(pid)" }
        XCTAssertEqual(fetched?.peripheralId, pid)
    }

    func testSetPeripheralIdUpdatesIt() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        XCTAssertNil(try store.all().first { $0.id == "my-whoop" }?.peripheralId)
        let pid = "11111111-2222-3333-4444-555555555555"
        try store.setPeripheralId("my-whoop", peripheralId: pid)
        XCTAssertEqual(try store.all().first { $0.id == "my-whoop" }?.peripheralId, pid)
        // passing nil un-adopts it
        try store.setPeripheralId("my-whoop", peripheralId: nil)
        XCTAssertNil(try store.all().first { $0.id == "my-whoop" }?.peripheralId)
    }

    func testDeviceForPeripheralIdFindsIt() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let pid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        XCTAssertNil(try store.device(forPeripheralId: pid))   // none adopted yet
        try store.setPeripheralId("my-whoop", peripheralId: pid)
        XCTAssertEqual(try store.device(forPeripheralId: pid)?.id, "my-whoop")
        XCTAssertNil(try store.device(forPeripheralId: "no-such-peripheral"))
    }

    // ah-delete (#616): deleteAllData(deviceId: "apple-health") clears every row stored under the
    // Apple-Health source across the deviceId-keyed tables, while leaving another device's rows untouched.
    func testDeleteAllDataClearsOnlyTheTargetDevicesRows() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)

        // Seed apple-health + my-whoop rows in two device-scoped tables (appleDaily + metricSeries).
        try dbq.write { db in
            for dev in ["apple-health", "my-whoop"] {
                try db.execute(sql: "INSERT INTO appleDaily (deviceId, day, steps) VALUES (?, ?, ?)",
                               arguments: [dev, "2026-06-15", 1234])
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                               arguments: [dev, "2026-06-15", "steps", 1234.0])
            }
        }

        func count(_ table: String, _ deviceId: String) throws -> Int {
            try dbq.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?",
                                 arguments: [deviceId]) ?? 0
            }
        }

        // Both devices start with a row in each table.
        XCTAssertEqual(try count("appleDaily", "apple-health"), 1)
        XCTAssertEqual(try count("metricSeries", "apple-health"), 1)
        XCTAssertEqual(try count("appleDaily", "my-whoop"), 1)

        try store.deleteAllData(deviceId: "apple-health")

        // The apple-health rows are gone everywhere; my-whoop's rows survive.
        XCTAssertEqual(try count("appleDaily", "apple-health"), 0)
        XCTAssertEqual(try count("metricSeries", "apple-health"), 0)
        XCTAssertEqual(try count("appleDaily", "my-whoop"), 1)
        XCTAssertEqual(try count("metricSeries", "my-whoop"), 1)

        // The registry row itself is never touched by a delete-data op (the seeded my-whoop remains).
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    // Regression guard (audit finding): every table with a `deviceId` column MUST appear in
    // `deviceScopedTables`, or `deleteAllData` silently leaves that device's rows behind — a privacy
    // defect for a delete-means-gone app. Enumerate the live schema and fail if any deviceId-keyed table
    // is uncovered, so a future migration that adds one can't reintroduce the gap.
    func testDeviceScopedTablesCoversEveryDeviceIdKeyedTable() throws {
        let dbq = try makeDB()
        let uncovered = try dbq.read { db -> [String] in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
            var missing: [String] = []
            for table in tables {
                let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                let hasDeviceId = cols.contains { ($0["name"] as String?) == "deviceId" }
                if hasDeviceId && !DeviceRegistryStore.deviceScopedTables.contains(table) {
                    missing.append(table)
                }
            }
            return missing
        }
        XCTAssertTrue(uncovered.isEmpty,
                      "deviceId-keyed tables missing from deviceScopedTables (deleteAllData would skip them): \(uncovered)")
    }

    func testDayOwnershipUpsertAndRead() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.setDayOwner(day: "2026-06-15", deviceId: "my-whoop", locked: true)
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.deviceId, "my-whoop")
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.locked, true)
        XCTAssertNil(try store.dayOwner("2000-01-01"))
        // upsert: re-writing the same day replaces the owner + locked flag (no duplicate row)
        try store.setDayOwner(day: "2026-06-15", deviceId: "polar-1", locked: false)
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.deviceId, "polar-1")
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.locked, false)
    }

    // MARK: #771 — adopt the ring's stable serial id (scoped to the active CB-UUID row only).

    private func addOura(_ store: DeviceRegistryStore, _ id: String, model: String = "Oura Ring 3",
                         peripheralId: String? = nil, status: DeviceStatus, addedAt: Int) throws {
        try store.add(PairedDevice(id: id, brand: "Oura", model: model, peripheralId: peripheralId ?? String(id.dropFirst(5)),
                                   sourceKind: .oura, capabilities: [.hr, .sleep], status: status,
                                   addedAt: addedAt, lastSeenAt: addedAt))
    }
    private func hrCount(_ dbq: DatabaseQueue, _ id: String) throws -> Int {
        try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = ?", arguments: [id]) ?? 0 }
    }

    func testAdoptSerialRenamesWhenSerialIsNew() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let cbuuid = "oura-4DD70E24", serial = "oura-2H3B2405003655"
        try addOura(store, cbuuid, peripheralId: "4DD70E24", status: .paired, addedAt: 100)
        try store.setActive(cbuuid)
        try dbq.write { try $0.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('oura-4DD70E24', 10, 55)") }

        XCTAssertTrue(try store.adoptSerialIdentity(from: cbuuid, to: serial))

        XCTAssertEqual(try hrCount(dbq, serial), 1)          // data moved onto the serial id
        XCTAssertEqual(try hrCount(dbq, cbuuid), 0)
        let ids = Set(try store.all().map(\.id))
        XCTAssertEqual(ids, ["my-whoop", serial])            // provisional CB-UUID row renamed away
        let row = try store.all().first { $0.id == serial }
        XCTAssertEqual(row?.peripheralId, "4DD70E24")        // BLE identity carried over → reconnect works
        XCTAssertEqual(row?.model, "Oura Ring 3")
    }

    func testAdoptSerialMergesWhenSerialAlreadyExists() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let serial = "oura-2H3B2405003655", cbuuid2 = "oura-0102A826"
        try addOura(store, serial, peripheralId: "OLDPID", status: .paired, addedAt: 100)   // prior pairing
        try addOura(store, cbuuid2, peripheralId: "0102A826", status: .paired, addedAt: 200)
        try store.setActive(cbuuid2)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('oura-2H3B2405003655', 10, 50)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('oura-0102A826', 20, 60)")
        }
        try store.adoptSerialIdentity(from: cbuuid2, to: serial)

        XCTAssertEqual(try hrCount(dbq, serial), 2)          // both beats now under the serial id
        XCTAssertEqual(try hrCount(dbq, cbuuid2), 0)
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", serial])
        let row = try store.all().first { $0.id == serial }
        XCTAssertEqual(row?.peripheralId, "0102A826")        // fresh pairing's BLE identity carried onto serial
    }

    func testAdoptSerialLeavesOtherOuraPairingsUntouched() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let other = "oura-99B6BA9D", cbuuid = "oura-D6235E4F", serial = "oura-2H3B2405003655"
        try addOura(store, other, status: .archived, addedAt: 50)     // a past pairing, NOT to be touched
        try addOura(store, cbuuid, peripheralId: "D6235E4F", status: .paired, addedAt: 300)
        try store.setActive(cbuuid)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('oura-99B6BA9D', 1, 44)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('oura-D6235E4F', 2, 70)")
        }
        try store.adoptSerialIdentity(from: cbuuid, to: serial)

        // The other pairing's row + data survive verbatim; only the active CB-UUID was folded into the serial.
        XCTAssertEqual(try hrCount(dbq, other), 1)
        XCTAssertNotNil(try store.all().first { $0.id == other })
        XCTAssertEqual(try hrCount(dbq, serial), 1)
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", other, serial])
    }

    func testAdoptSerialNoOpWhenSameOrAbsent() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        XCTAssertFalse(try store.adoptSerialIdentity(from: "oura-X", to: "oura-X"))       // same id
        XCTAssertFalse(try store.adoptSerialIdentity(from: "oura-absent", to: "oura-Y"))  // no active row
    }
}
