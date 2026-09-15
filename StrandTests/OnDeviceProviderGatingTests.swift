import XCTest
import Combine
@testable import Strand

@MainActor
final class OnDeviceProviderGatingTests: XCTestCase {
    func testOnDeviceIsFirstCaseAndInAllCases() {
        XCTAssertEqual(AIProvider.allCases.first, .onDevice)
    }

    /// The download setup card in CoachView observes the engine (`@EnvironmentObject`), not the nested
    /// `modelDownloads` manager. So the engine MUST forward the manager's changes, or the progress /
    /// cancel / ready transitions never re-render until the view is recreated (leave + re-enter).
    func testEngineForwardsModelDownloadStateChanges() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-download-forwarding"))
        var fired = 0
        let cancellable = engine.objectWillChange.sink { _ in fired += 1 }
        engine.modelDownloads.setStateForTesting(.downloading(progress: 0.35))
        engine.modelDownloads.setStateForTesting(.absent)
        cancellable.cancel()
        XCTAssertGreaterThanOrEqual(fired, 2,
            "engine.objectWillChange must fire on each modelDownloads.state change so the setup card updates live")
    }

    func testIsConfiguredTracksDownloadReadiness() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-ondevice-gating"))
        engine.provider = .onDevice
        // Fresh install: model absent → not configured.
        engine.modelDownloads.setStateForTesting(.absent)
        XCTAssertFalse(engine.isConfigured)
        engine.modelDownloads.setStateForTesting(.ready)
        XCTAssertTrue(engine.isConfigured)
    }

    #if os(iOS)
    func testDefaultProviderIsOnDeviceOniOS() {
        XCTAssertEqual(AIProvider.defaultProvider, .onDevice)
    }
    #else
    func testOnDeviceHiddenFromPickerOnMac() {
        XCTAssertFalse(AIProvider.available.contains(.onDevice))
        XCTAssertEqual(AIProvider.defaultProvider, .openAI)
    }
    #endif
}
