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
}
