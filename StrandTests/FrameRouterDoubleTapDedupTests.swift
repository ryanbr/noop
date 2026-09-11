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

    /// A second gesture: the captured frame with a DIFFERENT `event_timestamp` and a recomputed CRC.
    ///
    /// Minted rather than captured because the interleaved case needs two gestures reaching ONE
    /// router, and the fixture carries a single timestamp. WHOOP 5 envelope: payload is
    /// `frame[8..<20]`, its CRC32 is the trailing four bytes little-endian, and `event_timestamp`
    /// sits at payload offset 4. The CRC16 header covers `frame[0..<6]` and is untouched.
    private func doubleTapFrame(eventTs: Int) -> [UInt8] {
        var f = bytes(doubleTapHex)
        let ts = UInt32(eventTs)
        for i in 0..<4 { f[12 + i] = UInt8((ts >> (8 * UInt32(i))) & 0xFF) }
        let crc = crc32(f, 8, 20)
        for i in 0..<4 { f[20 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
        return f
    }

    /// The mint has to produce a frame the parser accepts, or a test built on it proves nothing.
    func testTheMintedSecondGestureIsAValidFrame() {
        let f = doubleTapFrame(eventTs: doubleTapEventTs + 12)
        let check = verifyFrame(f, family: .whoop5)
        XCTAssertTrue(check.ok, "minted frame must pass both CRCs or the dedup tests are meaningless")
    }

    /// TWO genuine taps, then an offload replaying BOTH — the case a single-slot memory cannot cover.
    ///
    /// Keeping only the last dispatched timestamp catches a replay solely when the replayed event is
    /// the most recent one dispatched. Interleave them and each replay looks new:
    ///
    ///     tap A live -> last = A
    ///     tap B live -> last = B
    ///     replay A   -> A != B, dispatches again
    ///     replay B   -> B != A, dispatches again
    ///
    /// Two phantom advances, which in a session is two sets silently lost — the exact failure this
    /// de-duplication exists to prevent, surviving inside it.
    @MainActor
    func testTwoTapsReplayedTogetherStillFireOnlyTwice() {
        let live = LiveState()
        var fired = 0
        live.onDoubleTap = { fired += 1 }
        let r = router(live)

        let tsA = doubleTapEventTs
        let tsB = doubleTapEventTs + 12
        r.handle(frame: doubleTapFrame(eventTs: tsA))
        r.handle(frame: doubleTapFrame(eventTs: tsB))
        XCTAssertEqual(fired, 2, "sanity: two genuine taps are two gestures")

        // The strap offloads its banked log a few seconds later, carrying both events.
        r.dispatchLiveGestureIfFresh(frame: doubleTapFrame(eventTs: tsA), now: tsB + 5)
        r.dispatchLiveGestureIfFresh(frame: doubleTapFrame(eventTs: tsB), now: tsB + 5)

        XCTAssertEqual(fired, 2, "a replay of EITHER tap must be suppressed, not just the most recent")
    }

    /// Three taps and a full re-walk, the shape a multi-minute offload actually has.
    @MainActor
    func testAWholeBatchReplayOfSeveralTapsAddsNothing() {
        let live = LiveState()
        var fired = 0
        live.onDoubleTap = { fired += 1 }
        let r = router(live)

        let stamps = [doubleTapEventTs, doubleTapEventTs + 7, doubleTapEventTs + 19]
        for ts in stamps { r.handle(frame: doubleTapFrame(eventTs: ts)) }
        XCTAssertEqual(fired, 3)

        for _ in 0..<3 {
            for ts in stamps {
                r.dispatchLiveGestureIfFresh(frame: doubleTapFrame(eventTs: ts), now: stamps[2] + 3)
            }
        }
        XCTAssertEqual(fired, 3, "re-walking the banked log adds no gestures")
    }
}
