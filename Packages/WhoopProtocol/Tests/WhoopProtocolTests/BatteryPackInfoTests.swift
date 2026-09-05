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

    /// WHOOP 4.0 path: the pack is read via GET_EXTENDED_BATTERY_INFO (98), reporting VOLTAGE not a %.
    /// The frame is the #592 WHOOP4 capture (pay[7..8] = 0x0f82 = 3970 mV). The Kotlin twin asserts the same.
    func testWhoop4PackReportsVoltageNotPercent() {
        let realFrame = "aa2400fa24c6620d010165006bff820f0c0128000f05e90321120200010100001a0000004675fe58"
        let info = BatteryPackInfo.decodeExtended(frame: bytes(realFrame))
        XCTAssertEqual(info?.present, true)
        XCTAssertEqual(info?.voltageMv, 3970)   // 3.97 V
        XCTAssertNil(info?.socPct)              // 4.0 has no fuel-gauge %
        XCTAssertNil(info?.serial)
        // A 5/MG 151 frame is not a 98 response → nil; and the 5/MG SoC decode never fills voltage.
        XCTAssertNil(BatteryPackInfo.decodeExtended(frame: bytes(attachedHex)))
        XCTAssertNil(BatteryPackInfo.decode(frame: bytes(attachedHex))?.voltageMv)
    }

    /// The gauge must be sanity-checked before it is shown. These offsets are an unvalidated candidate
    /// re-derived from two captures; a wrong one does not fail, it renders a confident wrong number — the
    /// failure this project treats as worse than a blank. A percentage outside 0...100 means the offset
    /// moved, so the caller renders nothing.
    func testOutOfRangeChargeIsNotDisplayable() {
        XCTAssertFalse(BatteryPackInfo.Info(present: true, socPct: 2488.1, serial: "P", btAddr: "aa").displayable)
        XCTAssertFalse(BatteryPackInfo.Info(present: true, socPct: -1, serial: "P", btAddr: "aa").displayable)
    }

    /// A plausible gauge on an attached pack is the one case that shows.
    func testInRangeChargeOnAnAttachedPackIsDisplayable() {
        XCTAssertTrue(BatteryPackInfo.Info(present: true, socPct: 73.4, serial: "P", btAddr: "aa").displayable)
        XCTAssertTrue(BatteryPackInfo.Info(present: true, socPct: 0, serial: "P", btAddr: "aa").displayable)
        XCTAssertTrue(BatteryPackInfo.Info(present: true, socPct: 100, serial: "P", btAddr: "aa").displayable)
    }

    /// A removed pack must clear the card, never hold the last reading.
    func testAbsentPackIsNeverDisplayable() {
        XCTAssertFalse(BatteryPackInfo.Info(present: false, socPct: nil, serial: nil, btAddr: nil).displayable)
        // Even if a stale charge rides along, absence wins.
        XCTAssertFalse(BatteryPackInfo.Info(present: false, socPct: 80, serial: nil, btAddr: nil).displayable)
    }

    /// The router branch that decodes this reply matches on the command NAME
    /// (`cmdName.hasPrefix("GET_BATTERY_PACK_INFO(")`), which comes from the schema's CommandNumber table.
    /// A rename or a removal there would not fail to compile — the branch would simply stop matching and
    /// the whole feature would go quiet, with the decoder back to having no caller. Pin the string.
    func testCommand151ResolvesToTheNameTheRouterMatchesOn() {
        XCTAssertEqual(loadSchema().enumName("CommandNumber", 151), "GET_BATTERY_PACK_INFO(151)")
    }

    /// `displayable` is about a CHARGE percentage, and the 4.0 path carries a voltage instead — so it is
    /// always false there, correctly. Pinned because the name is generic enough that a future 4.0 voltage
    /// card might reach for this gate and get a permanent no.
    func testFourPointOhVoltagePathIsNeverDisplayable() {
        let v = BatteryPackInfo.Info(present: true, socPct: nil, serial: nil, btAddr: nil, voltageMv: 3_900)
        XCTAssertFalse(v.displayable)
    }
}
