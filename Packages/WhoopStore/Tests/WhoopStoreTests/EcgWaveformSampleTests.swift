import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v48 migration: durable storage for the flash-banked MG ECG record (#2847).
///
/// #2839 landed the decoder for this record and it had nowhere to go: layout 16 stayed out of
/// `mappedWhoop5HistoricalVersions`, so every record went down the unmapped route into
/// `RawHistoryArchive`, a 5 MiB ring whose per-version floor protects 64 lines, which for a record of one
/// strap-second is 64 seconds of waveform. This proves the table exists, its key and shape, that a record
/// round-trips byte-for-byte, and that the cap keeps the NEWEST readings.
///
/// NOT covered here, deliberately: that "delete all of this device's data" clears these rows. That is
/// pinned by `DeviceRegistryStoreTests`, whose guard asserts EVERY deviceId-keyed table in the schema
/// appears in `deviceScopedTables` rather than naming them one at a time, and a per-table copy of it
/// would be the weaker test of the two.
///
/// Kotlin twin: `EcgWaveformMigrationTest`, which pins the migration SQL and the repository plumbing.
final class EcgWaveformSampleTests: XCTestCase {

    /// A record-shaped payload with a recognisable interior, so a truncation or an off-by-one in the blob
    /// path is visible rather than hidden in a run of zeros. Not a decodable R16: these tests are about
    /// the STORE, and `Whoop5EcgHistoricalStorageTests` covers the decode.
    private func record(seed: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Whoop5Ecg.r16InnerLength)
        for i in 0..<out.count { out[i] = UInt8((Int(seed) + i) & 0xff) }
        return out
    }

    private func sample(_ ts: Int, sequence: Int = 1, seed: UInt8 = 7) -> Streams {
        Streams(ecgWaveform: [EcgWaveformSample(ts: ts, sequence: sequence, record: record(seed: seed))])
    }

    /// Reads the table straight off the store's own writer, rather than through a reader method on
    /// `StreamStore`.
    ///
    /// There is deliberately no such method yet. Nothing in production would call one, and the parity
    /// ledger's call-graph rule records an in-scope declaration reached only from tests as new debt that
    /// its disposition schema has no kind for, so the honest options were a reader nobody calls or none
    /// at all. Android's reader exists because a Room `@Query` method is dispositionable as one; Apple's
    /// lands with its first real caller, and until then this is how the rows are reached.
    private func rows(_ store: WhoopStore, deviceId: String,
                      from: Int = 0, to: Int = 2_000_000_000) async throws -> [EcgWaveformSample] {
        try await store.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, sequence, record FROM ecgWaveformSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts
                """, arguments: [deviceId, from, to])
                .map { row in
                    let blob: Data = row["record"]
                    return EcgWaveformSample(ts: row["ts"], sequence: row["sequence"],
                                             record: [UInt8](blob))
                }
        }
    }

    // MARK: - shape

    func testV48CreatesEcgWaveformTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ecgWaveformSample"))
    }

    /// THREE columns, where every per-second stream beside this one keys on two. See the next test for
    /// what the two-column version lost.
    func testEcgWaveformPrimaryKeyCarriesTheSequence() async throws {
        let store = try await WhoopStore.inMemory()
        let pk = try await store.primaryKeyColumns("ecgWaveformSample")
        XCTAssertEqual(pk, ["deviceId", "ts", "sequence"])
    }

    func testEcgWaveformTableShape() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "ecgWaveformSample")
        XCTAssertEqual(Set(cols), ["deviceId", "ts", "sequence", "record"])
    }

    // MARK: - the round trip

    /// The bytes that go in are the bytes that come out. The whole storage shape rests on this: the row
    /// holds the wire record, so `Whoop5Ecg.parseR16` can read it later and nothing was decided at ingest.
    func testAnEcgRecordRoundTripsByteForByte() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(sample(1_760_000_000, sequence: 74_565), deviceId: "dev1")
        let rows = try await rows(store, deviceId: "dev1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.ts, 1_760_000_000)
        XCTAssertEqual(rows.first?.sequence, 74_565)
        XCTAssertEqual(rows.first?.record, record(seed: 7))
        XCTAssertEqual(rows.first?.record.count, Whoop5Ecg.r16InnerLength)
    }

    /// TWO RECORDS IN ONE STRAP-SECOND BOTH SURVIVE, which is why `sequence` is in the key.
    ///
    /// Found by re-reading this change rather than by a failure: R16 carries a `subseconds` field at all,
    /// and the opening records of a real run declare 0 samples and then 245 before the first full 500, so
    /// the start of a reading can stamp two records inside one second. On a (deviceId, ts) key the second
    /// of them hit ON CONFLICT DO NOTHING and was dropped with no error anywhere, which is the first
    /// record of a reading lost on every reading whose opening pair shares a second.
    func testTwoRecordsStampedInOneSecondAreBothKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(sample(100, sequence: 10, seed: 7), deviceId: "dev1")
        _ = try await store.insert(sample(100, sequence: 11, seed: 99), deviceId: "dev1")
        let kept = try await rows(store, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(kept.count, 2, "a second record in the same strap-second must not be dropped")
        XCTAssertEqual(kept.map(\.sequence).sorted(), [10, 11])
    }

    /// Re-offloading the SAME record keeps the first copy: the dedupe rule every per-second stream uses,
    /// read through the wider key. Both halves of the key repeat on a re-sync, so this still holds.
    func testReofferingTheSameRecordKeepsTheFirstCopy() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(sample(100, sequence: 1, seed: 7), deviceId: "dev1")
        _ = try await store.insert(sample(100, sequence: 1, seed: 99), deviceId: "dev1")
        let kept = try await rows(store, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.record, record(seed: 7), "the first-seen copy wins, not the last")
    }

    /// A record of the wrong length is SKIPPED rather than banked short. `parseR16` refuses any other
    /// length, so a short blob would read back as undecodable for the rest of that row's life, and the
    /// table's one structural invariant is worth more than a partial row.
    func testARecordOfTheWrongLengthIsNotBanked() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let short = Streams(ecgWaveform: [EcgWaveformSample(ts: 100, sequence: 1, record: [1, 2, 3])])
        _ = try await store.insert(short, deviceId: "dev1")
        let banked = try await rows(store, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(banked.count, 0)
    }

    /// Rows are per device, like every other stream: two straps' readings do not merge.
    func testRowsAreKeyedPerDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.upsertDevice(id: "dev2", mac: nil, name: nil)
        _ = try await store.insert(sample(100, seed: 7), deviceId: "dev1")
        _ = try await store.insert(sample(100, seed: 99), deviceId: "dev2")
        let d1 = try await rows(store, deviceId: "dev1", to: 1_000)
        let d2 = try await rows(store, deviceId: "dev2", to: 1_000)
        XCTAssertEqual(d1.count, 1)
        XCTAssertEqual(d2.count, 1)
        XCTAssertEqual(d1.first?.record, record(seed: 7))
        XCTAssertEqual(d2.first?.record, record(seed: 99))
    }

    // MARK: - retention

    private func retentionStore() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        return s
    }

    private func insertCapped(_ s: WhoopStore, _ ts: Int, keep: Int, every: Int,
                              device: String = "dev1") async throws {
        _ = try await s.insert(sample(ts), deviceId: device,
                               v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                               v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                               ecgWaveformRetentionRows: keep, ecgWaveformPruneEveryRows: every)
    }

    /// The cap keeps the NEWEST rows, and for this table that is also what makes it behave like a cap
    /// counted in READINGS: the sweep cuts from the oldest end, so the only reading it can ever leave as
    /// a fragment is the oldest one still in the window, and every newer reading stays whole.
    func testRetentionKeepsTheNewestRows() async throws {
        let s = try await retentionStore()
        for ts in 100...105 { try await insertCapped(s, ts, keep: 2, every: 1) }
        let rows = try await rows(s, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [104, 105], "newest-N, not oldest-N and not everything")
    }

    /// Under the sweep threshold nothing is evicted: the overshoot is deliberate amortisation, because the
    /// delete walks up to `ecgWaveformRetentionRows` index entries.
    func testRetentionDoesNotSweepUnderTheThreshold() async throws {
        let s = try await retentionStore()
        for ts in 100...104 { try await insertCapped(s, ts, keep: 2, every: 50) }
        let kept = try await rows(s, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(kept.count, 5, "under the threshold the sweep must not run")
    }

    /// The counter resets after each sweep, so a long reading sweeps repeatedly rather than latching once.
    func testRetentionCounterResetsAfterEachSweep() async throws {
        let s = try await retentionStore()
        for ts in 100...111 { try await insertCapped(s, ts, keep: 2, every: 4) }
        let rows = try await rows(s, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [110, 111],
                       "a second sweep must happen; the counter cannot latch after the first")
    }

    /// The budget is per device, because the delete is: one strap must not spend another's.
    func testRetentionBudgetIsNotSharedBetweenDevices() async throws {
        let s = try await retentionStore()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        for ts in 100...102 { try await insertCapped(s, ts, keep: 2, every: 4) }
        for ts in 100...102 { try await insertCapped(s, ts, keep: 2, every: 4, device: "dev2") }
        let a = try await rows(s, deviceId: "dev1", to: 1_000)
        let b = try await rows(s, deviceId: "dev2", to: 1_000)
        XCTAssertEqual(a.count + b.count, 6, "neither device reached its own budget, so neither swept")
    }

    /// The sweep never reaches across devices: dev2's rows are not what dev1's budget evicts.
    func testASweepOnlyEvictsItsOwnDevicesRows() async throws {
        let s = try await retentionStore()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        for ts in 100...102 { try await insertCapped(s, ts, keep: 1, every: 1, device: "dev2") }
        for ts in 100...105 { try await insertCapped(s, ts, keep: 2, every: 1) }
        let dev2 = try await rows(s, deviceId: "dev2", to: 1_000)
        let dev1 = try await rows(s, deviceId: "dev1", to: 1_000)
        XCTAssertEqual(dev2.map(\.ts), [102])
        XCTAssertEqual(dev1.map(\.ts), [104, 105])
    }
}
