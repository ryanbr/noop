import XCTest
@testable import WhoopProtocol

/// The fast encoder has to be byte-for-byte identical to the `%02x` join it replaces: its output goes
/// into capture files and reject archives that existing decode tooling reads. Twin of the Kotlin
/// `HexTest`, using the OLD implementation as the oracle rather than a hand-written expectation.
final class HexTests: XCTestCase {

    private func slow(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testMatchesTheFormatBasedEncoderAcrossTheWholeByteRange() {
        let all = (0...255).map { UInt8($0) }
        XCTAssertEqual(slow(all), all.hexLower)
    }

    /// The high half of the range is where a nibble-shifting encoder usually goes wrong.
    func testHighBytesAreZeroPadded() {
        XCTAssertEqual([0x00].hexLower, "00")
        XCTAssertEqual([0x0f].hexLower, "0f")
        XCTAssertEqual([0x80].hexLower, "80")
        XCTAssertEqual([0xff].hexLower, "ff")
    }

    func testEmptyInEmptyOut() {
        XCTAssertEqual([UInt8]().hexLower, "")
    }

    /// Lowercase, no separator: the shape every existing consumer of these dumps expects.
    func testOutputIsLowercaseAndUnseparated() {
        XCTAssertEqual([0xab, 0xcd, 0xef].hexLower, "abcdef")
    }

    /// A realistic deep-buffer frame, since that is the size this exists for.
    func testLongFrameMatchesTheOracle() {
        let frame = (0..<2140).map { UInt8($0 % 256) }
        XCTAssertEqual(slow(frame), frame.hexLower)
    }
}
