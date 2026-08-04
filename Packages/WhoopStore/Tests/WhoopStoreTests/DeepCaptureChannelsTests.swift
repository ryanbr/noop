import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v31: the four named channels ride existing per-second rows; the remaining fifteen v18 slots go to
/// `v18AuxSample` as a compact blob. All additive, all nullable, and nothing reads them.
final class DeepCaptureChannelsTests: XCTestCase {

    private func store() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        return s
    }

    // MARK: - Migration shape

    func testV31AddsTheAdditiveColumnsAndTheAuxTable() async throws {
        let s = try await store()
        let grav = try await s.columnNamesForTest(table: "gravitySample")
        let band = try await s.columnNamesForTest(table: "sleepStateSample")
        let skin = try await s.columnNamesForTest(table: "skinTempSample")
        let tables = try await s.tableNames()
        let auxPK = try await s.primaryKeyColumns("v18AuxSample")
        XCTAssertTrue(grav.contains("dynAccel"))
        XCTAssertTrue(band.contains("rawByte"))
        XCTAssertTrue(skin.contains("aux1Raw"))
        XCTAssertTrue(skin.contains("aux2Raw"))
        XCTAssertTrue(tables.contains("v18AuxSample"))
        XCTAssertEqual(auxPK, ["deviceId", "ts"])
        // The pre-existing columns must survive untouched — this is an ALTER, not a rebuild.
        XCTAssertTrue(["deviceId", "ts", "x", "y", "z"].allSatisfy(grav.contains))
        XCTAssertTrue(["deviceId", "ts", "state"].allSatisfy(band.contains))
    }

    /// The added columns must be NULLABLE with no DEFAULT: an absent channel has to stay absent (a WHOOP
    /// 4.0 never reports one, and history banked before v31 cannot be backfilled — the strap already
    /// trimmed it), so a fabricated 0 would be indistinguishable from a real reading of zero.
    func testTheNewColumnsAreNullableWithNoDefault() async throws {
        let s = try await store()
        for (table, column) in [("gravitySample", "dynAccel"), ("sleepStateSample", "rawByte"),
                                ("skinTempSample", "aux1Raw"), ("skinTempSample", "aux2Raw")] {
            let ok = try await s.columnIsNullableWithoutDefaultForTest(table: table, column: column)
            XCTAssertEqual(ok, true, "\(table).\(column) must be nullable with no DEFAULT")
        }
    }

    /// A row written before v31 (or by a WHOOP 4.0) reads back with every new field nil — never 0.
    func testPreV31StyleRowsReadBackAbsentNotZero() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(
            skinTemp: [SkinTempSample(ts: 100, raw: 3057)],
            gravity: [GravitySample(ts: 100, x: 0, y: 0, z: 1)],
            sleepState: [SleepStateSample(ts: 100, state: 2)]), deviceId: "dev1")

        let grav = try await s.gravitySamples(deviceId: "dev1", from: 0, to: 200, limit: 10).first
        let skin = try await s.skinTempSamples(deviceId: "dev1", from: 0, to: 200, limit: 10).first
        let band = try await s.sleepStateSamples(deviceId: "dev1", from: 0, to: 200).first
        let auxRows = try await s.v18AuxCountForTest()
        XCTAssertNil(grav?.dynAccel)
        XCTAssertNil(skin?.aux1Raw)
        XCTAssertNil(skin?.aux2Raw)
        XCTAssertNil(band?.rawByte)
        XCTAssertEqual(auxRows, 0)
    }

    // MARK: - Round trip

    func testTheFourNamedChannelsRoundTrip() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(
            skinTemp: [SkinTempSample(ts: 100, raw: 3057, aux1Raw: 247, aux2Raw: 265)],
            gravity: [GravitySample(ts: 100, x: 0.1, y: 0.2, z: 0.97, dynAccel: 0.0091596)],
            sleepState: [SleepStateSample(ts: 100, state: 2, rawByte: 0xE9)]), deviceId: "dev1")

        let gravRows = try await s.gravitySamples(deviceId: "dev1", from: 0, to: 200, limit: 10)
        let g = try XCTUnwrap(gravRows.first)
        XCTAssertEqual(g.dynAccel ?? .nan, 0.0091596, accuracy: 1e-9)
        XCTAssertEqual(g.x, 0.1, accuracy: 1e-9)   // the vector is untouched

        let skinRows = try await s.skinTempSamples(deviceId: "dev1", from: 0, to: 200, limit: 10)
        let t = try XCTUnwrap(skinRows.first)
        XCTAssertEqual(t.raw, 3057)
        XCTAssertEqual(t.aux1Raw, 247)
        XCTAssertEqual(t.aux2Raw, 265)

        let bandRows = try await s.sleepStateSamples(deviceId: "dev1", from: 0, to: 200)
        let b = try XCTUnwrap(bandRows.first)
        XCTAssertEqual(b.rawByte, 0xE9)
        XCTAssertEqual(b.state, 2, "#175's `state` column must be untouched by the raw byte")
    }

    func testAuxSlotsRoundTripThroughTheBlob() async throws {
        let s = try await store()
        let sample = V18AuxSample(ts: 100, recordIndex: 25_443_699, rrCount: 2, cardiacFlags: 0,
                                  hrQualityFlags: 141, heartRateAlt: 101, rrPacked: 25_444,
                                  cardiacStatus: 255, stepCadence: 170, statusWord: 1_792,
                                  statusWord1: 3_073, statusWord2: 3_074, auxByte82: 0,
                                  opticalBaselineA: 101, opticalBaselineB: 111,
                                  opticalAmpA: 30, opticalAmpB: 30, unknownF32Bits: 0xC0A7_619D)
        _ = try await s.insert(Streams(v18Aux: [sample]), deviceId: "dev1")
        let n = try await s.v18AuxCountForTest()
        XCTAssertEqual(n, 1)
        let auxRows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 200)
        let back = try XCTUnwrap(auxRows.first)
        XCTAssertEqual(back, sample)
        XCTAssertEqual(back.unknownF32At113 ?? .nan, -5.2307, accuracy: 0.001)
    }

    /// Absence survives storage: a partially-populated sample reads back with the same slots absent.
    func testAbsentSlotsStayAbsentAcrossStorage() async throws {
        let s = try await store()
        let sample = V18AuxSample(ts: 100, statusWord: 1_792, opticalAmpA: 128)
        _ = try await s.insert(Streams(v18Aux: [sample]), deviceId: "dev1")
        let auxRows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 200)
        let back = try XCTUnwrap(auxRows.first)
        XCTAssertEqual(back.statusWord, 1_792)
        XCTAssertEqual(back.opticalAmpA, 128)
        XCTAssertNil(back.recordIndex)
        XCTAssertNil(back.cardiacStatus)
        XCTAssertNil(back.unknownF32Bits)
        XCTAssertEqual(back, sample)
    }

    /// An all-absent sample banks no row rather than an empty one.
    func testAllAbsentSampleBanksNoRow() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 100)]), deviceId: "dev1")
        let n = try await s.v18AuxCountForTest()
        XCTAssertEqual(n, 0)
    }

    /// Re-syncing the same second is idempotent — the same ON CONFLICT DO NOTHING rule as every other
    /// per-second stream, so a repeated offload cannot duplicate or overwrite.
    func testResyncIsIdempotent() async throws {
        let s = try await store()
        let streams = Streams(
            gravity: [GravitySample(ts: 100, x: 0, y: 0, z: 1, dynAccel: 0.01)],
            v18Aux: [V18AuxSample(ts: 100, statusWord: 7)])
        _ = try await s.insert(streams, deviceId: "dev1")
        _ = try await s.insert(streams, deviceId: "dev1")
        let n = try await s.v18AuxCountForTest()
        let g = try await s.gravitySamples(deviceId: "dev1", from: 0, to: 200, limit: 10).count
        XCTAssertEqual(n, 1)
        XCTAssertEqual(g, 1)
    }

    // MARK: - Codec

    func testCodecHeaderShapeAndSize() {
        let full = V18AuxSample(ts: 0, recordIndex: 1, rrCount: 2, cardiacFlags: 3, hrQualityFlags: 4,
                                heartRateAlt: 5, rrPacked: 6, cardiacStatus: 7, stepCadence: 8,
                                statusWord: 9, statusWord1: 10, statusWord2: 11, auxByte82: 12,
                                opticalBaselineA: 13, opticalBaselineB: 14, opticalAmpA: 15,
                                opticalAmpB: 16, unknownF32Bits: 17)
        let blob = [UInt8](V18AuxCodec.pack(full))
        XCTAssertEqual(blob[0], UInt8(V18AuxCodec.formatVersion))
        // Bitmap is a u32 LE with every slot's bit set. It is a u32 and not a u16 because there are 17
        // slots: bit 16 has nowhere to live in two bytes, and a bitmap that silently dropped it would
        // stop banking `unknown_f32_113` on both platforms at once.
        var bitmap = 0
        for byte in 0..<4 { bitmap |= Int(blob[1 + byte]) << (8 * byte) }
        XCTAssertEqual(bitmap, (1 << V18AuxSlot.allCases.count) - 1)
        XCTAssertGreaterThan(V18AuxSlot.allCases.count, 16, "a u16 bitmap would no longer fit")
        // 5-byte header + the sum of the declared slot widths — a full row is 32 bytes.
        XCTAssertEqual(blob.count, 5 + V18AuxSlot.allCases.reduce(0) { $0 + $1.width })
        XCTAssertEqual(blob.count, 32)
        XCTAssertEqual(V18AuxCodec.unpack(V18AuxCodec.pack(full), ts: 0), full)
    }

    /// A sample with nothing present packs to nothing, so the caller can skip the row.
    func testEmptySamplePacksToEmptyData() {
        XCTAssertTrue(V18AuxCodec.pack(V18AuxSample(ts: 0)).isEmpty)
    }

    /// A read over durable rows must never crash on a bad blob — a truncated, short, or
    /// unknown-version record degrades to "nothing known about this second".
    func testMalformedBlobsDegradeToAbsentRatherThanThrow() {
        XCTAssertTrue(V18AuxCodec.unpack(Data(), ts: 5).isEmpty)
        XCTAssertTrue(V18AuxCodec.unpack(Data([2, 0xFF, 0xFF]), ts: 5).isEmpty)           // header cut short
        XCTAssertTrue(V18AuxCodec.unpack(Data([99, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2]), ts: 5).isEmpty) // future
        // A v1 blob (the pre-#861 layout, u16 bitmap and fused @36/@106 u16 slots) is an UNKNOWN version
        // to a v2 reader, so it reads back as "nothing known" instead of being sliced against the wrong
        // slot table. The format never shipped, so the only such rows possible are on a local build.
        XCTAssertTrue(V18AuxCodec.unpack(Data([1, 0xFF, 0x7F, 1, 2, 3, 4]), ts: 5).isEmpty)
        // Truncated body: the slots that fit are kept, the rest stay absent (never invented). Bitmap
        // 0b0110 claims slots 1 (rrCount, 1 byte) and 2 (cardiacFlags, 1 byte), but only one body byte
        // follows — so slot 1 decodes and slot 2 must read absent rather than borrowing a byte.
        let partial = V18AuxCodec.unpack(Data([2, 0b0000_0110, 0, 0, 0, 42]), ts: 5)
        XCTAssertEqual(partial.rrCount, 42)
        XCTAssertNil(partial.cardiacFlags)
        XCTAssertEqual(partial.ts, 5)
    }

    /// Every slot's value survives at its full declared width (a 4-byte slot must not be truncated to 2).
    func testWideSlotsSurviveAtFullWidth() {
        let s = V18AuxSample(ts: 0, recordIndex: 0xFEDC_BA98, unknownF32Bits: 0xC0A7_619D)
        let back = V18AuxCodec.unpack(V18AuxCodec.pack(s), ts: 0)
        XCTAssertEqual(back.recordIndex, 0xFEDC_BA98)
        XCTAssertEqual(back.unknownF32Bits, 0xC0A7_619D)
    }

    /// The exact bytes the codec produces for the real v18 fixture's slots. Hard-coded rather than
    /// derived, and asserted VERBATIM by the Kotlin twin
    /// (`DeepCaptureChannelsTest.fixtureRowPacksToTheExactCrossPlatformBytes`), so a one-sided edit to
    /// either codec's layout fails HERE instead of silently writing blobs the other platform cannot read
    /// out of a `.noopbak`.
    func testFixtureRowPacksToTheExactCrossPlatformBytes() {
        let a = V18AuxSample(ts: 1_780_916_150, recordIndex: 25_443_699, rrCount: 2, cardiacFlags: 0,
                             hrQualityFlags: 141, heartRateAlt: 101, rrPacked: 25_444,
                             cardiacStatus: 255, stepCadence: 170, statusWord: 1_792, statusWord1: 3_073,
                             statusWord2: 3_074, auxByte82: 0, opticalBaselineA: 101,
                             opticalBaselineB: 111, opticalAmpA: 30, opticalAmpB: 30,
                             unknownF32Bits: 0xC0A7_619D)
        let hex = V18AuxCodec.pack(a).map { String(format: "%02x", $0) }.joined()
        // The BODY is byte-for-byte what v1 wrote: splitting @36/@37 and @106/@107 out of their fused u16
        // slots emits the same two bytes in the same order (a LE u16 is its low byte then its high byte).
        // Only the header moved — version 1 -> 2, and a u16 bitmap -> u32 because 17 slots need 17 bits.
        XCTAssertEqual(hex,
            "02ffff0100" +      // version 2, bitmap 0x0001FFFF u32 LE (all 17 slots present)
            "733d8401" +        // record_index      25443699 u32 LE
            "02" +              // rr_count          2
            "00" +              // cardiac_flags     0
            "8d" +              // hr_quality_flags  141 (0x8D) @36
            "65" +              // heart_rate_alt    101        @37
            "6463" +            // rr_packed         25444 u16 LE
            "ff" +              // cardiac_status    255
            "aa" +              // step_cadence      170
            "0007" +            // status_word       1792 u16 LE
            "010c" +            // status_word_1     3073 u16 LE
            "020c" +            // status_word_2     3074 u16 LE
            "00" +              // aux_byte_82       0
            "65" +              // optical_baseline_a 101       @106
            "6f" +              // optical_baseline_b 111       @107
            "1e" +              // optical_amp_a     30
            "1e" +              // optical_amp_b     30
            "9d61a7c0")         // unknown_f32_113 bits 0xC0A7619D u32 LE
    }

    // MARK: - Rolling retention

    /// `v18AuxSample` is CAPPED, not unbounded — the same rolling shape `rawImuSample` uses (#423).
    /// Driven with a tiny cap so the SQL itself is proved rather than 600k rows written.
    func testAuxRowsAreCappedNewestFirst() async throws {
        let s = try await store()
        for ts in 100...109 {
            _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: ts, statusWord: ts)]),
                                   deviceId: "dev1", v18AuxRetentionRows: 3, v18AuxPruneEveryRows: 1)
        }
        let rows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.count, 3, "the cap must bound the table")
        XCTAssertEqual(rows.map(\.ts), [107, 108, 109], "the NEWEST rows survive")
        XCTAssertEqual(rows.last?.statusWord, 109, "and they keep their slots")
    }

    /// The cap is per DEVICE: one strap's history must not evict another's.
    func testRetentionIsScopedToTheDevice() async throws {
        let s = try await store()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        for ts in 100...104 {
            _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: ts, statusWord: 1)]),
                                   deviceId: "dev1", v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1)
        }
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 100, statusWord: 1)]),
                               deviceId: "dev2", v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1)
        let d1 = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        let d2 = try await s.v18AuxSamples(deviceId: "dev2", from: 0, to: 1_000)
        XCTAssertEqual(d1.map(\.ts), [103, 104])
        XCTAssertEqual(d2.map(\.ts), [100], "dev2's single old row must survive dev1's eviction")
    }

    /// Below the threshold the sweep must not run — the overshoot is the whole point.
    func testRetentionSweepIsDeferredBelowTheThreshold() async throws {
        let s = try await store()
        for ts in 100...109 {
            _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: ts, statusWord: ts)]),
                                   deviceId: "dev1", v18AuxRetentionRows: 3, v18AuxPruneEveryRows: 5_000)
        }
        let rows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.count, 10, "under the threshold the sweep must not run — overshoot is the point")
    }

    /// …and once the threshold is crossed it runs, so amortising did not make the cap unbounded.
    func testRetentionSweepRunsOnceTheThresholdIsCrossed() async throws {
        let s = try await store()
        // Four batches of two rows: the sweep is due on the fourth (8 >= 7) and not before.
        for batch in 0..<4 {
            let base = 100 + batch * 2
            _ = try await s.insert(
                Streams(v18Aux: [V18AuxSample(ts: base, statusWord: base),
                                 V18AuxSample(ts: base + 1, statusWord: base + 1)]),
                deviceId: "dev1", v18AuxRetentionRows: 3, v18AuxPruneEveryRows: 7)
        }
        let rows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [105, 106, 107],
                       "the sweep still keeps exactly the newest v18AuxRetentionRows")
    }

    /// The counter resets per sweep, so a long offload sweeps repeatedly rather than latching.
    func testTheAmortisationCounterResetsAfterEachSweep() async throws {
        let s = try await store()
        for ts in 100...111 {
            _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: ts, statusWord: ts)]),
                                   deviceId: "dev1", v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 4)
        }
        // 12 rows banked, sweeps due after the 4th, 8th and 12th — the last one leaves exactly the cap.
        let rows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [110, 111],
                       "a second sweep must happen; the counter cannot latch after the first")
    }

    /// The budget is per device, because the delete is — one strap must not spend another's.
    func testTheAmortisationBudgetIsNotSharedBetweenDevices() async throws {
        let s = try await store()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        // dev1 banks three rows against a threshold of four — one short, so no sweep is due for it.
        for ts in 100...102 {
            _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: ts, statusWord: ts)]),
                                   deviceId: "dev1", v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 4)
        }
        // dev2 banks one row. With a SHARED counter this crosses the threshold and sweeps — and because
        // the delete is scoped to dev2, it would evict nothing from dev1 while zeroing dev1's budget.
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 200, statusWord: 1)]),
                               deviceId: "dev2", v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 4)
        // dev1's fourth row must now be what crosses ITS OWN threshold and sweeps it to the cap.
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 103, statusWord: 103)]),
                               deviceId: "dev1", v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 4)
        let d1 = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(d1.map(\.ts), [103],
                       "dev1's own fourth row must trigger dev1's sweep — dev2 cannot spend its budget")
    }

    /// A batch that banks no aux row must not run the retention delete at all — a WHOOP 4.0 offload
    /// (or any non-v18 second) never pays for the index scan, and never evicts.
    func testNoAuxRowsMeansNoRetentionSweep() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 100, statusWord: 1),
                                                V18AuxSample(ts: 101, statusWord: 2)]),
                               deviceId: "dev1", v18AuxRetentionRows: 5, v18AuxPruneEveryRows: 1)
        // An all-absent sample packs to nothing, so this batch writes no row and must sweep nothing.
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 200)]),
                               deviceId: "dev1", v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 1)
        let rows = try await s.v18AuxSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [100, 101])
    }

    /// The shipped cap is a real bound, and documented in row terms.
    func testShippedRetentionConstant() {
        XCTAssertEqual(WhoopStore.v18AuxRetentionRows, 604_800)   // 7 x 86_400 strap-seconds
        XCTAssertGreaterThan(WhoopStore.v18AuxRetentionRows, WhoopStore.rawImuRetentionRows)
    }

    /// Deleting a device's data must clear the aux rows too — the same privacy rule every other
    /// deviceId-keyed per-second table follows.
    func testDeleteAllDataClearsAuxRows() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 100, statusWord: 7)]), deviceId: "dev1")
        let before = try await s.v18AuxCountForTest()
        XCTAssertEqual(before, 1)
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("v18AuxSample"))
        try await s.deleteAllData(deviceId: "dev1")
        let after = try await s.v18AuxCountForTest()
        XCTAssertEqual(after, 0)
    }
}
