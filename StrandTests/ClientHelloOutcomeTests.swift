import XCTest
@testable import Strand

/// Pins the CLIENT_HELLO outcome line (#1635). Kotlin twin: `ClientHelloOutcomeTest`.
final class ClientHelloOutcomeTests: XCTestCase {

    private let hello = "fd4b0002-cce1-4033-93ce-002d5875f58a"

    func testACompletionFromTheHelloCharacteristicIsARealAck() {
        XCTAssertEqual(
            ClientHelloOutcome.line(isHelloChar: true, charUuid: hello, elapsedMs: 120,
                                    status: "status=SUCCESS(0)"),
            "CLIENT_HELLO outcome: acked by \(hello) after 120ms status=SUCCESS(0)")
    }

    func testACompletionFromAnotherCharacteristicIsNamedNotCountedAsAnAck() {
        let line = ClientHelloOutcome.line(isHelloChar: false,
                                           charUuid: "00002a19-0000-1000-8000-00805f9b34fb",
                                           elapsedMs: 40, status: "status=SUCCESS(0)")
        XCTAssertTrue(line.contains("DIFFERENT characteristic 00002a19-0000-1000-8000-00805f9b34fb"), line)
        XCTAssertTrue(line.contains("NOT a CLIENT_HELLO ack"), line)
        XCTAssertFalse(line.contains("outcome: acked"), line)
    }

    func testNoCallbackAtAllIsReportedWithTheElapsedTime() {
        XCTAssertEqual(
            ClientHelloOutcome.line(isHelloChar: false, charUuid: nil, elapsedMs: 3200, status: nil),
            "CLIENT_HELLO outcome: NO write callback after 3200ms — the link dropped before the stack"
            + " reported, so the strap may never have seen it")
    }

    func testANilCharacteristicWinsOverTheIsHelloCharFlag() {
        XCTAssertTrue(ClientHelloOutcome.line(isHelloChar: true, charUuid: nil, elapsedMs: 10,
                                              status: "status=SUCCESS(0)").contains("NO write callback"))
    }

    func testABlankCharacteristicAndStatusDegradeWithoutPunctuationDebris() {
        XCTAssertEqual(
            ClientHelloOutcome.line(isHelloChar: true, charUuid: "   ", elapsedMs: 5, status: "  "),
            "CLIENT_HELLO outcome: acked by unknown after 5ms")
    }
}
