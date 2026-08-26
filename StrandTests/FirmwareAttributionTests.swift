import XCTest
@testable import Strand

/// Pins firmware attribution. Kotlin twin: `FirmwareAttributionTest`.
///
/// The reported bug: a WHOOP 5/MG showed 41.17.6.0 — the 4.0's firmware — because the persisted value
/// lived under ONE global key, written on any WHOOP connect and read back for whichever strap was active.
final class FirmwareAttributionTests: XCTestCase {

    func testLiveWinsOverEverything() {
        XCTAssertEqual(FirmwareAttribution.resolve(live: "50.1.0.0", perDevice: "49.0.0.0",
                                                   legacyGlobal: "41.17.6.0", pairedCount: 2), "50.1.0.0")
    }

    func testThisDevicesOwnPersistedValueBeatsTheLegacyGlobal() {
        XCTAssertEqual(FirmwareAttribution.resolve(live: nil, perDevice: "50.1.0.0",
                                                   legacyGlobal: "41.17.6.0", pairedCount: 2), "50.1.0.0")
    }

    func testTheLegacyGlobalIsRefusedWhenMoreThanOneDeviceIsPaired() {
        // The exact reported bug: two straps, no per-device value yet for the active one, and the global
        // key holds the other strap's firmware. nil is correct; 41.17.6.0 is not.
        XCTAssertNil(FirmwareAttribution.resolve(live: nil, perDevice: nil,
                                                 legacyGlobal: "41.17.6.0", pairedCount: 2))
    }

    func testTheLegacyGlobalIsHonouredForASingleDeviceInstall() {
        XCTAssertEqual(FirmwareAttribution.resolve(live: nil, perDevice: nil,
                                                   legacyGlobal: "41.17.6.0", pairedCount: 1), "41.17.6.0")
    }

    func testBlankValuesAreTreatedAsAbsentNotAsAnAnswer() {
        XCTAssertEqual(FirmwareAttribution.resolve(live: "", perDevice: "   ",
                                                   legacyGlobal: "41.17.6.0", pairedCount: 1), "41.17.6.0")
        XCTAssertNil(FirmwareAttribution.resolve(live: "", perDevice: "", legacyGlobal: "", pairedCount: 1))
    }

    func testThePrefKeyIsPerDeviceAndCaseInsensitiveOnTheAddress() {
        XCTAssertEqual(FirmwareAttribution.prefKey(peripheralId: "F1:D4:F7:24:53:DE"),
                       "noop.lastFirmware.f1:d4:f7:24:53:de")
        XCTAssertEqual(FirmwareAttribution.prefKey(peripheralId: "f1:d4:f7:24:53:de"),
                       FirmwareAttribution.prefKey(peripheralId: "F1:D4:F7:24:53:DE"))
    }

    func testNoAddressMeansNoKey() {
        XCTAssertNil(FirmwareAttribution.prefKey(peripheralId: nil))
        XCTAssertNil(FirmwareAttribution.prefKey(peripheralId: "   "))
    }
}
