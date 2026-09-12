import XCTest
@testable import WhoopProtocol

/// Tests for classifyHistoricalMeta using real frames built by frameFromPayload (type 49 = METADATA).
///
/// Frame layout: frameFromPayload(data, type:49, seq:0, cmd:N) produces
///   frame[4]=49, frame[5]=0, frame[6]=N (cmd == meta_type byte), frame[7...] = data.
/// MetadataType enum (verified from whoop_protocol.json):
///   1 = HISTORY_START, 2 = HISTORY_END, 3 = HISTORY_COMPLETE
///
/// HISTORY_END post-hook reads `pay = frame[7..<payEnd]` where pay is `<LHLL>` = 14 bytes:
///   pay[0..3]  = unix  (u32 LE)
///   pay[4..5]  = subsec (u16 LE)
///   pay[6..9]  = unk0  (u32 LE)
///   pay[10..13]= trim  (u32 LE)
final class HistoricalMetaTests: XCTestCase {

    // MARK: - helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// Build a parsed METADATA frame with the given cmd byte and optional payload.
    private func metaParsed(cmd: UInt8, payload: [UInt8] = []) -> ParsedFrame {
        let frame = frameFromPayload(payload, type: 49, seq: 0, cmd: cmd)
        return parseFrame(frame)
    }

    // MARK: - HISTORY_START (cmd=1)

    func testHistoryStart() {
        let p = metaParsed(cmd: 1)
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .start)
    }

    // MARK: - HISTORY_END (cmd=2) with known unix + trim

    func testHistoryEnd() {
        let expectedUnix: UInt32 = 1_700_000_000
        let expectedTrim: UInt32 = 9876
        // payload = unix(4) + subsec(2) + unk0(4) + trim(4) = 14 bytes
        let payload: [UInt8] = le32(expectedUnix) + le16(1000) + le32(0xDEAD) + le32(expectedTrim)
        let p = metaParsed(cmd: 2, payload: payload)
        XCTAssertEqual(p.typeName, "METADATA")
        let result = classifyHistoricalMeta(p)
        XCTAssertEqual(result, .end(unix: expectedUnix, trim: expectedTrim))
    }

    func testHistoryEndShortPayload() {
        // Post-hook requires >=14 bytes; a short payload means parsed keys are absent → .other
        let payload: [UInt8] = [0x01, 0x02, 0x03] // too short
        let p = metaParsed(cmd: 2, payload: payload)
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    // MARK: - HISTORY_COMPLETE (cmd=3)

    func testHistoryComplete() {
        let p = metaParsed(cmd: 3)
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .complete)
    }

    // MARK: - non-METADATA frame → .other

    func testNonMetadataFrame() {
        // type 40 = REALTIME_DATA (not METADATA)
        let frame = frameFromPayload([0x01, 0x02, 0x03], type: 40, seq: 0, cmd: 0)
        let p = parseFrame(frame)
        XCTAssertNotEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    // MARK: - unknown meta_type cmd → .other

    func testUnknownMetaType() {
        let p = metaParsed(cmd: 99) // not in MetadataType enum
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    // MARK: - parsed dict sanity checks

    func testHistoryStartParsedDict() {
        // Schema.enumName() appends "(rawValue)" → "HISTORY_START(1)"
        let p = metaParsed(cmd: 1)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_START(1)"))
    }

    func testHistoryEndParsedDict() {
        let unix: UInt32 = 1_600_000_000
        let trim: UInt32 = 42_000
        let payload: [UInt8] = le32(unix) + le16(0) + le32(0) + le32(trim)
        let p = metaParsed(cmd: 2, payload: payload)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_END(2)"))
        XCTAssertEqual(p.parsed["unix"], .int(Int(unix)))
        XCTAssertEqual(p.parsed["trim_cursor"], .int(Int(trim)))
    }

    func testHistoryCompleteParsedDict() {
        // Schema.enumName() appends "(rawValue)" → "HISTORY_COMPLETE(3)"
        let p = metaParsed(cmd: 3)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_COMPLETE(3)"))
    }

    // MARK: - the gate: a metadata frame that is not INTACT classifies as nothing
    //
    // Scenario "Zustandstreibende Tore fordern das volle Urteil / Verlaufs-Metadaten können nicht
    // gefälscht werden". Each frame below is a real, decodable HISTORY_END / HISTORY_COMPLETE broken in
    // exactly ONE way, so what the classifier refuses is attributable. `.end`/`.complete` are the two
    // results that advance the trim cursor and ack the strap to free its records, which is why they are
    // the ones a forged frame must never reach.

    /// Header checksum wrong, payload CRC32 RIGHT — the class that passed every gate before this change.
    func testHistoryEndWithABrokenHeaderChecksumIsNotClassified() {
        let payload: [UInt8] = le32(1_700_000_000) + le16(0) + le32(0) + le32(4242)
        var frame = frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
        frame[3] ^= 0xFF                       // CRC-8 over the length field only
        let p = parseFrame(frame)
        XCTAssertEqual(p.crcOK, true, "precondition: only the HEADER checksum is broken")
        XCTAssertEqual(p.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(p.typeName, "METADATA", "the frame stays readable for an inspector …")
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_END(2)"), "… including its meta type")
        XCTAssertEqual(classifyHistoricalMeta(p), .other,
                       "… but it must not advance the trim cursor or ack the strap")
    }

    func testHistoryCompleteWithABrokenHeaderChecksumIsNotClassified() {
        var frame = frameFromPayload([], type: 49, seq: 0, cmd: 3)
        frame[3] ^= 0xFF
        let p = parseFrame(frame)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_COMPLETE(3)"))
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    /// Declared length below the WHOOP 4.0 minimum of 11 total bytes. The bytes are all still there —
    /// only the length word claims a frame too small to hold an inner record.
    func testHistoryEndWithADeclaredLengthBelowTheMinimumIsNotClassified() {
        let payload: [UInt8] = le32(1_700_000_000) + le16(0) + le32(0) + le32(4242)
        var frame = frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
        frame[1] = 6; frame[2] = 0                     // declared 6 → total 10, below the 11-byte floor
        frame[3] = crc8(frame, 1, 3)                   // …with a CORRECT header checksum for that word
        let p = parseFrame(frame)
        XCTAssertEqual(p.rejectReason, .belowMinimumLength)
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    /// The CRC32 trailer is cut off: the declared length promises four bytes that are not there.
    func testHistoryEndWithATruncatedTrailerIsNotClassified() {
        let payload: [UInt8] = le32(1_700_000_000) + le16(0) + le32(0) + le32(4242)
        let full = frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
        let cut = Array(full.dropLast(2))              // still >= 11 bytes, so it parses
        let p = parseFrame(cut)
        XCTAssertEqual(p.rejectReason, .lengthMismatch)
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_END(2)"),
                       "precondition: without the gate this frame WOULD be read as a history end")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    /// Trailing bytes past the frame's own end — the other half of the exact-length rule.
    func testHistoryCompleteWithTrailingBytesIsNotClassified() {
        let frame = frameFromPayload([], type: 49, seq: 0, cmd: 3) + [0x00, 0x00]
        let p = parseFrame(frame)
        XCTAssertEqual(p.rejectReason, .lengthMismatch)
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    /// The counterpart that must NOT regress: the smallest REAL metadata frames in the capture corpus
    /// sit exactly on the 11-byte minimum, with the meta type in their last payload byte. If the bound
    /// or the gate were one byte stricter, the offload would never see a history end and never finish.
    func testRealElevenByteMetadataFramesStillClassify() {
        let start = FrameIntegrityTests.hex(FrameIntegrityTests.w4MetaHistoryStart11)
        let complete = FrameIntegrityTests.hex(FrameIntegrityTests.w4MetaHistoryComplete11)
        XCTAssertEqual(classifyHistoricalMeta(parseFrame(start)), .start)
        XCTAssertEqual(classifyHistoricalMeta(parseFrame(complete)), .complete)
    }

    /// And the real 25-byte HISTORY_END still yields its unix + trim cursor.
    func testRealHistoryEndFrameStillClassifies() {
        let p = parseFrame(FrameIntegrityTests.hex(FrameIntegrityTests.w4HistoryEnd25))
        guard case .end(let unix, let trim) = classifyHistoricalMeta(p) else {
            return XCTFail("the real HISTORY_END frame must still classify as an end, got \(classifyHistoricalMeta(p))")
        }
        XCTAssertEqual(unix, 1_700_000_000)
        XCTAssertEqual(trim, 12345)
    }

    // MARK: - a metadata TYPE is never read out of the CRC32 trailer (D7, shared with package 1)

    /// Scenario "Kein Byte des CRC-Anhangs wird als Metadatentyp gelesen". This 14-byte WHOOP 5.0 frame
    /// is fully INTACT — correct header checksum, correct CRC32, exact length — and the first byte of
    /// its own trailer sits where the metadata type would be read, carrying the value 3
    /// (HISTORY_COMPLETE). Only the payload bound stops it, so this is the case that would end an
    /// offload on a forged frame the integrity gate cannot object to.
    func testWhoop5FrameAtTheMinimumCannotFakeHistoryComplete() {
        let frame = FrameIntegrityTests.hex(FrameIntegrityTests.w5Meta14FakesHistoryComplete)
        let p = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(p.ok, "precondition: the gate has no objection to this frame at all")
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertNil(p.parsed["meta_type"], "the type byte would come from the CRC32 trailer")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    func testWhoop5FrameAtTheMinimumLengthClassifiesAsNothing() {
        let p = parseFrame(FrameIntegrityTests.hex(FrameIntegrityTests.w5Min13Metadata), family: .whoop5)
        XCTAssertTrue(p.ok, "precondition: 13 bytes is the family minimum, not a rejection")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }
}
