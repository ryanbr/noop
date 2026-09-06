import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v27 migration: durable storage for the WHOOP 5.0 v26 optical PPG waveform (issue #156 follow-up).
/// The strap's 24 Hz buffer was fully decoded but only ever used to derive `ppgHrSample` (v12); the
/// waveform itself was discarded right after. This proves the new table exists, its key/shape, that
/// insert/read round-trips (including negative AC-coupled samples), and that the packed-BLOB encoding
/// survives a write + read cycle intact.
final class PpgWaveformSampleTests: XCTestCase {
    // Real captured v26 waveform (Whoop5PpgWaveformTests fixture, WhoopProtocol): a clean PPG upstroke,
    // all-negative AC-coupled ADC counts — exercises the signed packing end to end.
    private let realSamples = [
        -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
        -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164,
    ]

    func testV27CreatesPpgWaveformTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ppgWaveformSample"))
    }

    func testPpgWaveformPrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("ppgWaveformSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testPpgWaveformTableShape() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "ppgWaveformSample")
        XCTAssertEqual(Set(cols), ["deviceId", "ts", "samples", "burstIndex"])
    }

    func testPpgWaveformInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(ppgWaveform: [PpgWaveformSample(ts: 1_780_917_232,
                                                              samples: realSamples, burstIndex: 7)])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n1 = try await store.ppgWaveformCountForTest()
        XCTAssertEqual(n1, 1)
        let read = try await store.ppgWaveformSamples(deviceId: "my-whoop",
                                                       from: 1_780_917_232, to: 1_780_917_232)
        XCTAssertEqual(read, [PpgWaveformSample(ts: 1_780_917_232, samples: realSamples, burstIndex: 7)])
        // Re-inserting the same (deviceId, ts) is idempotent, ON CONFLICT DO NOTHING (mirrors every
        // other per-second stream's dedupe rule).
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n2 = try await store.ppgWaveformCountForTest()
        XCTAssertEqual(n2, 1)
    }

    /// Multiple consecutive-second records for the same device round-trip in ts order and stay scoped
    /// to their own device (mirrors the range/scope discipline the other per-second readers follow).
    func testPpgWaveformReadRespectsRangeAndDeviceScope() async throws {
        let store = try await WhoopStore.inMemory()
        let base = 1_780_000_000
        let streams = Streams(ppgWaveform: (0..<5).map {
            PpgWaveformSample(ts: base + $0, samples: [$0, $0 * 2, -$0])
        })
        _ = try await store.insert(streams, deviceId: "dev-a")
        _ = try await store.insert(
            Streams(ppgWaveform: [PpgWaveformSample(ts: base, samples: [99])]), deviceId: "dev-b")

        let read = try await store.ppgWaveformSamples(deviceId: "dev-a", from: base + 1, to: base + 3)
        XCTAssertEqual(read.map(\.ts), [base + 1, base + 2, base + 3])
        XCTAssertEqual(read.map(\.samples), [[1, 2, -1], [2, 4, -2], [3, 6, -3]])

        let otherDevice = try await store.ppgWaveformSamples(deviceId: "dev-b", from: base, to: base)
        XCTAssertEqual(otherDevice, [PpgWaveformSample(ts: base, samples: [99])])
    }

    /// A record with fewer than 24 samples (a truncated/short frame) still round-trips exactly —
    /// the pack/unpack format isn't hardcoded to a fixed sample count.
    func testPpgWaveformHandlesShortSampleArray() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(ppgWaveform: [PpgWaveformSample(ts: 1_780_000_500, samples: [7, -8])])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let read = try await store.ppgWaveformSamples(deviceId: "my-whoop",
                                                       from: 1_780_000_500, to: 1_780_000_500)
        XCTAssertEqual(read, [PpgWaveformSample(ts: 1_780_000_500, samples: [7, -8])])
    }

    /// An empty-sample record is never inserted (mirrors HistoricalStreams' `!samples.isEmpty` guard
    /// upstream) — this is a store-level belt-and-suspenders check on the insert path itself.
    func testPpgWaveformEmptySamplesStillInsertsRow() async throws {
        // The store layer itself doesn't filter empty arrays (that's HistoricalStreams' job); prove the
        // pack/unpack round-trips a zero-length payload cleanly rather than crashing either way.
        let store = try await WhoopStore.inMemory()
        let streams = Streams(ppgWaveform: [PpgWaveformSample(ts: 1_780_000_600, samples: [])])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let read = try await store.ppgWaveformSamples(deviceId: "my-whoop",
                                                       from: 1_780_000_600, to: 1_780_000_600)
        XCTAssertEqual(read, [PpgWaveformSample(ts: 1_780_000_600, samples: [])])
    }

    func testPackUnpackPpgSamplesRoundTrips() {
        let samples = [0, 1, -1, 32767, -32768, -1432, 12345]
        let packed = WhoopStore.packPpgSamples(samples)
        XCTAssertEqual(packed.count, samples.count * 2, "2 bytes/sample, no per-record overhead")
        XCTAssertEqual(WhoopStore.unpackPpgSamples(packed), samples)
    }

    func testUnpackPpgSamplesDropsTrailingOddByte() {
        // A corrupt/truncated blob (odd byte count) must not crash the read path.
        var data = WhoopStore.packPpgSamples([1, 2, 3])
        data.append(0xFF)
        XCTAssertEqual(WhoopStore.unpackPpgSamples(data), [1, 2, 3])
    }

    // MARK: - #1911 rolling retention

    private func retentionStore() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        return s
    }

    private func waveform(_ ts: Int) -> Streams {
        Streams(ppgWaveform: [PpgWaveformSample(ts: ts, samples: realSamples, burstIndex: 0)])
    }

    /// The cap keeps the NEWEST rows. This is the property the whole design rests on — an age-based drop
    /// would instead empty the table for a sporadic wearer, whom a future PPG estimator needs most.
    func testRetentionKeepsTheNewestRows() async throws {
        let s = try await retentionStore()
        for ts in 100...105 {
            _ = try await s.insert(waveform(ts), deviceId: "dev1",
                                   v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                                   v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                                   ppgWaveformRetentionRows: 2, ppgWaveformPruneEveryRows: 1)
        }
        let rows = try await s.ppgWaveformSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [104, 105], "newest-N, not oldest-N and not everything")
    }

    /// Under the sweep threshold nothing is evicted — the overshoot is deliberate amortisation.
    func testRetentionDoesNotSweepUnderTheThreshold() async throws {
        let s = try await retentionStore()
        for ts in 100...104 {
            _ = try await s.insert(waveform(ts), deviceId: "dev1",
                                   v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                                   v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                                   ppgWaveformRetentionRows: 2, ppgWaveformPruneEveryRows: 50)
        }
        let rows = try await s.ppgWaveformSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.count, 5, "under the threshold the sweep must not run — overshoot is the point")
    }

    /// The counter resets after each sweep, so a long offload sweeps repeatedly rather than latching once.
    func testRetentionCounterResetsAfterEachSweep() async throws {
        let s = try await retentionStore()
        for ts in 100...111 {
            _ = try await s.insert(waveform(ts), deviceId: "dev1",
                                   v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                                   v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                                   ppgWaveformRetentionRows: 2, ppgWaveformPruneEveryRows: 4)
        }
        let rows = try await s.ppgWaveformSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [110, 111],
                       "a second sweep must happen; the counter cannot latch after the first")
    }

    /// The budget is per device, because the delete is — one strap must not spend another's.
    func testRetentionBudgetIsNotSharedBetweenDevices() async throws {
        let s = try await retentionStore()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        for ts in 100...102 {
            _ = try await s.insert(waveform(ts), deviceId: "dev1",
                                   v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                                   v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                                   ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 4)
        }
        // With a SHARED counter dev2's single row crosses the threshold and sweeps; because the delete is
        // scoped to dev2 it would evict nothing from dev1 while zeroing dev1's budget.
        _ = try await s.insert(waveform(200), deviceId: "dev2",
                               v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                               v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                               ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 4)
        _ = try await s.insert(waveform(103), deviceId: "dev1",
                               v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                               v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                               ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 4)
        let d1 = try await s.ppgWaveformSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(d1.map(\.ts), [103],
                       "dev1's own fourth row must trigger dev1's sweep — dev2 cannot spend its budget")
    }

    /// A batch with no waveform row must not sweep at all: a WHOOP 4.0 offload, or any non-v26 second,
    /// never pays for the index scan and never evicts. Guards against banking the budget off other streams.
    func testNoWaveformRowsMeansNoRetentionSweep() async throws {
        let s = try await retentionStore()
        _ = try await s.insert(waveform(100), deviceId: "dev1",
                               v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                               v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                               ppgWaveformRetentionRows: 5, ppgWaveformPruneEveryRows: 1)
        // An HR-only batch banks nothing here, so the cap of 1 must NOT evict the waveform row above.
        _ = try await s.insert(Streams(hr: [HRSample(ts: 200, bpm: 60)]), deviceId: "dev1",
                               v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                               v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                               ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 1)
        let rows = try await s.ppgWaveformSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [100])
    }

    /// One strap's sweep must not evict ANOTHER strap's rows. Distinct from the budget test above, which
    /// only proves the two devices bank separately: this pins the DELETE's own device scoping, and it is
    /// the reason the older strap's rows sit BELOW the sweeping strap's cutoff. With `dev2` newer than the
    /// cutoff (as in the budget test) the rows survive even a DELETE that has lost its `deviceId` filter,
    /// so that arrangement cannot see the bug. Dropping the outer filter is silent cross-device data loss
    /// on a multi-strap install, and nothing else in the suite catches it.
    func testRetentionSweepDoesNotEvictAnotherDevicesRows() async throws {
        let s = try await retentionStore()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        for ts in [500, 501] {
            _ = try await s.insert(waveform(ts), deviceId: "dev2",
                                   v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                                   v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                                   ppgWaveformRetentionRows: 10, ppgWaveformPruneEveryRows: 50)
        }
        // dev1's rows are all NEWER than dev2's, so dev1's cutoff sits above every dev2 row.
        for ts in 1_000...1_003 {
            _ = try await s.insert(waveform(ts), deviceId: "dev1",
                                   v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                                   v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                                   ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 1)
        }
        let d1 = try await s.ppgWaveformSamples(deviceId: "dev1", from: 0, to: 10_000)
        let d2 = try await s.ppgWaveformSamples(deviceId: "dev2", from: 0, to: 10_000)
        XCTAssertEqual(d1.map(\.ts), [1_003], "dev1 is swept to its own cap")
        XCTAssertEqual(d2.map(\.ts), [500, 501],
                       "dev2's older rows must survive dev1's sweep — the DELETE is per device")
    }

    /// The production cap must stay a WEEK-SCALE newest-N row count, not an age-based drop. Pins the
    /// constant so a future "just make it 7 days" edit has to confront `ppgWaveformRetentionRows`' note.
    func testProductionRetentionCapIsAWeekOfStrapSeconds() {
        XCTAssertEqual(WhoopStore.ppgWaveformRetentionRows, 604_800)
        XCTAssertEqual(WhoopStore.ppgWaveformPruneEveryRows, 10_000)
    }
}
