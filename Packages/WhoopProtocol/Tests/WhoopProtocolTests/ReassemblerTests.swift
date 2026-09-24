import XCTest
@testable import WhoopProtocol

final class ReassemblerTests: XCTestCase {
    // Build a real ~1928-byte type-43 frame from a 1917-byte synthetic payload so the
    // test is self-contained (no capture dependency): inner = 1917+3, length = 1924,
    // total = 1928. Reassembly must reproduce it exactly from 244-byte fragments.
    private func bigFrame() -> [UInt8] {
        let payload = (0..<1917).map { UInt8($0 & 0xFF) }
        return frameFromPayload(payload, type: 43, seq: 7, cmd: 0)
    }

    func testReassembleFromFragments() {
        let frame = bigFrame()
        XCTAssertEqual(frame.count, 1928)
        var fragments: [[UInt8]] = []
        var i = 0
        while i < frame.count {
            fragments.append(Array(frame[i..<min(i + 244, frame.count)]))
            i += 244
        }
        XCTAssertEqual(fragments.count, 8)
        // Only the first fragment carries the 0xAA SOF.
        XCTAssertEqual(fragments[0].first, 0xAA)
        for f in fragments.dropFirst() {
            XCTAssertNotEqual(f.first, 0xAA)
        }
        let r = Reassembler()
        var assembled: [[UInt8]] = []
        for f in fragments {
            assembled.append(contentsOf: r.feed(f))
        }
        XCTAssertEqual(assembled.count, 1)
        XCTAssertEqual(assembled[0], frame)
    }

    func testTwoFramesInOneFeed() {
        let a = frameFromPayload([0x01, 0x02], type: 40)
        let b = frameFromPayload([0x03, 0x04], type: 48)
        let r = Reassembler()
        let out = r.feed(a + b)
        XCTAssertEqual(out, [a, b])
    }

    func testReassembleFromOneBytePerFragment() {
        // Two back-to-back frames, fed a single byte per fragment. This is the worst case for the old
        // removeFirst drain and exercises the offset/compact window hard: head advances byte by byte,
        // compact() slides the tail every feed(). Output must still be the two exact frames, in order.
        let a = frameFromPayload([0x01, 0x02], type: 40)
        let b = frameFromPayload([0x03, 0x04], type: 48)
        let r = Reassembler()
        var out: [[UInt8]] = []
        for byte in a + b {
            out.append(contentsOf: r.feed([byte]))
        }
        XCTAssertEqual(out, [a, b])
    }

    func testLeadingGarbageIsSkipped() {
        let a = frameFromPayload([0x09], type: 40)
        let r = Reassembler()
        let out = r.feed([0x11, 0x22, 0x33] + a)
        XCTAssertEqual(out, [a])
    }

    func testPartialFrameWaitsForRest() {
        let a = frameFromPayload([0x01, 0x02, 0x03, 0x04], type: 40)
        let r = Reassembler()
        XCTAssertTrue(r.feed(Array(a[0..<5])).isEmpty)        // header + part
        XCTAssertEqual(r.feed(Array(a[5..<a.count])), [a])    // remainder completes it
    }

    func testOversizedDeclaredLengthResyncsInsteadOfWedging() {
        // A corrupt/misaligned 0xAA declaring an impossibly large length (a bit-flip or a spurious
        // mid-frame SOF) must be dropped so the stream resyncs to the next real frame. Without the
        // ceiling, feed() would wait forever for bytes that can never arrive and the live stream
        // would freeze until a reconnect. (Reimplemented from @vulnix0x4's PR #374.)
        let valid = frameFromPayload([0x09], type: 40)
        let r = Reassembler()
        // Spurious SOF with a 0xFFFF length (total 65539, far past the 8 KB ceiling), then a real
        // frame. With the cap, the real frame emerges instead of the stream wedging.
        let out = r.feed([0xAA, 0xFF, 0xFF, 0x00] + valid)
        XCTAssertEqual(out, [valid], "a garbage oversized SOF must not wedge the stream")
    }

    /// A false start-of-frame whose declared length is PLAUSIBLE, which the floor and ceiling guards
    /// both accept. Before the header-checksum gate, feed() waited for that many bytes and emitted them
    /// as a single frame, consuming the valid frames that fell inside it — they never reached a parser
    /// and nothing downstream could put them back, because the CRC32 that rejects the bad frame runs
    /// after `head` has advanced past them.
    ///
    /// Built to be exactly the case the range guards miss: length 0x0064 gives total 104, well past the
    /// WHOOP 4.0 floor and far under the 8 KB ceiling. The byte at offset 3 is a deliberately wrong
    /// header CRC-8, which is what a payload byte read as a frame start looks like.
    func testFalseSOFWithAnInRangeLengthDoesNotSwallowTheFramesBehindIt() {
        let first = frameFromPayload([0x01, 0x02, 0x03], type: 40)
        let second = frameFromPayload([0x04, 0x05], type: 41)
        // 0xAA, length 100 (in range), then a crc8 that cannot be right for those length bytes.
        let wrongCRC = crc8([0xAA, 0x64, 0x00], 1, 3) ^ 0xFF
        let falseSOF: [UInt8] = [0xAA, 0x64, 0x00, wrongCRC]
        let r = Reassembler()
        let out = r.feed(falseSOF + first + second)
        XCTAssertEqual(out, [first, second],
                       "a false SOF must resync by one byte, not eat the frames behind it")
        XCTAssertEqual(r.headerChecksumDrops, 1, "and the drop must be counted, not silent")
    }

    /// The gate must not cost a real frame. Every valid frame carries a correct header checksum, so
    /// this is the half that would break loudly if the CRC span or byte order were wrong.
    func testAValidFrameStillPassesTheHeaderGate() {
        let frame = frameFromPayload([0x09, 0x08, 0x07], type: 40)
        let r = Reassembler()
        XCTAssertEqual(r.feed(frame), [frame])
        XCTAssertEqual(r.headerChecksumDrops, 0, "a real frame must never be counted as a false SOF")
    }

    /// A 5/MG false SOF is rejected by its CRC-16 header for the same reason, on the family whose
    /// length lives at a different offset — so a gate written for one family cannot silently pass here.
    func testFalseSOFIsRejectedOnWhoop5Too() {
        let r = Reassembler(family: .whoop5)
        // 0xAA, fmt, declared length 0x0040 (total 72: in range), header bytes, then a bad CRC16.
        let falseSOF: [UInt8] = [0xAA, 0x01, 0x40, 0x00, 0x00, 0x00, 0xFF, 0xFF]
        let out = r.feed(falseSOF)
        XCTAssertEqual(out, [], "nothing to emit")
        XCTAssertEqual(r.headerChecksumDrops, 1, "the bad 5/MG header must be counted and resynced")
    }
}
