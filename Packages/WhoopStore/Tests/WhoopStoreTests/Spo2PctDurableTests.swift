import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v34: the durable `@82` SpO2 percentage stream.
///
/// The 5/MG emits its own computed SpO2 % on `@82` of the v18 record. That byte has been banked since v31
/// — inside `v18AuxSample.fields`, a table CAPPED at 604,800 rows/device (~7 days at 1 Hz) because the aux
/// blob costs ~30 MB/day. So every reading rolled off after a week and was gone permanently: the strap
/// trims its own history the moment an offload is acked, leaving no second copy anywhere.
///
/// `spo2PctSample` is the narrow, never-pruned sibling that fixes that. ~2,000 samples/week — ~100k
/// rows/year — is nothing to keep forever. These tests pin the two properties the fix rests on: the right
/// values get in (and only those), and the aux sweep cannot touch them.
final class Spo2PctDurableTests: XCTestCase {

    private func store() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        return s
    }

    /// One v18 aux sample carrying `@82` = `v` at `ts`, and nothing else.
    private func aux(_ ts: Int, _ v: Int?) -> V18AuxSample { V18AuxSample(ts: ts, auxByte82: v) }

    // MARK: - Migration shape

    func testV34CreatesTheDurableTable() async throws {
        let s = try await store()
        let tables = try await s.tableNames()
        XCTAssertTrue(tables.contains("spo2PctSample"))
        let pk = try await s.primaryKeyColumns("spo2PctSample")
        let cols = try await s.columnNamesForTest(table: "spo2PctSample")
        XCTAssertEqual(pk, ["deviceId", "ts"])
        XCTAssertEqual(Set(cols), ["deviceId", "ts", "pct"])
    }

    /// The v3 `spo2Sample` table is NOT the home for this and must be left exactly as it was: its
    /// `red`/`ir` are NOT NULL raw ADC channels off the WHOOP 4.0 v24 layout, and
    /// `AnalyticsEngine.nightlySpo2RawMeans` averages them into a live tile. Storing percentages there
    /// would have meant fabricating red/ir zeros on every insert and dragging that mean toward zero.
    func testTheWhoop4RawTableIsUntouched() async throws {
        let s = try await store()
        let cols = try await s.columnNamesForTest(table: "spo2Sample")
        // Its own columns, unchanged (`synced` is the outbox flag a later migration added).
        XCTAssertEqual(Set(cols), ["deviceId", "ts", "red", "ir", "synced"])
        // And emphatically no percentage column: the two quantities never share a table.
        XCTAssertFalse(cols.contains("pct"))
    }

    // MARK: - In-band values persist

    func testInBandValuesPersistVerbatim() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [aux(100, 97), aux(101, 94), aux(102, 88)]),
                               deviceId: "dev1")
        let rows = try await s.spo2PctSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [100, 101, 102])
        XCTAssertEqual(rows.map(\.pct), [97, 94, 88])
    }

    /// The band is INCLUSIVE at both ends — 70 and 100 are real readings, and a gate that quietly dropped
    /// the endpoints would bias every night's median upward at exactly the readings that matter most.
    func testBandBoundariesAreInclusive() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [aux(200, 70), aux(201, 100)]), deviceId: "dev1")
        let rows = try await s.spo2PctSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.pct), [70, 100])
    }

    // MARK: - Out-of-band values are rejected

    /// `@82` is MULTIPLEXED: the same byte carries measurements, bit-7 status sentinels, sub-70 diagnostic
    /// codes, and 0 for "not emitted". Only `70...100` is a percentage of anything. A sentinel banked as a
    /// percentage would not merely be wrong, it would be *plausible* — 0x88 is 136, which no reader would
    /// flag, and 0x08 is 8, which reads as catastrophic hypoxia. Rejection has to happen at the boundary.
    func testStatusSentinelsAndDiagnosticCodesAreRejected() async throws {
        let s = try await store()
        let rejected = [0x00, 0x08, 0x45, 0x80, 0x88, 0x90, 0xA0, 0xA8, 0xFF]
        let samples = rejected.enumerated().map { aux(300 + $0.offset, $0.element) }
        _ = try await s.insert(Streams(v18Aux: samples), deviceId: "dev1")
        let banked = try await s.spo2PctCountForTest()
        let auxRows = try await s.v18AuxCountForTest()
        XCTAssertEqual(banked, 0, "no sentinel or diagnostic code may be banked as a percentage")
        // The raw bytes are still captured in the aux table — this gate demultiplexes, it does not discard.
        XCTAssertEqual(auxRows, rejected.count)
    }

    /// `101...127` is the EMPTY BAND — nothing has ever been observed there across 626,725 production
    /// records. It is what makes measurements and bit-7 sentinels separable by value alone, with no side
    /// channel. A value appearing there would mean the demultiplex assumption has broken, so it must not
    /// be admitted on the strength of merely being "close to 100".
    func testTheEmptyBandAbove100IsRejected() async throws {
        let s = try await store()
        let samples = (101...127).enumerated().map { aux(400 + $0.offset, $0.element) }
        _ = try await s.insert(Streams(v18Aux: samples), deviceId: "dev1")
        let banked = try await s.spo2PctCountForTest()
        XCTAssertEqual(banked, 0)
    }

    /// An aux record with no `@82` slot at all banks no percentage — absence stays absence.
    func testAbsentSlotBanksNothing() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 500, statusWord: 7)]), deviceId: "dev1")
        let banked = try await s.spo2PctCountForTest()
        let auxRows = try await s.v18AuxCountForTest()
        XCTAssertEqual(banked, 0)
        XCTAssertEqual(auxRows, 1)
    }

    // MARK: - Idempotence

    /// A re-offload of a window already banked must not duplicate or mutate it. ON CONFLICT DO NOTHING
    /// keeps the FIRST value for a second, matching every other per-second stream's dedupe rule.
    func testReInsertIsIdempotentAndKeepsTheFirstValue() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [aux(600, 96), aux(601, 95)]), deviceId: "dev1")
        _ = try await s.insert(Streams(v18Aux: [aux(600, 96), aux(601, 95)]), deviceId: "dev1")
        // Same seconds, different values — the first-seen reading survives.
        _ = try await s.insert(Streams(v18Aux: [aux(600, 71), aux(601, 99)]), deviceId: "dev1")
        let rows = try await s.spo2PctSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [600, 601])
        XCTAssertEqual(rows.map(\.pct), [96, 95])
    }

    /// Two straps' readings for the same second are different rows — the PK is (deviceId, ts).
    func testPerDeviceScoping() async throws {
        let s = try await store()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        _ = try await s.insert(Streams(v18Aux: [aux(700, 97)]), deviceId: "dev1")
        _ = try await s.insert(Streams(v18Aux: [aux(700, 92)]), deviceId: "dev2")
        let d1 = try await s.spo2PctSamples(deviceId: "dev1", from: 0, to: 1_000)
        let d2 = try await s.spo2PctSamples(deviceId: "dev2", from: 0, to: 1_000)
        XCTAssertEqual(d1.map(\.pct), [97])
        XCTAssertEqual(d2.map(\.pct), [92])
    }

    // MARK: - Retention: the whole point of the table

    /// THE LOAD-BEARING TEST. The aux sweep must not reach this table. Retention is forced to 1 row and
    /// the prune to every row, so the aux capture is cut to its newest row — while every percentage
    /// survives. This is the entire reason v34 exists: before it, seven-day-old SpO2 was destroyed with
    /// no recoverable copy.
    func testSpo2SurvivesTheAuxPrune() async throws {
        let s = try await store()
        let samples = (0..<40).map { aux(1_000 + $0, 90 + ($0 % 8)) }
        _ = try await s.insert(Streams(v18Aux: samples), deviceId: "dev1",
                               v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 1)

        // The aux table was swept down to its cap...
        let auxRows = try await s.v18AuxCountForTest()
        XCTAssertEqual(auxRows, 1)
        // ...and not one percentage was lost.
        let rows = try await s.spo2PctSamples(deviceId: "dev1", from: 0, to: 10_000)
        XCTAssertEqual(rows.count, 40)
        XCTAssertEqual(rows.map(\.ts), Array(1_000..<1_040))
        XCTAssertEqual(rows.map(\.pct), (0..<40).map { 90 + ($0 % 8) })
    }

    /// Repeated sweeps across many batches never erode the durable rows.
    func testRepeatedPrunesNeverErodeTheDurableRows() async throws {
        let s = try await store()
        for batch in 0..<5 {
            let samples = (0..<10).map { aux(2_000 + batch * 10 + $0, 95) }
            _ = try await s.insert(Streams(v18Aux: samples), deviceId: "dev1",
                                   v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1)
        }
        let banked = try await s.spo2PctCountForTest()
        let auxRows = try await s.v18AuxCountForTest()
        XCTAssertEqual(banked, 50)
        XCTAssertLessThanOrEqual(auxRows, 12)
    }

    // MARK: - Privacy

    /// A never-pruned table makes delete-means-gone MORE important, not less: without this the wipe would
    /// leave years of blood-oxygen readings behind after the user asked for them to be erased.
    func testDeleteAllDataClearsTheDurableRows() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [aux(3_000, 96)]), deviceId: "dev1")
        let before = try await s.spo2PctCountForTest()
        XCTAssertEqual(before, 1)
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("spo2PctSample"))
        try await s.deleteAllData(deviceId: "dev1")
        let after = try await s.spo2PctCountForTest()
        XCTAssertEqual(after, 0)
    }
}

/// The blob-offset question, pinned.
///
/// The cloud reader takes `fields[23]` of the STORED `v18AuxSample.fields` blob and gets physiologically
/// valid SpO2 out of it. That works — but it is an ARITHMETIC COINCIDENCE of a fully-populated record, not
/// a property of the format. `V18AuxCodec` is a presence-bitmap codec: absent slots are omitted from the
/// body entirely, so every slot's byte offset depends on which slots ahead of it were present.
///
/// These tests establish both halves, because only the pair is decisive. The first alone would license
/// the fragile read; the second is what says the device write path must not use it.
final class V18AuxCodecOffsetTests: XCTestCase {

    /// A record carrying every slot: `auxByte82` lands at blob byte 23. Header is 5 bytes (version +
    /// u32 bitmap), then the eleven slots ahead of it occupy 4+1+1+1+1+2+1+1+2+2+2 = 18 bytes, so it sits
    /// at 5 + 18 = 23 and the whole blob is 32 bytes. THIS is why the cloud's `fields[23]` reads real
    /// percentages: in production every one of those slots is present.
    func testFullyPopulatedRecordPutsAuxByte82AtBlobByte23() {
        let full = V18AuxSample(
            ts: 1, recordIndex: 0x11223344, rrCount: 4, cardiacFlags: 0x21, hrQualityFlags: 0x82,
            heartRateAlt: 58, rrPacked: 0x0505, cardiacStatus: 0x31, stepCadence: 0x41,
            statusWord: 0x0606, statusWord1: 0x0707, statusWord2: 0x0808, auxByte82: 93,
            opticalBaselineA: 0x51, opticalBaselineB: 0x52, opticalAmpA: 0x53, opticalAmpB: 0x54,
            unknownF32Bits: 0x55667788)
        let blob = [UInt8](V18AuxCodec.pack(full))

        XCTAssertEqual(blob.count, 32, "5-byte header + 27 body bytes")
        XCTAssertEqual(Int(blob[23]), 93, "byte 23 of a fully-populated blob IS @82")
        // And it agrees with the decoded struct, which is the only contract that actually holds.
        XCTAssertEqual(V18AuxCodec.unpack(Data(blob), ts: 1).auxByte82, 93)
        // Derive the offset from the slot table rather than trusting the literal, so a future slot
        // inserted ahead of @82 fails HERE with a readable number instead of silently moving the cloud's
        // read onto a neighbouring byte.
        let ahead = V18AuxSlot.allCases
            .filter { $0.rawValue < V18AuxSlot.auxByte82.rawValue }
            .reduce(0) { $0 + $1.width }
        XCTAssertEqual(V18AuxCodec.headerBytes + ahead, 23)
    }

    /// ONE absent slot ahead of it and byte 23 is a different field entirely — while the decoded value is
    /// still correct. The blob read does not degrade loudly; it returns a neighbouring byte that can look
    /// exactly like a plausible saturation. This is why `StreamStore` reads `s.auxByte82` off the decoded
    /// struct and never indexes the blob.
    func testOneAbsentEarlierSlotMovesAuxByte82OffByte23() {
        // Identical to the record above except `recordIndex` (4 bytes, slot 0) is absent.
        let partial = V18AuxSample(
            ts: 1, rrCount: 4, cardiacFlags: 0x21, hrQualityFlags: 0x82,
            heartRateAlt: 58, rrPacked: 0x0505, cardiacStatus: 0x31, stepCadence: 0x41,
            statusWord: 0x0606, statusWord1: 0x0707, statusWord2: 0x0808, auxByte82: 93,
            opticalBaselineA: 0x51, opticalBaselineB: 0x52, opticalAmpA: 0x53, opticalAmpB: 0x54,
            unknownF32Bits: 0x55667788)
        let blob = [UInt8](V18AuxCodec.pack(partial))

        XCTAssertEqual(blob.count, 28, "four fewer body bytes without recordIndex")
        // @82 has slid four bytes earlier...
        XCTAssertEqual(Int(blob[19]), 93)
        // ...and byte 23 now holds opticalAmpB, four slots further along. Reading it as a percentage
        // would yield 0x54 = 84: in band, unremarkable, and completely fabricated. Note it does NOT
        // fail loudly — an optical amplitude byte and a saturation percentage occupy the same numeric
        // range, so the bad read is indistinguishable from a good one at the call site.
        XCTAssertEqual(Int(blob[23]), 0x54)
        XCTAssertNotEqual(Int(blob[23]), 93)
        XCTAssertTrue(spo2CandidateInBand.contains(Int(blob[23])),
                      "the wrong byte is still 'in band' — which is exactly why this read is unsafe")
        // The decoded read is unaffected — it is driven by the bitmap, not by an offset.
        XCTAssertEqual(V18AuxCodec.unpack(Data(blob), ts: 1).auxByte82, 93)
    }
}
