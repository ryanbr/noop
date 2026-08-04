import XCTest
import WhoopProtocol
@testable import WhoopStore

final class LatestSampleTests: XCTestCase {
    func testLatestHRSampleTs() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        // No rows yet → nil.
        let empty = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertNil(empty)
        // Insert HR rows at ts 100 and 250; latest = 250.
        let s = Streams(hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 250, bpm: 61)])
        _ = try await store.insert(s, deviceId: "d")
        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 250)
    }

    /// The stuck-strap watchdog frontier must advance on a PPG-only offload too (#156): a v26
    /// WHOOP 5 night with no measured HR still has a real data frontier from its PPG rows.
    func testLatestHRSampleTsIncludesPpgFallbackRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "d")
        _ = try await store.insert(
            Streams(ppgHr: [PpgHrSample(ts: 300, bpm: 62, conf: 0.8)]), deviceId: "d")

        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 300)
    }

    /// The mirror of the test above: when the MEASURED stream is the newer one, it must win. Together
    /// the pair pins "max over BOTH streams" rather than "whichever stream is checked last", which is
    /// the property the per-arm `SELECT MAX(ts)` form has to preserve.
    func testLatestHRSampleTsPrefersNewerMeasuredRowOverOlderPpg() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(ppgHr: [PpgHrSample(ts: 300, bpm: 62, conf: 0.8)]), deviceId: "d")
        _ = try await store.insert(Streams(hr: [HRSample(ts: 900, bpm: 60)]), deviceId: "d")

        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 900)
    }

    /// The frontier is per-device: a second strap's newer rows must not advance this one's watchdog.
    func testLatestHRSampleTsIsScopedToTheRequestedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "a", mac: nil, name: nil)
        try await store.upsertDevice(id: "b", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "a")
        _ = try await store.insert(Streams(hr: [HRSample(ts: 9_000, bpm: 61)]), deviceId: "b")
        _ = try await store.insert(
            Streams(ppgHr: [PpgHrSample(ts: 8_000, bpm: 62, conf: 0.8)]), deviceId: "b")

        let a = try await store.latestHRSampleTs(deviceId: "a")
        XCTAssertEqual(a, 100)
        // And a device that has never reported stays nil even while other devices have rows.
        try await store.upsertDevice(id: "c", mac: nil, name: nil)
        let c = try await store.latestHRSampleTs(deviceId: "c")
        XCTAssertNil(c)
    }
}
