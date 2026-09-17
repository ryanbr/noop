import XCTest
import StrandAnalytics
@testable import Strand

/// `OuraLiveSource.shouldSuspendLiveHR` — when the live-HR re-engage stands down because nobody is looking.
///
/// The decision is a pure static precisely so it can be tested: `OuraLiveSource` owns a
/// `CBCentralManager` and cannot be constructed in a unit test. These tests pin the decision only. That suspending the re-engage actually lets the ring run its own night suite is a STRAP
/// claim — it needs an overnight capture showing `check_sleep` reaching a run and `DHR_mode` leaving 3 —
/// and is called out as owed in the PR body, not asserted here.
///
/// Why the rule exists: across 10 nights the correlation between our overnight re-engage count and the ring
/// running its night suite is r = -0.91, but both of the nights that broke the pattern also broke the LINK
/// (one disconnect, one phone deliberately out of range), confounding "we stopped poking the ring" with "we
/// stopped talking to the ring at all". Suspending the re-engage while staying connected is what separates
/// them.
final class OuraLiveHRSuspendPolicyTests: XCTestCase {

    private let delay: TimeInterval = 300   // the 5-minute grace
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Presence

    func testNeverSuspendsWhileTheUserIsPresent() {
        // No screen-off timestamp means the user is here; no elapsed time can change that.
        XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: nil, now: t0.addingTimeInterval(86_400), delay: delay))
    }

    func testDoesNotSuspendDuringTheGrace() {
        // A glance-and-pocket must not cost the user their live HR for the evening.
        for elapsed in [0.0, 1, 60, 200, 299.9] {
            XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: t0, now: t0.addingTimeInterval(elapsed), delay: delay),
                "\(elapsed)s of screen-off is still inside the 5-minute grace")
        }
    }

    func testSuspendsAtTheThreshold() {
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: t0, now: t0.addingTimeInterval(delay), delay: delay))
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: t0, now: t0.addingTimeInterval(delay + 15), delay: delay))
    }

    func testStaysSuspendedAllNight() {
        // The predicate is elapsed-since-screen-off, not a one-shot edge, so a reconnect at 03:00 that
        // re-reaches `.streaming` still reads "suspended" and does not silently restart the stream.
        for hours in [1.0, 4, 8] {
            XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: t0, now: t0.addingTimeInterval(hours * 3600), delay: delay),
                "\(hours)h into a screen-off night the re-engage must still be suspended")
        }
    }

    // MARK: - Seeding the clock at construction (the background-launch case)

    // The tests above pin the PREDICATE, and they passed on the build that produced a void night — because
    // the defect was never in the predicate, it was in what feeds it. `screenOffAt` was written in exactly
    // one place, from `UIApplication.didEnterBackgroundNotification`, and a process launched *into* the
    // background never posts that notification: it was never in the foreground to leave it. That is the
    // overnight path this build runs (#1215 has iOS relaunch NOOP for BLE while the phone is locked), so
    // the suspend never armed and the night was indistinguishable from the build with no suspend at all.
    //
    // These pin the seed instead: constructed while the screen is dark ⇒ suspended, not merely eventually.

    func testForegroundLaunchDoesNotSeedTheClock() {
        // The ordinary launch: the user is looking at the app. Nothing to suspend, and the notification
        // path will start the clock honestly when they leave.
        XCTAssertNil(OuraLiveSource.seedScreenOffAt(screenIsDark: false, now: t0, delay: delay))
    }

    func testBackgroundLaunchSeedsTheClock() {
        XCTAssertNotNil(OuraLiveSource.seedScreenOffAt(screenIsDark: true, now: t0, delay: delay),
                        "a process launched into the background gets no didEnterBackground edge — if the "
                        + "seed does not stand in for it, nothing ever writes screenOffAt")
    }

    func testBackgroundLaunchSuspendsImmediatelyRatherThanEarningAFreshGrace() {
        // The grace is courtesy to a user who glanced at live HR and pocketed the phone — and that user's
        // app was in the FOREGROUND. A process iOS woke for BLE has no such user, so it does not get a
        // fresh 5 minutes. Decisive, not academic: the voided night ran FOUR app sessions, and a fresh
        // grace per launch is a relaunch storm that resets the clock forever and never suspends.
        let seeded = OuraLiveSource.seedScreenOffAt(screenIsDark: true, now: t0, delay: delay)
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(screenOffAt: seeded, now: t0, delay: delay),
                      "a background launch must read as suspended at the very first check")
    }

    func testSeededBackgroundLaunchStaysSuspendedAllNight() {
        // The end-to-end shape of the fix: seed at 22:00 launch, still suspended at every hour of the night.
        let seeded = OuraLiveSource.seedScreenOffAt(screenIsDark: true, now: t0, delay: delay)
        for hours in [0.0, 1, 4, 8] {
            XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: seeded, now: t0.addingTimeInterval(hours * 3600), delay: delay),
                "\(hours)h after a background launch the re-engage must still be suspended")
        }
    }

    func testTheOldBehaviourIsWhatTheSeedReplaces() {
        // The regression this locks down, stated as the counterfactual: with screenOffAt left nil — which
        // is what a background launch produced before the seed — no elapsed time ever suspends, so the
        // 15 s re-engage runs all night and holds the ring in daytime-HR mode.
        XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: nil, now: t0.addingTimeInterval(8 * 3600), delay: delay))
    }
}

// MARK: - Item 27: the all-day HR toggle keys the stand-down on the learned night, not the screen

/// Why: the ring emits daytime HR only while a client holds daytime-HR mode, so the screen-keyed suspend
/// emptied every working day from the night it shipped (daytime 5-min bins 123–144/144 → median ~16).
/// With the toggle ON the same predicate stands down only inside `NightStandDown`'s learned band; OFF is
/// byte-identical to the rule above. Pinned here; that the ring then banks a full day and still runs its
/// night suite is a strap claim, owed on hardware.
extension OuraLiveHRSuspendPolicyTests {

    private var night: NightStandDown.Band { NightStandDown.Band(startSec: 21 * 3_600 + 1_800, endSec: 7 * 3_600 + 1_800) }
    private var pastGrace: Date { Date(timeIntervalSince1970: 1_760_000_000).addingTimeInterval(3_600) }
    private var screenOff: Date { Date(timeIntervalSince1970: 1_760_000_000) }

    func testToggleOffIsTheScreenRuleExactly() {
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(screenOffAt: screenOff, now: pastGrace, delay: 300, allDay: .off))
        XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(screenOffAt: nil, now: pastGrace, delay: 300, allDay: .off))
    }

    func testToggleOnDoesNotSuspendOutsideTheNightBand() {
        // Midday, phone in a pocket for an hour: keep holding the ring.
        for sec in [7 * 3_600 + 1_800, 9 * 3_600, 12 * 3_600, 18 * 3_600, 21 * 3_600 + 1_799] {
            XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: screenOff, now: pastGrace, delay: 300, allDay: .on(band: night, nowSecOfDay: sec)),
                "\(sec / 3_600)h is daytime")
        }
    }

    func testToggleOnSuspendsInsideTheNightBandAfterTheGrace() {
        for sec in [21 * 3_600 + 1_800, 23 * 3_600, 0, 3 * 3_600, 7 * 3_600 + 1_799] {
            XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
                screenOffAt: screenOff, now: pastGrace, delay: 300, allDay: .on(band: night, nowSecOfDay: sec)),
                "\(sec / 3_600)h is inside the night")
        }
        // The screen-off grace still applies inside the band: an evening on the phone keeps live HR.
        XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: screenOff, now: screenOff.addingTimeInterval(60), delay: 300,
            allDay: .on(band: night, nowSecOfDay: 23 * 3_600)))
        // And presence always wins.
        XCTAssertFalse(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: nil, now: pastGrace, delay: 300, allDay: .on(band: night, nowSecOfDay: 23 * 3_600)))
    }

    func testToggleOnWithoutALearnedNightKeepsTheScreenRule() {
        // Cold start: no band ⇒ do not invent a clock; behave as if the toggle were off.
        XCTAssertTrue(OuraLiveSource.shouldSuspendLiveHR(
            screenOffAt: screenOff, now: pastGrace, delay: 300, allDay: .on(band: nil, nowSecOfDay: 12 * 3_600)))
    }

    /// The band the app layer hands the policy is the learner's own (midsleep ± half the typical night, ±1 h).
    func testBandComesFromTheLearnedSchedule() {
        let band = NightStandDown.band(habitualMidsleepSec: 2 * 3_600 + 1_800, typicalSleepHours: 8)
        XCTAssertEqual(band, night)
    }
}
