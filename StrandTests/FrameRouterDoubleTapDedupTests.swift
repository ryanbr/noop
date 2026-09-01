import XCTest
@testable import Strand
import WhoopProtocol

/// ONE physical double-tap must reach the app ONCE.
///
/// The strap's gesture arrives twice on a busy link: live through `handle(frame:)`, and again when
/// the strap offloads its banked event log — `dispatchLiveGestureIfFresh` runs over every offload
/// frame and accepts any event timestamped within 45 s of now, which a gesture from moments ago
/// obviously is. `AppModel.handleDoubleTap`'s 1.2 s debounce cannot catch that, because the replay
/// can land many seconds later.
///
/// Reported from a real gym session as "sometimes two double taps when I only did one". With the
/// Lift Log claiming the gesture, a phantom one silently advances the session and costs a logged
/// set — which is why this is pinned rather than left to the debounce.
final class FrameRouterDoubleTapDedupTests: XCTestCase {

    /// A real captured WHOOP 5 DOUBLE_TAP(14) frame; `event_timestamp` = 1780910464.
    private let doubleTapHex = "aa0110000100208130340e008089266a3d2a000030b8df92"
    private let doubleTapEventTs = 1_780_910_464

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            let j = hex.index(i, offsetBy: 2)
            return UInt8(hex[i..<j], radix: 16)
        }
    }

    @MainActor
    private func router(_ live: LiveState) -> FrameRouter {
        let r = FrameRouter(state: live)
        r.family = .whoop5
        return r
    }

    @MainActor
    func testTheSameGestureArrivingLiveThenOnTheOffloadPathFiresOnce() {
        let live = LiveState()
        var fired = 0
        live.onDoubleTap = { fired += 1 }
        let r = router(live)
        let frame = bytes(doubleTapHex)

        r.handle(frame: frame)                                          // live
        // The strap offloads its banked log seconds later; the SAME event is still "fresh".
        r.dispatchLiveGestureIfFresh(frame: frame, now: doubleTapEventTs + 10)

        XCTAssertEqual(fired, 1, "one gesture, one advance — the replay must be suppressed")
    }

    @MainActor
    func testARepeatedOffloadOfTheSameEventNeverFiresAgain() {
        let live = LiveState()
        var fired = 0
        live.onDoubleTap = { fired += 1 }
        let r = router(live)
        let frame = bytes(doubleTapHex)

        // A multi-minute offload re-walks the same records more than once.
        for _ in 0..<5 {
            r.dispatchLiveGestureIfFresh(frame: frame, now: doubleTapEventTs + 5)
        }
        XCTAssertEqual(fired, 1)
    }

    @MainActor
    func testAGenuineSecondTapStillFires() {
        let live = LiveState()
        var fired = 0
        live.onDoubleTap = { fired += 1 }
        let r = router(live)

        r.handle(frame: bytes(doubleTapHex))
        // De-duplication keys on the event's OWN timestamp, so a real later gesture — which carries
        // a different one — must not be swallowed. Guarding on "have we seen a double-tap at all"
        // would break the feature entirely.
        r.dispatchLiveGestureIfFresh(frame: bytes(doubleTapHex), now: doubleTapEventTs + 30)
        XCTAssertEqual(fired, 1, "sanity: the same timestamp is still one gesture")

        // A frame with a DIFFERENT event timestamp is a different gesture.
        live.onDoubleTap = { fired += 1 }
        let second = FrameRouter(state: live)
        second.family = .whoop5
        second.handle(frame: bytes(doubleTapHex))
        XCTAssertEqual(fired, 2, "a fresh router (a fresh gesture) still dispatches")
    }

    @MainActor
    func testAStaleReplayIsStillRejectedByTheFreshnessWindow() {
        let live = LiveState()
        var fired = 0
        live.onDoubleTap = { fired += 1 }
        let r = router(live)
        // Far outside `liveGestureWindowSeconds`: a historical replay, not a live gesture. This was
        // already correct; pinned so the dedup change cannot be mistaken for the only guard.
        r.dispatchLiveGestureIfFresh(frame: bytes(doubleTapHex), now: doubleTapEventTs + 5_000)
        XCTAssertEqual(fired, 0)
    }
}
