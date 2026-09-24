import XCTest
@testable import Strand
import WhoopProtocol

/// A strap's WRIST_ON / WRIST_OFF leaves a line in the strap log, on both routes a live event takes. Nothing named
/// them before, so whether a WHOOP 5.0 sends WRIST_OFF when it leaves the wrist — which decides how soon the Live HR
/// banner can show the dash — had to be read from the silence that followed it (24 Sep 2026).
final class FrameRouterWristEventTests: XCTestCase {

    /// The captured WHOOP 5 DOUBLE_TAP(14) frame of `FrameRouterDoubleTapDedupTests`; `event_timestamp` = 1780910464.
    private let doubleTapHex = "aa0110000100208130340e008089266a3d2a000030b8df92"
    private let eventTs = 1_780_910_464

    /// That frame carrying another event: its event byte replaced and its payload CRC32 recomputed.
    private func wristEventFrame(_ event: UInt8) -> [UInt8] {
        var f = stride(from: 0, to: doubleTapHex.count, by: 2).map {
            let i = doubleTapHex.index(doubleTapHex.startIndex, offsetBy: $0)
            return UInt8(doubleTapHex[i..<doubleTapHex.index(i, offsetBy: 2)], radix: 16)!
        }
        f[10] = event
        let crc = crc32(f, 8, f.count - 4)
        f.replaceSubrange(f.count - 4..<f.count, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        return f
    }
    private let wristOn: UInt8 = 9
    private let wristOff: UInt8 = 10

    @MainActor
    private func wristRouter(heartRate: Int?) -> (LiveState, FrameRouter) {
        let live = LiveState()
        live.heartRate = heartRate
        let router = FrameRouter(state: live)
        router.family = .whoop5
        return (live, router)
    }

    @MainActor
    private func wristLines(_ live: LiveState) -> [String] {
        live.log.filter { $0.contains("Strap: WRIST_") }
    }

    @MainActor
    func testALiveWristOffClearsTheHeartRateAndSaysSo() {
        let (live, router) = wristRouter(heartRate: 91)
        router.handle(frame: wristEventFrame(wristOff))
        XCTAssertNil(live.heartRate)
        XCTAssertFalse(live.worn)
        XCTAssertEqual(wristLines(live).count, 1)
        XCTAssertTrue(wristLines(live).last?.hasSuffix("Strap: WRIST_OFF; live heart rate cleared") == true,
                      "\(live.log)")

        router.handle(frame: wristEventFrame(wristOff))                     // already off: said, nothing to clear
        XCTAssertTrue(wristLines(live).last?.hasSuffix("Strap: WRIST_OFF") == true, "\(wristLines(live))")

        router.handle(frame: wristEventFrame(wristOn))
        XCTAssertTrue(live.worn)
        XCTAssertTrue(wristLines(live).last?.hasSuffix("Strap: WRIST_ON") == true, "\(wristLines(live))")
    }

    /// During a sync a live event reaches the router through the offload path; it is said to have come that way. One
    /// that is history being offloaded stays silent, as before.
    @MainActor
    func testAWristEventDuringASyncIsSaidOnlyWhenItIsLive() {
        let (live, router) = wristRouter(heartRate: 91)
        router.dispatchLiveGestureIfFresh(frame: wristEventFrame(wristOff), now: eventTs + 600)
        XCTAssertEqual(wristLines(live), [])
        XCTAssertEqual(live.heartRate, 91)

        router.dispatchLiveGestureIfFresh(frame: wristEventFrame(wristOff), now: eventTs + 2)
        XCTAssertNil(live.heartRate)
        let line = wristLines(live).last ?? ""
        XCTAssertTrue(line.hasSuffix("Strap: WRIST_OFF during a sync; live heart rate cleared"), line)
    }
}
