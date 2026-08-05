import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    /// v24 widens the R-R key with a `seq` tiebreaker so two EQUAL successive intervals in the same
    /// second both survive (the old value-only key dropped the 2nd, biasing RMSSD/HRV high). #163.
    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV24AddsSeqColumnToRrInterval() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("seq"), "rrInterval missing v24 seq column")
    }

    func testV24KeepsEqualSameSecondBeats() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Two EQUAL R-R intervals in the same second: the old value-only key dropped the 2nd; v24 keeps both.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 812), RRInterval(ts: 100, rrMs: 812)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 2)
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.count, 2)
        XCTAssertTrue(read.allSatisfy { $0.ts == 100 && $0.rrMs == 812 })
    }

    func testV24DistinctBeatsAllKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Distinct (ts, rrMs) beats — incl. two values in the same second — each keep seq 0 and their slot.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 602), RRInterval(ts: 100, rrMs: 613),
                         RRInterval(ts: 101, rrMs: 602)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 3)
    }

    // MARK: - v30 R-R emission order (#823)

    /// `ord` must exist and must stay OUT of the primary key. An insertion counter in the key would
    /// collide distinct beats arriving in separate batches — the data-loss regression v24's note warns
    /// about, and the reason the obvious `ORDER BY ts, seq` fix was rejected.
    func testV30AddsOrdColumnAndKeepsItOutOfThePrimaryKey() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("ord"), "rrInterval missing v30 ord column")
        let pk = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(pk, ["deviceId", "ts", "rrMs", "seq"], "ord must not enter the key")
    }

    /// The bug itself: a second's beats came back sorted by VALUE. Sorting makes successive beats
    /// similar by construction, and RMSSD is built entirely from successive differences.
    func testV30ReadsSameSecondBeatsInEmissionOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let emission = [812, 795, 840, 801, 833]
        let n = try await store.insert(
            Streams(rr: emission.map { RRInterval(ts: 100, rrMs: $0) }), deviceId: "dev1")
        XCTAssertEqual(n.rr, emission.count, "every distinct beat must still be stored")

        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), emission,
                       "beats must read back in emission order, not magnitude order")
        let ords = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 100)
        XCTAssertEqual(ords, [0, 1, 2, 3, 4])

        // The measurable consequence, on the issue's own example: magnitude order reads 12.72 ms,
        // emission order 34.85 ms. A one-directional −22 ms bias in a headline metric.
        func rmssd(_ v: [Int]) -> Double {
            let d = zip(v, v.dropFirst()).map { pow(Double($1 - $0), 2) }
            return (d.reduce(0, +) / Double(d.count)).squareRoot()
        }
        XCTAssertEqual(rmssd(read.map(\.rrMs)), rmssd(emission), accuracy: 1e-9)
        XCTAssertEqual(rmssd(read.map(\.rrMs)), 34.85, accuracy: 0.01)
        XCTAssertGreaterThan(rmssd(read.map(\.rrMs)), rmssd(emission.sorted()) + 20.0,
                             "sorted order should be the badly-biased one this fix avoids")
    }

    /// `ord` is BATCH-LOCAL — a beat's position among the beats sharing its second *in this insert* —
    /// which is what let #1072 happen: a transport that inserts one beat at a time restarts the counter
    /// on every row, so every beat is written `ord = 0` and the v30 fix silently does nothing. With
    /// `ord` tied the read falls back to `(rrMs, seq)`, i.e. magnitude order, which is exactly the #823
    /// symptom. This pins both shapes side by side so the store-side contract the Oura call sites now
    /// satisfy (one record's beats = one insert) cannot regress unnoticed.
    func testV30OrdIsBatchLocalSoOneInsertPerBeatRecordsNoOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let emission = [812, 795, 840, 801, 833]
        for v in emission {   // the pre-#1072 Oura shape: one insert per beat
            _ = try await store.insert(Streams(rr: [RRInterval(ts: 400, rrMs: v)]), deviceId: "dev1")
        }
        let ords = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 400)
        XCTAssertEqual(ords, [0, 0, 0, 0, 0], "a one-beat insert can only ever compute ord 0")
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), emission.sorted(),
                       "tied ord falls through to (rrMs, seq) — the magnitude order #823 reports")

        // The same beats delivered as ONE insert keep their emission order, `ord` counting 0,1,2,…
        _ = try await store.insert(
            Streams(rr: emission.map { RRInterval(ts: 500, rrMs: $0) }), deviceId: "dev1")
        let batchedOrds = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 500)
        XCTAssertEqual(batchedOrds, [0, 1, 2, 3, 4])
    }

    /// The second consequence of insert-per-beat, and the reason a post-fix night holds slightly MORE
    /// rows than a pre-fix one: `seq` (v24) exists so two beats with the same interval in the same
    /// second survive as distinct rows, and it is batch-local for the same reason `ord` is. One insert
    /// per beat recomputed `seq = 0` for the second beat, so it collided on the primary key and was
    /// silently dropped by `ON CONFLICT DO NOTHING`. Batched, both are stored — real beats recovered,
    /// not duplicates invented.
    func testEqualIntervalsInOneRecordSurviveOnlyWhenTheRecordIsOneInsert() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        for _ in 0..<2 {   // the pre-#1072 shape
            _ = try await store.insert(Streams(rr: [RRInterval(ts: 600, rrMs: 812)]), deviceId: "dev1")
        }
        let dropped = try await store.rrIntervals(deviceId: "dev1", from: 590, to: 610, limit: 100)
        XCTAssertEqual(dropped.count, 1, "insert-per-beat silently loses the second identical beat")

        _ = try await store.insert(
            Streams(rr: [RRInterval(ts: 700, rrMs: 812), RRInterval(ts: 700, rrMs: 812)]),
            deviceId: "dev1")
        let kept = try await store.rrIntervals(deviceId: "dev1", from: 690, to: 710, limit: 100)
        XCTAssertEqual(kept.count, 2, "batched, seq 0/1 keeps both beats")
    }

    /// Rows written before v30 have `ord` NULL — the order was never recorded, so it cannot be
    /// backfilled. SQLite sorts NULL first in ASC, so an all-legacy second ties on `ord` and falls
    /// through to the old (rrMs, seq) order: existing data reads back exactly as it did before.
    func testV30LegacyNullOrdRowsKeepTheOldDeterministicOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        for v in [812, 795, 840, 801, 833] {
            try await store.insertLegacyRrWithoutOrdForTest(deviceId: "dev1", ts: 200, rrMs: v)
        }
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), [795, 801, 812, 833, 840],
                       "pre-v30 rows must keep the old (rrMs, seq) order, unchanged and deterministic")
        let ords = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 200)
        XCTAssertEqual(ords, [nil, nil, nil, nil, nil])
    }

    /// A second holding both legacy and post-v30 rows (possible via import/merge) must still be
    /// deterministic. NULL-first is arbitrary but fixed, which is the property that matters:
    /// the same data must never read back two different ways.
    func testV30MixedLegacyAndOrderedRowsAreDeterministic() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 300, rrMs: 700)]), deviceId: "dev1")
        try await store.insertLegacyRrWithoutOrdForTest(deviceId: "dev1", ts: 300, rrMs: 650)
        let first = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        let again = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(first.map(\.rrMs), [650, 700], "NULL ord sorts first")
        XCTAssertEqual(first.map(\.rrMs), again.map(\.rrMs), "repeated reads must not differ")
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 18)
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    /// v26 heals `efficiency` values stored on the 0-100 percent scale (written by the pre-fix Oura API
    /// importer AND the pre-fix WHOOP CSV importer, under any deviceId) back to NOOP's 0-1 fraction
    /// convention. UPDATE-only: seed rows at the v25 schema (i.e. BEFORE v26 has run), then apply the
    /// rest of the migrator and confirm the heal.
    func testV26HealsEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v25-oura-raw")
        try await dbQueue.write { db in
            // oura-api, bad (percent) → must be healed to a fraction.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 100, 200, 90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-01', 90)
                """)
            // oura-api, already a fraction → must be left unchanged (idempotent predicate: efficiency > 1.5).
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 300, 400, 0.9)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-02', 0.9)
                """)
            // A WHOOP-CSV-imported percent row (arbitrary strap deviceId) must ALSO be healed — the
            // pre-fix WhoopImporter wrote "Sleep efficiency %" straight through, same bug class.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 500, 600, 90)
                """)
            // A native fraction row under a strap deviceId must be left unchanged.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 700, 800, 0.66)
                """)
        }

        // Apply the FULL migrator: GRDB resumes from the already-applied v25, so only v26 runs here.
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 500"), 0.9,
                           "a CSV-imported percent row must be healed regardless of deviceId")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 700"), 0.66,
                           "a native fraction row must never be touched")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"), 0.9)
        }
    }
}
