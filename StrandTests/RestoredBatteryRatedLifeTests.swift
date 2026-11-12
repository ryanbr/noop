import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// #2887: a relaunched (BLE-restored) 5/MG must estimate against the 5/MG rated life, and a reconnect must
/// re-seed the discharge history `clearBiometrics` dropped.
@MainActor
final class RestoredBatteryRatedLifeTests: XCTestCase {
    private let key = "selectedWhoopModel"
    private var saved: Any?

    override func setUp() async throws {
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: key)
    }

    func testPersistedWhoop5GetsWhoop5RatedLifeWithoutConnect() {
        UserDefaults.standard.set(WhoopModel.whoop5mg.rawValue, forKey: key)
        let state = LiveState()
        _ = BLEManager(state: state, collector: nil)
        XCTAssertEqual(state.batteryRatedHours, BatteryEstimator.ratedLifeHoursWhoop5)
    }

    func testPersistedWhoop4KeepsWhoop4RatedLife() {
        UserDefaults.standard.set(WhoopModel.whoop4.rawValue, forKey: key)
        let state = LiveState()
        _ = BLEManager(state: state, collector: nil)
        XCTAssertEqual(state.batteryRatedHours, BatteryEstimator.ratedLifeHoursWhoop4)
    }

    func testReseedAfterClearRestoresMeasuredEstimate() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let now = Int(Date().timeIntervalSince1970)
        _ = try await store.insert(Streams(battery: [
            BatterySample(ts: now - 6 * 3600, soc: 90, mv: nil),
            BatterySample(ts: now - 3600, soc: 85, mv: nil),
        ]), deviceId: "my-whoop")
        let state = LiveState()
        let manager = BLEManager(state: state, collector: nil)

        state.clearBiometrics()
        await manager.seedBatteryHistory(from: store)

        XCTAssertEqual(state.batterySamples.count, 2)
        XCTAssertEqual(state.batteryEstimate?.source, .measured)
    }
}
