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

    /// The name never reaches a shared log at all. The sink rule is defence-in-depth; this is the real
    /// guarantee, and it is an ALLOWLIST so an unanticipated naming shape is dropped by default.
    func testLogSafeDeviceNameKeepsOnlyTheModel() {
        XCTAssertEqual(LiveState.logSafeDeviceName("Ryan's Whoop"), "<name> Whoop")
        XCTAssertEqual(LiveState.logSafeDeviceName("Ryan B's WHOOP 4.0"), "<name> WHOOP 4.0")
        XCTAssertEqual(LiveState.logSafeDeviceName("Ryan\u{2019}s WHOOP 5.0 MG"), "<name> WHOOP 5.0 MG")
    }

    /// A fully custom name has no model token to keep, so nothing of it survives.
    func testLogSafeDeviceNameDropsAWhollyCustomName() {
        XCTAssertEqual(LiveState.logSafeDeviceName("Dad's spare"), "<name>")
        XCTAssertEqual(LiveState.logSafeDeviceName("Sarah"), "<name>")
    }

    /// "We saw no name" and "we removed a name" are different facts to a reader, so the sentinel stays.
    func testLogSafeDeviceNameKeepsTheNoNameSentinel() {
        XCTAssertEqual(LiveState.logSafeDeviceName("unknown"), "unknown")
        XCTAssertEqual(LiveState.logSafeDeviceName(nil), "unknown")
        XCTAssertEqual(LiveState.logSafeDeviceName("   "), "unknown")
    }


    /// Third-party straps: the MODEL is the diagnostic, so a name carrying no person survives intact.
    func testLogSafeDeviceNameKeepsAnUnrenamedThirdPartyModel() {
        XCTAssertEqual(LiveState.logSafeDeviceName("Polar H10"), "Polar H10")
        XCTAssertEqual(LiveState.logSafeDeviceName("TICKR"), "TICKR")
        XCTAssertEqual(LiveState.logSafeDeviceName("WHOOP 4.0"), "WHOOP 4.0")
    }

    /// ...but a renamed one loses the person and keeps the model.
    func testLogSafeDeviceNameStripsThePersonFromARenamedThirdPartyStrap() {
        XCTAssertEqual(LiveState.logSafeDeviceName("Ryan's Polar H10"), "<name> Polar H10")
        XCTAssertEqual(LiveState.logSafeDeviceName("Sarah TICKR"), "<name> TICKR")
    }

}
