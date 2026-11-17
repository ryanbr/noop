import XCTest
@testable import Strand

/// Pins the activity BLEManager holds while a strap link is up on macOS: user-initiated, so App Nap does not
/// throttle a history drain when NOOP's window is hidden, and never one that keeps the Mac from sleeping.
final class AppNapExemptionTests: XCTestCase {

    #if os(macOS)
    func testExemptionStopsAppNap() {
        XCTAssertTrue(BLEManager.appNapExemptionOptions.contains(.userInitiatedAllowingIdleSystemSleep))
    }

    func testExemptionNeverKeepsTheMacAwake() {
        XCTAssertFalse(BLEManager.appNapExemptionOptions.contains(.idleSystemSleepDisabled),
                       "syncing must not stop the Mac from idle-sleeping")
        XCTAssertFalse(BLEManager.appNapExemptionOptions.contains(.idleDisplaySleepDisabled))
    }
    #endif
}
