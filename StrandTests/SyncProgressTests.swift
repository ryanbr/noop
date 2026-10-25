import XCTest
@testable import Strand

/// Pins the time-based sync progress estimate: share done, the "caught up" slack, and a time remaining
/// that accounts for the strap still recording while it drains.
final class SyncProgressTests: XCTestCase {

    private let t0 = 1_791_500_000   // arbitrary wall-clock anchor

    func testHalfwayShareAndRemainingTimeAccountForTheMovingTarget() {
        // Drain began at data t0-10h; after 30 min of wall time it has reached t0-5h... of a target at "now".
        let now = t0
        let p = SyncProgress.estimate(firstDataUnix: now - 36_000, frontierUnix: now - 18_000,
                                      sessionStartedUnix: now - 1_800, nowUnix: now)!
        XCTAssertEqual(p.percent, 50)
        // rate = 18000/1800 = 10 data-s per wall-s; behind 18000 - 300 slack = 17700 → 17700/(10-1) ≈ 1967 s.
        XCTAssertEqual(p.secondsRemaining, 1967)
        XCTAssertEqual(p.remainingText, "about 33 min left")
    }

    func testWithinTheSlackCountsAsCaughtUp() {
        let p = SyncProgress.estimate(firstDataUnix: t0 - 7_200, frontierUnix: t0 - 120,
                                      sessionStartedUnix: t0 - 600, nowUnix: t0)!
        XCTAssertEqual(p.percent, 100)
        XCTAssertEqual(p.secondsRemaining, 0)
        XCTAssertEqual(p.remainingText, "finishing up", "100% must not also claim time is left")
    }

    func testNeverShows100PercentBeforeCaughtUp() {
        let p = SyncProgress.estimate(firstDataUnix: t0 - 100_000, frontierUnix: t0 - 400,
                                      sessionStartedUnix: t0 - 3_600, nowUnix: t0)!
        XCTAssertEqual(p.percent, 99)
    }

    func testNoEstimateTooEarlyOrWhenNotOutrunningRealTime() {
        let early = SyncProgress.estimate(firstDataUnix: t0 - 3_600, frontierUnix: t0 - 3_500,
                                          sessionStartedUnix: t0 - 10, nowUnix: t0)!
        XCTAssertNil(early.secondsRemaining, "10 s of session is too little to measure a rate")

        let slow = SyncProgress.estimate(firstDataUnix: t0 - 3_600, frontierUnix: t0 - 3_590,
                                         sessionStartedUnix: t0 - 600, nowUnix: t0)!
        XCTAssertNil(slow.secondsRemaining, "a drain slower than real time never finishes; say nothing")
        XCTAssertNil(slow.remainingText)
    }

    func testRejectsInconsistentInputs() {
        XCTAssertNil(SyncProgress.estimate(firstDataUnix: t0, frontierUnix: t0 - 10,
                                           sessionStartedUnix: t0 - 60, nowUnix: t0 + 60))
    }

    func testRemainingTextFormats() {
        func text(_ s: Int) -> String? {
            SyncProgress(fraction: 0.5, syncedThroughUnix: t0, secondsRemaining: s).remainingText
        }
        XCTAssertEqual(text(30), "less than a minute left")
        XCTAssertEqual(text(3_600), "about 1 h left")
        XCTAssertEqual(text(7_800), "about 2 h 10 min left")
    }
}
