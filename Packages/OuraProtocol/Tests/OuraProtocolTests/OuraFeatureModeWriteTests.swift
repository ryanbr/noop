import XCTest
@testable import OuraProtocol

/// The feature-mode WRITE (`2f 03 22 <id> <mode>`) and its generalized status read (`2f 02 20 <id>`) —
/// UNVALIDATED on NOOP's own hardware (OURA_PROTOCOL.md s7.5). These builders are pure byte construction;
/// they carry no gate of their own, so the caller (Test Centre only, per the plan) is what keeps this
/// off the automatic connect path.
final class OuraFeatureModeWriteTests: XCTestCase {
    func testFeatureReadStatusGeneralizesTheExistingSpo2AndRealStepsProbes() {
        XCTAssertEqual(OuraCommands.featureReadStatus(OuraCommands.featureSpO2).bytes,
                       OuraCommands.spo2ReadStatus().bytes)
        XCTAssertEqual(OuraCommands.featureReadStatus(OuraCommands.featureRealSteps).bytes,
                       OuraCommands.realStepsReadStatus().bytes)
    }

    func testSetFeatureModeBytesExactForSpo2AndRealSteps() {
        XCTAssertEqual(OuraCommands.setFeatureMode(OuraCommands.featureSpO2, mode: 0x01).bytes,
                       [0x2F, 0x03, 0x22, 0x04, 0x01])
        XCTAssertEqual(OuraCommands.setFeatureMode(OuraCommands.featureRealSteps, mode: 0x00).bytes,
                       [0x2F, 0x03, 0x22, 0x0B, 0x00])
    }

    func testSetFeatureModeBytesExactForExerciseHrAndCvaPpg() {
        XCTAssertEqual(OuraCommands.setFeatureMode(OuraCommands.featureExerciseHR, mode: 0x01).bytes,
                       [0x2F, 0x03, 0x22, 0x03, 0x01])
        XCTAssertEqual(OuraCommands.setFeatureMode(OuraCommands.featureCvaPpg, mode: 0x00).bytes,
                       [0x2F, 0x03, 0x22, 0x0D, 0x00])
    }

    func testSetFeatureModeSubOpIsTheEnableVerbNotTheReadVerb() {
        // sub-op 0x22 is the SET-MODE write; 0x20 (used by featureReadStatus) is the READ. Never confuse them.
        XCTAssertEqual(OuraCommands.setFeatureMode(OuraCommands.featureSpO2, mode: 0x01).bytes[2], 0x22)
        XCTAssertEqual(OuraCommands.featureReadStatus(OuraCommands.featureSpO2).bytes[2], 0x20)
    }
}
