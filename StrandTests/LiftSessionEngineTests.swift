import XCTest
@testable import Strand
import WhoopStore

/// The Lift Log session state machine. Pure, so a whole gym session can be driven through a known
/// timeline with no strap, no database and no simulator — which is the point of keeping it pure.
final class LiftSessionEngineTests: XCTestCase {

    private let t0 = 1_700_000_000

    /// Two exercises: 2 sets then 1 set. Small enough to assert every transition by hand.
    private func twoExercisePlan() -> [LiftPlanItem] {
        [
            LiftPlanItem(exercise: "Incline dumbbell press",
                         primaryMuscle: .chest, secondaryMuscles: [.frontDelts, .triceps],
                         targetSets: 2, restSec: 90),
            LiftPlanItem(exercise: "Lat pulldown",
                         primaryMuscle: .lats, secondaryMuscles: [.biceps],
                         targetSets: 1, restSec: 60),
        ]
    }

    private func slot(_ e: Int, _ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: e, setIndex: s) }

    // MARK: - The sheet

    func testTheSheetListsEverySetOfEveryExercise() {
        let e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertEqual(e.slots(forExercise: 0), [slot(0, 1), slot(0, 2)])
        XCTAssertEqual(e.slots(forExercise: 1), [slot(1, 1)])
        XCTAssertEqual(e.allSlots.count, 3)
        XCTAssertEqual(e.plannedWorkingSets, 3)
    }

    func testASessionStartsInTheWarmUpWithNothingCompleted() {
        let e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertEqual(e.stage, .warmup)
        XCTAssertTrue(e.sets.isEmpty)
        XCTAssertFalse(e.canUndo)
        XCTAssertEqual(e.nextPendingSlot, slot(0, 1))
    }

    // MARK: - The default in-order path

    func testTheFullTapThroughRecordsEverySetInOrder() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)

        e.advance(now: t0 + 300)                                  // warm-up → set 1
        XCTAssertEqual(e.stage, .working(slot(0, 1)))

        e.advance(now: t0 + 340)                                  // done → rest (90s)
        XCTAssertEqual(e.stage, .resting(slot(0, 1), endsAt: t0 + 430))
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: 8, isWarmup: false)

        e.advance(now: t0 + 440)                                  // rest → set 2
        XCTAssertEqual(e.stage, .working(slot(0, 2)))

        e.advance(now: t0 + 480)
        e.updateSet(slot(0, 2), weightKg: 30, reps: 8, rpe: 9, isWarmup: false)

        e.advance(now: t0 + 580)                                  // rest → next exercise
        XCTAssertEqual(e.stage, .working(slot(1, 1)))

        e.advance(now: t0 + 620)
        e.updateSet(slot(1, 1), weightKg: 55, reps: 12, rpe: 7, isWarmup: false)

        XCTAssertTrue(e.allCompleted)
        XCTAssertEqual(e.sets.count, 3)
        XCTAssertEqual(e.sets.map(\.reps), [10, 8, 12])
    }

    func testFinishClosesTheRunningRestSoItsDurationIsNotLost() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)                                   // resting from t0+40
        e.finish(now: t0 + 160)
        XCTAssertEqual(e.stage, .finished)
        XCTAssertEqual(e.sets[0].restSec, 120, "the rest that was running still happened")
    }

    // MARK: - Out of order: the reason this model exists

    func testAnyPendingSetCanBeStartedWhenAMachineIsBusy() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.start(slot(1, 1), now: t0 + 60)                         // skip straight to the second exercise
        XCTAssertEqual(e.stage, .working(slot(1, 1)))

        e.advance(now: t0 + 100)
        e.updateSet(slot(1, 1), weightKg: 55, reps: 12, rpe: nil, isWarmup: false)
        XCTAssertTrue(e.isCompleted(slot(1, 1)))
        XCTAssertEqual(e.nextPendingSlot, slot(0, 1),
                       "the skipped sets are still outstanding and come back round")
    }

    func testAdvancingFromRestGoesToTheFirstOUTSTANDINGSetNotTheNextInLine() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.start(slot(0, 2), now: t0)                              // did set 2 first
        e.advance(now: t0 + 40)                                   // → resting
        e.advance(now: t0 + 140)                                  // → next OUTSTANDING
        XCTAssertEqual(e.stage, .working(slot(0, 1)),
                       "set 1 was never done, so it is what comes next")
    }

    func testStartingAnAlreadyCompletedSetRedoesItRatherThanDoubleCounting() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: nil, isWarmup: false)
        XCTAssertEqual(e.sets.count, 1)

        e.start(slot(0, 1), now: t0 + 200)                        // redo it
        XCTAssertEqual(e.sets.count, 0, "the old record is dropped, not duplicated")
        XCTAssertEqual(e.stage, .working(slot(0, 1)))
    }

    func testStartingAnotherSetMidSetRecordsNothingForTheAbandonedOne() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)                                        // working set 1
        e.start(slot(1, 1), now: t0 + 20)                         // changed mind
        XCTAssertTrue(e.sets.isEmpty, "an unfinished set is not a set")
        XCTAssertEqual(e.stage, .working(slot(1, 1)))
    }

    func testAdvancingWhenEverythingIsDoneDoesNotInventASet() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 30)                                   // → resting, all done
        e.advance(now: t0 + 120)                                  // nothing left to start
        XCTAssertEqual(e.sets.count, 1)
        XCTAssertTrue(e.allCompleted)
    }

    // MARK: - Time

    func testRestIsAnchoredToAnAbsoluteInstantNotACountdown() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 10)                                   // rest ends at t0+100

        XCTAssertEqual(e.restRemaining(now: t0 + 10), 90)
        XCTAssertEqual(e.restRemaining(now: t0 + 55), 45)
        // A phone sleeping through a rest must not "pause" it — the answer depends only on the clock.
        XCTAssertEqual(e.restRemaining(now: t0 + 100), 0)
    }

    func testAnOverrunRestFloorsAtZeroAndNeverAutoAdvances() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 10)
        XCTAssertEqual(e.restRemaining(now: t0 + 5_000), 0, "an overrun rest reads 0:00, never negative")
        XCTAssertEqual(e.stage, .resting(slot(0, 1), endsAt: t0 + 100),
                       "rest waits for the user; nothing starts a set on its own")
    }

    func testRestRecordedIsWhatWasActuallyTakenNotWhatWasPlanned() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 10)                                   // planned 90s
        e.advance(now: t0 + 210)                                  // actually rested 200s
        XCTAssertEqual(e.sets[0].restSec, 200,
                       "work-vs-rest is measured from the taps, not assumed from the plan")
    }

    func testASetCarriesTheDurationItWasPerformedOver() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0 + 300)
        e.advance(now: t0 + 345)
        XCTAssertEqual(e.sets[0].startTs, t0 + 300)
        XCTAssertEqual(e.sets[0].endTs, t0 + 345)
    }

    // MARK: - Entering what you lifted

    func testASetIsRecordedWithItsTimingBeforeAnyNumbersAreTyped() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0 + 300)
        e.advance(now: t0 + 345)
        XCTAssertEqual(e.sets.count, 1)
        XCTAssertNil(e.sets[0].weightKg, "numbers are typed during the rest, not while lifting")
        XCTAssertNil(e.sets[0].reps)
    }

    func testTypingEditsTheSetRatherThanAddingOne() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: nil, isWarmup: false)
        e.updateSet(slot(0, 1), weightKg: 32.5, reps: 9, rpe: 8, isWarmup: false)
        XCTAssertEqual(e.sets.count, 1)
        XCTAssertEqual(e.sets[0].weightKg, 32.5)
        XCTAssertEqual(e.sets[0].rpe, 8)
    }

    func testTypingIntoASetThatWasNeverPerformedInventsNothing() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.updateSet(slot(0, 1), weightKg: 100, reps: 5, rpe: 10, isWarmup: false)
        XCTAssertTrue(e.sets.isEmpty, "a number nobody performed must never become a set")
    }

    func testAWarmUpSetIsRecordedButDoesNotCountAsAWorkingSet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 20, reps: 12, rpe: nil, isWarmup: true)
        XCTAssertEqual(e.sets.count, 1)
        XCTAssertEqual(e.completedWorkingSets, 0,
                       "studies count working sets; a warm-up must not inflate the tally")
    }

    // MARK: - Ghost values

    func testThePreviousSetInThisSessionIsWhatASetGhostsFrom() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: 8, isWarmup: false)

        let ghost = e.previousSetInSession(for: slot(0, 2))
        XCTAssertEqual(ghost?.weightKg, 30, "set 2 ghosts from set 1 of the same exercise")
        XCTAssertEqual(ghost?.reps, 10)
    }

    func testTheFirstSetOfAnExerciseHasNothingToGhostFrom() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: 8, isWarmup: false)
        XCTAssertNil(e.previousSetInSession(for: slot(0, 1)))
        XCTAssertNil(e.previousSetInSession(for: slot(1, 1)),
                     "a different exercise never ghosts from this one")
    }

    // MARK: - Undo

    func testUndoRestoresTheStageAndRemovesTheRecordedSet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        XCTAssertEqual(e.sets.count, 1)
        e.undo()
        XCTAssertEqual(e.stage, .working(slot(0, 1)))
        XCTAssertTrue(e.sets.isEmpty, "undoing a mis-tap must take the set back with it")
    }

    func testUndoWalksAllTheWayBackToTheWarmUp() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.advance(now: t0 + 140)
        while e.canUndo { e.undo() }
        XCTAssertEqual(e.stage, .warmup)
        XCTAssertTrue(e.sets.isEmpty)
    }

    func testUndoIsGlobalAndWalksBackACROSSExercises() {
        // Undo is one stack for the WHOLE session, not a per-exercise one: from the last set of the
        // last exercise you can walk all the way back to the first set of the first.
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)                                        // ex0 set1
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: nil, isWarmup: false)
        e.advance(now: t0 + 140)                                  // ex0 set2
        e.advance(now: t0 + 180)
        e.advance(now: t0 + 280)                                  // ex1 set1
        e.advance(now: t0 + 320)
        XCTAssertEqual(e.sets.count, 3)
        XCTAssertEqual(e.currentSlot?.exerciseIndex, 1)

        // One undo steps back out of the SECOND exercise into the first — no boundary in the way.
        e.undo()
        XCTAssertEqual(e.sets.count, 2)
        e.undo()
        XCTAssertEqual(e.currentSlot?.exerciseIndex, 0,
                       "undo crosses from one exercise back into the previous one")

        while e.canUndo { e.undo() }
        XCTAssertEqual(e.stage, .warmup)
        XCTAssertTrue(e.sets.isEmpty, "the whole session unwinds, set by set, with no cap")
    }

    func testUndoHasNoDepthLimit() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        for i in 0..<60 { e.advance(now: t0 + i * 10) }           // far more steps than the plan has
        var undone = 0
        while e.canUndo { e.undo(); undone += 1 }
        XCTAssertGreaterThan(undone, 10, "undo depth is not capped")
        XCTAssertEqual(e.stage, .warmup)
    }

    func testUndoOnAFreshSessionIsHarmless() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.undo()
        XCTAssertEqual(e.stage, .warmup)
    }

    func testUndoTakesBackARedoRestoringTheSetItDropped() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 30, reps: 10, rpe: nil, isWarmup: false)
        e.start(slot(0, 1), now: t0 + 200)                        // redo drops it
        XCTAssertTrue(e.sets.isEmpty)
        e.undo()
        XCTAssertEqual(e.sets.count, 1, "a redo started by accident is recoverable")
        XCTAssertEqual(e.sets[0].weightKg, 30)
    }

    // MARK: - Degenerate plans

    func testALineWithNoTargetStillGetsOneTappableSet() {
        XCTAssertEqual(LiftPlanItem(exercise: "Face pull", targetSets: nil).targetSets, 1)
    }

    func testAMissingRestFallsBackToTheDefault() {
        XCTAssertEqual(LiftPlanItem(exercise: "Face pull", restSec: nil).restSec,
                       LiftPlanItem.defaultRestSec)
    }

    func testAnEmptyPlanHasNothingToStartAndCannotTrap() {
        var e = LiftSessionEngine(plan: [], startTs: t0)
        XCTAssertNil(e.nextPendingSlot)
        e.advance(now: t0 + 10)
        XCTAssertEqual(e.stage, .warmup, "with no sets there is nothing to advance into")
        e.finish(now: t0 + 20)
        XCTAssertEqual(e.stage, .finished, "and it can still be ended")
    }

    func testStartingASlotOutsideThePlanIsIgnored() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.start(slot(99, 1), now: t0)
        XCTAssertEqual(e.stage, .warmup)
    }
}
