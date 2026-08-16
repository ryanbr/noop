import XCTest
@testable import PolarProtocol

/// The PMD control-point command builder + response parse (`PolarPmdControl`). Pure byte work — the
/// cross-platform contract mirrored by `com.noop.polar.PmdControl`. No CoreBluetooth, no hardware.
final class PmdControlTests: XCTestCase {

    func testGetSettingsBytes() {
        XCTAssertEqual(PolarPmdControl.getSettings(.ppi), [0x01, 0x03])
        XCTAssertEqual(PolarPmdControl.getSettings(.ecg), [0x01, 0x00])
    }

    func testStartOnlineNoSettings() {
        // Online streaming (recording=false) → bit 7 clear → the type byte is just the measurement type.
        XCTAssertEqual(PolarPmdControl.start(.ppi), [0x02, 0x03])
        XCTAssertEqual(PolarPmdControl.start(.ecg), [0x02, 0x00])
    }

    func testStartWithSettingsSerialisesU16LEBlocks() {
        // ACC start with sampleRate=52 Hz + range=8 g → [op, type, {0x00,1,52,0}, {0x02,1,8,0}].
        let bytes = PolarPmdControl.start(.acc, settings: [
            .init(.sampleRate, [52]),
            .init(.range, [8]),
        ])
        XCTAssertEqual(bytes, [0x02, 0x02, 0x00, 0x01, 52, 0x00, 0x02, 0x01, 8, 0x00])
    }

    func testStartRecordingSetsBit7() {
        // recording=true rides bit 7 of the type byte; ECG(0x00) → 0x80.
        XCTAssertEqual(PolarPmdControl.start(.ecg, recording: true), [0x02, 0x80])
        XCTAssertEqual(PolarPmdControl.start(.ppi, recording: true), [0x02, 0x83])
    }

    func testStopBytes() {
        XCTAssertEqual(PolarPmdControl.stop(.ppi), [0x03, 0x03])
    }

    func testParseResponseSuccessAndFailure() {
        let ok = PolarPmdControl.parseResponse([0xF0, 0x02, 0x03, 0x00, 0x00])
        XCTAssertEqual(ok?.requestOpcode, 0x02)
        XCTAssertEqual(ok?.measurement, .ppi)
        XCTAssertEqual(ok?.status, 0x00)
        XCTAssertEqual(ok?.isSuccess, true)

        let fail = PolarPmdControl.parseResponse([0xF0, 0x02, 0x03, 0x05])
        XCTAssertEqual(fail?.isSuccess, false)
        XCTAssertEqual(fail?.status, 0x05)
    }

    func testParseResponseRejectsNonResponseFrames() {
        XCTAssertNil(PolarPmdControl.parseResponse([0x00, 0x02, 0x03, 0x00]))   // not the 0xF0 marker
        XCTAssertNil(PolarPmdControl.parseResponse([0xF0, 0x02, 0x03]))         // too short
        XCTAssertNil(PolarPmdControl.parseResponse([]))
    }
}
