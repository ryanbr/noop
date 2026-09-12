import XCTest
@testable import WhoopProtocol

final class FramingTests: XCTestCase {
    // Synthetic, CRC-valid frames built by scripts/gen_synthetic_fixtures.py (no real capture).
    static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    func testVerifyFrameRealtimeData() {
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 24)
        XCTAssertEqual(check.crc8OK, true)
        XCTAssertEqual(check.crc32OK, true)
    }

    func testVerifyFrameCommandResponse() {
        let frame = Self.hex("aa10005724241a0000ff000000000000ac811df4")
        XCTAssertTrue(verifyFrame(frame).ok)
    }

    func testFlippingByteBreaksCRC() {
        var frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        frame[10] ^= 0xFF // corrupt an inner byte -> crc32 must fail
        let check = verifyFrame(frame)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.crc8OK, true)   // header CRC untouched
        XCTAssertEqual(check.crc32OK, false) // body CRC now wrong
    }

    func testFlippingCrc8ByteBreaksCRC() {
        var frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        frame[3] ^= 0xFF
        XCTAssertEqual(verifyFrame(frame).crc8OK, false)
    }

    func testShortFrameRejected() {
        XCTAssertFalse(verifyFrame([0xAA, 0x01, 0x02]).ok)
        XCTAssertEqual(verifyFrame([0xAA, 0x01, 0x02]).length, nil)
    }

    func testNonSOFRejected() {
        let bad: [UInt8] = [0x00, 0x18, 0x00, 0xff, 0x28, 0x02, 0x0f, 0x00]
        XCTAssertFalse(verifyFrame(bad).ok)
    }

    func testCrc32EmptyIsZero() {
        XCTAssertEqual(crc32([]), 0)
    }

    func testCrc8KnownVector() {
        // crc8 over the 2 length bytes of the realtime frame: bytes [0x18,0x00] -> 0xff.
        XCTAssertEqual(crc8([0x18, 0x00]), 0xff)
    }

    func testFrameFromPayloadRoundTrip() {
        // Bare payload of 4 bytes; type=43, seq=0, cmd=0.
        let data: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let frame = frameFromPayload(data, type: 43, seq: 0, cmd: 0)
        // inner = [43,0,0] + data (7 bytes); length = 7 + 4 = 11.
        XCTAssertEqual(frame[0], 0xAA)
        XCTAssertEqual(Int(frame[1]) | (Int(frame[2]) << 8), 11)
        // The header checksum is computed for real (it used to be a 0x00 placeholder), so a rebuilt
        // frame is one a strap could have sent rather than one every gate now rejects.
        XCTAssertEqual(frame[3], crc8([frame[1], frame[2]]))
        XCTAssertEqual(frame[4], 43)
        XCTAssertEqual(frame[5], 0)
        XCTAssertEqual(frame[6], 0)
        XCTAssertEqual(Array(frame[7..<11]), data)
        // crc32 is over the inner bytes (type+seq+cmd+data).
        let inner: [UInt8] = [43, 0, 0] + data
        let want = crc32(inner)
        let got = UInt32(frame[11]) | (UInt32(frame[12]) << 8)
            | (UInt32(frame[13]) << 16) | (UInt32(frame[14]) << 24)
        XCTAssertEqual(got, want)
        // The reconstructed frame verifies end to end: both checksums AND the exact length.
        let check = verifyFrame(frame)
        XCTAssertEqual(check.crc32OK, true)
        XCTAssertEqual(check.crc8OK, true)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.reason, .none)
    }

    func testFrameFromPayloadDefaults() {
        let frame = frameFromPayload([0x01], type: 40)
        XCTAssertEqual(frame[5], 0) // seq default
        XCTAssertEqual(frame[6], 0) // cmd default
    }
}
