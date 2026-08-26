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

    // MARK: - The loop

    func testASessionStartsInTheWarmUp() {
        let e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertEqual(e.stage, .warmup)
        XCTAssertTrue(e.sets.isEmpty)
        XCTAssertFalse(e.canUndo)
    }

    func testTheFullTapThroughReachesFinishedAndRecordsEverySet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)

        e.advance(now: t0 + 300)                                  // warm-up → set 1
        XCTAssertEqual(e.stage, .working(item: 0, set: 1))

        e.advance(now: t0 + 340)                                  // set 1 done → rest
        XCTAssertEqual(e.stage, .resting(item: 0, set: 1, endsAt: t0 + 340 + 90))
        // The numbers are typed DURING the rest that follows the set, not while holding the bar.
        e.updateLastSet(weightKg: 30, reps: 10, rpe: 8, isWarmup: false)

        e.advance(now: t0 + 440)                                  // rest → set 2
        XCTAssertEqual(e.stage, .working(item: 0, set: 2))

        e.advance(now: t0 + 480)                                  // set 2 done → rest
        XCTAssertEqual(e.stage, .resting(item: 0, set: 2, endsAt: t0 + 480 + 90))
        e.updateLastSet(weightKg: 30, reps: 8, rpe: 9, isWarmup: false)

        e.advance(now: t0 + 580)                                  // rest → next exercise, set 1
        XCTAssertEqual(e.stage, .working(item: 1, set: 1))

        e.advance(now: t0 + 620)                                  // last set → cool-down, no rest
        XCTAssertEqual(e.stage, .cooldown)
        // The final set has no rest after it, so its numbers are entered during the cool-down.
        e.updateLastSet(weightKg: 55, reps: 12, rpe: 7, isWarmup: false)

        e.advance(now: t0 + 700)                                  // cool-down → finished
        XCTAssertEqual(e.stage, .finished)
        XCTAssertTrue(e.isFinished)

        XCTAssertEqual(e.sets.count, 3)
        XCTAssertEqual(e.sets.map(\.exerciseIndex), [0, 0, 1])
        XCTAssertEqual(e.sets.map(\.setIndex), [1, 2, 1])
        XCTAssertEqual(e.sets.map(\.reps), [10, 8, 12])
    }

    func testNoRestFollowsTheFinalSet() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], startTs: t0)
        e.advance(now: t0 + 60)                                   // → set 1
        e.advance(now: t0 + 100)          // final set → cool-down
        XCTAssertEqual(e.stage, .cooldown, "the last set is followed by the cool-down, not a rest")
        XCTAssertNil(e.sets[0].restSec, "no rest was taken after the final set, so none is recorded")
    }

    // MARK: - Time

    func testRestIsAnchoredToAnAbsoluteInstantNotACountdown() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 10)           // rest ends at t0+100 (90s)

        XCTAssertEqual(e.restRemaining(now: t0 + 10), 90)
        XCTAssertEqual(e.restRemaining(now: t0 + 55), 45)
        // The phone sleeping for a minute must not "pause" the rest: the answer depends only on the
        // clock, which is the whole reason the end instant is stored rather than a counter.
        XCTAssertEqual(e.restRemaining(now: t0 + 100), 0)
    }

    func testAnOverrunRestFloorsAtZeroAndNeverAutoAdvances() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 10)

        XCTAssertEqual(e.restRemaining(now: t0 + 5_000), 0, "an overrun rest reads 0:00, never negative")
        XCTAssertEqual(e.stage, .resting(item: 0, set: 1, endsAt: t0 + 100),
                       "rest waits for the user; nothing starts a set on its own")
    }

    func testRestRecordedIsWhatWasActuallyTakenNotWhatWasPlanned() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 10)           // planned rest 90s
        e.advance(now: t0 + 210)                                  // actually rested 200s

        XCTAssertEqual(e.sets[0].restSec, 200,
                       "the work-vs-rest split is measured from the taps, not assumed from the plan")
    }

    func testASetCarriesTheDurationItWasPerformedOver() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0 + 300)                                  // set 1 begins
        e.advance(now: t0 + 345)          // set 1 ends
        XCTAssertEqual(e.sets[0].startTs, t0 + 300)
        XCTAssertEqual(e.sets[0].endTs, t0 + 345)
    }

    // MARK: - Undo

    func testUndoRestoresTheStageAndRemovesTheRecordedSet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        XCTAssertEqual(e.sets.count, 1)

        e.undo()
        XCTAssertEqual(e.stage, .working(item: 0, set: 1))
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

    func testUndoOnAFreshSessionIsHarmless() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.undo()
        XCTAssertEqual(e.stage, .warmup)
    }

    func testTappingPastTheEndDoesNothingAndCannotFillTheUndoStack() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 30)
        e.advance(now: t0 + 60)
        XCTAssertEqual(e.stage, .finished)

        e.advance(now: t0 + 90)
        e.advance(now: t0 + 120)
        XCTAssertEqual(e.stage, .finished, "finished is terminal")

        e.undo()
        XCTAssertEqual(e.stage, .cooldown, "a stray tap after the end must not consume the undo history")
    }

    // MARK: - Warm-ups and counting

    func testAWarmUpSetIsRecordedButDoesNotCountAsAWorkingSet() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        e.updateLastSet(weightKg: 20, reps: 12, rpe: nil, isWarmup: true)

        XCTAssertEqual(e.sets.count, 1)
        XCTAssertTrue(e.sets[0].isWarmup)
        XCTAssertEqual(e.completedWorkingSets, 0,
                       "studies count working sets; a warm-up must not inflate the tally")
    }

    // MARK: - Entering the set during the rest that follows it

    func testASetIsRecordedWithItsTimingBeforeAnyNumbersAreTyped() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0 + 300)
        e.advance(now: t0 + 345)

        XCTAssertEqual(e.sets.count, 1, "the set exists the moment it ends")
        XCTAssertEqual(e.sets[0].startTs, t0 + 300)
        XCTAssertEqual(e.sets[0].endTs, t0 + 345)
        XCTAssertNil(e.sets[0].weightKg, "numbers are typed during the rest, not while lifting")
        XCTAssertNil(e.sets[0].reps)
    }

    func testTheSetAwaitingEntryIsTheOneJustPerformed() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertNil(e.setAwaitingEntry, "nothing to fill in during the warm-up")
        e.advance(now: t0)
        XCTAssertNil(e.setAwaitingEntry, "nothing to fill in while the set is being performed")
        e.advance(now: t0 + 40)
        XCTAssertEqual(e.setAwaitingEntry?.setIndex, 1, "resting → the set just done is editable")
    }

    func testTypingDuringRestEditsTheSetRatherThanAddingOne() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)

        // Someone correcting themselves mid-rest must not accumulate sets.
        e.updateLastSet(weightKg: 30, reps: 10, rpe: nil, isWarmup: false)
        e.updateLastSet(weightKg: 32.5, reps: 9, rpe: 8, isWarmup: false)

        XCTAssertEqual(e.sets.count, 1)
        XCTAssertEqual(e.sets[0].weightKg, 32.5)
        XCTAssertEqual(e.sets[0].reps, 9)
        XCTAssertEqual(e.sets[0].rpe, 8)
    }

    func testTheFinalSetIsEditableDuringTheCoolDown() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], startTs: t0)
        e.advance(now: t0)
        e.advance(now: t0 + 40)
        XCTAssertEqual(e.stage, .cooldown)
        XCTAssertNotNil(e.setAwaitingEntry, "the last set has no rest after it, so the cool-down is its entry window")
        e.updateLastSet(weightKg: 20, reps: 12, rpe: 9, isWarmup: false)
        XCTAssertEqual(e.sets[0].reps, 12)
    }

    func testUpdatingWithNoSetRecordedIsHarmless() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        e.updateLastSet(weightKg: 100, reps: 5, rpe: 10, isWarmup: false)
        XCTAssertTrue(e.sets.isEmpty, "typing before any set exists must not invent one")
    }

    func testPlannedWorkingSetsSumsTheWholePlan() {
        let e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertEqual(e.plannedWorkingSets, 3)
    }

    // MARK: - Degenerate plans

    func testAnEmptyPlanGoesStraightToTheCoolDownRatherThanTrapping() {
        var e = LiftSessionEngine(plan: [], startTs: t0)
        XCTAssertEqual(e.stage, .cooldown)
        e.advance(now: t0 + 10)
        XCTAssertEqual(e.stage, .finished)
    }

    func testALineWithNoTargetStillGetsOneTappableSet() {
        let item = LiftPlanItem(exercise: "Face pull", targetSets: nil)
        XCTAssertEqual(item.targetSets, 1, "a plan that schedules zero sets could not be tapped through")
    }

    func testAMissingRestFallsBackToTheDefault() {
        let item = LiftPlanItem(exercise: "Face pull", restSec: nil)
        XCTAssertEqual(item.restSec, LiftPlanItem.defaultRestSec)
    }

    func testCurrentItemTracksTheExerciseBeingWorked() {
        var e = LiftSessionEngine(plan: twoExercisePlan(), startTs: t0)
        XCTAssertNil(e.currentItem, "there is no exercise during the warm-up")
        e.advance(now: t0)
        XCTAssertEqual(e.currentItem?.exercise, "Incline dumbbell press")
        e.advance(now: t0 + 40)
        e.advance(now: t0 + 140)
        e.advance(now: t0 + 180)
        e.advance(now: t0 + 280)
        XCTAssertEqual(e.currentItem?.exercise, "Lat pulldown")
    }
}
