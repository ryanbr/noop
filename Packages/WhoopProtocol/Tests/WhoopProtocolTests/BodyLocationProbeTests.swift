import XCTest
@testable import WhoopProtocol

/// #690: the pure formatter for the GET_BODY_LOCATION_AND_STATUS (0x54) probe result. Byte-parity twin of
/// the Kotlin `BodyLocationProbeFormatTest` (same fixtures, same expectations). Fixtures are SYNTHETIC —
/// the wire layout (4-byte revision/location/confidence/status) is RE'd but not yet hardware-captured, so
/// these pin the decode/format contract; a real capture can be added when a strap answers 0x54.
final class BodyLocationProbeTests: XCTestCase {

    private func hexToBytes(_ h: String) -> [UInt8] {
        let c = Array(h)
        return stride(from: 0, to: c.count, by: 2).map {
            UInt8((Int(String(c[$0]), radix: 16)! << 4) | Int(String(c[$0 + 1]), radix: 16)!)
        }
    }

    // WHOOP4-shape frame: cmd 0x54 @6, 4-byte payload [revision=01, location=01 WRIST, confidence=5a=90,
    // status=00], then a 4-byte CRC tail. (deadbeef stands in for the CRC — the formatter never validates it.)
    private let wristFrame = "aa09000024005401015a00deadbeef"

    func testWhoop4_acceptedDecodesTheFourFields() {
        let (text, payHex) = BodyLocationProbe.format(frame: hexToBytes(wristFrame), cmdOff: 6, isWhoop5: false, prevPayloadHex: nil)
        XCTAssertTrue(text.contains("WHOOP 4.0"))
        XCTAssertTrue(text.contains("opcode 84 ACCEPTED — 4-byte payload"))
        XCTAssertTrue(text.contains(wristFrame))                 // full raw hex on one copyable line
        XCTAssertTrue(text.contains("  @00  01 01 5a 00"))       // offset-labelled hex grid
        XCTAssertTrue(text.contains("revision:   1"))
        XCTAssertTrue(text.contains("location:   1  (WRIST)"))
        XCTAssertTrue(text.contains("confidence: 90  (raw)"))    // 0x5a = 90, kept raw
        XCTAssertTrue(text.contains("status:     0  (raw)"))
        XCTAssertTrue(text.contains("first capture"))
        XCTAssertEqual(payHex?.count, 4 * 2)                     // 4-byte payload persisted for the next diff
    }

    func testUnknownLocation_isPreservedAsRawNotCrashedOrCoerced() {
        // location = 6 (the enum gap between GLUTE=5 and ANKLE=7): must NOT crash and must NOT map to a
        // known position — it reads back as raw.
        let (text, _) = BodyLocationProbe.format(frame: hexToBytes("aa09000024005401060000deadbeef"), cmdOff: 6, isWhoop5: false, prevPayloadHex: nil)
        XCTAssertTrue(text.contains("location:   6  (raw6)"))
    }

    func testKnownEnumValues_mapToTheirLabels() {
        for (raw, label) in [(2, "BICEP"), (3, "CALF"), (4, "SIDE_TORSO"), (5, "GLUTE"), (7, "ANKLE"),
                             (128, "NOT_CONCLUSIVE"), (160, "UNKNOWN_GARMENT")] {
            let frame = "aa090000240054" + "01" + String(format: "%02x", raw) + "0000" + "deadbeef"
            let (text, _) = BodyLocationProbe.format(frame: hexToBytes(frame), cmdOff: 6, isWhoop5: false, prevPayloadHex: nil)
            XCTAssertTrue(text.contains("(\(label))"), "location \(raw) should read \(label)")
        }
    }

    func testDiff_flagsTheChangedLocationByte() {
        let first = hexToBytes(wristFrame)
        let (_, prev) = BodyLocationProbe.format(frame: first, cmdOff: 6, isWhoop5: false, prevPayloadHex: nil)
        var second = first
        second[8] = 0x03            // payload offset 1 (location) WRIST(01) → CALF(03)
        let (text, _) = BodyLocationProbe.format(frame: second, cmdOff: 6, isWhoop5: false, prevPayloadHex: prev)
        XCTAssertTrue(text.contains("Δ vs previous capture:"))
        XCTAssertTrue(text.contains("@01:01→03"))
        XCTAssertTrue(text.contains("location:   3  (CALF)"))
    }

    func testBareStub_isCalledOut() {
        // 11-byte frame: cmd 0x54 @6 then ONLY the 4-byte CRC tail ⇒ payEnd(7) == payStart(7) ⇒ no payload.
        let (text, payHex) = BodyLocationProbe.format(frame: hexToBytes("aa0700fa24005446758858"), cmdOff: 6, isWhoop5: false, prevPayloadHex: nil)
        XCTAssertTrue(text.contains("bare stub"))
        XCTAssertNil(payHex)
        // A bare stub is one reply, not a firmware capability. The Verdict line already calls it
        // "ambiguous"; the detail line used to contradict it with "no body-location data on this
        // firmware", which is the conclusion a reader would quote. Neither line may say it. (#914 class)
        XCTAssertTrue(text.contains("ambiguous"), text)
        XCTAssertFalse(text.contains("no body-location data on this firmware"), text)
        XCTAssertTrue(text.contains("not the same as the firmware having none"), text)
    }

    /// Golden FULL-output lock: pins the exact byte-for-byte report so the Swift and Kotlin twins can't
    /// drift on whitespace/labels (the parity contract). The Kotlin `BodyLocationProbeFormatTest` asserts
    /// this identical line-list against `formatBodyLocationProbe`.
    func testFullOutput_goldenParityLock() {
        let (text, _) = BodyLocationProbe.format(frame: hexToBytes(wristFrame), cmdOff: 6, isWhoop5: false, prevPayloadHex: nil)
        let golden = [
            "#690 BODY-LOCATION PROBE — WHOOP 4.0",
            "Verdict: opcode 84 ACCEPTED — 4-byte payload",
            "",
            "Raw frame (15 B):",
            "aa09000024005401015a00deadbeef",
            "",
            "Payload (4 B, CRC excluded):",
            "  @00  01 01 5a 00",
            "",
            "Decoded:",
            "  revision:   1",
            "  location:   1  (WRIST)",
            "  confidence: 90  (raw)",
            "  status:     0  (raw)",
            "",
            "Δ vs previous capture: first capture — probe again in another position to diff",
        ].joined(separator: "\n")
        XCTAssertEqual(text, golden)
    }

    func testWhoop5Success_doesNotMisdecodeTheResultCodeAsAField() {
        // 5/MG SUCCESS(1) with a payload: pay[1] here is the RESULT CODE @12, so decoding the WHOOP4 offsets
        // would falsely read "location: 1 (WRIST)". The formatter must NOT decode on 5/MG — raw grid only.
        let (text, _) = BodyLocationProbe.format(frame: hexToBytes("aa000c000000000000005400010102030405060708090a46758858"), cmdOff: 10, isWhoop5: true, prevPayloadHex: nil)
        XCTAssertTrue(text.contains("Result code @12: SUCCESS(1)"))
        XCTAssertFalse(text.contains("location:"))       // must never present the result code as a location
        XCTAssertTrue(text.contains("unconfirmed"))
    }

    func testWhoop5Unsupported_isDecisiveVerdict() {
        // 5/MG frame with the command byte 0x54 @10 and result code 3 (UNSUPPORTED) @12.
        let (text, _) = BodyLocationProbe.format(frame: hexToBytes("aa000c000000000000005400030046758858"), cmdOff: 10, isWhoop5: true, prevPayloadHex: nil)
        XCTAssertTrue(text.contains("REJECTED by firmware (UNSUPPORTED)"))
        XCTAssertTrue(text.contains("Result code @12: UNSUPPORTED(3)"))
    }
}
