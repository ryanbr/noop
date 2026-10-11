import XCTest
import Combine
@testable import Strand
import WhoopStore

/// Pins the DETERMINISTIC pieces of the experimental clean-room BLE drivers: the Huami custom HR parse,
/// the brand recogniser, and the SourceKind routing for the Huami tier. The live BLE I/O itself can't be
/// hardware-verified here (CoreBluetooth needs a real radio + a real band), so these tests cover the pure
/// logic the drivers stand on. Mirrors the StandardHeartRate / FTMSDecode test discipline.
final class ExperimentalDriversTests: XCTestCase {

    // MARK: - Huami custom HR parse

    /// The 2-byte [status, hr] shape: byte 0 is a status/flags byte, byte 1 the bpm.
    func testHuamiTwoByteStatusHr() {
        XCTAssertEqual(HuamiHeartRate.parse([0x00, 72]), 72)
        XCTAssertEqual(HuamiHeartRate.parse([0x10, 58]), 58)   // a non-zero status byte is ignored
    }

    /// The 1-byte [hr] shape.
    func testHuamiOneByteHr() {
        XCTAssertEqual(HuamiHeartRate.parse([65]), 65)
    }

    /// 0 = "no reading" → nil (we show "—", never a fake 0). 255 = the off-wrist / no-contact sentinel → nil.
    func testHuamiNoReadingSentinelsAreNil() {
        XCTAssertNil(HuamiHeartRate.parse([0x00, 0]))     // status + zero bpm
        XCTAssertNil(HuamiHeartRate.parse([0]))           // bare zero
        XCTAssertNil(HuamiHeartRate.parse([0x00, 255]))   // status + 0xFF sentinel
        XCTAssertNil(HuamiHeartRate.parse([255]))         // bare 0xFF
    }

    /// Empty packet → nil, never a crash or an out-of-bounds read.
    func testHuamiEmptyIsNil() {
        XCTAssertNil(HuamiHeartRate.parse([]))
    }

    /// A plausible high-but-real value still parses (the caller's 30–220 gate, not the parser, drops
    /// out-of-physiology values — the parser only owns byte extraction).
    func testHuamiHighValueParses() {
        XCTAssertEqual(HuamiHeartRate.parse([0x00, 200]), 200)
    }

    // MARK: - Brand recognition

    func testRecogniseAmazfitFamily() {
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Amazfit GTR 4"), .amazfit)
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Amazfit Helio Ring"), .amazfit)
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Zepp E"), .amazfit)
    }

    func testRecogniseMiBand() {
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Mi Band 7"), .miBand)
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Xiaomi Smart Band 8"), .miBand)
    }

    func testRecogniseGarmin() {
        // Exercise the catalog-to-enum bridge used by discovery, including model-only names and
        // case/diacritic folding. Every recognised Garmin routes through standard broadcast HR.
        for name in ["Garmin Instinct 2", "Garmin Forerunner 265", "FORERUNNER 265",
                     "fenix 7", "fēnix 7", "vívoactive 5", "Venu 3", "Instinct 2", "epix Pro", "vívosmart 5", "HRM-Pro"] {
            let brand = ExperimentalBrand.recognise(name: name)
            XCTAssertEqual(brand, .garmin, name)
            XCTAssertEqual(brand?.sourceKind, .liveBLE, name)
            XCTAssertEqual(brand?.idPrefix, "garmin", name)
            XCTAssertEqual(brand?.canStreamLiveHR, true, name)
        }
    }

    func testGarminRecognitionDoesNotCaptureOtherBrands() {
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Amazfit GTS"), .amazfit)
        for name in ["Polar H10", "Wahoo TICKR", "Some Random Speaker", "", "   "] {
            XCTAssertNil(ExperimentalBrand.recognise(name: name), name)
        }
    }

    func testRecogniseOura() {
        XCTAssertEqual(ExperimentalBrand.recognise(name: "Oura Ring"), .oura)
    }

    /// An unrecognised name returns nil — no wrong guess. (A Polar HR strap is the GENERIC path, not this
    /// experimental tier.)
    func testUnknownNameIsNil() {
        XCTAssertNil(ExperimentalBrand.recognise(name: "Polar H10"))
        XCTAssertNil(ExperimentalBrand.recognise(name: ""))
        XCTAssertNil(ExperimentalBrand.recognise(name: "Some Random Speaker"))
    }

    /// Oura is the only experimental brand with NO live HR — it must route to file import, not a fake live
    /// connect. The others can attempt live HR.
    func testOnlyOuraCannotStreamLive() {
        XCTAssertFalse(ExperimentalBrand.oura.canStreamLiveHR)
        XCTAssertTrue(ExperimentalBrand.amazfit.canStreamLiveHR)
        XCTAssertTrue(ExperimentalBrand.miBand.canStreamLiveHR)
        XCTAssertTrue(ExperimentalBrand.garmin.canStreamLiveHR)
    }

    // MARK: - Garmin is the standard path, not a proprietary one

    func testGarminBroadcastGuidanceExists() {
        // The hint exists and is non-empty so the prep step has guidance to show.
        XCTAssertFalse(GarminBroadcast.broadcastHint.isEmpty)
    }

    // MARK: - SourceKind routing

    /// A `.huami` device is NOT a WHOOP, so the SourceCoordinator routes it to a non-WHOOP source. This
    /// pins that the new enum case round-trips and is classified as non-WHOOP (so the WHOOP path is never
    /// stolen by an Amazfit/Mi Band).
    @MainActor
    func testHuamiSourceKindIsNotWhoop() {
        let huami = PairedDevice(
            id: "huami-1", brand: "Amazfit", model: "GTR 4", peripheralId: "AA",
            sourceKind: .huami, capabilities: [.hr], status: .paired, addedAt: 0, lastSeenAt: 0)
        XCTAssertFalse(SourceCoordinator.isWhoop(huami))
        // The enum rawValue is stable for the cross-platform store encoding.
        XCTAssertEqual(SourceKind.huami.rawValue, "huami")
    }

    /// A Garmin row is a plain `.liveBLE` device (standard broadcast HR), branded "Garmin", non-WHOOP.
    @MainActor
    func testGarminSourceKindIsLiveBLENonWhoop() {
        let garmin = PairedDevice(
            id: "garmin-1", brand: "Garmin", model: "Forerunner 265", peripheralId: "BB",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .paired, addedAt: 0, lastSeenAt: 0)
        XCTAssertFalse(SourceCoordinator.isWhoop(garmin))
    }

    // MARK: - Apple Watch is a HealthKit source, not a BLE peripheral

    /// REGRESSION GUARD: activating the Apple Watch (`apple-health`, `.liveAppleWatch`, `peripheralId: nil`)
    /// must NOT touch the BLE world. The watch is a HealthKit pseudo-device read entirely by
    /// `HealthKitBridge`. If `SourceCoordinator` ever routed it through `switchToStrap` it would
    /// `stopWhoop()` (tearing down a live WHOOP) and then BLE-scan a peripheral that doesn't exist.
    /// This asserts both never happen: `stopWhoop` is not called, and no `StandardHRSource` is started
    /// (which would synchronously emit an "HR-strap:" line through the strap log on `scan()`).
    @MainActor
    func testActivatingAppleWatchDoesNotStopWhoopOrStartABLESource() async throws {
        // Real in-memory store + registry, matching how `AppModel.wireSourceCoordinator` builds them.
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()   // seeds 'my-whoop' active from migration v15

        // Register the Apple Watch exactly as `AppleWatchDevice.device(...)` would: HealthKit source,
        // nil peripheralId, `.liveAppleWatch`.
        registry.add(PairedDevice(
            id: "apple-health", brand: "Apple", model: "Apple Watch",
            peripheralId: nil, sourceKind: .liveAppleWatch,
            capabilities: [.hr, .hrv, .sleep], status: .paired, addedAt: 0, lastSeenAt: 0))
        registry.setActive("apple-health")

        var stopWhoopCalls = 0
        var startWhoopCalls = 0
        var strapLogLines: [String] = []

        let coordinator = SourceCoordinator(
            registry: registry,
            live: LiveState(),
            storeHandle: { nil },
            startWhoop: { startWhoopCalls += 1 },
            stopWhoop: { stopWhoopCalls += 1 },
            setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            straplog: { strapLogLines.append($0) })

        // Drive the transition directly (the same call `start()`'s subscription makes on an active-id change).
        coordinator.activeDeviceChanged(to: "apple-health")

        XCTAssertEqual(stopWhoopCalls, 0, "Activating the Apple Watch must NOT tear down the live WHOOP link")
        XCTAssertEqual(startWhoopCalls, 0, "The HealthKit watch source must not re-scan WHOOP")
        XCTAssertFalse(strapLogLines.contains(where: { $0.hasPrefix("HR-strap:") }),
                       "No StandardHRSource should be started for a HealthKit pseudo-device")
    }
}
