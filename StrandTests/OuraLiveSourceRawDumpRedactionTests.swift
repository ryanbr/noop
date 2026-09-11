import XCTest
import OuraProtocol
@testable import Strand

/// `OuraLiveSource.rawDumpBytes` is what actually reaches `oura-raw.jsonl` — the sidecar's own
/// redaction pass only ever masks the JSON envelope's `deviceId`, never bytes inside a frame body.
/// A `0x18`/`0x19` GetProductInfo reply's body IS the ring's serial/hardware string in plain ASCII
/// (found via a user's own capture, which carried a stable 16-digit identifier into a public GitHub
/// issue attachment this way). These pin that the raw sidecar never sees that frame, while every
/// other frame — including ones that happen to share a notification with it — is untouched.
final class OuraLiveSourceRawDumpRedactionTests: XCTestCase {
    private func encoded(_ frames: [OuraOuterFrame]) -> [UInt8] {
        frames.flatMap { [$0.op, UInt8($0.body.count)] + $0.body }
    }

    func testProductInfoRequestAndResponseAreBothDropped() {
        let serial = Array("2038082631034041".utf8)
        let frames = [OuraOuterFrame(op: 0x18, body: [0x08, 0x00, 0x10]),
                      OuraOuterFrame(op: 0x19, body: serial)]
        XCTAssertEqual(OuraLiveSource.rawDumpBytes(frames), [])
    }

    func testAnOrdinaryFrameIsUnaffected() {
        let frames = [OuraOuterFrame(op: 0x5D, body: [0x01, 0x02, 0x03])]
        XCTAssertEqual(OuraLiveSource.rawDumpBytes(frames), encoded(frames))
    }

    func testOnlyTheProductInfoFrameIsStrippedOutOfAMixedNotification() {
        let hr = OuraOuterFrame(op: 0x80, body: [0x42])
        let productInfo = OuraOuterFrame(op: 0x19, body: Array("COR_08".utf8))
        let battery = OuraOuterFrame(op: 0x0D, body: [0x64])
        XCTAssertEqual(OuraLiveSource.rawDumpBytes([hr, productInfo, battery]), encoded([hr, battery]))
    }

    /// PR #2090 review (ryanbr): `parseOuterFrames` silently drops an incomplete trailing frame
    /// (`guard i + total <= bytes.count else { break }`) — ordinary, not rare, since the Reassembler
    /// exists precisely because notifications split mid-frame. A caller reconstructing the sidecar from
    /// `frames` alone therefore loses that unconsumed remainder. Reproduces the exact worked example from
    /// the review: `41 02 AA BB 42 05 01 02` parses ONE complete frame (`41 02 AA BB`, 4 bytes) and leaves
    /// `42 05 01 02` (4 of the claimed 7 body bytes) unconsumed - `rawDumpBytes(fromNotification:frames:)`
    /// must still carry it into the sidecar, verbatim, appended after the (filtered) complete frames.
    func testIncompleteTrailingFrameSurvivesAsATailNotAsALoss() {
        let bytes: [UInt8] = [0x41, 0x02, 0xAA, 0xBB, 0x42, 0x05, 0x01, 0x02]
        let frames = OuraFraming.parseOuterFrames(bytes)
        XCTAssertEqual(frames, [OuraOuterFrame(op: 0x41, body: [0xAA, 0xBB])], "sanity: only one frame parses")
        let dump = OuraLiveSource.rawDumpBytes(fromNotification: bytes, frames: frames)
        XCTAssertEqual(dump, bytes, "the unconsumed tail must survive verbatim, not be dropped")
    }

    /// The same convenience function must still drop a product-info frame when the notification parses
    /// cleanly with nothing left over (the ordinary case, no tail to preserve).
    func testNotificationConvenienceStillStripsProductInfoWithNoTrailingPartial() {
        let serial = Array("2038082631034041".utf8)
        let bytes: [UInt8] = [0x19, UInt8(serial.count)] + serial
        let frames = OuraFraming.parseOuterFrames(bytes)
        XCTAssertEqual(OuraLiveSource.rawDumpBytes(fromNotification: bytes, frames: frames), [])
    }

    func testSplitProductInfoFrameTailIsDroppedNotAppended() {
        let partialSerial = Array("2H3B2405003655".utf8) // 14 of the 20 bytes the header claims
        let bytes: [UInt8] = [0x41, 0x02, 0xAA, 0xBB, 0x19, 0x14] + partialSerial
        let frames = OuraFraming.parseOuterFrames(bytes)
        XCTAssertEqual(frames, [OuraOuterFrame(op: 0x41, body: [0xAA, 0xBB])], "sanity: only one frame parses")
        let dump = OuraLiveSource.rawDumpBytes(fromNotification: bytes, frames: frames)
        XCTAssertEqual(dump, [0x41, 0x02, 0xAA, 0xBB], "the split product-info tail must be dropped whole")
        XCTAssertFalse(String(decoding: dump, as: UTF8.self).contains("2H3B2405003655"))
    }

    /// The same guard applies to a bare one-byte remainder (just the op, not even a length byte yet) -
    /// the review's "a one-byte remainder is fine to test the same way" note.
    func testOneByteProductInfoOpRemainderIsDropped() {
        let bytes: [UInt8] = [0x41, 0x02, 0xAA, 0xBB, 0x18]
        let frames = OuraFraming.parseOuterFrames(bytes)
        let dump = OuraLiveSource.rawDumpBytes(fromNotification: bytes, frames: frames)
        XCTAssertEqual(dump, [0x41, 0x02, 0xAA, 0xBB])
    }
}
