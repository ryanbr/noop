import XCTest
@testable import Strand

/// The strap log publishes at most four times a second, however fast lines arrive, and never loses one.
///
/// #2547: `LiveState` carries dozens of `@Published` properties on one `ObservableObject`, and an
/// `ObservableObject` invalidates EVERY observer on ANY published change. Publishing per appended line
/// therefore woke every view in the app for each line, and a history drain plus a re-score burst emits
/// hundreds a minute. That was the invalidation half of the #2521 background CPU kill; #2546 cut the cost of
/// each invalidation, this cuts how many there are. The Android twin has throttled this for a while, via
/// `boundedRevision(ble.logRevision, coalesceMs = 250)`.
///
/// The decision is a pure function so the policy is pinned without a clock or a run loop. The async adapter
/// around it makes no decisions of its own.
final class LogPublishCoalesceTests: XCTestCase {

    private let interval = 0.25

    /// The first line after an idle gap publishes immediately: a leading edge, so a live log does not sit a
    /// quarter second behind on its first line.
    func testTheFirstLineAfterAGapPublishesImmediately() {
        XCTAssertEqual(
            LiveState.logPublishDecision(now: 100, lastPublish: 99, flushQueued: false, interval: interval),
            .publishNow)
    }

    /// Never published yet. The sentinel is a very negative number, so this must not overflow into a wait.
    func testAFreshStatePublishesItsFirstLine() {
        XCTAssertEqual(
            LiveState.logPublishDecision(now: 0, lastPublish: -.greatestFiniteMagnitude,
                                         flushQueued: false, interval: interval),
            .publishNow)
    }

    /// A second line inside the window does not publish; it queues one flush for the end of the window.
    func testALineInsideTheWindowSchedulesTheRemainder() {
        XCTAssertEqual(
            LiveState.logPublishDecision(now: 100.10, lastPublish: 100, flushQueued: false, interval: interval),
            .scheduleIn(0.15))
    }

    /// Every further line in the same window is covered by the flush already queued. THIS is the coalescing:
    /// a hundred lines in one window still produce one publish.
    func testFurtherLinesInTheWindowAddNothing() {
        for offset in [0.11, 0.12, 0.2, 0.249] {
            XCTAssertEqual(
                LiveState.logPublishDecision(now: 100 + offset, lastPublish: 100,
                                             flushQueued: true, interval: interval),
                .alreadyQueued, "offset \(offset)")
        }
    }

    /// The boundary belongs to publishNow, so a steady stream at exactly the interval keeps publishing
    /// rather than queueing a flush per line and doubling the work.
    func testTheBoundaryPublishesRatherThanSchedules() {
        XCTAssertEqual(
            LiveState.logPublishDecision(now: 100.25, lastPublish: 100, flushQueued: false, interval: interval),
            .publishNow)
    }

    /// A clock that goes backwards must not ask for a negative sleep.
    func testABackwardClockNeverSchedulesANegativeWait() {
        guard case .scheduleIn(let wait) = LiveState.logPublishDecision(
            now: 100, lastPublish: 100.20, flushQueued: false, interval: interval) else {
            return XCTFail("a now before lastPublish is inside the window, so it should schedule")
        }
        XCTAssertGreaterThanOrEqual(wait, 0)
        XCTAssertLessThanOrEqual(wait, interval)
    }

    /// The one that matters: capture is per line whatever the publish does.
    ///
    /// Coalescing the CAPTURE instead of the notification would lose log lines, which is the whole risk of
    /// this change, and the many tests that append and then inspect `live.log` in the same turn depend on the
    /// read staying synchronous.
    @MainActor
    func testEveryLineIsCapturedSynchronouslyDespiteTheCoalescedPublish() {
        let live = LiveState()
        for i in 0..<50 { live.append(log: "coalesce-probe \(i)") }
        let mine = live.log.filter { $0.contains("coalesce-probe") }
        XCTAssertEqual(mine.count, 50, "every appended line must be readable immediately")
        XCTAssertEqual(mine.first, "coalesce-probe 0")
        XCTAssertEqual(mine.last, "coalesce-probe 49")
    }

    /// And the point of the exercise: fifty lines in one window are ONE publish, not fifty.
    ///
    /// Synchronous because the leading edge publishes on the first line and the remaining forty-nine fall
    /// inside the window, so no waiting is needed to observe the count. Reverting to a per-line publish makes
    /// this fifty.
    @MainActor
    func testFiftyLinesInOneWindowPublishOnce() {
        let live = LiveState()
        XCTAssertEqual(live.logRevision, 0, "a fresh state has not published")
        for i in 0..<50 { live.append(log: "coalesce-probe \(i)") }
        XCTAssertEqual(live.logRevision, 1,
                       "one leading-edge publish should cover the whole burst, got \(live.logRevision)")
    }

    /// A queued flush never starves: whatever the line rate, the decision is only ever `alreadyQueued` while
    /// one is outstanding, and the adapter clears the flag when it fires. Pinning that the flag is the ONLY
    /// thing suppressing a publish, so a stuck flag is the single failure mode to look for.
    func testOnlyAQueuedFlushSuppressesAPublish() {
        let queued = LiveState.logPublishDecision(now: 100.1, lastPublish: 100,
                                                  flushQueued: true, interval: interval)
        let notQueued = LiveState.logPublishDecision(now: 100.1, lastPublish: 100,
                                                     flushQueued: false, interval: interval)
        XCTAssertEqual(queued, .alreadyQueued)
        XCTAssertNotEqual(notQueued, .alreadyQueued)
    }
}
