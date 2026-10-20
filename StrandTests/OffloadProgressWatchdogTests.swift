import XCTest
import WhoopProtocol
@testable import Strand

/// Which offload frames may re-arm the backfill idle watchdog (`BLEManager.offloadFrameShowsProgress`).
///
/// A WHOOP 4.0 that answered SEND_HISTORICAL_DATA with PENDING and then sent only its periodic EVENT
/// frames kept the session open indefinitely, because every event re-armed the 60 s watchdog. These pin
/// that events no longer count as progress on a 4.0 while every genuine offload type still does, and
/// that 5/MG keeps its existing behaviour. Twin of the Android `OffloadProgressWatchdogTest`.
@MainActor
final class OffloadProgressWatchdogTests: XCTestCase {

    private func frame(type: UInt8, at index: Int) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 16)
        f[index] = type
        return f
    }

    func testWhoop4EventFrameIsNotProgress() {
        XCTAssertTrue(BLEManager.isOffloadFrame(frame(type: 48, at: 4), family: .whoop4),
                      "an EVENT is still an offload frame and is still routed to the Backfiller")
        XCTAssertFalse(BLEManager.offloadFrameShowsProgress(frame(type: 48, at: 4), family: .whoop4))
    }

    func testWhoop4HistoryTypesAreProgress() {
        for t: UInt8 in [47, 49, 50, 56] {
            XCTAssertTrue(BLEManager.offloadFrameShowsProgress(frame(type: t, at: 4), family: .whoop4),
                          "type \(t) must re-arm the watchdog")
        }
    }

    func testLiveFramesAreNeverProgress() {
        for t: UInt8 in [40, 43] {
            XCTAssertFalse(BLEManager.offloadFrameShowsProgress(frame(type: t, at: 4), family: .whoop4))
            XCTAssertFalse(BLEManager.offloadFrameShowsProgress(frame(type: t, at: 8), family: .whoop5))
        }
    }

    func testWhoop5EventFrameIsUnchanged() {
        XCTAssertTrue(BLEManager.offloadFrameShowsProgress(frame(type: 48, at: 8), family: .whoop5))
    }

    func testShortFrameIsNotProgress() {
        XCTAssertFalse(BLEManager.offloadFrameShowsProgress([0xAA, 0x01, 0x00], family: .whoop4))
    }
}
