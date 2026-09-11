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
}
