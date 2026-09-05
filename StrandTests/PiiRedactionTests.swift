import XCTest
@testable import Strand

/// The account holder's NAME in the shareable strap log (#445).
///
/// WHOOP names a strap "<FirstName>'s Whoop" by default, and the scan path logs that advertised name on
/// every discovery, so the file we ask people to attach to public issues carried a real person's name.
/// None of the other rules in `LiveState.redactPii` could see it: they key on MAC shape, a "WHOOP " +
/// digit serial, or a "whoop-" id.
///
/// Twin of the Kotlin `PiiRedactionTest` name cases, same inputs and same expected text, so the two
/// platforms cannot redact a log differently.
final class PiiRedactionTests: XCTestCase {

    func testPersonalNameInDiscoveryLineIsRedacted() {
        XCTAssertEqual(
            LiveState.redactPii("Discovered Ryan's Whoop (rssi -55) - connecting"),
            "Discovered <name>'s Whoop (rssi -55) - connecting")
    }

    /// Apple platforms write U+2019 into default device names, so the straight quote is not enough —
    /// a straight-quote-only rule would miss this platform's own logs.
    func testCurlyApostropheNameIsRedacted() {
        XCTAssertEqual(
            LiveState.redactPii("Discovered Ryan\u{2019}s Whoop (rssi -55)"),
            "Discovered <name>\u{2019}s Whoop (rssi -55)")
    }

    /// The MODEL after the possessive is diagnostic and identifies nobody, so it must survive.
    func testModelSurvivesNameRedaction() {
        XCTAssertEqual(LiveState.redactPii("Ryan's WHOOP 4.0"), "<name>'s WHOOP 4.0")
    }

    /// The documented gap, pinned so it stays visible rather than assumed: ONE token before the
    /// possessive. A multi-token rule cannot tell a name from surrounding log text.
    func testMultiTokenNameKeepsTheLeadingToken() {
        XCTAssertEqual(LiveState.redactPii("Ryan B's Whoop"), "Ryan <name>'s Whoop")
    }

    /// The rule must not touch ids or ordinary text that merely contain "whoop".
    func testNameRuleLeavesIdsAndPlainTextAlone() {
        XCTAssertEqual(LiveState.redactPii("my-whoop and my-whoop-noop"), "my-whoop and my-whoop-noop")
        XCTAssertEqual(LiveState.redactPii("no pii here"), "no pii here")
    }
}
