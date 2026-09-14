import XCTest
@testable import OuraProtocol

/// Pins the `0x20` user-info setters against the shapes [open_oura-cheat] records as tested-success
/// on a Ring 3, and guards the encoding helpers that turn a NOOP profile into value bytes.
final class UserInfoTests: XCTestCase {

    private func hex(_ c: OuraCommand) -> String {
        c.bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The five zero-writes upstream actually put on a ring and got `result 0` back for. If any of
    /// these strings changes, our builder has drifted from the only shapes known to be accepted.
    func testClearCommandsMatchTheUpstreamTestedShapes() {
        XCTAssertEqual(hex(OuraUserInfoWrite.clear(.gender)),      "2003020000")
        XCTAssertEqual(hex(OuraUserInfoWrite.clear(.height)),      "200403000000")
        XCTAssertEqual(hex(OuraUserInfoWrite.clear(.weight)),      "200404000000")
        XCTAssertEqual(hex(OuraUserInfoWrite.clear(.unit)),        "2003060000")
        XCTAssertEqual(hex(OuraUserInfoWrite.clear(.dateOfBirth)), "200a05000000000000000000")
    }

    /// `len` is 1 (the type byte) + the field's value width, for every field.
    func testLengthByteCountsTypePlusValue() {
        for field in OuraUserInfoField.allCases {
            let bytes = OuraUserInfoWrite.clear(field).bytes
            XCTAssertEqual(bytes[0], 0x20, "\(field) opcode")
            XCTAssertEqual(Int(bytes[1]), 1 + field.valueByteCount, "\(field) len")
            XCTAssertEqual(bytes[2], field.rawValue, "\(field) type")
            XCTAssertEqual(bytes.count, 2 + 1 + field.valueByteCount, "\(field) total")
        }
    }

    /// The candidate encoding: whole cm / whole kg, little-endian. 175 -> af 00 00, 62 -> 3e 00 00.
    func testProfileValuesEncodeLittleEndianInWholeUnits() throws {
        XCTAssertEqual(hex(try OuraUserInfoWrite.height(cm: 175)), "200403af0000")
        XCTAssertEqual(hex(try OuraUserInfoWrite.weight(kg: 62)),  "2004043e0000")
        // A value that needs a second byte must land in the second byte, not be truncated.
        XCTAssertEqual(try OuraUserInfoWrite.encodeLE(300, width: 3), [0x2C, 0x01, 0x00])
    }

    /// Truncation would put a plausible-looking wrong number on the ring, so it must throw instead.
    func testOverWideValueThrowsRatherThanTruncating() {
        XCTAssertThrowsError(try OuraUserInfoWrite.encodeLE(256, width: 1)) { error in
            XCTAssertEqual(error as? OuraUserInfoError, .valueOutOfRange(value: 256, width: 1))
        }
        XCTAssertEqual(try? OuraUserInfoWrite.encodeLE(255, width: 1), [0xFF])
    }

    /// A wrong-width value is an untested wire shape and must never be built.
    func testWrongValueWidthThrows() {
        XCTAssertThrowsError(try OuraUserInfoWrite.command(.height, value: [0x01])) { error in
            XCTAssertEqual(error as? OuraUserInfoError,
                           .wrongValueWidth(field: .height, expected: 3, got: 1))
        }
    }

    /// male/female map to the `0x5c` codes; everything else takes the ring's own neutral path.
    func testGenderCodeMapping() {
        XCTAssertEqual(OuraUserInfoWrite.genderCode(forSex: "male"), 0)
        XCTAssertEqual(OuraUserInfoWrite.genderCode(forSex: "female"), 1)
        XCTAssertEqual(OuraUserInfoWrite.genderCode(forSex: "nonbinary"), 2)
        XCTAssertEqual(OuraUserInfoWrite.genderCode(forSex: "Male"), 0, "case-insensitive")
        XCTAssertEqual(OuraUserInfoWrite.genderCode(forSex: ""), 2, "unset is unspecified")
    }

    /// Age has no setter - the builder returns nil rather than inventing a DOB layout.
    func testNoAgeSetterIsOfferedYet() {
        XCTAssertNil(OuraUserInfoWrite.dateOfBirthCommand(year: 1963, month: 5, day: 27))
    }

    /// The `0x21` ack parses only its exact shape.
    func testAckParsing() {
        XCTAssertEqual(parseOuraUserInfoAck([0x21, 0x02, 0x03, 0x00]),
                       OuraUserInfoAck(field: .height, result: 0))
        XCTAssertEqual(parseOuraUserInfoAck([0x21, 0x02, 0x04, 0x07])?.isSuccess, false)
        XCTAssertNil(parseOuraUserInfoAck([0x21, 0x02, 0x99, 0x00]), "unknown field type")
        XCTAssertNil(parseOuraUserInfoAck([0x21, 0x02, 0x03]), "short frame")
        XCTAssertNil(parseOuraUserInfoAck([0x2F, 0x02, 0x03, 0x00]), "not a 0x21 frame")
    }

    /// Every builder is labelled EXPERIMENT_ so a strap log never reads as routine traffic.
    func testAllWritesAreLabelledExperiment() {
        for field in OuraUserInfoField.allCases {
            XCTAssertTrue(OuraUserInfoWrite.clear(field).label.hasPrefix("EXPERIMENT_"),
                          "\(field) label: \(OuraUserInfoWrite.clear(field).label)")
        }
    }

    // MARK: - 0x5c read-back

    /// The record every capture of this ring has produced, decoded under [open_oura-evt]'s inference.
    func testDecodesTheObservedDefaultRecord() {
        let bytes: [UInt8] = [0x5C, 0x08, 0xFC, 0xEA, 0x5D, 0x01, 0x28, 0x4B, 0x02, 0xB0]
        let recs = scanOuraUserInfoRecords(tlvBytes: bytes)
        XCTAssertEqual(recs.count, 1)
        let r = try! XCTUnwrap(recs.first)
        XCTAssertEqual(r.ringTimestamp, 0x015D_EAFC)
        XCTAssertEqual(r.ageYears, 40)
        XCTAssertEqual(r.weightKg, 75)
        XCTAssertEqual(r.sexCode, 2)
        XCTAssertEqual(r.heightCm, 176)
        XCTAssertEqual(r.rawHex, "284b02b0")
        XCTAssertTrue(r.isFirmwareDefault)
    }

    /// A written-through value must read back as NOT the default - that is the experiment's readout.
    func testANonDefaultRecordIsNotFlaggedDefault() {
        let bytes: [UInt8] = [0x5C, 0x08, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x3E, 0x00, 0xAF]
        let r = try! XCTUnwrap(scanOuraUserInfoRecords(tlvBytes: bytes).first)
        XCTAssertEqual([r.ageYears, r.weightKg, r.sexCode, r.heightCm], [63, 62, 0, 175])
        XCTAssertFalse(r.isFirmwareDefault)
    }

    /// The scanner walks a concatenated notification and picks 0x5c out from among other tags.
    func testScannerFindsTheRecordAmongOtherTags() {
        let bytes: [UInt8] = [0x43, 0x03, 0x01, 0x02, 0x03]           // some other tag
            + [0x5C, 0x08, 0x01, 0x00, 0x00, 0x00, 0x28, 0x4B, 0x02, 0xB0]
            + [0x4A, 0x04, 0x00, 0x00, 0x00, 0x00]                     // and another
        let recs = scanOuraUserInfoRecords(tlvBytes: bytes)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.heightCm, 176)
    }

    /// A truncated tail must stop the walk, never crash - this runs on every inbound notification.
    func testTruncatedTailIsIgnoredNotFatal() {
        XCTAssertEqual(scanOuraUserInfoRecords(tlvBytes: [0x5C, 0x08, 0x01, 0x02]).count, 0)
        XCTAssertEqual(scanOuraUserInfoRecords(tlvBytes: []).count, 0)
        XCTAssertEqual(scanOuraUserInfoRecords(tlvBytes: [0x5C]).count, 0)
    }
}
