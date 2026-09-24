import XCTest
@testable import Strand

/// When the Live HR banner is pushed. It shows three numbers and used to be pushed on the first heart-rate tick more
/// than 2 s after the last push — every ~3 s while a strap was connected — whether or not any of them had moved.
final class LiveHRBannerPushPolicyTests: XCTestCase {

    private struct Shown: Equatable { var bpm: Int?; var recovery: Int?; var effort: Int? }
    private let staleAfter: TimeInterval = 120

    func testTheFirstPushAlwaysGoesOut() {
        XCTAssertTrue(LiveHRBannerPushPolicy.due(shown: nil as Shown?, next: Shown(bpm: 62),
                                                 reading: \.bpm, sinceLastPush: .infinity, staleAfter: staleAfter))
    }

    func testAnUnchangedBannerIsNotPushedAgain() {
        let same = Shown(bpm: 62, recovery: 71, effort: 4)
        for since: TimeInterval in [3, 10, 30, 59] {
            XCTAssertFalse(LiveHRBannerPushPolicy.due(shown: same, next: same, reading: \.bpm, sinceLastPush: since,
                                                      staleAfter: staleAfter), "\(since) s")
        }
    }

    /// Each push carries a stale date `staleAfter` ahead; an unchanged banner is re-pushed at half of that, so a
    /// connected strap never lets it go stale.
    func testAnUnchangedBannerIsRepushedBeforeItGoesStale() {
        let same = Shown(bpm: 62, recovery: 71, effort: 4)
        XCTAssertTrue(LiveHRBannerPushPolicy.due(shown: same, next: same, reading: \.bpm, sinceLastPush: 60,
                                                 staleAfter: staleAfter))
    }

    /// A change reaches the banner as soon as before: any field, after the same 2 s spacing.
    func testAChangeIsPushedAfterTheSameSpacingAsBefore() {
        let shown = Shown(bpm: 62, recovery: 71, effort: 4)
        for next in [Shown(bpm: 63, recovery: 71, effort: 4), Shown(bpm: 62, recovery: 72, effort: 4),
                     Shown(bpm: 62, recovery: 71, effort: 5)] {
            XCTAssertFalse(LiveHRBannerPushPolicy.due(shown: shown, next: next, reading: \.bpm, sinceLastPush: 2,
                                                      staleAfter: staleAfter))
            XCTAssertTrue(LiveHRBannerPushPolicy.due(shown: shown, next: next, reading: \.bpm, sinceLastPush: 2.5,
                                                     staleAfter: staleAfter))
        }
    }

    /// The strap taken off the wrist sends WRIST_OFF and then nothing: a dash held back for the spacing would never be
    /// retried, and the last number would stand until iOS's stale date. It goes out at once, and so does the number
    /// coming back; everything else still waits for the spacing.
    func testTheNumberGivingWayToTheDashOrComingBackIsPushedAtOnce() {
        let number = Shown(bpm: 91, recovery: 71, effort: 4)
        let dash = Shown(bpm: nil, recovery: 71, effort: 4)
        for since: TimeInterval in [0, 0.5, 2] {
            XCTAssertTrue(LiveHRBannerPushPolicy.due(shown: number, next: dash, reading: \.bpm, sinceLastPush: since,
                                                     staleAfter: staleAfter), "number -> dash after \(since) s")
            XCTAssertTrue(LiveHRBannerPushPolicy.due(shown: dash, next: number, reading: \.bpm, sinceLastPush: since,
                                                     staleAfter: staleAfter), "dash -> number after \(since) s")
            XCTAssertFalse(LiveHRBannerPushPolicy.due(shown: dash, next: Shown(bpm: nil, recovery: 72, effort: 4),
                                                      reading: \.bpm, sinceLastPush: since, staleAfter: staleAfter))
        }
    }

    /// The cost this exists for: an hour of ticks once a second with a heart rate that holds still. The old rule
    /// (any tick more than 2 s after the last push) made that 1,200 pushes of the same banner; now it is 60.
    func testAnHourOfASteadyReadingIsOnePushAMinute() {
        let steady = Shown(bpm: 58, recovery: 80, effort: 2)
        var shown: Shown?
        var lastPush = -TimeInterval.infinity
        var pushes = 0
        for second in 0..<3600 {
            let now = TimeInterval(second)
            if LiveHRBannerPushPolicy.due(shown: shown, next: steady, reading: \.bpm, sinceLastPush: now - lastPush,
                                          staleAfter: staleAfter) {
                pushes += 1; shown = steady; lastPush = now
            }
        }
        XCTAssertEqual(pushes, 60)
    }
}
