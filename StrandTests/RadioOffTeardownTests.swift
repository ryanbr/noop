import XCTest
import CoreBluetooth
@testable import Strand

/// Pins which radio states end the current link. CoreBluetooth reports no disconnect for these, so
/// BLEManager runs the disconnect teardown itself; without it the next link inherited the old one's
/// flags and skipped the connect handshake (no history request, no battery read, a frozen "Syncing").
final class RadioOffTeardownTests: XCTestCase {

    func testPowerOffAndResetEndTheLink() {
        XCTAssertTrue(BLEManager.radioStateEndsLink(.poweredOff))
        XCTAssertTrue(BLEManager.radioStateEndsLink(.resetting))
    }

    func testOtherStatesLeaveTheLinkAlone() {
        // poweredOn is the reconnect path; unauthorized / unknown / unsupported are settling or permission
        // states that the existing banner handling owns, and never followed a live link in the field logs.
        for state in [CBManagerState.poweredOn, .unauthorized, .unknown, .unsupported] {
            XCTAssertFalse(BLEManager.radioStateEndsLink(state), "\(state.rawValue)")
        }
    }
}
