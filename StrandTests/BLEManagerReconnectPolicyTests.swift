import XCTest
@testable import Strand

/// The WHOOP reconnect policy after an involuntary drop or a failed connect — twin of
/// `OuraReconnectPolicyTests` (#1413).
///
/// The original `DispatchQueue.main.asyncAfter` backoff does not fire in a suspended app and, after
/// `didFailToConnect`, left NOTHING outstanding with CoreBluetooth — so an overnight drop stayed dead for
/// hours (measured 10h46m50s on a 5/MG). The first fix handed off to a standing `central.connect`, but only
/// after three consecutive failures, which made it unreachable in the case it was written for: a drop while
/// suspended wakes the app just long enough to arm a 3-second timer that then never fires, so the counter
/// never reaches three and nothing is outstanding meanwhile. The handoff now happens on the FIRST drop.
///
/// ⚠️ These test the POLICY, not the plumbing. Whether a standing `central.connect` really survives
/// suspension on a real phone is a hardware question and is owed a strap night.
final class BLEManagerReconnectPolicyTests: XCTestCase {

    /// THE REGRESSION TEST. The first drop must hand off to CoreBluetooth immediately. Anything else is a
    /// timer, and a timer is what the suspended app swallows — this is the state the night died in.
    func testFirstDropHandsOffImmediately() {
        XCTAssertEqual(BLEManager.reconnectStep(secondsSinceStandingConnect: nil), .standingConnect)
    }

    /// A standing connect that stayed outstanding a while before failing (the `Failed to encrypt the
    /// connection` shape this strap produces after 7–11s) is re-issued IMMEDIATELY, so a suspension can never
    /// catch us holding nothing.
    func testSlowStandingFailureReissuesImmediately() {
        XCTAssertEqual(BLEManager.reconnectStep(secondsSinceStandingConnect: 8), .standingConnect)
    }

    /// Only a near-instant failure — which proves the app is awake and could hot-loop — gets a timer, floored
    /// so it can't hammer the radio while awake.
    func testInstantStandingFailureIsFlooredWithATimer() {
        XCTAssertEqual(BLEManager.reconnectStep(secondsSinceStandingConnect: 1),
                       .standingConnectAfter(delay: BLEManager.standingConnectRetryFloor - 1))
    }

    /// The boundary itself: at exactly the fast-failure threshold the connect stayed up long enough to count
    /// as a real attempt, so it re-issues rather than waiting.
    func testAtTheFastFailureBoundaryItReissues() {
        XCTAssertEqual(BLEManager.reconnectStep(
            secondsSinceStandingConnect: BLEManager.standingConnectFastFailureS), .standingConnect)
    }

    /// No path returns a bare timer any more. The only timer left is floored and reachable only while awake,
    /// so there is no arrangement of inputs that leaves CoreBluetooth holding nothing.
    func testNoInputProducesAnUnbackedTimer() {
        for since in [nil, 0, 0.5, 1.9, 2, 8, 60, 3600] as [TimeInterval?] {
            switch BLEManager.reconnectStep(secondsSinceStandingConnect: since) {
            case .standingConnect:
                continue                                   // something is outstanding
            case .standingConnectAfter(let d):
                XCTAssertLessThanOrEqual(d, BLEManager.standingConnectRetryFloor, "since=\(String(describing: since))")
                XCTAssertGreaterThan(d, 0, "since=\(String(describing: since))")
            }
        }
    }
}
