import XCTest
@testable import Strand

/// The WHOOP reconnect policy after an involuntary drop or a failed connect — twin of
/// `OuraReconnectPolicyTests` (#1413, the #1286 fix ported). The old `DispatchQueue.main.asyncAfter` backoff
/// does not fire in a suspended app and, after `didFailToConnect`, left NOTHING outstanding with
/// CoreBluetooth — so an overnight drop stayed dead for hours (measured 10h46m50s on a 5/MG). After a few
/// quick timed retries (the app is awake there) the policy hands off to a standing `central.connect`.
///
/// ⚠️ These test the POLICY, not the plumbing. Whether a standing `central.connect` really survives
/// suspension on a real phone is a hardware question and is owed a strap night.
final class BLEManagerReconnectPolicyTests: XCTestCase {

    /// The app is awake when the first callbacks land, so the short backoff still gets its chance to fix a
    /// transient blip (3s, 6s — unchanged from #414).
    func testEarlyAttemptsUseTheShortTimedBackoff() {
        XCTAssertEqual(BLEManager.reconnectStep(attempt: 1, secondsSinceStandingConnect: nil),
                       .timedRetry(delay: 3))
        XCTAssertEqual(BLEManager.reconnectStep(attempt: 2, secondsSinceStandingConnect: nil),
                       .timedRetry(delay: 6))
    }

    /// THE REGRESSION TEST. After `standingConnectAfterAttempts` (3) failures the reconnect must hand off to
    /// CoreBluetooth, never schedule another swallowed timer — attempt 3 is where the night died.
    func testThirdFailureHandsOffToAStandingConnect() {
        XCTAssertEqual(BLEManager.reconnectStep(attempt: 3, secondsSinceStandingConnect: nil),
                       .standingConnect)
        XCTAssertEqual(BLEManager.reconnectStep(attempt: 9, secondsSinceStandingConnect: nil),
                       .standingConnect)
    }

    /// A standing connect that stayed outstanding a while before failing (the `Failed to encrypt the
    /// connection` shape this strap produces after 7–11s) is re-issued IMMEDIATELY, so a suspension can never
    /// catch us holding nothing.
    func testSlowStandingFailureReissuesImmediately() {
        XCTAssertEqual(BLEManager.reconnectStep(attempt: 4, secondsSinceStandingConnect: 8),
                       .standingConnect)
    }

    /// Only a near-instant failure — which proves the app is awake and could hot-loop — gets a timer, floored
    /// so it can't hammer the radio while awake.
    func testInstantStandingFailureIsFlooredWithATimer() {
        XCTAssertEqual(BLEManager.reconnectStep(attempt: 4, secondsSinceStandingConnect: 1),
                       .standingConnectAfter(delay: BLEManager.standingConnectRetryFloor - 1))
    }
}
