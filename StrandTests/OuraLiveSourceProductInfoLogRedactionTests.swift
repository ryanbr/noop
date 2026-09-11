import XCTest
@testable import Strand

/// #2092, route 1: the product-info reply log line printed `ascii: <serial>` in the clear — neither
/// `LiveState.redactPii` rule matches a bare, unprefixed serial (by design: a shape-only rule would mask
/// ordinary prose), and the hex half was only masked by `redactHexDump`'s accident of matching a
/// letter-led alnum run, which an all-digit serial (this repo's own #2075/#2090 evidence) never
/// triggers. `OuraLiveSource.logSafeProductInfo` is the fix: computed right where the code already knows
/// (via `isPlausibleSerial`) whether a decoded string IS a serial, so it can mask deliberately instead of
/// relying on an unrelated heuristic to get lucky.
final class OuraLiveSourceProductInfoLogRedactionTests: XCTestCase {

    func testASerialPageIsMaskedInBothHexAndAscii() {
        let serial = "2H3B2405003655"
        let hex = Array(serial.utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let safe = OuraLiveSource.logSafeProductInfo(hex: hex, ascii: serial, decoded: serial)
        XCTAssertEqual(safe.hex, "<serial>")
        XCTAssertEqual(safe.ascii, "2H3…")
        XCTAssertFalse(safe.ascii.contains("2405003655"))
    }

    /// This repo's own evidence (#2075's attachment): an all-digit serial with no letter to anchor a
    /// letter-required heuristic on. Must mask the same as an alphanumeric one.
    func testAnAllDigitSerialPageIsMaskedToo() {
        let serial = "2038082631034041"
        let hex = Array(serial.utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let safe = OuraLiveSource.logSafeProductInfo(hex: hex, ascii: serial, decoded: serial)
        XCTAssertEqual(safe.hex, "<serial>")
        XCTAssertEqual(safe.ascii, "203…")
    }

    /// A hardware-generation page ("BLB_03") identifies no one - never `isPlausibleSerial` because of the
    /// underscore - and must survive in full: masking it would throw away a real diagnostic for nothing.
    func testAHardwarePageIsLoggedInFull() {
        let hex = Array("BLB_03".utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let safe = OuraLiveSource.logSafeProductInfo(hex: hex, ascii: "BLB_03", decoded: "BLB_03")
        XCTAssertEqual(safe.hex, hex)
        XCTAssertEqual(safe.ascii, "BLB_03")
    }

    /// A frame that failed to decode at all (nil) has nothing to mask and nothing to leak; pass through.
    func testANilDecodeIsLeftAlone() {
        let safe = OuraLiveSource.logSafeProductInfo(hex: "00 01", ascii: "..", decoded: nil)
        XCTAssertEqual(safe.hex, "00 01")
        XCTAssertEqual(safe.ascii, "..")
    }
}
