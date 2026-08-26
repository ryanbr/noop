import XCTest
@testable import WhoopProtocol

/// Pins the 5/MG firmware-gate diagnostic. Kotlin twin: `FirmwareGateDiagnosticTest`.
///
/// The decoder reads the version at pay[93] behind a `pay[93] == 50` guard, both anchored to a single
/// 50.38.1.0 capture. The guards fail closed, so a strap that does not match reports nothing — and a
/// different generation byte is indistinguishable from a MOVED offset unless the line says which.
final class FirmwareGateDiagnosticTests: XCTestCase {

    private func payload(count: Int, at93: UInt8) -> [UInt8] {
        var p = (0..<count).map { UInt8($0 % 256) }
        if count > 93 { p[93] = at93 }
        return p
    }

    func testReportsTheByteItActuallySawAndTheExpectedOne() {
        let line = firmwareGateDiagnostic(payload: payload(count: 128, at93: 51), nameEndIndex: 27)
        XCTAssertTrue(line.contains("at93=51 expected=50"), line)
        XCTAssertTrue(line.contains("len=128"), line)
    }

    func testCarriesTheNameEndBecauseThatIsWhatMovesTheOffset() {
        // The version sits after the name+token region, so where the printable-ASCII name run ended is
        // the number that lets a reader re-derive a shifted offset.
        let line = firmwareGateDiagnostic(payload: payload(count: 128, at93: 51), nameEndIndex: 31)
        XCTAssertTrue(line.contains("nameEnd=31"), line)
    }

    func testTheHexWindowSpansTheRegionTheVersionShouldOccupy() {
        let line = firmwareGateDiagnostic(payload: payload(count: 128, at93: 51), nameEndIndex: 27)
        XCTAssertTrue(line.contains("hex[88..<101]="), line)
        // 13 bytes, two hex chars each.
        let hex = line.components(separatedBy: "hex[88..<101]=").last ?? ""
        XCTAssertEqual(hex.count, 26, hex)
    }

    func testAShortPayloadCannotTrapAndSaysSo() {
        // A malformed/truncated hello must not crash the decoder; the window clamps and at93 reports n/a.
        let line = firmwareGateDiagnostic(payload: [1, 2, 3], nameEndIndex: 2)
        XCTAssertTrue(line.contains("at93=n/a"), line)
        XCTAssertTrue(line.contains("len=3"), line)
    }

    func testAPayloadEndingExactlyAtTheWindowStartYieldsAnEmptyWindow() {
        let line = firmwareGateDiagnostic(payload: Array(repeating: 0, count: 88), nameEndIndex: 20)
        XCTAssertTrue(line.hasSuffix("hex[88..<88]="), line)
    }
}
