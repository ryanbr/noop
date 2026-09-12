import XCTest
@testable import WhoopProtocol

/// Tests for `rejectedHistoricalRecords` — the history-loss guard (#77 / #91). It returns the
/// HISTORICAL_DATA (type-47) record frames that would otherwise be silently dropped (CRC failure or
/// an unmapped layout), so the Backfiller can archive them BEFORE acking the trim. Frames that
/// decode cleanly, console (type-50) frames, and 5/MG v26 PPG blocks must NOT be returned.
final class RejectedHistoryTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // A synthetic WHOOP 4.0 V24 type-47 record (HR=63) that decodes cleanly (from HistoricalV24Tests).
    private let v24Hex =
        "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
        "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
        "200364006400b80bb80b000000000000c25c1a88"

    // A real WHOOP 5/MG type-47 v18 record (HR present, decodes cleanly; from Whoop5HistoricalTests).
    private let whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    // A real WHOOP 5/MG type-47 v26 record — the high-rate PPG waveform buffer NOOP stores by design.
    private let whoop5V26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff405fb33c50080101006cb67c17"

    // MARK: - clean records are NOT rejected

    func testDecodableWhoop4RecordNotRejected() {
        let rejected = rejectedHistoricalRecords([bytes(v24Hex)], family: .whoop4)
        XCTAssertTrue(rejected.isEmpty, "a cleanly-decoding type-47 record must not be flagged as lost")
    }

    func testDecodableWhoop5RecordNotRejected() {
        let rejected = rejectedHistoricalRecords([bytes(whoop5V18Hex)], family: .whoop5)
        XCTAssertTrue(rejected.isEmpty)
    }

    // MARK: - undecodable records ARE rejected

    func testCRCCorruptWhoop4RecordIsRejected() {
        // Flip a payload byte so the CRC32 trailer mismatches (crcOK == false) but the type byte is
        // still 47 — exactly the silent-loss case the guard exists to catch.
        var bad = bytes(v24Hex)
        bad[10] ^= 0xFF
        let f = parseFrame(bad)
        XCTAssertEqual(f.crcOK, false, "precondition: the corrupted frame must fail CRC")
        let rejected = rejectedHistoricalRecords([bad], family: .whoop4)
        XCTAssertEqual(rejected, [bad])
    }

    func testCRCCorruptWhoop5RecordIsRejected() {
        var bad = bytes(whoop5V18Hex)
        bad[20] ^= 0xFF                    // corrupt a biometric payload byte (type byte @8 untouched)
        XCTAssertEqual(bad[8], 47)         // still a HISTORICAL_DATA record
        let rejected = rejectedHistoricalRecords([bad], family: .whoop5)
        XCTAssertEqual(rejected, [bad])
    }

    // MARK: - by-design skips are NEVER rejected

    func testConsoleFrameExcluded() {
        // type-50 CONSOLE_LOGS is strap-side debug text — decodes to zero rows by design, never lost.
        let console = frameFromPayload([0x01, 0x02, 0x03, 0x04], type: 50, seq: 0, cmd: 0)
        XCTAssertEqual(console[4], 50)
        XCTAssertTrue(rejectedHistoricalRecords([console], family: .whoop4).isEmpty)
    }

    func testWhoop5V26PpgExcluded() {
        let v26 = bytes(whoop5V26Hex)
        XCTAssertEqual(v26[8], 47)         // it IS a type-47 record…
        XCTAssertEqual(v26[9], 26)         // …but version 26 (PPG), skipped by design — not lost data
        XCTAssertTrue(rejectedHistoricalRecords([v26], family: .whoop5).isEmpty)
    }

    /// The v26 skip is bound to the VERDICT, not to the version byte alone. Its whole premise is that
    /// `extractHistoricalStreams` stores such a record durably in the PPG waveform stream — which stops
    /// being true the moment the record is rejected: the extraction drops it, and an unconditional skip
    /// here would leave it archived nowhere while the section is acked anyway.
    func testWhoop5V26RecordWithABrokenHeaderChecksumIsArchived() {
        var bad = bytes(whoop5V26Hex)
        bad[6] ^= 0xFF                                  // CRC-16-Modbus over the first six bytes
        XCTAssertEqual(bad[8], 47)                      // still a HISTORICAL_DATA record…
        XCTAssertEqual(bad[9], 26)                      // …still version 26
        let p = parseFrame(bad, family: .whoop5)
        XCTAssertEqual(p.crcOK, true, "precondition: the PAYLOAD CRC32 still verifies")
        XCTAssertEqual(p.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop5), [bad],
                       "a rejected v26 record reaches no stream, so its bytes are the only copy left")
    }

    /// The other direction of the same rule: binding the skip to the verdict must not start archiving
    /// the NORMAL case. An intact v26 record is stored in its own stream and stays out of the archive.
    func testIntactWhoop5V26RecordIsStillNotArchived() {
        let v26 = bytes(whoop5V26Hex)
        XCTAssertTrue(parseFrame(v26, family: .whoop5).ok, "precondition: the record is intact")
        XCTAssertTrue(rejectedHistoricalRecords([v26], family: .whoop5).isEmpty,
                      "the archive must not grow by the normal case")
    }

    func testNonHistoricalFrameExcluded() {
        // A REALTIME_DATA (type-40) frame is live, not offload — never a history-loss candidate.
        let realtime = frameFromPayload([0x01, 0x02, 0x03], type: 40, seq: 0, cmd: 0)
        XCTAssertTrue(rejectedHistoricalRecords([realtime], family: .whoop4).isEmpty)
    }

    func testTooShortFrameExcluded() {
        XCTAssertTrue(rejectedHistoricalRecords([[0xAA, 0x01]], family: .whoop4).isEmpty)
        XCTAssertTrue(rejectedHistoricalRecords([[]], family: .whoop5).isEmpty)
    }

    // MARK: - mixed batch returns only the genuine losses, in order

    func testMixedBatchReturnsOnlyRejects() {
        var bad = bytes(v24Hex); bad[10] ^= 0xFF   // undecodable
        let good = bytes(v24Hex)                   // clean
        let console = frameFromPayload([0x00], type: 50, seq: 0, cmd: 0)
        let rejected = rejectedHistoricalRecords([good, bad, console], family: .whoop4)
        XCTAssertEqual(rejected, [bad])
    }

    // MARK: - D8: this reader runs the OTHER WAY ROUND — a negative verdict means ARCHIVE

    /// Scenario "Beweissichernde Leser verlieren keine Rahmen / Rahmen mit kaputtem Header wird
    /// gesichert statt verworfen". Before the change this frame passed as decodable and was archived
    /// NOWHERE; the strap frees it on the next trim ack, so the archive is the only copy that can exist.
    func testWhoop4RecordWithABrokenHeaderChecksumIsArchived() {
        var bad = bytes(v24Hex)
        bad[3] ^= 0xFF                                  // CRC-8 over the length field only
        let p = parseFrame(bad)
        XCTAssertEqual(p.crcOK, true, "precondition: the PAYLOAD CRC32 still verifies")
        XCTAssertEqual(p.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop4), [bad],
                       "a frame we cannot trust is a frame we must keep the bytes of")
    }

    func testWhoop5RecordWithABrokenHeaderChecksumIsArchived() {
        var bad = bytes(whoop5V18Hex)
        bad[6] ^= 0xFF                                  // CRC-16-Modbus over the first six bytes
        XCTAssertEqual(bad[8], 47)
        XCTAssertEqual(parseFrame(bad, family: .whoop5).rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop5), [bad])
    }

    func testWhoop4RecordWithTrailingBytesIsArchived() {
        let bad = bytes(v24Hex) + [0x00]                // one byte past the frame's own end
        XCTAssertEqual(parseFrame(bad).rejectReason, .lengthMismatch)
        XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop4), [bad])
    }

    func testWhoop4RecordWithATruncatedTrailerIsArchived() {
        let bad = Array(bytes(v24Hex).dropLast(2))
        XCTAssertEqual(parseFrame(bad).rejectReason, .lengthMismatch)
        XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop4), [bad])
    }

    /// Scenario "Bisher gesicherte Rahmen bleiben gesichert", over the real capture corpus.
    ///
    /// The pre-change reader is re-implemented here verbatim, with the one substitution the change
    /// makes: its `ok` was a constant that meant "these bytes read as a frame", which is
    /// `isParsable` today. Every frame it would have archived must still be archived. The direction
    /// is asserted as a SUBSET, not as equality, because the new reader is expected to archive more.
    func testNoCorpusFrameIsArchivedLessThanBefore() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "frames", withExtension: "json"),
                                "the WHOOP 4.0 capture corpus must be present")
        struct HexOnly: Decodable { let hex: String }
        let corpus = try JSONDecoder().decode([HexOnly].self, from: Data(contentsOf: url))
            .map { bytes($0.hex) }
        XCTAssertGreaterThan(corpus.count, 50, "precondition: a corpus worth calling a corpus")

        // The pre-change predicate, for WHOOP 4.0.
        func archivedBefore(_ f: [UInt8]) -> Bool {
            guard f.count > 4, Int(f[4]) == 47 else { return false }
            let p = parseFrame(f, family: .whoop4)
            if !p.isParsable || p.crcOK == false { return true }
            return p.parsed["unix"]?.intValue == nil
                || (p.parsed["heart_rate"]?.intValue == nil && p.parsed["gravity_x"]?.doubleValue == nil)
        }

        let before = corpus.filter(archivedBefore)
        let now = Set(rejectedHistoricalRecords(corpus, family: .whoop4).map { Data($0) })
        for f in before {
            XCTAssertTrue(now.contains(Data(f)),
                          "a frame archived before this change must still be archived: \(f.prefix(8))")
        }
        // And nothing INTACT and decodable was dragged in: the corpus's clean records stay out.
        let clean = corpus.filter { $0.count > 4 && Int($0[4]) == 47 && parseFrame($0).ok }
        XCTAssertGreaterThan(clean.count, 0, "precondition: the corpus holds intact type-47 records")
    }

    func testIsEmptyRecordFrameFlagsAllZeroPayloadOnly() {
        // A 104 B frame with header + CRC bytes set but the record payload (21..<count-4) all zero -> empty.
        var empty = [UInt8](repeating: 0, count: 104)
        empty[0] = 0xAA; empty[103] = 0x78
        XCTAssertTrue(isEmptyRecordFrame(empty))
        // One non-zero byte inside the payload -> not empty.
        var nonEmpty = empty
        nonEmpty[50] = 0x01
        XCTAssertFalse(isEmptyRecordFrame(nonEmpty))
        // A runt frame (no room for a payload past header+CRC) is never treated as empty.
        XCTAssertFalse(isEmptyRecordFrame([UInt8](repeating: 0, count: 20)))
    }
}
