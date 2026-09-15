import XCTest
@testable import WhoopProtocol

/// Byte-parity twin of the Kotlin `DataRangeScanTest`: `DataRange.newestUnix` offset/future-date
/// correctness (#451/#928/#1012). Same real WHOOP 4.0 GET_DATA_RANGE fixtures, so a Swift-side edit that
/// drifts from Kotlin fails here (the app-target copies were Kotlin-tested only before this extraction).
final class DataRangeTests: XCTestCase {

    private let skew48h = 48 * 3600         // AUTO_CONTINUE_FUTURE_SKEW_SECONDS twin
    private let wallNow = 1_783_786_000      // 2026-07-11 ~16:06, just after the captured newest
    private let realNewest = 1_783_785_625   // 2026-07-11 16:00:25 (frame a)

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { off in
            let start = s.index(s.startIndex, offsetBy: off)
            let end = s.index(start, offsetBy: 2)
            return UInt8(s[start..<end], radix: 16)!
        }
    }

    /// Little-endian u32 `value` written at `offset` into a `size`-byte frame (rest zero).
    private func frameWithU32(_ size: Int, _ offset: Int, _ value: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        for k in 0..<4 { b[offset + k] = UInt8((value >> (8 * k)) & 0xFF) }
        return b
    }

    func testReadsRealWhoop4NewestAtByteOffset8() {
        // Three real captured frames → their true newest (offset-8 u32), all 2026-07-11 ~16:00.
        let expected: [(String, Int)] = [
            ("aa100057305d22009968526a083900001d2e2263", 1_783_785_625), // 16:00:25
            ("aa10005730612200a268526ab0290000e87d155d", 1_783_785_634), // 16:00:34
            ("aa100057307c2200e768526a78760000c997138d", 1_783_785_703), // 16:01:43
        ]
        for (h, ts) in expected {
            XCTAssertEqual(DataRange.newestUnix(from: hex(h), wallNowUnix: wallNow, futureSkewSeconds: skew48h),
                           ts, "newest for \(h) should be its offset-8 value, not nil")
        }
    }

    func testLoneFutureStraddleNeverBecomesFrontier() {
        let future = wallNow + 400 * 86_400
        var frame = frameWithU32(16, 4, realNewest)
        for k in 0..<4 { frame[10 + k] = UInt8((future >> (8 * k)) & 0xFF) }
        XCTAssertEqual(DataRange.newestUnix(from: frame, wallNowUnix: wallNow, futureSkewSeconds: skew48h),
                       realNewest)
    }

    func testAllFutureFrameStillReturnsFutureSoTheGuardFires() {
        let future = wallNow + 400 * 86_400
        XCTAssertEqual(DataRange.newestUnix(from: frameWithU32(12, 4, future),
                                            wallNowUnix: wallNow, futureSkewSeconds: skew48h), future)
    }

    func testValueJustInsideTheSkewIsPresentNotFuture() {
        let within = wallNow + 40 * 3600     // 40h ahead, under the 48h skew
        XCTAssertEqual(DataRange.newestUnix(from: frameWithU32(12, 4, within),
                                            wallNowUnix: wallNow, futureSkewSeconds: skew48h), within)
    }

    // MARK: - oldestUnix (aligned-from-7; asymmetric with newestUnix by design)

    /// The whole reason `oldestUnix` scans the aligned grid instead of every offset: the real WHOOP 4.0
    /// frame carries a spurious plausible straddle at byte offset 6 (1_754_857_506, ~11 months BEFORE the
    /// true newest at offset 8). An any-offset MIN would return it → a bogus deep backlog. The aligned grid
    /// skips it, so this frame (no distinct oldest word) → nil. Guards against a future "consistency" refactor.
    func testOldestAlignedScanSkipsTheSpuriousOffset6Straddle() {
        XCTAssertNil(DataRange.oldestUnix(from: hex("aa100057305d22009968526a083900001d2e2263")))
    }

    func testOldestReadsAGridAlignedWord() {
        XCTAssertEqual(DataRange.oldestUnix(from: frameWithU32(12, 7, 1_750_000_000)), 1_750_000_000)
    }

    func testOldestKeepsTheMinimumAcrossGridWords() {
        var frame = frameWithU32(16, 7, 1_800_000_000)              // grid offset 7
        for k in 0..<4 { frame[11 + k] = UInt8((1_750_000_000 >> (8 * k)) & 0xFF) } // grid offset 11
        XCTAssertEqual(DataRange.oldestUnix(from: frame), 1_750_000_000)
    }

    // MARK: - #689/#815 pagesBehind (ring backlog). Byte-parity twin of the Kotlin DataRangeScanTest cases.

    /// Frame (zero-filled) with W/U/T u32 LE at the pagesBehind offsets (cmdOff+12/16/24).
    private func pagesFrame(cmdOff: Int, w: Int, u: Int, t: Int, size: Int = 40) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        func put(_ off: Int, _ v: Int) { for k in 0..<4 { b[off + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        put(cmdOff + 12, w); put(cmdOff + 16, u); put(cmdOff + 24, t)
        return b
    }

    func testPagesBehind_normalNoWrap() {   // W > U ⇒ W − U
        XCTAssertEqual(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 500, u: 200, t: 1024), cmdOff: 6), 300)
    }

    func testPagesBehind_wraparound() {     // W < U ⇒ W + (T − U); synthetic — no real capture has crossed the wrap yet
        XCTAssertEqual(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 100, u: 800, t: 1000), cmdOff: 6), 300)
    }

    func testPagesBehind_tooShortIsNil() {
        XCTAssertNil(DataRange.pagesBehind(from: [UInt8](repeating: 0, count: 20), cmdOff: 6))
    }

    func testPagesBehind_implausibleIsNil() {
        XCTAssertNil(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 1, u: 1, t: 0), cmdOff: 6))               // capacity 0
        XCTAssertNil(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 1, u: 1, t: 1_783_785_625), cmdOff: 6))  // T is a timestamp → over ceiling
        XCTAssertNil(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 5, u: 2000, t: 1000), cmdOff: 6))        // U ≥ T
    }

    /// Real captures (#791 WHOOP4, #815 WHOOP 5.0/MG) — confirms the offset fix against hardware, not just
    /// synthetic math. All four are the non-wrapped case (W > U); ring capacity `T` is 131072 in every one.
    func testPagesBehind_realCaptures() {
        let cases: [(String, Int, Int)] = [
            // WHOOP4, cmdOff 6 (Galaxy S24 Ultra capture, #791)
            ("aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
             "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04", 6, 83),
            // WHOOP 5.0/MG, cmdOff 10 (#815)
            ("aa014c00010032d124cc22040101c0890100b4890100b6890100b4890100110000000000020012000000" +
             "e2ff1d00785ac169707d0000edeb626a5c0f0000edeb626a5c0f0000feeb626a5c0f00000000a7c3ec16", 10, 2),
            ("aa014c00010032d1241e22050101008a0100dd890100e5890100dd890100110000000000020" +
             "05d00000088ff1d00da5dc169b87e000002ee626a0000000002ee626a000000005dee626a140e000000009f8dfab4", 10, 8),
            ("aa014c00010032d124982207010180b901005ab7010048b901005ab7010010000000000002" +
             "00da1b00000ee31d00b0e1ff69d7430000a3ab266a3d4a0000a3ab266a3d4a00007cc7266a5c4f00000000623977f5", 10, 494),
        ]
        for (h, cmdOff, expected) in cases {
            XCTAssertEqual(DataRange.pagesBehind(from: hex(h), cmdOff: cmdOff), expected,
                           "pagesBehind for \(h) at cmdOff \(cmdOff) should be \(expected)")
        }
    }

    // MARK: - #689 PENDING ack. Byte-parity twin of the Kotlin DataRangeScanTest cases.
    //
    // GET_DATA_RANGE answers twice and only the second carries the ring pointers. Both frames below are
    // real, captured on a WHOOP MG (WS50_r00, fw 50.39.1.0) on 2026-08-28, and they are one request's
    // two replies.

    /// The PENDING(2) ack: 20 bytes, result byte at cmdOff+2 is 0x02, no ring pointers in it at all.
    func testIsPendingResponse_trueForPendingAck() {
        XCTAssertTrue(DataRange.isPendingResponse(hex("aa010c000100271124e8220402000000c391bc3d"), cmdOff: 10))
    }

    /// The SUCCESS(1) answer to that same request. Must NOT be skipped.
    func testIsPendingResponse_falseForSuccessAnswer() {
        let h = "aa014c00010032d124e92204010100bf0000b4be0000c1be0000b4be00000c000000000002008f00"
        XCTAssertFalse(DataRange.isPendingResponse(hex(h), cmdOff: 10))
    }

    /// The reason this pair matters: the ack decodes to nil, so before the guard it logged as a decode
    /// failure once per sync while the real answer decoded fine two lines later.
    func testPendingAckIsExactlyTheFramePagesBehindCannotDecode() {
        let pending = hex("aa010c000100271124e8220402000000c391bc3d")
        XCTAssertNil(DataRange.pagesBehind(from: pending, cmdOff: 10))
        XCTAssertTrue(DataRange.isPendingResponse(pending, cmdOff: 10))
    }

    /// A frame too short to hold a result byte is not a PENDING ack; the caller keeps its own handling.
    func testIsPendingResponse_falseWhenTooShortForResultByte() {
        XCTAssertFalse(DataRange.isPendingResponse([UInt8](repeating: 0, count: 11), cmdOff: 10))
    }

    /// A negative cmdOff is rejected rather than indexing backwards.
    func testIsPendingResponse_falseForNegativeCmdOff() {
        XCTAssertFalse(DataRange.isPendingResponse([UInt8](repeating: 0, count: 40), cmdOff: -1))
    }

    // MARK: - the BLE seam's gate on this reply (task 2.15)

    /// GET_DATA_RANGE(34) — the opcode the seam compares at `cmdOff`, held by the app target's command
    /// table; the predicate takes it as an argument rather than restating the protocol fact.
    private let getDataRangeOpcode: UInt8 = 34

    /// A complete WHOOP 4.0 GET_DATA_RANGE COMMAND_RESPONSE: type@4, seq@5, cmd@6, body from 7 —
    /// `oldest` on the aligned grid `oldestUnix` scans, `newest` one word later.
    private func dataRangeReply(oldest: Int, newest: Int) -> [UInt8] {
        var payload = [UInt8]()
        for v in [oldest, newest] { for k in 0..<4 { payload.append(UInt8((v >> (8 * k)) & 0xFF)) } }
        return frameFromPayload(payload, type: 0x24, seq: 1, cmd: getDataRangeOpcode)
    }

    /// An intact reply is accepted, and it is the value the seam then applies as the reported window
    /// and as the offload's plausibility bounds.
    func testAnIntactDataRangeReplyIsAcceptedAndCarriesTheWindow() {
        let oldest = 1_750_000_000, newest = 1_780_000_000
        let f = dataRangeReply(oldest: oldest, newest: newest)
        let p = parseFrame(f, family: .whoop4)
        XCTAssertTrue(p.ok, "precondition: the reply is intact")
        XCTAssertTrue(DataRange.acceptsReply(f, cmdOff: 6, opcode: getDataRangeOpcode, verdictOK: p.ok))
        XCTAssertEqual(DataRange.newestUnix(from: f, wallNowUnix: 1_790_000_000, futureSkewSeconds: skew48h),
                       newest)
        XCTAssertEqual(DataRange.oldestUnix(from: f), oldest)
    }

    /// Scenario "eine Antwort mit falscher Kopfprüfsumme verändert weder den gemeldeten Zeitbereich
    /// noch die Plausibilitätsgrenzen des Abzugs" (task 2.15). The damaged reply still DECODES a
    /// window — the verdict is the only thing that keeps it out, which is why the gate has to be a
    /// predicate a test can hold rather than a condition buried in the seam.
    func testABrokenDataRangeReplyMovesNeitherTheWindowNorThePlausibilityBounds() {
        let oldest = 1_750_000_000, newest = 1_780_000_000
        var bad = dataRangeReply(oldest: oldest, newest: newest)
        bad[3] ^= 0xFF                                   // CRC-8 over the length field only
        let p = parseFrame(bad, family: .whoop4)
        XCTAssertEqual(p.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(p.crcOK, true, "precondition: the payload CRC32 still verifies")
        XCTAssertEqual(DataRange.newestUnix(from: bad, wallNowUnix: 1_790_000_000, futureSkewSeconds: skew48h),
                       newest, "precondition: these bytes DO carry a window a seam could apply")

        // The seam in miniature: the reported window and the two plausibility bounds, moved only on
        // an accepted reply. Their previous values must survive a damaged one untouched.
        var reportedNewest: Int? = 1_700_000_001
        var boundsNewest: Int? = 1_700_000_001
        var boundsOldest: Int? = 1_700_000_000
        if DataRange.acceptsReply(bad, cmdOff: 6, opcode: getDataRangeOpcode, verdictOK: p.ok) {
            reportedNewest = DataRange.newestUnix(from: bad, wallNowUnix: 1_790_000_000,
                                                  futureSkewSeconds: skew48h)
            boundsNewest = reportedNewest
            boundsOldest = DataRange.oldestUnix(from: bad)
        }
        XCTAssertEqual(reportedNewest, 1_700_000_001, "the reported range must not move")
        XCTAssertEqual(boundsNewest, 1_700_000_001, "the offload's upper plausibility bound must not move")
        XCTAssertEqual(boundsOldest, 1_700_000_000, "the offload's lower plausibility bound must not move")
    }

    /// The gate is per-reply, not per-connection: a frame carrying another opcode at `cmdOff` is not a
    /// data-range reply at all, however intact it is.
    func testAnotherOpcodeIsNotADataRangeReply() {
        let other = frameFromPayload([0x00, 0x01, 0x02, 0x03], type: 0x24, seq: 1, cmd: 26)
        XCTAssertTrue(parseFrame(other, family: .whoop4).ok)
        XCTAssertFalse(DataRange.acceptsReply(other, cmdOff: 6, opcode: getDataRangeOpcode, verdictOK: true))
    }
}
