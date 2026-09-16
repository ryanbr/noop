import XCTest
import Combine
@testable import Strand
import WhoopStore

/// A knock is not a double-tap.
///
/// In the 16 Sep 2026 gym session the strap's own sensor log recorded two double-taps 3 s and 4 s
/// after one that had just started a set. Both were genuine detections with their own timestamps —
/// the arm going onto the bar — so nothing downstream could tell them from a tap, and each finished
/// a set seconds old: "it skipped two things when it should have done only one". The session now
/// holds back a strap tap that comes too soon after the last one it acted on, without a buzz, and
/// says so in the strap log.
@MainActor
final class LiftSessionStrapTapTests: XCTestCase {

    private var buzzes: [UInt8] = []
    private var logged: [String] = []
    private var strapHandler: (@MainActor () -> Void)?

    private func controller() -> LiftSessionController {
        LiftSessionController(buzz: { [unowned self] in buzzes.append($0) },
                              setStrapHandler: { [unowned self] in strapHandler = $0 },
                              log: { [unowned self] in logged.append($0) })
    }

    private func plan(restSec: Int = 90) -> [LiftPlanItem] {
        [LiftPlanItem(exercise: "Lat pulldown", primaryMuscle: .lats, targetSets: 3, restSec: restSec)]
    }

    private func slot(_ e: Int, _ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: e, setIndex: s) }

    override func tearDown() {
        LiftSessionPersistence.clear()
        buzzes = []; logged = []; strapHandler = nil
        super.tearDown()
    }

    /// The reported case: a tap starts the set, and a knock straight after must not finish it.
    func testADoubleTapRightAfterTheOneThatStartedASetDoesNotFinishIt() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Pull")

        strapHandler?()                                   // the tap: set 1 starts
        XCTAssertEqual(c.engine?.stage, .working(slot(0, 1)))
        strapHandler?()                                   // the knock, a moment later

        XCTAssertEqual(c.engine?.stage, .working(slot(0, 1)), "the set is still running")
        XCTAssertTrue(c.engine?.sets.isEmpty ?? false, "nothing was recorded")
        XCTAssertEqual(buzzes, [LiftSessionController.advanceConfirmBuzzes], "one buzz, for the tap only")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("not acted on") && logged[0].contains("knock"), logged[0])
    }

    /// The handler the strap calls acts at once, so the buzz is written before anything that follows
    /// the tap in the same frame handling (see `FrameRouterDoubleTapDedupTests`).
    func testTheStrapHandlerBuzzesBeforeItReturns() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Pull")
        strapHandler?()
        XCTAssertEqual(buzzes, [LiftSessionController.advanceConfirmBuzzes])
        XCTAssertEqual(c.engine?.stage, .working(slot(0, 1)))
    }

    /// The button on the screen is pressed on purpose; only strap taps are judged.
    func testTheOnScreenButtonIsNeverHeldBack() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Pull")
        strapHandler?()
        c.advance()
        guard case .resting(let s, _) = c.engine?.stage else { return XCTFail("expected a rest") }
        XCTAssertEqual(s, slot(0, 1))
        XCTAssertTrue(logged.isEmpty)
    }

    /// A line planned with no rest goes straight on: the rest is over the moment it starts.
    func testWithNoRestPlannedTheNextSetStartsOnTheNextTap() {
        let c = controller()
        c.start(plan: plan(restSec: 0), programId: nil, programName: "Pull")
        c.advance()                                        // set 1 starts (on screen)
        strapHandler?()                                    // set 1 done: a rest of zero
        strapHandler?()                                    // straight into set 2
        XCTAssertEqual(c.engine?.stage, .working(slot(0, 2)))
        XCTAssertTrue(logged.isEmpty)
    }

    /// The Lock Screen lights on a strap step, once, with the new stage already in place, so that one
    /// update shows where the lifter is now. A held-back knock and the on-screen button light nothing.
    func testAStrapStepSignalsTheLockScreenOnceWithTheNewStage() {
        let c = controller()
        var seen: [LiftSessionEngine.Stage?] = []
        let watch = c.strapStepTaken.sink { [unowned c] in seen.append(c.engine?.stage) }
        defer { watch.cancel() }
        c.start(plan: plan(), programId: nil, programName: "Pull")

        strapHandler?()                                   // set 1 starts
        XCTAssertEqual(seen, [.working(slot(0, 1))])
        strapHandler?()                                   // a knock: held back
        c.advance()                                       // the on-screen button
        XCTAssertEqual(seen.count, 1, "neither a knock nor the button lights the screen")
    }

    func testAKnockIsJudgedByTimeAndByWhetherTheRestIsOver() {
        let now = 1_800_000_000
        let working = LiftSessionEngine.Stage.working(slot(0, 1))
        let resting = LiftSessionEngine.Stage.resting(slot(0, 1), endsAt: now + 60)
        let restOver = LiftSessionEngine.Stage.resting(slot(0, 1), endsAt: now)
        let window = LiftSessionController.strapKnockWindowSec

        XCTAssertTrue(LiftSessionController.isKnock(secondsSinceLastStep: 0, stage: working, now: now))
        XCTAssertTrue(LiftSessionController.isKnock(secondsSinceLastStep: 3, stage: working, now: now))
        XCTAssertTrue(LiftSessionController.isKnock(secondsSinceLastStep: 4, stage: resting, now: now))
        XCTAssertTrue(LiftSessionController.isKnock(secondsSinceLastStep: window - 1, stage: working, now: now))
        XCTAssertFalse(LiftSessionController.isKnock(secondsSinceLastStep: window, stage: working, now: now))
        XCTAssertFalse(LiftSessionController.isKnock(secondsSinceLastStep: 21, stage: working, now: now),
                       "the shortest real set in that session was 21 s")
        XCTAssertFalse(LiftSessionController.isKnock(secondsSinceLastStep: 2, stage: restOver, now: now))
        XCTAssertFalse(LiftSessionController.isKnock(secondsSinceLastStep: -5, stage: working, now: now),
                       "a clock that stepped back is not evidence of a knock")
    }
}
