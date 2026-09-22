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

    /// Pins the predicate: banked iff at least one counter moved.
    ///
    /// What this does NOT do is stop a caller passing the wrong counter, which is the mistake that nearly
    /// shipped — Kotlin's neighbouring `bankedThisOffload` counts offload FRAMES, and a stall still
    /// receives them (three sessions in one field log ran 66–109s and took 42, 51 and 59 frames while
    /// banking zero rows). No test over this function can catch that, because a frame count is not one of
    /// its inputs. The guard is the signature plus named arguments at both call sites: `chunks:`, `rows:`
    /// and `deepPackets:` make a frame count visibly wrong where it is passed, not here.
    func testBankedIffSomeCounterMoved() {
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

    // MARK: - sessionEndedOutcome (#2387)

    /// The banner above is right and always was; the LOG line was the one that read as a failure either
    /// way. A reporter read six productive timeouts as six interrupted syncs, and so did the maintainer
    /// reviewing their log. The rows were on the next line the whole time.
    func testATimeoutThatBankedRowsSaysItDrained() {
        XCTAssertEqual(BLEManager.sessionEndedOutcome(reason: "timeout", bankedRows: true),
                       " outcome=drained")
    }

    /// The stall case, the one the banner also warns about.
    func testATimeoutThatBankedNothingSaysSo() {
        XCTAssertEqual(BLEManager.sessionEndedOutcome(reason: "timeout", bankedRows: false),
                       " outcome=nothing-banked")
    }

    /// Every other ending is byte-identical to before: HISTORY_COMPLETE already says it completed, and a
    /// disconnect is not a claim about what landed.
    func testOtherReasonsAreUnchanged() {
        for reason in ["HISTORY_COMPLETE", "disconnected", "aborted by user"] {
            XCTAssertEqual(BLEManager.sessionEndedOutcome(reason: reason, bankedRows: true), "")
            XCTAssertEqual(BLEManager.sessionEndedOutcome(reason: reason, bankedRows: false), "")
        }
    }

    /// Deliberately ROWS, where the banner asks `offloadBankedAnything` (chunks OR rows OR deep packets).
    /// A session that acked chunks but persisted nothing is the #77/#120/#214 empty-offload shape: the
    /// banner stays silent because progress was made, while the log says nothing-banked because nothing
    /// landed. Both are honest about their own question; pinned so the difference is not read as a bug.
    func testOutcomeAsksAboutRowsNotProgress() {
        XCTAssertEqual(BLEManager.sessionEndedOutcome(reason: "timeout", bankedRows: false),
                       " outcome=nothing-banked")
        XCTAssertNil(BLEManager.timeoutSyncError(
            futureClockBanner: nil,
            bankedThisOffload: BLEManager.offloadBankedAnything(chunks: 3, rows: 0, deepPackets: 0)))
    }
}
