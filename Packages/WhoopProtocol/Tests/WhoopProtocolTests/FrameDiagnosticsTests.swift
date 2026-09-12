import XCTest
@testable import WhoopProtocol

/// Scenario group "Diagnose behält Parsbarkeit und Ablehnungsgrund", plus the two counters D3 asks for.
///
/// The frames are the same corpus-derived fixtures the integrity tests use, each broken in exactly ONE
/// way, so every assertion below attributes a single cause.
final class FrameDiagnosticsTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] { FrameIntegrityTests.hex(s) }

    /// A real WHOOP 4.0 REALTIME_DATA frame with ONLY its header checksum broken: the class that
    /// passed every gate before this change.
    private func headerBroken() -> [UInt8] {
        var f = hex(FrameIntegrityTests.w4Valid)
        f[3] ^= 0xFF
        return f
    }

    // MARK: - parseability is not integrity

    func testARejectedFrameKeepsItsPacketType() {
        let p = parseFrame(headerBroken())
        XCTAssertFalse(p.ok)
        XCTAssertTrue(p.isParsable, "the decoder read this frame; only the envelope failed")
        XCTAssertEqual(p.typeName, "REALTIME_DATA")
    }

    func testAByteRunThatIsNotAFrameIsNotParsable() {
        let p = parseFrame([0xAA, 0x00, 0x00])
        XCTAssertFalse(p.isParsable)
        XCTAssertEqual(p.typeName, ParsedFrame.unparsableTypeName)
    }

    func testAnIntactFrameIsBothIntactAndParsable() {
        let p = parseFrame(hex(FrameIntegrityTests.w4Valid))
        XCTAssertTrue(p.ok)
        XCTAssertTrue(p.isParsable)
        XCTAssertEqual(p.rejectReason, .none)
    }

    // MARK: - the inspector's line keeps type AND names the reason

    func testInspectionLineOfARejectedFrameCarriesTypeAndReason() {
        let line = frameInspectionLine(index: 7, family: .whoop4, parsed: parseFrame(headerBroken()))
        XCTAssertTrue(line.contains("ok=false"), line)
        XCTAssertTrue(line.contains("type=REALTIME_DATA"), "a rejected frame must keep its type: \(line)")
        XCTAssertTrue(line.contains("reason=headerChecksumMismatch"), line)
        // The payload CRC32 verified — the line says so rather than smearing one failure over both.
        XCTAssertTrue(line.contains("crc=ok"), line)
    }

    func testInspectionLineOfAnIntactFrameCarriesNoReason() {
        let line = frameInspectionLine(index: 0, family: .whoop4,
                                       parsed: parseFrame(hex(FrameIntegrityTests.w4Valid)))
        XCTAssertTrue(line.contains("ok=true"), line)
        XCTAssertFalse(line.contains("reason="), "an intact frame has no reason to report: \(line)")
    }

    /// Scenario "Nicht prüfbar wird nicht als falsch gemeldet": a payload CRC32 that could not be
    /// computed is reported as unverifiable, and the CRC column stays "—" rather than claiming "BAD".
    func testUnverifiablePayloadCRCIsNotReportedAsAMismatch() {
        let p = parseFrame(hex(FrameIntegrityTests.w4Total8))
        XCTAssertNil(p.crcOK)
        XCTAssertNotEqual(p.rejectReason, .payloadCRCMismatch)
        let line = frameInspectionLine(index: 1, family: .whoop4, parsed: p)
        XCTAssertTrue(line.contains("crc=—"), line)
        XCTAssertFalse(line.contains("crc=BAD"), "we did not observe a mismatch, so we do not report one")
    }

    // MARK: - the capture export keeps the type and gains the reason

    func testCaptureRecordKeepsThePacketTypeOfARejectedFrame() {
        // A 5/MG frame with only its header checksum broken.
        var frame = hex(FrameIntegrityTests.w5Valid)
        frame[6] ^= 0xFF
        let capture = PuffinCapture()
        let rec = capture.record(frame: frame, char: "fd4b0005", tsMs: 1234, hr: 60)
        XCTAssertFalse(rec.ok)
        XCTAssertEqual(rec.typeName, "COMMAND_RESPONSE",
                       "a capture exists to map unexplained frames; blanking the type throws that away")
        XCTAssertEqual(rec.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(rec.crcOK, true)
    }

    func testCaptureRecordOfAnIntactFrameCarriesNoReason() {
        let capture = PuffinCapture()
        let rec = capture.record(frame: hex(FrameIntegrityTests.w5Valid), char: "fd4b0005",
                                 tsMs: 1, hr: nil)
        XCTAssertTrue(rec.ok)
        XCTAssertEqual(rec.rejectReason, .none)
    }

    func testCaptureJSONCarriesTheReasonAndOlderCapturesStillDecode() throws {
        var frame = hex(FrameIntegrityTests.w5Valid)
        frame[6] ^= 0xFF
        let capture = PuffinCapture()
        capture.record(frame: frame, char: "fd4b0005", tsMs: 1234, hr: nil)
        let json = try XCTUnwrap(String(data: try capture.encodedJSON(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"reject_reason\" : \"headerChecksumMismatch\""), json)
        XCTAssertTrue(json.contains("\"type_name\""), "the packet type stays in the export")

        // A record written before the key existed must still decode — additive, not breaking.
        let legacy = """
        [{"hex":"aa","char":"fd4b0005","ts_ms":1,"type_name":"EVENT","seq":2,"crc_ok":true,"ok":true}]
        """
        let decoded = try JSONDecoder().decode([PuffinCaptureRecord].self, from: Data(legacy.utf8))
        // Spelled out: a bare `.none` here would resolve to `Optional.none`, not to the reason.
        XCTAssertEqual(decoded.first?.rejectReason, FrameRejectReason.none)
        XCTAssertEqual(decoded.first?.typeName, "EVENT")
    }

    // MARK: - counters (D3)

    func testTallyCountsEachReasonSeparately() {
        var tally = FrameRejectTally()
        tally.note(parseFrame(headerBroken()))
        tally.note(parseFrame(hex(FrameIntegrityTests.w4Valid) + [0x00]))     // trailing byte
        tally.note(parseFrame(hex(FrameIntegrityTests.w4Total8)))            // below the 11-byte floor
        tally.note(parseFrame(hex(FrameIntegrityTests.w4Valid)))             // intact: not counted
        XCTAssertEqual(tally.count(.headerChecksumMismatch), 1)
        XCTAssertEqual(tally.count(.lengthMismatch), 1)
        XCTAssertEqual(tally.count(.belowMinimumLength), 1)
        XCTAssertEqual(tally.count(.none), 0, "an intact frame is never counted as a rejection")
        XCTAssertEqual(tally.totalRejected, 3)
    }

    func testTallyReportsUnverifiableSeparatelyFromMismatch() {
        var tally = FrameRejectTally()
        // Payload byte flipped: the CRC32 was computed and disagreed.
        var wrongPayload = hex(FrameIntegrityTests.w4Valid)
        wrongPayload[10] ^= 0xFF
        tally.note(parseFrame(wrongPayload))
        XCTAssertEqual(tally.count(.payloadCRCMismatch), 1)
        XCTAssertEqual(tally.count(.payloadCRCUnverifiable), 0,
                       "\"could not be checked\" and \"was wrong\" are different claims")
    }

    /// Scenario "Die vorher durchgelassene Klasse ist einzeln ablesbar" (2.16) — the ONE counter the
    /// hardware run's abort criterion is read from. A per-reason bucket cannot express it: the length
    /// bucket also collects the harmless resyncs after a lost notification.
    func testThePreviouslyAdmittedClassHasItsOwnCounter() {
        var tally = FrameRejectTally()
        tally.note(parseFrame(headerBroken()))                                // header wrong, CRC32 right
        tally.note(parseFrame(hex(FrameIntegrityTests.w4Valid) + [0x00]))     // length wrong, CRC32 right
        var wrongPayload = hex(FrameIntegrityTests.w4Valid)
        wrongPayload[10] ^= 0xFF
        tally.note(parseFrame(wrongPayload))                                  // CRC32 wrong: NOT the class
        tally.note(parseFrame(hex(FrameIntegrityTests.w4Total8)))             // CRC32 unverifiable: not it
        XCTAssertEqual(tally.payloadCRCOKButEnvelopeRejected, 2)
        XCTAssertEqual(tally.totalRejected, 4, "the class is counted BESIDE its reason, not instead of it")
    }

    /// The offload path never parses its frames at the BLE seam — it hands them straight to the
    /// Backfiller — so the parse-result overload cannot count them, and the ONE counter the hardware
    /// run's abort criterion reads was blind for exactly the traffic in which the loss occurs. Counting
    /// from the verifier's own result closes that without a second parse.
    func testTheVerdictOverloadCountsTheSameReasonAndClassAsTheParseResult() {
        let broken = headerBroken()
        var fromParse = FrameRejectTally()
        fromParse.note(parseFrame(broken, family: .whoop4))
        var fromVerdict = FrameRejectTally()
        let reason = fromVerdict.note(verifyFrame(broken, family: .whoop4))
        XCTAssertEqual(reason, .headerChecksumMismatch)
        XCTAssertEqual(fromVerdict, fromParse, "the two routes into the tally must agree exactly")
        XCTAssertEqual(fromVerdict.payloadCRCOKButEnvelopeRejected, 1,
                       "envelope rejected while the payload CRC32 verified — the abort-criterion class")
    }

    /// The same three separations the parse-result overload keeps: an intact frame is not counted, a
    /// wrong payload CRC32 is not the named class, and an unverifiable one is neither.
    func testTheVerdictOverloadKeepsTheClassSeparations() {
        var tally = FrameRejectTally()
        XCTAssertEqual(tally.note(verifyFrame(hex(FrameIntegrityTests.w4Valid), family: .whoop4)), .none)
        XCTAssertEqual(tally.totalRejected, 0, "an intact frame is never counted as a rejection")
        var wrongPayload = hex(FrameIntegrityTests.w4Valid)
        wrongPayload[10] ^= 0xFF
        tally.note(verifyFrame(wrongPayload, family: .whoop4))
        tally.note(verifyFrame(hex(FrameIntegrityTests.w4Total8), family: .whoop4))
        XCTAssertEqual(tally.count(.payloadCRCMismatch), 1)
        XCTAssertEqual(tally.count(.belowMinimumLength), 1)
        XCTAssertEqual(tally.payloadCRCOKButEnvelopeRejected, 0,
                       "neither a wrong nor an uncomputable payload CRC32 is the admitted class")
    }

    /// Scenario "Vom Zusammensetzer verworfene Byteläufe sind gesondert erfasst": a byte run the
    /// reassembler drops never reaches a parser — and never reaches the evidence-preserving reader —
    /// so its disappearance is only visible if it is counted.
    func testReassemblerDropsAreCountedAsBelowMinimumLength() {
        let r = Reassembler(family: .whoop4)
        // A start-of-frame declaring a total of 8 bytes (below the 11-byte floor), then a real frame.
        let runt: [UInt8] = [0xAA, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let good = hex(FrameIntegrityTests.w4Valid)
        let out = r.feed(runt + good)
        XCTAssertEqual(out.count, 1, "the stream resyncs and still yields the real frame")
        XCTAssertGreaterThan(r.belowMinimumLengthDrops, 0, "precondition: the runt was dropped")

        var tally = FrameRejectTally()
        tally.absorbReassemblerDrops(r.belowMinimumLengthDrops)
        XCTAssertEqual(tally.count(.belowMinimumLength), r.belowMinimumLengthDrops)
        // The counter is monotonic, so folding it again must not double-count.
        tally.absorbReassemblerDrops(r.belowMinimumLengthDrops)
        XCTAssertEqual(tally.count(.belowMinimumLength), r.belowMinimumLengthDrops)
    }

    func testSummaryLineIsSilentWhenNothingWasRejected() {
        var tally = FrameRejectTally()
        tally.note(parseFrame(hex(FrameIntegrityTests.w4Valid)))
        XCTAssertNil(tally.summaryLine(), "no \"0 rejections\" line to read past")
    }

    func testSummaryLineNamesOnlyTheReasonsThatOccurred() {
        var tally = FrameRejectTally()
        tally.note(parseFrame(headerBroken()))
        let line = try? XCTUnwrap(tally.summaryLine())
        XCTAssertEqual(line, "frameReject total=1 headerChecksumMismatch=1 payloadCRCOKButEnvelopeRejected=1")
    }
}
