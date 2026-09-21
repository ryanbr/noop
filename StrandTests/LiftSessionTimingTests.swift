import XCTest
import Combine
@testable import Strand
import WhoopStore

/// A running session does no work between taps: no once-a-second tick, only a rest's two moments.
///
/// From Utku's crash reports of 21 Sep 2026: iOS killed NOOP four times in one gym session for background CPU
/// (over 80% for 60 s, redrawing SwiftUI views). The session published a tick every second to every screen
/// watching it, so each of them was redrawn every second, on screen or not.
@MainActor
final class LiftSessionTimingTests: XCTestCase {

    private func plan(restSec: Int) -> [LiftPlanItem] {
        [LiftPlanItem(exercise: "Bench press", primaryMuscle: .chest, targetSets: 2, restSec: restSec)]
    }

    override func tearDown() {
        LiftSessionPersistence.clear()
        super.tearDown()
    }

    /// Nothing is published while nothing happens — the property that stops a session from redrawing every
    /// screen that watches it once a second.
    func testASessionPublishesNothingBetweenTaps() {
        let c = LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
        c.start(plan: plan(restSec: 90), programId: "p", programName: "Upper A")
        c.advance()                                              // a set being worked: its clock runs on screen
        var changes = 0
        let watching = c.objectWillChange.sink { changes += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        watching.cancel()
        XCTAssertEqual(changes, 0, "a running set changes nothing the session publishes; its clock ticks by itself")
    }

    /// A rest's end is the one moment the words change with time alone, and the warning buzz still comes.
    func testARestsEndIsPublishedOnceAndItsWarningBuzzes() {
        var buzzes: [UInt8] = []
        let c = LiftSessionController(buzz: { buzzes.append($0) }, setStrapHandler: { _ in })
        c.start(plan: plan(restSec: 2), programId: "p", programName: "Upper A")
        c.advance()                                              // set 1 working
        c.advance()                                              // set 1 done: a 2 s rest
        XCTAssertEqual(c.presentation(system: .metric)?.status, "Resting after set 1")
        var changes = 0
        let watching = c.objectWillChange.sink { changes += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))
        watching.cancel()
        XCTAssertEqual(changes, 1, "the rest's end, once")
        XCTAssertEqual(buzzes, [LiftSessionController.restWarningBuzzes], "the warning, once")
        XCTAssertEqual(c.presentation(system: .metric)?.status, "Ready for the next set")
    }

    /// When the warning and the end fire. A rest inside the warning window warns a second from now, clear of
    /// the tap's own buzz; a rest already over has no end to wait for.
    func testRestEventTimes() {
        let now = 1_700_000_000
        let lead = LiftSessionController.restWarningLeadSec
        let long = LiftSessionController.restEventTimes(endsAt: now + 90, now: now)
        XCTAssertEqual(long.warning, now + 90 - lead)
        XCTAssertEqual(long.end, now + 90)
        let short = LiftSessionController.restEventTimes(endsAt: now + 3, now: now)
        XCTAssertEqual(short.warning, now + 1)
        XCTAssertEqual(short.end, now + 3)
        let over = LiftSessionController.restEventTimes(endsAt: now, now: now)
        XCTAssertEqual(over.warning, now + 1)
        XCTAssertNil(over.end)
    }

    /// Undoing out of a rest cancels its timers: no warning, no end, for a rest that no longer runs.
    func testARestUndoneFiresNothing() {
        var buzzes: [UInt8] = []
        let c = LiftSessionController(buzz: { buzzes.append($0) }, setStrapHandler: { _ in })
        c.start(plan: plan(restSec: 2), programId: "p", programName: "Upper A")
        c.advance()
        c.advance()                                              // resting, 2 s
        c.undo()                                                 // back to working set 1
        var changes = 0
        let watching = c.objectWillChange.sink { changes += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))
        watching.cancel()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(buzzes, [])
    }
}
