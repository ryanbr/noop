import XCTest
import WhoopProtocol
@testable import Strand

final class Whoop5PairedRRTests: XCTestCase {
    func testCapturedNativeRRUsesTheSameWireUnitsAsPairedStandardHR() throws {
        struct Fixture: Decodable {
            struct Pair: Decodable { let name: String; let kind: String; let native_hex: String; let standard_hex: String; let rr_count: Int }
            let firmware: String
            let cases: [Pair]
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "whoop5_rr_paired_capture", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.firmware, "50.41.1.0")
        XCTAssertEqual(Set(fixture.cases.map(\.kind)), ["type40", "v18"])
        func bytes(_ hex: String) -> [UInt8] {
            let chars = Array(hex)
            return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
        }
        for pair in fixture.cases {
            let standardBytes = bytes(pair.standard_hex)
            // This fixture fixes flags at 0x10 and an 8-bit HR; R-R words start at byte 2.
            XCTAssertEqual(standardBytes[0], 0x10)
            let rawTicks = stride(from: 2, to: standardBytes.count, by: 2).map {
                Int(standardBytes[$0]) | (Int(standardBytes[$0 + 1]) << 8)
            }
            XCTAssertEqual(rawTicks.count, pair.rr_count, pair.name)
            XCTAssertGreaterThan(pair.rr_count, 1, "compare complete multi-beat arrays")
            let native = parseFrame(bytes(pair.native_hex), family: .whoop5)
            XCTAssertTrue(native.ok, pair.name)
            XCTAssertEqual(native.crcOK, true, pair.name)
            XCTAssertEqual(native.parsed["rr_raw_ticks"]?.intArrayValue, rawTicks, pair.name)
            // This existing SIG parser is independent of Whoop5RR; the fixture has no converter-generated expectation.
            let standard = try XCTUnwrap(StandardHeartRate.parse(standardBytes))
            XCTAssertNotEqual(standard.rr, rawTicks, "treating native words as milliseconds must fail")
            XCTAssertEqual(native.parsed["rr_intervals"]?.intArrayValue, standard.rr, pair.name)
            let streams = pair.kind == "v18"
                ? extractHistoricalStreams([native], deviceClockRef: 0, wallClockRef: 0)
                : extractStreams([native], deviceClockRef: 0, wallClockRef: 0)
            XCTAssertEqual(streams.rr.map(\.rrMs), standard.rr, pair.name)
        }
    }

}
