import XCTest
@testable import OuraProtocol

/// Framing tests: outer command/response frames, the 0x2F secure-session sub-frame, and the TLV
/// inner-record parse — open_oura's ONE-packet-per-notification model (lenient `len`, no buffering,
/// no multi-record loop, no byte-drop resync).
final class FramingTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: - Outer frame

    func testParseOuterFrame() {
        // 0d 06 <6 body bytes> (a battery response shape).
        let f = OuraFraming.parseOuterFrame(bytes("0d06570000003c0f"))
        XCTAssertEqual(f?.op, 0x0D)
        XCTAssertEqual(f?.body, bytes("570000003c0f"))
        XCTAssertEqual(f?.totalLength, 8)
    }

    func testParseOuterFrameShortReturnsNil() {
        // Declares 6 body bytes but only 2 present -> nil (wait for more).
        XCTAssertNil(OuraFraming.parseOuterFrame(bytes("0d065700")))
    }

    func testMultipleOuterFramesInOneValue() {
        // 25 01 00  (SetAuthKey resp)  then  1d 01 00 (SetNotification resp).
        let frames = OuraFraming.parseOuterFrames(bytes("2501001d0100"))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].op, 0x25)
        XCTAssertEqual(frames[0].body, [0x00])
        XCTAssertEqual(frames[1].op, 0x1D)
        XCTAssertEqual(frames[1].body, [0x00])
    }

    // MARK: - GetBattery response (0x0D, s6.10)

    func testBatteryResponseOpIsRecognisedAsAnOuterFrame() {
        // 0d 06 <percent=57=87> <charging=00> <flag=00> <3 unknown> - the live path routes this op to the
        // battery decoder, never to the TLV record decoder (op 0x0D is below the event-tag range).
        let frames = OuraFraming.parseOuterFrames(bytes("0d06570000003c0f"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].op, OuraFraming.batteryResponseOp)
        let battery = OuraDecoders.decodeBattery(frames[0].body)
        XCTAssertEqual(battery?.percent, 0x57)   // 87%
    }

    // MARK: - GetEvents response (0x11, s5.2)

    func testParseGetEventsResponseMoreDataWhileBytesLeft() {
        // REAL on-device capture (2026-07-11 07:04, full-pull first summary):
        // 11 08 <events=ff> <progress=00> <bytes_left:4LE = a6 a1 1a 00 = 1,745,318> <pad 03 00>.
        let outer = OuraFraming.parseOuterFrame(bytes("1108ff00a6a11a000300"))
        XCTAssertEqual(outer?.op, OuraFraming.getEventsResponseOp)
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.eventsReceived, 0xFF)
        XCTAssertEqual(summary?.bytesLeft, 1_745_318)
        XCTAssertEqual(summary?.moreData, true)
    }

    func testParseGetEventsResponseCompleteAtZeroBytesLeft() {
        // REAL on-device capture (final summary of a completed drain): bytes_left == 0 -> caught up.
        let outer = OuraFraming.parseOuterFrame(bytes("11080000000000000300"))
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.eventsReceived, 0)
        XCTAssertEqual(summary?.bytesLeft, 0)
        XCTAssertEqual(summary?.moreData, false)
    }

    func testParseGetEventsResponseZeroEventsButBytesLeftIsMoreData() {
        // THE #91 regression case, byte-for-byte from the 2026-07-11 18:53 log: events_received == 0 but
        // bytes_left = e9 1d 06 00 = 400,873. The old parse read body[0] as a status and STOPPED here,
        // abandoning the newest 400 KB of the log (the previous night's hypnogram). moreData must be true.
        let outer = OuraFraming.parseOuterFrame(bytes("11080000e91d06000300"))
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.eventsReceived, 0)
        XCTAssertEqual(summary?.bytesLeft, 400_873)
        XCTAssertEqual(summary?.moreData, true, "bytes_left > 0 means the drain MUST continue")
    }

    func testParseGetEventsResponseShortBodyReturnsNil() {
        XCTAssertNil(OuraFraming.parseGetEventsResponse(bytes("ff0012")))
    }

    // MARK: - Secure-session sub-frame (0x2F)

    func testSecureFrameNonceResponse() {
        // Wire: 2f 10 2c <nonce:15>. Outer: op 0x2F, len 0x10 (16), body = 2c + 15 nonce bytes.
        let wire = bytes("2f102c0102030405060708090a0b0c0d0e0f")
        guard let outer = OuraFraming.parseOuterFrame(wire) else { return XCTFail("outer parse") }
        XCTAssertEqual(outer.op, 0x2F)
        guard let secure = OuraFraming.parseSecureFrame(outer) else { return XCTFail("secure parse") }
        XCTAssertEqual(secure.subop, 0x2C)
        XCTAssertEqual(secure.subBody, bytes("0102030405060708090a0b0c0d0e0f"))
        // And the auth layer pulls the 15-byte nonce straight out.
        XCTAssertEqual(OuraAuth.nonce(from: secure), bytes("0102030405060708090a0b0c0d0e0f"))
    }

    func testSecureFrameAuthStatus() {
        // 2f 02 2e 00 -> success.
        let wire = bytes("2f022e00")
        guard let outer = OuraFraming.parseOuterFrame(wire),
              let secure = OuraFraming.parseSecureFrame(outer) else { return XCTFail("parse") }
        XCTAssertEqual(secure.subop, 0x2E)
        XCTAssertEqual(OuraAuth.authStatus(from: secure), .success)
    }

    func testNonSecureFrameReturnsNilSecure() {
        let outer = OuraOuterFrame(op: 0x0D, body: [0x01])
        XCTAssertNil(OuraFraming.parseSecureFrame(outer))
    }

    // MARK: - TLV record parsing

    func testParseTLVRecord() {
        // 7b 06 <rt:4 LE 02000100> 03 ca  -> type 0x7B, rt 0x00010002, payload 03 ca.
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.counter, 0x0002)
        XCTAssertEqual(rec?.session, 0x0001)
        XCTAssertEqual(rec?.payload, bytes("03ca"))
        XCTAssertEqual(rec?.totalLength, 8)
    }

    func testTLVLenBelowFourIsRejected() {
        // len must be >= 4 to cover the 4 timestamp bytes; len=3 -> nil (honest, no guess).
        XCTAssertNil(OuraFraming.parseRecord([0x7B, 0x03, 0x00, 0x01, 0x02]))
    }

    func testTLVBelowSixBytesIsRejected() {
        // A record floor is 6 bytes (2 header + 4 timestamp). Fewer than that cannot yield a ring time.
        XCTAssertNil(OuraFraming.parseRecord([0x7B, 0x06, 0x02, 0x00, 0x01]))   // only 5 bytes
    }

    // MARK: - Lenient parse (open_oura Packet::parse): len need not equal notification length

    func testParseRecordIgnoresTrailingBytesBeyondLen() {
        // A notification carrying a complete record PLUS trailing bytes (BLE padding, or a following
        // packet the ring did not pack for us) yields exactly ONE record whose payload is the declared
        // `len - 4` bytes; the trailing bytes are ignored, never minted into a phantom record.
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca" + "ffeeddcc"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.payload, bytes("03ca"), "payload is exactly len-4; trailing bytes dropped")
    }

    func testParseRecordTooBigLenUsesWhatArrived() {
        // `len` claims a longer payload than the notification carries. open_oura tolerates the
        // disagreement and uses the bytes present, rather than waiting for (and swallowing) the next
        // notification. Here len=0x0A (payload 6) but only 2 payload bytes arrived.
        let rec = OuraFraming.parseRecord(bytes("7b0a0200010003ca"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.payload, bytes("03ca"), "uses the 2 payload bytes present, no wait")
    }

    // MARK: - One packet per notification (no buffering, no multi-record loop, no resync)

    func testFeedReturnsAtMostOneRecordPerNotification() {
        // What LOOKS like two packed records is treated as ONE lenient packet: the first record only,
        // trailing bytes ignored. The ring never packs several events into one notification (it streams
        // one event per notification + a 0x11 summary), so this is the honest interpretation.
        let r = OuraReassembler()
        let recs = r.feed(bytes("7b060200010003ca" + "4e0602000100006c"))
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].type, 0x7B)
        XCTAssertEqual(recs[0].payload, bytes("03ca"))
    }

    func testFeedNeverBuffersAcrossNotifications() {
        // A too-short notification is dropped whole (no leftover bytes carried); the NEXT notification is
        // parsed independently. This is the property the old buffering reassembler lacked — a leftover
        // partial used to corrupt the following notification into the phantom-record storm.
        let r = OuraReassembler()
        XCTAssertTrue(r.feed(bytes("7b0602")).isEmpty, "3-byte fragment is below the record floor")
        XCTAssertEqual(r.bufferedByteCount, 0, "nothing is retained between notifications")
        let recs = r.feed(bytes("4e0602000100006c"))
        XCTAssertEqual(recs.map { $0.type }, [0x4E], "next notification parses cleanly on its own")
    }

    func testFeedDropsUnusableNotificationWholeNoResync() {
        // A notification whose len is < 4 is not walked byte-by-byte looking for a later record (there is
        // no start-of-frame marker to realign to, and byte-walking is exactly what minted phantoms). It
        // is dropped whole: no record, no buffered tail.
        let r = OuraReassembler()
        let recs = r.feed([0x00, 0x01, 0x02, 0x03, 0x01, 0x02])   // len byte 0x01 < 4
        XCTAssertTrue(recs.isEmpty)
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    func testResetIsANoOpWithNoBufferedState() {
        let r = OuraReassembler()
        _ = r.feed(bytes("7b0602"))            // below floor, nothing retained
        XCTAssertEqual(r.bufferedByteCount, 0)
        r.reset()
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    // MARK: - 0x13 SyncTime response (ringverse BLE.md: device_ts u32 LE + status)

    func testParseSyncTimeResponse() {
        // ringverse example body: 4b ed a9 00 00 -> device_ts 0x00A9ED4B, status 0.
        let r = OuraFraming.parseSyncTimeResponse(bytes("4beda90000"))
        XCTAssertEqual(r?.deviceTimestamp, 0x00A9_ED4B)
        XCTAssertEqual(r?.status, 0)
        // Short body -> nil, never a guessed timestamp.
        XCTAssertNil(OuraFraming.parseSyncTimeResponse(bytes("4beda900")))
    }

    // MARK: - 0x13 -> anchor tick disambiguation (OuraDriver.syncTimeAnchorCandidate)

    func testSyncTimeAnchorCandidateResolvesUnit() {
        // The 2026-07-13 shape: floor banked at 4_413_933 (last night's log end); ~11 h later the
        // ring's clock is ~4.81M ticks. A raw-ticks response fits the [floor, floor+45d] window and
        // the seconds x10 reading does not -> unambiguous ticks.
        XCTAssertEqual(OuraDriver.syncTimeAnchorCandidate(responseValue: 4_810_000, lowerBoundTicks: 4_413_933),
                       4_810_000)
        // A seconds-unit response (481_000 s = 4.81M ticks) only fits when multiplied x10.
        XCTAssertEqual(OuraDriver.syncTimeAnchorCandidate(responseValue: 481_000, lowerBoundTicks: 4_413_933),
                       4_810_000)
        // Below the floor in both readings (ring reboot / stale value) -> nil.
        XCTAssertNil(OuraDriver.syncTimeAnchorCandidate(responseValue: 100_000, lowerBoundTicks: 4_413_933))
        // Beyond floor+45d in both readings -> nil.
        XCTAssertNil(OuraDriver.syncTimeAnchorCandidate(responseValue: 50_000_000, lowerBoundTicks: 4_413_933))
        // No reference at all -> nil (never guess).
        XCTAssertNil(OuraDriver.syncTimeAnchorCandidate(responseValue: 4_810_000, lowerBoundTicks: 0))
        // Ambiguity guard: BOTH readings inside the window -> nil. Reachable only while the floor is
        // under window/9 (~5 days of ring clock), i.e. a barely-run ring.
        XCTAssertNil(OuraDriver.syncTimeAnchorCandidate(responseValue: 150_000, lowerBoundTicks: 140_000))
    }

    /// Regression from the 2026-09-02/03 iOS captures. The ring's 0x13 reply reads 0x0218767f =
    /// 35_157_631 ticks while the persisted resume cursor sits at 28_073_725 — 8.20 days behind. Under the
    /// old 7-day window neither reading fit, so no anchor was adopted; with no anchor the drain-end commit
    /// could not advance the cursor (`resumeCursorAtDrainEnd(resolvesUnderAnchor: false)` returns it
    /// unchanged), so the cursor stayed stale and the gap only grew — a permanent loop, one full re-serve
    /// of the same window per launch. The widened window resolves it, unambiguously.
    func testSyncTimeAnchorCandidateAcceptsAStaleCursorFromTheCaptures() {
        let staleCursor: UInt32 = 28_073_725          // banked 2026-08-26 02:49:56 by the 300 s guard
        for reply: UInt32 in [0x0218767f, 0x02187ce8, 0x02189fce] {   // the three 09-03 launches
            XCTAssertEqual(OuraDriver.syncTimeAnchorCandidate(responseValue: reply,
                                                              lowerBoundTicks: staleCursor),
                           reply, "0x\(String(reply, radix: 16)) must resolve as raw ticks")
        }
        // The old 7-day window is what excluded it: 28_073_725 + 6_048_000 = 34_121_725 < 35_157_631.
        XCTAssertGreaterThan(OuraDriver.syncTimeAnchorWindowTicks, 35_157_631 - Int64(staleCursor),
                             "the window must cover the observed 8.2-day staleness")
    }

    /// The other half of the deadlock: on a fresh pair / post-reboot reset the cursor is 0, so it
    /// can never be the reference. The drain's `maxSeenRingTime` can — it counts EVERY history record's
    /// envelope time and needs no anchor to read — so the caller retries the parked reply against it.
    func testSyncTimeAnchorCandidateResolvesAgainstSeenRingTimeWhenCursorIsZero() {
        let reply: UInt32 = 0x0211dbd0                // 34_724_816 — the 2026-09-02 capture, cursor 0
        XCTAssertNil(OuraDriver.syncTimeAnchorCandidate(responseValue: reply, lowerBoundTicks: 0))
        // First batch of a full pull lands the ring's OLDEST banked record (~14 days back).
        let oldestBanked: UInt32 = 34_724_816 - 12_096_000
        XCTAssertEqual(OuraDriver.syncTimeAnchorCandidate(responseValue: reply,
                                                          lowerBoundTicks: oldestBanked),
                       reply)
    }

    func testAdoptSyncTimeAnchorResolvesHistoryTimes() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)
        let now: Int64 = 1_784_000_000                     // inside the 2020-2035 plausibility window
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 4_800_000), "no anchor yet")
        XCTAssertTrue(d.adoptSyncTimeAnchor(ringTimestamp: 4_810_000, unixSeconds: now))
        // A record 10_000 ticks (1000 s) before the anchor resolves to now - 1000.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: 4_800_000), Int(now) - 1000)
        // An implausible host epoch is refused (never anchors to a garbage clock).
        XCTAssertFalse(d.adoptSyncTimeAnchor(ringTimestamp: 4_810_000, unixSeconds: 100))
    }
}
