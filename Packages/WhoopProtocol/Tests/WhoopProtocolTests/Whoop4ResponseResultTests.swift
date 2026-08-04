import XCTest
@testable import WhoopProtocol

/// COMMAND_RESPONSE origin-seq echo + result code — the Swift twin of Android's `Whoop4ResponseResultTest`
/// (#894, closing the gap #791 closed on the other platform).
///
/// Kotlin has published `resp_seq` and `result` on 5/MG since the port and on 4.0 since #791. Swift published
/// neither, on either family: an Apple strap log named the command a response was for and then said nothing
/// about whether it had succeeded. The consequence was not only cosmetic — every probe that needed the answer
/// re-derived the byte privately (`FeatureFlagProbe.resultLabel`, `DeviceConfigReadProbe`,
/// `BodyLocationProbe`'s "Result code @12"), three copies of one two-line decode.
///
/// The frames below are the **same real captures the Kotlin test uses**, byte for byte, so the two suites now
/// assert the same decode of the same bytes — which is the only thing that actually holds two independent
/// reimplementations together. They come from the #791 report (WHOOP 4.0, Galaxy S24 Ultra).
final class Whoop4ResponseResultTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// A `GET_DATA_RANGE` the strap actually answered: result `0x01` = SUCCESS, origin-seq echo `0x0A`.
    private let answeredDataRangeHex =
        "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
        "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"

    func testAnsweredDataRangeReportsSuccessAndItsOriginSeq() {
        let f = parseFrame(bytes(answeredDataRangeHex))
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["resp_cmd"]?.stringValue, "GET_DATA_RANGE(34)")
        XCTAssertEqual(f.parsed["resp_seq"]?.intValue, 0x0A)
        XCTAssertEqual(f.parsed["result"]?.stringValue, "SUCCESS(1)")
    }

    /// The empty extended-battery reply at the heart of #791: acknowledged, correct echo, result FAILURE with
    /// an all-zero payload. Without the result byte this is indistinguishable from a success carrying zeros —
    /// a materially different conclusion, and the one the reporter had to hand-decode from raw hex.
    private var emptyExtendedBatteryHex: String {
        "aa2400fa2495622200" + String(repeating: "00", count: 27) + "0ac33306"
    }

    func testEmptyExtendedBatteryReplyReportsFailureNotEmptySuccess() {
        let f = parseFrame(bytes(emptyExtendedBatteryHex))
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["resp_cmd"]?.stringValue, "GET_EXTENDED_BATTERY_INFO(98)")
        XCTAssertEqual(f.parsed["resp_seq"]?.intValue, 0x22)
        XCTAssertEqual(f.parsed["result"]?.stringValue, "FAILURE(0)")
    }

    /// The duplicate-write symptom the echo makes legible. One `GET_DATA_RANGE` send produced three CRC-valid
    /// responses whose strap-side seq advanced (0x7E/0x7F/0x80) while the origin-seq echo stayed at 0x0A — so
    /// the strap really did receive the command three times, visible in a log instead of by frame archaeology.
    func testDuplicateResponsesShareOneOriginSeqAcrossAdvancingStrapSeq() {
        let bodyAfterCmd = "0a01010000000050070100a307010050070100000000000000020035030000" +
            "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"
        let echoes = ["7e", "7f", "80"].map { strapSeq -> Int? in
            let f = parseFrame(bytes("aa4c00a724\(strapSeq)22" + bodyAfterCmd))
            XCTAssertEqual(f.parsed["resp_cmd"]?.stringValue, "GET_DATA_RANGE(34)")
            return f.parsed["resp_seq"]?.intValue
        }
        XCTAssertEqual(echoes, [0x0A, 0x0A, 0x0A] as [Int?])
    }

    /// Fails closed. A response whose declared payload stops before the result byte must decode neither field
    /// rather than read the CRC32 trailer as a result code — the reason both fields are read from the bounded
    /// payload slice and not from a raw frame offset.
    func testShortResponseDecodesNoResultRatherThanReadingTheCrc() {
        // Inner record is [type][seq][cmd] only: declared length 7, so the payload is empty and the four
        // bytes at offsets 7..10 are the CRC32 trailer.
        let inner: [UInt8] = [36, 0x11, 34]
        var frame: [UInt8] = [0xAA, 7, 0, 0]
        frame[3] = crc8(Array(frame[1..<3]))
        frame += inner
        let c32 = crc32(inner)
        frame += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF),
                  UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]

        let f = parseFrame(frame)
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["resp_cmd"]?.stringValue, "GET_DATA_RANGE(34)")
        XCTAssertNil(f.parsed["resp_seq"])
        XCTAssertNil(f.parsed["result"])
    }

    /// An oddity in one `GET_BATTERY_LEVEL` fixture, pinned rather than left to surprise someone.
    ///
    /// The frame carries a valid 42.5% — it plainly succeeded — yet `pay[1]` is `0x00`, which the #791
    /// mapping renders `FAILURE(0)`, and `pay[0]` is `0x00` too, so the whole `[seq][result]` prefix reads
    /// as zero.
    ///
    /// **How much that is worth is very little, which #900 established the slow way.** Four in-tree 4.0
    /// battery fixtures share this shape, and three of them are declared generated in their own files:
    /// `StreamsTests` ("Synthetic, protocol-valid frames … No real biometric capture is embedded", and
    /// `(synthetic)` again at the fixture), `FramingTests` ("Synthetic, CRC-valid frames … (no real
    /// capture)"), and the Kotlin `FramingTest` ("All vectors were generated independently (Python …)").
    /// Zero bytes in a generated vector are whatever the generator emitted.
    ///
    /// That leaves this one, from the parity corpus, which `docs/BLE_REVERSE_ENGINEERING.md` describes as
    /// captured frames — but it shares a byte-identical header with the synthetic `StreamsTests` frame
    /// (`aa0f00c324141a`, differing only in the value bytes), which is what one test vector derived from
    /// another looks like, and the repo's single squashed initial commit leaves no history to check. So the
    /// count of confirmed-real captures behind the apparent counterexample is somewhere between zero and
    /// one.
    ///
    /// Meanwhile the mapping itself is supported by real captures: `GET_EXTENDED_BATTERY_INFO` answers
    /// `SUCCESS(1)` with `resp_seq` 13 and real data in `ExtendedBatteryProbeTests.realFrame`, and
    /// `FAILURE(0)` with `resp_seq` 34 and an empty body in the #791 capture — the same command, both
    /// outcomes, the byte discriminating them correctly.
    ///
    /// So this is asserted to keep the behaviour deliberate, not as evidence against #791. #900 tracks the
    /// one thing that would resolve it: a single 4.0 battery capture of known provenance.
    func testSuccessfulBatteryReadStillReportsResultZero() {
        let f = parseFrame(bytes("aa0f00c324141a0000a9010000000052cd1a49"))
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["battery_pct"]?.doubleValue, 42.5)   // it succeeded
        XCTAssertEqual(f.parsed["resp_seq"]?.intValue, 0)            // echo zeroed too, not just the result
        XCTAssertEqual(f.parsed["result"]?.stringValue, "FAILURE(0)")
    }

    /// An undocumented result code stays a number rather than becoming an invented name, and renders exactly
    /// as the Kotlin twin's `hexLabel` does.
    func testUnknownResultCodeRendersAsHexNotAName() {
        let inner: [UInt8] = [36, 0x11, 34, 0x0A, 0x7F]
        var frame: [UInt8] = [0xAA, 9, 0, 0]
        frame[3] = crc8(Array(frame[1..<3]))
        frame += inner
        let c32 = crc32(inner)
        frame += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF),
                  UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]

        let f = parseFrame(frame)
        XCTAssertEqual(f.parsed["result"]?.stringValue, "0x7F(127)")
    }
}
