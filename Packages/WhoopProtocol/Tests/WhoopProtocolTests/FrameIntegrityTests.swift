import XCTest
@testable import WhoopProtocol

/// The frame-integrity contract: the parse result carries the verifier's FULL verdict plus a
/// non-optional reason, the structural bounds are enforced per device family, and a named inner
/// field is only ever read out of payload bytes.
///
/// Every synthetic frame below is built the way a strap builds one (real CRC-8 / CRC-16-Modbus
/// header checksum, real zlib CRC32 payload trailer, exact declared length) and then broken in
/// exactly ONE way, so each assertion attributes a single cause. The frames taken from the capture
/// corpus are marked as such.
final class FrameIntegrityTests: XCTestCase {

    static func hex(_ s: String) -> [UInt8] { FramingTests.hex(s) }

    // MARK: - Fixtures

    /// Real captured WHOOP 4.0 REALTIME_DATA frame (28 bytes), fully valid.
    static let w4Valid = "aa1800ff28020f3de10128663c0000000000000000000000da855212"
    /// Real captured WHOOP 4.0 METADATA frames. The 11-byte ones sit EXACTLY on the family minimum
    /// and their `meta_type` occupies the last payload byte — the case that fixes the bound's
    /// comparison form ("start + length must not exceed the limit").
    static let w4MetaHistoryStart11 = "aa07006b3100012366efad"
    static let w4MetaHistoryComplete11 = "aa07006b3100030f07e143"
    /// Real captured 25-byte HISTORY_END frame. Its CRC32 trailer starts at 21, and the 8-byte
    /// acknowledgement block the strap echoes back runs from 17 to 25 — into the trailer.
    static let w4HistoryEnd25 = "aa15001631000200f1536500000000000039300000c3401bdb"
    /// Synthetic, fully valid WHOOP 5.0/MG COMMAND_RESPONSE frame (20 bytes).
    static let w5Valid = "aa010c000001e74124070211223344557481f36e"

    /// Total 8, 9 and 10 bytes: declared lengths 4, 5 and 6. Each carries a correct header checksum
    /// and a correct CRC32 over its (0-2 byte) inner record, so ONLY the structural minimum rejects
    /// them — which is the point.
    static let w4Total8 = "aa04005400000000"
    static let w4Total9 = "aa05004131b7efdc83"
    static let w4Total10 = "aa06007e31004d158487"
    /// Total 12 bytes (declared 4): a WHOOP 5.0 frame one byte below the minimum, again with both
    /// checksums correct. Its byte at offset 8 — the inner packet type — is the first byte of its
    /// own CRC32 trailer.
    static let w5Total12 = "aa0104000001e52100000000"

    /// Exactly 13 bytes (declared 5): valid header checksum, valid CRC32 over its single payload
    /// byte, exact length. It PASSES the tightened gate; the sequence number, command byte and
    /// metadata type it appears to carry are all inside its CRC32 trailer.
    static let w5Min13Metadata = "aa0105000001e4dd31b7efdc83"
    /// The same frame at 14 bytes (declared 6). It is fully valid AND the first byte of its trailer
    /// reads 3 = HISTORY_COMPLETE at the metadata-type offset — the forgery F-05 describes. The
    /// sequence number at offset 9 is now a genuine payload byte and must still decode.
    static let w5Meta14FakesHistoryComplete = "aa0106000001e49931530315e675"

    /// WHOOP 4.0 REALTIME_DATA with a SHORTENED inner record: 14 bytes, declared length 10, so the
    /// trailer starts at 10 and everything the schema places at 10 or beyond is trailer, not data.
    static let w4ShortRealtime14 = "aa0a0082280111223344854deb31"
    /// 11 bytes present, declared length 61440. Structurally the frame claims ~60 KB it does not
    /// have; the bound must fall back on the bytes that exist.
    static let w4HugeDeclared11 = "aa00f0de31000102030405"

    private func corrupt(_ hexString: String, at index: Int) -> [UInt8] {
        var f = Self.hex(hexString)
        f[index] ^= 0xFF
        return f
    }

    // MARK: - Vollständiges Integritätsurteil im Parse-Ergebnis

    func testWhoop4HeaderChecksumWrongPayloadCRCRightIsRejected() {
        let frame = corrupt(Self.w4Valid, at: 3)
        let parsed = parseFrame(frame)
        XCTAssertFalse(parsed.ok, "a broken header checksum must not yield a positive verdict")
        XCTAssertEqual(parsed.rejectReason, .headerChecksumMismatch)
        // The payload CRC32 is untouched — this is exactly the class that passed the gates before.
        XCTAssertEqual(parsed.crcOK, true)
        // …and the frame stays readable for an inspector.
        XCTAssertEqual(parsed.typeName, "REALTIME_DATA")
    }

    func testWhoop5HeaderChecksumWrongPayloadCRCRightIsRejected() {
        let frame = corrupt(Self.w5Valid, at: 6)
        let parsed = parseFrame(frame, family: .whoop5)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.typeName, "COMMAND_RESPONSE")
    }

    func testPayloadCRCThatCannotBeComputedIsNegativeNotUnknown() {
        // Too short for a CRC32 over any payload byte at all.
        let parsed = parseFrame(Self.hex(Self.w4Total8))
        XCTAssertFalse(parsed.ok, "an uncomputable payload CRC must never read as a pass")
        XCTAssertNil(parsed.crcOK, "the tri-state stays honest: the CRC is unknown …")
        XCTAssertEqual(parsed.rejectReason, .belowMinimumLength, "… but the verdict is not")
    }

    func testFullyValidFrameKeepsItsPositiveVerdictAndFields() {
        let parsed = parseFrame(Self.hex(Self.w4Valid))
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.rejectReason, .none)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.typeName, "REALTIME_DATA")
        XCTAssertEqual(parsed.seq, 2)
        XCTAssertEqual(parsed.parsed["heart_rate"], .int(60))

        let five = parseFrame(Self.hex(Self.w5Valid), family: .whoop5)
        XCTAssertTrue(five.ok)
        XCTAssertEqual(five.rejectReason, .none)
        XCTAssertEqual(five.seq, 7)
    }

    // MARK: - Ablehnungsgrund liegt am Parse-Ergebnis an

    func testConsumerReadsTheReasonFromTheParseResultAlone() {
        // A consumer sees only what it was handed — no frame bytes, no second verify, no second
        // parse. That is the whole point of carrying the reason on the result.
        func report(_ parsed: ParsedFrame) -> FrameRejectReason { parsed.rejectReason }
        XCTAssertEqual(report(parseFrame(corrupt(Self.w4Valid, at: 3))), .headerChecksumMismatch)
        XCTAssertEqual(report(parseFrame(corrupt(Self.w4Valid, at: 10))), .payloadCRCMismatch)
    }

    func testEveryRejectionReasonIsDistinguishable() {
        var wrongSOF = Self.hex(Self.w4Valid)
        wrongSOF[0] = 0x00
        let trailing = Self.hex(Self.w4Valid) + [0x00]

        let reasons: [FrameRejectReason] = [
            parseFrame(wrongSOF).rejectReason,
            parseFrame(Self.hex(Self.w4Total10)).rejectReason,
            parseFrame(trailing).rejectReason,
            parseFrame(corrupt(Self.w4Valid, at: 3)).rejectReason,
            parseFrame(corrupt(Self.w4Valid, at: 10)).rejectReason,
            parseFrame(Self.hex(Self.w4Valid)).rejectReason,
        ]
        XCTAssertEqual(reasons, [.noStartOfFrame, .belowMinimumLength, .lengthMismatch,
                                 .headerChecksumMismatch, .payloadCRCMismatch, .none])
        XCTAssertEqual(Set(reasons).count, reasons.count, "the reasons must not collapse into each other")
        // The seventh reason exists so an uncomputable CRC can never be reported as a wrong one. The
        // structural rules above make it unreachable from the verifier today; it is a fail-closed
        // default, and this pins that it is a value of its own rather than an alias.
        XCTAssertFalse(reasons.contains(.payloadCRCUnverifiable))
        XCTAssertEqual(FrameRejectReason.allCases.count, 7)
    }

    func testValidFrameCarriesNoReason() {
        XCTAssertEqual(parseFrame(Self.hex(Self.w4Valid)).rejectReason, .none)
        XCTAssertEqual(parseFrame(Self.hex(Self.w5Valid), family: .whoop5).rejectReason, .none)
        XCTAssertEqual(verifyFrame(Self.hex(Self.w4Valid)).reason, .none)
    }

    func testMissingReasonInAnOlderSerialisedResultDecodesAsNone() throws {
        // Capture files and hand-written fixtures predate the field; decoding must not turn strict.
        let json = Data("""
        {"ok":true,"typeName":"REALTIME_DATA","crcOK":true,"lenBytes":28,"rawHex":"",
         "fields":[],"parsed":{}}
        """.utf8)
        let decoded = try JSONDecoder().decode(ParsedFrame.self, from: json)
        XCTAssertEqual(decoded.rejectReason, .none)
    }

    // MARK: - Strukturelle Mindest- und Genaulänge je Gerätefamilie

    func testWhoop4BelowMinimumLengthIsRejectedWithoutReadingAPacketType() {
        for h in [Self.w4Total8, Self.w4Total9, Self.w4Total10] {
            let frame = Self.hex(h)
            let check = verifyFrame(frame)
            XCTAssertFalse(check.ok, "\(h) is below the 11-byte minimum")
            XCTAssertEqual(check.reason, .belowMinimumLength, "\(h)")
            let parsed = parseFrame(frame, collectFields: true)
            XCTAssertFalse(parsed.ok, "\(h)")
            XCTAssertEqual(parsed.typeName, "INVALID/FRAGMENT", "no packet type is read out of \(h)")
            XCTAssertTrue(parsed.fields.isEmpty, "\(h)")
            XCTAssertTrue(parsed.parsed.isEmpty, "\(h)")
        }
    }

    func testWhoop5BelowMinimumLengthIsRejectedInsteadOfReadingTheTrailer() {
        let frame = Self.hex(Self.w5Total12)
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.reason, .belowMinimumLength)
        // Its header checksum is genuinely correct (recomputed here, since a frame this short is not
        // read at all any more), so only the structural minimum stands between it and the gates —
        // and its "inner packet type" would be the first byte of its own CRC32 trailer.
        XCTAssertEqual(crc16Modbus(Array(frame[0..<6])), UInt16(frame[6]) | (UInt16(frame[7]) << 8))
        XCTAssertNil(check.crc8OK, "nothing is read out of a frame below the minimum")
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        XCTAssertEqual(parsed.typeName, "INVALID/FRAGMENT")
        XCTAssertTrue(parsed.parsed.isEmpty)
    }

    func testFramesExactlyAtEachFamilyMinimumStayValid() {
        // 11 bytes, from the capture corpus — the smallest real WHOOP 4.0 frame there is.
        let w4 = Self.hex(Self.w4MetaHistoryStart11)
        XCTAssertEqual(w4.count, FrameLimits.whoop4MinimumFrameBytes)
        XCTAssertTrue(verifyFrame(w4).ok)
        // Its metadata type occupies the LAST payload byte; the bound must not swallow it, or the
        // offload would never learn that a chunk ended.
        XCTAssertEqual(parseFrame(w4).parsed["meta_type"], .string("HISTORY_START(1)"))

        let w5 = Self.hex(Self.w5Min13Metadata)
        XCTAssertEqual(w5.count, FrameLimits.whoop5MinimumFrameBytes)
        XCTAssertTrue(verifyFrame(w5, family: .whoop5).ok)
    }

    func testOneByteTooManyIsRejected() {
        for (h, family) in [(Self.w4Valid, DeviceFamily.whoop4), (Self.w5Valid, .whoop5)] {
            let frame = Self.hex(h) + [0x00]
            let check = verifyFrame(frame, family: family)
            XCTAssertFalse(check.ok, "trailing bytes must be rejected (\(family))")
            XCTAssertEqual(check.reason, .lengthMismatch, "\(family)")
            // The payload CRC still verifies — the envelope is what is wrong, and the diagnostic
            // must say so rather than blame the payload.
            XCTAssertEqual(check.crc32OK, true, "\(family)")
            XCTAssertFalse(parseFrame(frame, family: family).ok, "\(family)")
        }
    }

    func testOneByteTooFewIsRejected() {
        for (h, family) in [(Self.w4Valid, DeviceFamily.whoop4), (Self.w5Valid, .whoop5)] {
            let frame = Array(Self.hex(h).dropLast())
            let check = verifyFrame(frame, family: family)
            XCTAssertFalse(check.ok, "a truncated frame must be rejected (\(family))")
            XCTAssertEqual(check.reason, .lengthMismatch, "\(family)")
            XCTAssertNil(check.crc32OK, "a CRC over bytes we do not have is not computed (\(family))")
            XCTAssertFalse(parseFrame(frame, family: family).ok, "\(family)")
        }
    }

    // MARK: - Innere Felder werden nur aus Nutzdatenbytes gelesen

    func testWhoop5AtTheMinimumDecodesNoSequenceCommandOrMetadataField() {
        let frame = Self.hex(Self.w5Min13Metadata)
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        // It passes the gate — which is exactly why the field bound has to hold on its own.
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.typeName, "METADATA")
        XCTAssertNil(parsed.seq, "offset 9 is the first byte of the CRC32 trailer")
        XCTAssertNil(parsed.parsed["meta_type"], "offset 10 is trailer, not a metadata type")
        XCTAssertNil(parsed.parsed["cmd"])
        XCTAssertFalse(parsed.fields.contains { $0.name == "seq" })
    }

    func testWhoop5OneByteAboveTheMinimumDecodesTheSequenceButNotTheMetadataType() {
        let frame = Self.hex(Self.w5Meta14FakesHistoryComplete)
        XCTAssertEqual(frame.count, 14)
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        XCTAssertTrue(parsed.ok, "the frame is fully valid — nothing but the bound protects it")
        // Offset 9 is now a genuine payload byte.
        XCTAssertEqual(parsed.seq, 83)
        // Offset 10 holds 0x03 — the byte that means HISTORY_COMPLETE — but it is the first byte of
        // the CRC32 trailer, so no metadata type is decoded from it.
        XCTAssertEqual(frame[10], 3)
        XCTAssertNil(parsed.parsed["meta_type"],
                     "a frame must not be able to forge a chunk state out of its own checksum")
        XCTAssertNil(parsed.parsed["cmd"])
    }

    func testWhoop4WithAShortenedInnerRecordStopsAtTheTrailer() {
        let frame = Self.hex(Self.w4ShortRealtime14)
        XCTAssertEqual(frame.count, 14)
        let parsed = parseFrame(frame, collectFields: true)
        XCTAssertTrue(parsed.ok, "valid header checksum, valid CRC32, exact length")
        XCTAssertEqual(parsed.typeName, "REALTIME_DATA")
        // The declared length is 10, so the trailer starts at 10.
        XCTAssertEqual(parsed.parsed["timestamp"], .int(0x44332211), "offset 6..10 is payload")
        XCTAssertNil(parsed.parsed["subseconds"], "offset 10 is trailer")
        XCTAssertNil(parsed.parsed["heart_rate"], "offset 12 is trailer")
        XCTAssertNil(parsed.parsed["rr_count"], "offset 13 is trailer")
    }

    func testDeclaredLengthFarBeyondTheBytesReadsNothingThatIsNotThere() {
        // 11 bytes present, ~60 KB declared. The bound is the MINIMUM of the trailer start and the
        // real size, so it falls back on the 11 bytes we hold. Reaching for the declared trailer
        // start instead would read off the end of the buffer.
        let frame = Self.hex(Self.w4HugeDeclared11)
        let check = verifyFrame(frame)
        XCTAssertEqual(check.length, 61440)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.reason, .lengthMismatch)
        XCTAssertNil(check.crc32OK)
        let parsed = parseFrame(frame, collectFields: true)
        XCTAssertFalse(parsed.ok)
        for field in parsed.fields {
            XCTAssertLessThanOrEqual(field.off + field.len, frame.count,
                                     "field \(field.name) reaches past the bytes we hold")
        }
        // The same shape below the family minimum — the usual on-the-wire case, a fragment whose
        // length word promises thousands of bytes — decodes no field at all.
        let fragment = Array(frame.dropLast())
        let fragmentParsed = parseFrame(fragment, collectFields: true)
        XCTAssertTrue(fragmentParsed.fields.isEmpty)
        XCTAssertTrue(fragmentParsed.parsed.isEmpty)
        XCTAssertEqual(fragmentParsed.rejectReason, .belowMinimumLength)
    }

    func testAcknowledgementBlockOfTheRealHistoryEndFrameIsUnchanged() {
        // The 8-byte block the trim acknowledgement mirrors back to the strap is NOT a decoded
        // field: it is an opaque echo, and by construction it reaches into the CRC32 trailer. The
        // field bound must never be applied to it — a clipped block either makes the strap refuse
        // the acknowledgement (the offload stops) or makes it trim on altered bytes.
        let frame = Self.hex(Self.w4HistoryEnd25)
        XCTAssertEqual(frame.count, 25)
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 21, "the CRC32 trailer starts at 21 …")
        // … and the block runs 17..25, four bytes of it inside that trailer. Derive the block from
        // the frame rather than from a second literal: comparing one spelling of the fixture with
        // another cannot fail, and this assertion exists to fail when a later tidy-up narrows the
        // block. The literal pin stays as the byte-level record of what the strap is echoed.
        let ackStart = 25 - 8
        let block = Array(frame.suffix(8))
        XCTAssertEqual(block, Array(frame[ackStart..<25]))
        XCTAssertEqual(block, Self.hex("39300000c3401bdb"))
        // The exception has to BE an exception: the block must straddle the D7 bound, or this test
        // would be pinning an ordinary payload read and would go on passing after a clip.
        let bound = check.length!
        XCTAssertLessThan(ackStart, bound, "the block starts inside the payload …")
        XCTAssertGreaterThan(25, bound, "… and ends inside the CRC32 trailer")
        // What a clipped block would look like, spelled out so the difference is not a matter of
        // reading: applying the field bound would hand the strap four bytes instead of eight.
        XCTAssertNotEqual(block, Array(frame[ackStart..<min(25, bound)]))
        XCTAssertEqual(Array(frame[ackStart..<min(25, bound)]).count, 4)
        // The extraction itself lives in `Strand/Collect/Backfiller.swift` (`endData(from:family:)`,
        // start 17), which belongs to package 2 — its caller-side proof is owed there, not here.
        // The trim cursor is the block's first u32 and lies in the payload, so it still decodes.
        XCTAssertEqual(parseFrame(frame).parsed["trim_cursor"], .int(0x3039))
        XCTAssertEqual(parseFrame(frame).parsed["meta_type"], .string("HISTORY_END(2)"))
    }

    // MARK: - Zusammensetzer gibt keinen unterlangen Rahmen aus

    func testReassemblerDropsAnUndersizedStartOfFrameAndResyncs() {
        let undersized = Self.hex(Self.w4Total8)     // declares a total of 8 bytes
        let valid = Self.hex(Self.w4Valid)
        let r = Reassembler()
        let out = r.feed(undersized + valid)
        XCTAssertEqual(out, [valid], "only the complete valid frame may be emitted")
        XCTAssertEqual(r.belowMinimumLengthDrops, 1,
                       "the discarded byte run is counted, not silently dropped")
    }

    func testWhoop5ReassemblerDropsAnUndersizedStartOfFrameAndResyncs() {
        let undersized = Self.hex(Self.w5Total12)    // declares a total of 12 bytes
        let valid = Self.hex(Self.w5Valid)
        let r = Reassembler(family: .whoop5)
        XCTAssertEqual(r.feed(undersized + valid), [valid])
        XCTAssertEqual(r.belowMinimumLengthDrops, 1)
    }

    func testReassemblerLeavesFragmentedDeliveryByteIdentical() {
        let valid = Self.hex(Self.w4Valid)
        let r = Reassembler()
        var out: [[UInt8]] = []
        for chunk in stride(from: 0, to: valid.count, by: 5) {
            out += r.feed(Array(valid[chunk..<min(chunk + 5, valid.count)]))
        }
        XCTAssertEqual(out, [valid])
        XCTAssertEqual(r.belowMinimumLengthDrops, 0)
    }

    // MARK: - Echte aufgezeichnete Rahmen bleiben gültig

    private struct HexEntry: Decodable { let hex: String }
    private struct FamilyHexEntry: Decodable { let hex: String; let family: String? }
    private struct DecoderOracleFile: Decodable { let frames: [FamilyHexEntry] }
    private struct OpticalOracleFile: Decodable { let records: [HexEntry] }

    private func resource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"),
                                "missing \(name).json test resource")
        return try Data(contentsOf: url)
    }

    /// Every real frame the package's capture corpus holds must keep a POSITIVE verdict under the
    /// tightened rules — minimum length, exact length, header checksum and payload CRC32 together.
    /// This is the regression guard for the whole change: the corpus is what a strap actually sent.
    func testEveryRecordedFrameInTheCorpusStaysValid() throws {
        var checked = 0
        func assertValid(_ hexString: String, _ family: DeviceFamily, _ label: String) {
            let frame = Self.hex(hexString)
            let check = verifyFrame(frame, family: family)
            XCTAssertTrue(check.ok, "\(label) (\(frame.count) B) rejected: \(check.reason)")
            XCTAssertEqual(check.reason, .none, "\(label)")
            XCTAssertTrue(parseFrame(frame, family: family).ok, "\(label)")
            checked += 1
        }

        let dec = JSONDecoder()
        for (i, e) in try dec.decode([HexEntry].self, from: resource("frames")).enumerated() {
            assertValid(e.hex, .whoop4, "frames.json #\(i)")
        }
        for (i, e) in try dec.decode([HexEntry].self, from: resource("historical_frames")).enumerated() {
            assertValid(e.hex, .whoop4, "historical_frames.json #\(i)")
        }
        for (i, e) in try dec.decode(DecoderOracleFile.self, from: resource("decoder_oracle")).frames.enumerated() {
            assertValid(e.hex, e.family == "whoop5" ? .whoop5 : .whoop4, "decoder_oracle.json #\(i)")
        }
        for (i, e) in try dec.decode(OpticalOracleFile.self,
                                     from: resource("r20_optical_oracle")).records.enumerated() {
            assertValid(e.hex, .whoop5, "r20_optical_oracle.json #\(i)")
        }
        XCTAssertEqual(checked, 116, "the corpus size is pinned so a lost resource cannot pass as green")
    }
}
