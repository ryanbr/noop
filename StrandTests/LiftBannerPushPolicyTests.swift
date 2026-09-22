import XCTest
@testable import Strand

/// What the gym banner may spend on a heart rate. The session of 22 Sep 2026 pushed it about 450 times in 75
/// minutes for a number nobody was reading, and the light-ups a strap double-tap asks for ran 5–10 s late in
/// the middle of it.
final class LiftBannerPushPolicyTests: XCTestCase {

    func testTheSameReadingNeverPushes() {
        XCTAssertFalse(LiftBannerPushPolicy.heartRateDue(shown: 128, latest: 128, sinceLastPush: 600))
        XCTAssertFalse(LiftBannerPushPolicy.heartRateDue(shown: nil, latest: nil, sinceLastPush: 600))
    }

    func testNoiseNeverPushes() {
        // One beat apart is the same reading with noise on it, however long ago the last push was.
        XCTAssertFalse(LiftBannerPushPolicy.heartRateDue(shown: 128, latest: 129, sinceLastPush: 600))
        XCTAssertFalse(LiftBannerPushPolicy.heartRateDue(shown: 128, latest: 127, sinceLastPush: 600))
    }

    func testARealChangePushesOnlyOnceTheIntervalHasPassed() {
        XCTAssertFalse(LiftBannerPushPolicy.heartRateDue(shown: 120, latest: 145, sinceLastPush: 29))
        XCTAssertTrue(LiftBannerPushPolicy.heartRateDue(shown: 120, latest: 145, sinceLastPush: 30))
        XCTAssertTrue(LiftBannerPushPolicy.heartRateDue(shown: 145, latest: 120, sinceLastPush: 30))
    }

    /// A strap dropping (or coming back) changes the banner from a number to a dash: a visible change of
    /// state, not a moving number, so it is allowed sooner — but still not on every tick.
    func testTheStrapAppearingOrDisappearingIsAllowedSooner() {
        XCTAssertFalse(LiftBannerPushPolicy.heartRateDue(shown: 128, latest: nil, sinceLastPush: 4))
        XCTAssertTrue(LiftBannerPushPolicy.heartRateDue(shown: 128, latest: nil, sinceLastPush: 5))
        XCTAssertTrue(LiftBannerPushPolicy.heartRateDue(shown: nil, latest: 128, sinceLastPush: 5))
    }

    /// The cost this exists for: a strap streaming once a second through a 75-minute session.
    func testASessionOfTicksBecomesAHandfulOfPushes() {
        var since: TimeInterval = 0
        var shown: Int? = 100
        var pushes = 0
        for second in 0..<(75 * 60) {
            // A heart rate that drifts across a wide range, as a working set does.
            let latest = 100 + Int((sin(Double(second) / 40) * 35).rounded())
            if LiftBannerPushPolicy.heartRateDue(shown: shown, latest: latest, sinceLastPush: since) {
                pushes += 1
                shown = latest
                since = 0
            } else {
                since += 1
            }
        }
        XCTAssertLessThanOrEqual(pushes, 150, "a heart rate alone must not push more than twice a minute")
        XCTAssertGreaterThan(pushes, 40, "it still follows a moving heart rate")
    }
}
