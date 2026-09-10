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

    /// Three exercises, so an EARLIER one can be left pending while a later one is worked.
    private func threeExercisePlan() -> [LiftPlanItem] {
        [
            LiftPlanItem(exercise: "Leg press", primaryMuscle: .quads, targetSets: 3, restSec: 90),
            LiftPlanItem(exercise: "Lying leg curl", primaryMuscle: .hamstrings, targetSets: 3, restSec: 90),
            LiftPlanItem(exercise: "Leg extension", primaryMuscle: .quads, targetSets: 2, restSec: 60),
        ]
    }

    /// One line carrying the targets a program actually plans.
    private func targetedPlanItem() -> LiftPlanItem {
        LiftPlanItem(exercise: "Leg press", primaryMuscle: .quads, targetSets: 3,
                     restSec: 60, targetRepsLow: 10, targetWeightKg: 50)
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

    // MARK: - The occupied-machine path (reported from a real session)

    /// Skipping an exercise because its machine is busy must not drag the session back to it after
    /// every set. Reported from the gym: "I switched to a different move because the machine was
    /// occupied. When I double-tap for the next set, it reverts to the first set of the exercise I
    /// couldn't do earlier."
    func testFinishingASetStaysOnTheSameExerciseEvenWithAnEarlierOneSkipped() {
        var e = LiftSessionEngine(plan: threeExercisePlan(), startTs: t0)

        // Exercise 0's machine is busy — start exercise 2 instead.
        e.start(slot(2, 1), now: t0 + 60)
        e.advance(now: t0 + 100)                       // set done -> rest
        XCTAssertEqual(e.stage, .resting(slot(2, 1), endsAt: t0 + 100 + 60))

        e.advance(now: t0 + 160)                       // rest done -> next set
        XCTAssertEqual(e.stage, .working(slot(2, 2)),
                       "must continue on the machine the user is standing at, not jump back to 0")
    }

    /// And once that exercise IS finished, the skipped one is exactly what comes next — it was
    /// deferred, not abandoned.
    func testTheSkippedExerciseIsWhatComesNextOnceTheCurrentOneIsDone() {
        var e = LiftSessionEngine(plan: threeExercisePlan(), startTs: t0)
        e.start(slot(2, 1), now: t0 + 60)
        e.advance(now: t0 + 100); e.advance(now: t0 + 160)   // set 1 done, on to set 2
        e.advance(now: t0 + 200)                              // set 2 done -> rest
        e.advance(now: t0 + 260)                              // rest done -> exercise 2 finished

        XCTAssertEqual(e.stage, .working(slot(0, 1)),
                       "with exercise 2 complete, the deferred exercise 0 is next")
    }

    func testSlotAfterPrefersTheSameExerciseThenFallsBackToPlanOrder() {
        var e = LiftSessionEngine(plan: threeExercisePlan(), startTs: t0)
        XCTAssertEqual(e.slotAfter(slot(2, 1)), slot(2, 1), "its own set is still pending")

        e.start(slot(2, 1), now: t0); e.advance(now: t0 + 40)
        XCTAssertEqual(e.slotAfter(slot(2, 1)), slot(2, 2))

        e.advance(now: t0 + 100); e.advance(now: t0 + 140)   // finish exercise 2 entirely
        XCTAssertEqual(e.slotAfter(slot(2, 2)), slot(0, 1), "exhausted -> first pending in plan order")
    }

    // MARK: - Carrying the shown numbers onto a completed set

    /// A set completed with nothing typed records the numbers the sheet was showing in grey. Before
    /// this, 19 sets from a real session saved with weight and reps NIL — the sheet displayed
    /// "50 x 10" the whole time and stored nothing, so the session's volume was zero.
    func testCompletingASetWithoutTypingRecordsTheProgramTarget() {
        var e = LiftSessionEngine(plan: [targetedPlanItem()], startTs: t0)
        e.advance(now: t0 + 10)     // warm-up -> working set 1
        e.advance(now: t0 + 70)     // set done

        let row = e.recordedSet(for: slot(0, 1))
        XCTAssertEqual(row?.weightKg, 50)
        XCTAssertEqual(row?.reps, 10)
    }

    /// The second set carries what the FIRST set actually was, not the plan — if you dropped to
    /// 45 kg, set 2 follows you down rather than snapping back to the program.
    func testASetCarriesWhatTheExerciseActuallyDidEarlierInTheSession() {
        var e = LiftSessionEngine(plan: [targetedPlanItem()], startTs: t0)
        e.advance(now: t0 + 10)
        e.advance(now: t0 + 70)
        e.updateSet(slot(0, 1), weightKg: 45, reps: 8, rpe: 9, isWarmup: false)
        e.advance(now: t0 + 130)    // rest done -> set 2
        e.advance(now: t0 + 190)    // set 2 done

        let row = e.recordedSet(for: slot(0, 2))
        XCTAssertEqual(row?.weightKg, 45, "the session's own history outranks the program's plan")
        XCTAssertEqual(row?.reps, 8)
    }

    /// The store's answer sits between this session and the program target.
    func testLastSessionIsUsedWhenTheSessionHasNoEarlierSetForTheExercise() {
        var e = LiftSessionEngine(plan: [targetedPlanItem()], startTs: t0)
        e.advance(now: t0 + 10)
        e.advance(now: t0 + 70, lastSession: LiftSetCarry(weightKg: 52.5, reps: 9))

        let row = e.recordedSet(for: slot(0, 1))
        XCTAssertEqual(row?.weightKg, 52.5, "last session beats the program's target")
        XCTAssertEqual(row?.reps, 9)
    }

    /// RPE is never carried: it is how hard a set FELT, which nothing can know in advance, and
    /// inventing it would make the RPE card report full coverage for sets nobody rated.
    func testRpeIsNeverCarried() {
        var e = LiftSessionEngine(plan: [targetedPlanItem()], startTs: t0)
        e.advance(now: t0 + 10)
        e.advance(now: t0 + 70)
        e.updateSet(slot(0, 1), weightKg: 50, reps: 10, rpe: 8.5, isWarmup: false)
        e.advance(now: t0 + 130)
        e.advance(now: t0 + 190)

        XCTAssertEqual(e.recordedSet(for: slot(0, 2))?.weightKg, 50, "weight carries")
        XCTAssertNil(e.recordedSet(for: slot(0, 2))?.rpe, "the felt effort of a set does not")
    }

    /// Nothing to carry stays nil rather than inventing a zero — a set with no plan, no history and
    /// nothing typed genuinely has no measurement, and 0 kg would be a false one.
    func testASetWithNothingToCarryStaysEmpty() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], startTs: t0)
        e.advance(now: t0 + 10)
        e.advance(now: t0 + 70)

        XCTAssertNil(e.recordedSet(for: slot(0, 1))?.weightKg)
        XCTAssertNil(e.recordedSet(for: slot(0, 1))?.reps)
    }

    /// A carried value is a normal entry: typing over it wins, including typing a 0 for a set that
    /// was planned but not actually performed.
    func testTypingZeroOverAcarriedValueSticks() {
        var e = LiftSessionEngine(plan: [targetedPlanItem()], startTs: t0)
        e.advance(now: t0 + 10)
        e.advance(now: t0 + 70)
        XCTAssertEqual(e.recordedSet(for: slot(0, 1))?.weightKg, 50)

        e.updateSet(slot(0, 1), weightKg: 0, reps: 0, rpe: nil, isWarmup: false)
        XCTAssertEqual(e.recordedSet(for: slot(0, 1))?.weightKg, 0)
        XCTAssertEqual(e.recordedSet(for: slot(0, 1))?.reps, 0)
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

    // MARK: - Warm-ups

    func testAWarmUpMarkedBeforeTheSetIsPerformedSurvivesOntoIt() {
        // You know a set is a warm-up on the way IN. The mark is held until the set exists, then
        // applied — the regression this guards against silently counted every warm-up as a working
        // set, inflating the one figure the whole feature rests on.
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)                                        // working set 1
        e.advance(now: t0 + 40)                                   // recorded
        e.updateSet(slot(0, 1), weightKg: 20, reps: 12, rpe: nil, isWarmup: true)

        XCTAssertTrue(e.sets[0].isWarmup)
        XCTAssertEqual(e.completedWorkingSets, 0,
                       "a warm-up must not count toward the working-set tally")
    }

    func testAWarmUpCanBeUnmarkedBackToAWorkingSet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 20, reps: 12, rpe: nil, isWarmup: true)
        XCTAssertEqual(e.completedWorkingSets, 0)

        e.updateSet(slot(0, 1), weightKg: 20, reps: 12, rpe: nil, isWarmup: false)
        XCTAssertEqual(e.completedWorkingSets, 1, "un-marking restores it to a working set")
    }

    func testAWarmUpStillCarriesItsWeightAndRepsForTheRecord() {
        // Excluded from the COUNTS, but still logged: what you warmed up with is worth keeping.
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateSet(slot(0, 1), weightKg: 20, reps: 12, rpe: nil, isWarmup: true)
        XCTAssertEqual(e.sets[0].weightKg, 20)
        XCTAssertEqual(e.sets[0].reps, 12)
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

    // MARK: - Adding and dropping a set mid-session
    //
    // A program is what you INTENDED. Five sets when it says four is ordinary, and so is stopping at
    // three — and before this the fifth set was performed and then simply lost, because the sheet
    // drew exactly `1...targetSets`.

    func testAnAddedSetBecomesATappableRowAndCountsTowardThePlan() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertEqual(e.plannedWorkingSets, 3)
        XCTAssertTrue(e.addSet(toExercise: 0))
        XCTAssertEqual(e.slots(forExercise: 0), [slot(0, 1), slot(0, 2), slot(0, 3)])
        XCTAssertEqual(e.plannedWorkingSets, 4)
        XCTAssertFalse(e.allCompleted)
    }

    /// The whole point: the extra set has to be recordable, with its own numbers.
    func testAnExtraSetIsWhereTheSessionGoesNextAndRecordsWhatItWasDoing() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1, restSec: 60)],
                                  startTs: t0)
        e.advance(now: t0)                                        // set 1
        e.advance(now: t0 + 40)                                   // set 1 done, resting
        XCTAssertTrue(e.allCompleted, "the plan is finished, as written")

        e.addSet(toExercise: 0)
        XCTAssertFalse(e.allCompleted, "and now it is not — there is one more to do")
        e.advance(now: t0 + 160)                                  // out of the rest, into set 2
        XCTAssertEqual(e.stage, .working(slot(0, 2)))
        e.advance(now: t0 + 200, lastSession: LiftSetCarry(weightKg: 20, reps: 12))
        XCTAssertEqual(e.sets.count, 2)
        XCTAssertEqual(e.sets.last?.setIndex, 2)
        XCTAssertEqual(e.sets.last?.weightKg, 20, "an added set carries like any other")
    }

    func testAddingSetsStopsAtTheBound() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], startTs: t0)
        while e.addSet(toExercise: 0) { }
        XCTAssertEqual(e.slots(forExercise: 0).count, LiftSessionEngine.maxSetsPerExercise)
        XCTAssertFalse(e.addSet(toExercise: 0), "a stuck finger cannot grow the sheet without end")
    }

    func testAddingASetToALineThatIsNotThereDoesNothing() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertFalse(e.addSet(toExercise: 99))
        XCTAssertEqual(e.plannedWorkingSets, 3)
    }

    func testDroppingTheLastSetTakesItOffTheSheet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertTrue(e.canRemoveSet(fromExercise: 0))
        XCTAssertTrue(e.removeSet(fromExercise: 0))
        XCTAssertEqual(e.slots(forExercise: 0), [slot(0, 1)])
        XCTAssertEqual(e.plannedWorkingSets, 2)
    }

    /// The minus edits a PLAN. A completed set is data — deleting it from here would throw away a
    /// set that was actually performed.
    func testACompletedSetIsNeverDroppedByTheMinus() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.start(slot(0, 2), now: t0)
        e.advance(now: t0 + 40)                                   // set 2 recorded
        // Move the session OFF that set, so the only thing protecting it is that it was performed.
        e.start(slot(1, 1), now: t0 + 100)
        XCTAssertNotEqual(e.currentSlot, slot(0, 2))
        XCTAssertTrue(e.isCompleted(slot(0, 2)))

        XCTAssertFalse(e.canRemoveSet(fromExercise: 0))
        XCTAssertFalse(e.removeSet(fromExercise: 0))
        XCTAssertEqual(e.slots(forExercise: 0).count, 2, "what was logged stays on the sheet")
        XCTAssertEqual(e.sets.count, 1, "and stays recorded")
    }

    func testTheSetTheSessionIsStandingOnIsNeverDropped() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.start(slot(0, 2), now: t0)
        XCTAssertEqual(e.stage, .working(slot(0, 2)))
        XCTAssertFalse(e.canRemoveSet(fromExercise: 0))
        XCTAssertEqual(e.slots(forExercise: 0).count, 2)
    }

    func testTheLastRemainingSetIsNeverDropped() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertFalse(e.canRemoveSet(fromExercise: 1), "a line with one set has nothing to give up")
        XCTAssertFalse(e.removeSet(fromExercise: 1))
        XCTAssertEqual(e.slots(forExercise: 1), [slot(1, 1)])
    }

    func testUndoTakesBackAnAddedSet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.addSet(toExercise: 0)
        XCTAssertEqual(e.plannedWorkingSets, 4)
        e.undo()
        XCTAssertEqual(e.plannedWorkingSets, 3, "undo takes back the plan change, not only sets")
        XCTAssertEqual(e.slots(forExercise: 0), [slot(0, 1), slot(0, 2)])
    }

    func testUndoPutsADroppedSetBack() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.removeSet(fromExercise: 0)
        e.undo()
        XCTAssertEqual(e.slots(forExercise: 0), [slot(0, 1), slot(0, 2)])
    }

    /// The reason the plan travels in the undo snapshot at all.
    ///
    /// Start the last set, walk away to another exercise (which leaves it pending), drop it, then
    /// undo back past the drop. Without the plan in the snapshot the stage would be restored onto a
    /// slot the sheet no longer draws — and completing it would write a set nobody could see.
    func testUndoingPastADroppedSetCannotStrandTheSessionOnASlotThatIsGone() {
        var e = LiftSessionEngine(plan: threeExercisePlan(), startTs: t0)
        e.start(slot(0, 3), now: t0)                              // the last set of exercise 0
        e.start(slot(1, 1), now: t0 + 30)                         // machine busy: move on, 0/3 pending
        XCTAssertTrue(e.removeSet(fromExercise: 0))
        XCTAssertEqual(e.slots(forExercise: 0).count, 2)

        e.undo()                                                  // back past the drop
        XCTAssertEqual(e.slots(forExercise: 0).count, 3, "the slot the stage refers to is back")
        e.undo()                                                  // back onto that very slot
        XCTAssertEqual(e.stage, .working(slot(0, 3)))
        XCTAssertTrue(e.allSlots.contains(slot(0, 3)),
                      "the session is never left working a set the sheet does not draw")
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
