import XCTest
@testable import WhoopProtocol

/// GET_BATTERY_PACK_INFO (151) has two answers and the Devices card must behave oppositely on each: a
/// reply naming a pack fills the row, a reply naming none must CLEAR it. Both frames below came off one
/// WHOOP 5 strap — pack attached, then physically removed — so the decode is pinned to real bytes. The
/// Kotlin `BatteryPackInfoTest` asserts the same values, keeping the two decoders byte-identical.
final class BatteryPackInfoTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let a = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[a...s.index(a, offsetBy: 1)], radix: 16)!
        }
    }

    private let attachedHex =
        "aa01280001002de1245c9704010101f7381d2e3161574242354150303132363339" +
        "35000000e5020c01000000be577aee"
    private let absentHex =
        "aa01280001002de1240797040101000000000000000000000000000000000000" +
        "000000000000000000000000cf8e5340"

    func testAttachedPackNamesItsChargeAndSerial() {
        let info = BatteryPackInfo.decode(frame: bytes(attachedHex))
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.present, true)
        XCTAssertEqual(info?.socPct ?? 0, 74.1, accuracy: 1e-9)
        XCTAssertEqual(info?.serial, "WBB5AP0126395")
        XCTAssertEqual(info?.btAddr, "f7381d2e3161")
    }

    func testRemovedPackReportsAbsenceNotAStaleReading() {
        let info = BatteryPackInfo.decode(frame: bytes(absentHex))
        XCTAssertEqual(info?.present, false)
        XCTAssertNil(info?.socPct)
        XCTAssertNil(info?.serial)
        XCTAssertNil(info?.btAddr)
    }

    func testNonPackOrShortFrameIsNil() {
        XCTAssertNil(BatteryPackInfo.decode(frame: bytes("aa0128000100"))) // too short
        // A 151 response whose result byte is not SUCCESS decodes to nil.
        var f = bytes(attachedHex); f[12] = 0 // result = FAILURE
        XCTAssertNil(BatteryPackInfo.decode(frame: f))
    }

    /// Edge vectors mutated off the attached golden. The Kotlin twin asserts the SAME results, byte for
    /// byte — including the non-ASCII-serial case, where both must return a nil serial (not a garbage one).
    func testEdgeVectorsDecodeIdenticallyToKotlin() {
        let base = bytes(attachedHex)
        func mut(_ kv: [Int: UInt8]) -> [UInt8] { var f = base; for (i, v) in kv { f[i] = v }; return f }
        XCTAssertEqual(BatteryPackInfo.decode(frame: mut([37: 0, 38: 0]))?.socPct ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(BatteryPackInfo.decode(frame: mut([37: 0xe8, 38: 0x03]))?.socPct ?? -1, 100.0, accuracy: 1e-9)
        XCTAssertNil(BatteryPackInfo.decode(frame: mut([21: 0]))?.serial)            // empty serial → nil
        let hb = BatteryPackInfo.decode(frame: mut([21: 0x80]))                       // non-ASCII byte
        XCTAssertEqual(hb?.present, true)
        XCTAssertNil(hb?.serial)                                                      // undecodable → nil
        XCTAssertNil(BatteryPackInfo.decode(frame: mut([10: 0])))                     // not a 151 response
        XCTAssertNil(BatteryPackInfo.decode(frame: mut([12: 0])))                     // not SUCCESS
    }
}
