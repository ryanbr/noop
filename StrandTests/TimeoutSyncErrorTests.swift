import XCTest
@testable import Strand

/// #1466: a WHOOP 4.0 routinely ends a full, successful night on the idle timeout rather than
/// HISTORY_COMPLETE — a field log shows a session banking 17,205 rows and still exiting `reason=timeout`.
/// Before this, every such sync raised "Sync interrupted - the strap went quiet", reporting a success as a
/// failure. Twin of the Kotlin `TimeoutSyncErrorTest`.
final class TimeoutSyncErrorTests: XCTestCase {

    private let wentQuiet = "Sync interrupted - the strap went quiet. It will retry on the next sync."

    /// The regression: rows landed, so there is nothing to warn about.
    func testProductiveTimeoutRaisesNoBanner() {
        XCTAssertNil(BLEManager.timeoutSyncError(futureClockBanner: nil, bankedThisOffload: true))
    }

    /// The case the banner exists for: the session held the radio and handed over nothing.
    func testStalledTimeoutStillWarns() {
        XCTAssertEqual(BLEManager.timeoutSyncError(futureClockBanner: nil, bankedThisOffload: false),
                       wentQuiet)
    }

    /// The near-miss this exists to prevent. A stall still RECEIVES frames — three sessions in one field
    /// log ran 66–109s and took 42, 51 and 59 frames while banking zero rows. So "did we bank anything"
    /// must be chunks/rows/deep-packets, never a frame count, or the banner goes silent on real stalls.
    func testFramesWithoutChunksOrRowsIsNotBanked() {
        XCTAssertFalse(BLEManager.offloadBankedAnything(chunks: 0, rows: 0, deepPackets: 0))
        // ...and the productive night from the same log is banked on rows alone.
        XCTAssertTrue(BLEManager.offloadBankedAnything(chunks: 0, rows: 17_205, deepPackets: 0))
        XCTAssertTrue(BLEManager.offloadBankedAnything(chunks: 3, rows: 0, deepPackets: 0))
        XCTAssertTrue(BLEManager.offloadBankedAnything(chunks: 0, rows: 0, deepPackets: 5))
    }

    /// #324/#928: a future-dated strap times out BECAUSE of its clock, so that banner names the real cause
    /// and must outrank the generic one — including on a stalled session.
    func testFutureClockBannerOutranksTheGenericWarning() {
        XCTAssertEqual(BLEManager.timeoutSyncError(futureClockBanner: "clock is ahead",
                                                   bankedThisOffload: false), "clock is ahead")
    }

    /// ...and it must survive a PRODUCTIVE timeout too: rows landing does not make a bad clock fine, and
    /// those rows are exactly the ones being misfiled.
    func testFutureClockBannerSurvivesAProductiveTimeout() {
        XCTAssertEqual(BLEManager.timeoutSyncError(futureClockBanner: "clock is ahead",
                                                   bankedThisOffload: true), "clock is ahead")
    }
}
