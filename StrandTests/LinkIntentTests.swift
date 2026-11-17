import XCTest
@testable import Strand

/// Pins the `intentionalDisconnect` lifecycle (#2787 review). Every writer of the flag goes through
/// `BLEManager.LinkIntent`, so this table is the lifecycle: both connect entry points clear the flag, and
/// only an intended teardown sets it. The regression it guards: `connectRestored` never cleared the flag,
/// so after a radio-off teardown on a state-restored iOS session the next genuine drop did not reconnect.
@MainActor
final class LinkIntentTests: XCTestCase {

    func testEveryConnectEntryClearsTheFlag() {
        XCTAssertFalse(BLEManager.LinkIntent.connect.leavesLinkDown)
        XCTAssertFalse(BLEManager.LinkIntent.restoredConnect.leavesLinkDown,
                       "the restored-peripheral path must clear the flag exactly as connectCore does")
    }

    func testOnlyIntendedTeardownsSetTheFlag() {
        XCTAssertTrue(BLEManager.LinkIntent.userDisconnect.leavesLinkDown)
        XCTAssertTrue(BLEManager.LinkIntent.forget.leavesLinkDown)
        XCTAssertTrue(BLEManager.LinkIntent.radioOff.leavesLinkDown)
    }

    func testRadioOffThenAnyReconnectLeavesTheNextDropRecoverable() {
        // The sequence from the review: radio-off teardown, then poweredOn reconnects through EITHER entry.
        // Whichever runs last decides how the next genuine drop is handled, and it must not be "intentional".
        for reconnect in [BLEManager.LinkIntent.connect, .restoredConnect] {
            var intentional = BLEManager.LinkIntent.radioOff.leavesLinkDown
            XCTAssertTrue(intentional)
            intentional = reconnect.leavesLinkDown
            XCTAssertFalse(intentional, "\(reconnect)")
        }
    }

    func testTableCoversEveryIntent() {
        XCTAssertEqual(BLEManager.LinkIntent.allCases.count, 5,
                       "a new intent needs a decision here and at its call site")
    }
}
