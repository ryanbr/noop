import XCTest
@testable import Strand
import WhoopStore

/// Finishing a session: what saves, and what reaches the program.
///
/// From real sessions. 15 Sep 2026: grey numbers stay grey during the session, and a set count changed
/// with ⊕/⊖ reaches the program only if the user says so. 21 Sep 2026: a set that was done is complete —
/// typed numbers, else its grey ones — with no question at finish; only sets never started are asked
/// about ("the user might not complete all the workout"); and each program line takes its heaviest done
/// set's numbers, without asking.
@MainActor
final class LiftSessionFinishTests: XCTestCase {

    private func controller() -> LiftSessionController {
        LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
    }

    /// Bench 3 sets and rows 2 sets, both with targets and program lines behind them.
    private func plan() -> [LiftPlanItem] {
        [LiftPlanItem(exercise: "Bench press", primaryMuscle: .chest, targetSets: 3,
                      restSec: 60, targetRepsLow: 10, targetWeightKg: 50, programItemId: "bench"),
         LiftPlanItem(exercise: "Row", primaryMuscle: .lats, targetSets: 2,
                      restSec: 60, targetRepsLow: 12, targetWeightKg: 40, programItemId: "row")]
    }

    private func slot(_ e: Int, _ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: e, setIndex: s) }

    override func tearDown() {
        LiftSessionPersistence.clear()
        super.tearDown()
    }

    /// Bench set 1 done with only its weight typed, bench set 2 done untyped, the rest never started.
    private func halfDoneSession() -> LiftSessionController {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.advance()                                               // bench 1 working
        c.updateSet(slot(0, 1), weightKg: 55, reps: nil, rpe: nil, isWarmup: false)
        c.advance()                                               // bench 1 done, resting
        c.advance()                                               // bench 2 working
        c.advance()                                               // bench 2 done, untyped
        return c
    }

    /// A session run face-down, every set done on the strap and nothing typed: every set is complete
    /// with the grey numbers the sheet showed, and there is nothing to ask.
    func testSetsDoneOnTheStrapAreCompleteWithoutAsking() {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        for _ in 0..<10 { c.advance() }                           // every set worked, none typed
        XCTAssertTrue(c.unfinishedSlots.isEmpty, "every set was done, so nothing is unfinished")
        let saved = c.setsToSave(completingUnfinished: false)
        XCTAssertEqual(saved.map(\.weightKg), [50, 50, 50, 40, 40])
        XCTAssertEqual(saved.map(\.reps), [10, 10, 10, 12, 12])
        XCTAssertTrue(saved.allSatisfy { $0.endTs != nil })
    }

    /// With no set done and the rest discarded, no set counts: the precondition `LiftSessionView.save`
    /// guards on, so an hour that recorded nothing never reads back as a workout with strain.
    func testNothingDoneAndTheRestDiscardedLeavesNothingToFile() {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        XCTAssertEqual(c.unfinishedSlots.count, 5)
        XCTAssertFalse(LiftSessionController.anyPerformed(c.setsToSave(completingUnfinished: false)))
        XCTAssertTrue(LiftSessionController.anyPerformed(c.setsToSave(completingUnfinished: true)),
                      "completing them still files every set with its grey numbers")
    }

    func testUnfinishedSetsAreOnlyTheOnesNeverStarted() {
        XCTAssertEqual(halfDoneSession().unfinishedSlots, [slot(0, 3), slot(1, 1), slot(1, 2)],
                       "bench 2 was done untyped, so it is complete, not unfinished")
    }

    /// A set with anything typed always saves, and a blank field takes its grey number rather than
    /// saving empty.
    func testATypedSetSavesEitherWayWithItsBlanksFilled() {
        let c = halfDoneSession()
        for completing in [false, true] {
            let bench1 = c.setsToSave(completingUnfinished: completing).first { $0.slot == slot(0, 1) }
            XCTAssertEqual(bench1?.weightKg, 55)
            XCTAssertEqual(bench1?.reps, 10, "the untyped reps take the grey target, not nil")
            XCTAssertNotNil(bench1?.startTs)
        }
    }

    /// Discarding keeps every set never started as 0 kg × 0 reps: out of every figure, but still there to
    /// fill in under Edit sets if the discard was a mistake. The sets that were done are not touched.
    func testDiscardingSavesOnlyTheNeverStartedSetsAsZeros() {
        let saved = halfDoneSession().setsToSave(completingUnfinished: false)
        XCTAssertEqual(saved.map(\.slot), [slot(0, 1), slot(0, 2), slot(0, 3), slot(1, 1), slot(1, 2)])
        XCTAssertEqual(saved[0].weightKg, 55, "the typed set is untouched")
        XCTAssertEqual(saved[1].weightKg, 55, "bench 2 was done untyped: it keeps its grey numbers")
        XCTAssertEqual(saved[1].reps, 10)
        XCTAssertNotNil(saved[1].endTs)
        for set in saved.dropFirst(2) {
            XCTAssertEqual(set.weightKg, 0)
            XCTAssertEqual(set.reps, 0)
            XCTAssertNil(set.rpe)
            XCTAssertNil(set.startTs, "never started")
        }
    }

    /// Completing saves the untyped and the never-started sets with the grey numbers the sheet showed:
    /// bench follows bench set 1, rows take their target. Performed sets keep their order and timing;
    /// the never-started ones follow, with no timing to invent.
    func testCompletingSavesThemWithTheirGreyNumbers() {
        let saved = halfDoneSession().setsToSave(completingUnfinished: true)
        XCTAssertEqual(saved.map(\.slot), [slot(0, 1), slot(0, 2), slot(0, 3), slot(1, 1), slot(1, 2)])

        let bench2 = saved[1]
        XCTAssertEqual(bench2.weightKg, 55, "set 2 follows what set 1 counts as")
        XCTAssertEqual(bench2.reps, 10)
        XCTAssertNotNil(bench2.endTs, "it was performed, so its timing is real")

        let row1 = saved[3]
        XCTAssertEqual(row1.weightKg, 40)
        XCTAssertEqual(row1.reps, 12)
        XCTAssertNil(row1.startTs, "never started: no moment to record")
        XCTAssertNil(row1.restSec)
        XCTAssertNil(row1.rpe, "this plan sets no max RPE, so there is nothing to fill")
    }

    /// Numbers typed in advance and a warm-up mark still count for a set completed at finish.
    func testCompletingUsesWhatWasTypedAndMarkedInAdvance() {
        let c = halfDoneSession()
        c.updateSet(slot(1, 1), weightKg: 42.5, reps: nil, rpe: 7, isWarmup: false)
        c.setWarmup(slot(1, 2), true)

        let saved = c.setsToSave(completingUnfinished: true)
        let row1 = saved.first { $0.slot == slot(1, 1) }
        XCTAssertEqual(row1?.weightKg, 42.5)
        XCTAssertEqual(row1?.reps, 12, "the field left alone is still grey")
        XCTAssertEqual(row1?.rpe, 7)
        XCTAssertEqual(saved.first { $0.slot == slot(1, 2) }?.isWarmup, true)
    }

    /// A program's max RPE is grey in the session, and grey numbers are what a set saves when nothing is
    /// typed over them — RPE included (Utku, 16 Sep 2026). A typed rating always wins.
    func testAMaxRpeFillsAnEmptyRatingLikeEveryOtherGreyNumber() {
        let c = controller()
        c.start(plan: [LiftPlanItem(exercise: "Squat", targetSets: 2, targetRepsLow: 5, targetRpe: 8)],
                programId: nil, programName: nil)
        c.advance()                                               // set 1 working
        c.updateSet(slot(0, 1), weightKg: 60, reps: nil, rpe: nil, isWarmup: false)
        c.advance()                                               // set 1 done: a weight typed, no rating

        let kept = c.setsToSave(completingUnfinished: false)[0]
        XCTAssertEqual(kept.weightKg, 60)
        XCTAssertEqual(kept.rpe, 8, "an unrated set saves the plan's max RPE, as its grey number")

        let completed = c.setsToSave(completingUnfinished: true)
        XCTAssertEqual(completed.count, 2)
        XCTAssertTrue(completed.allSatisfy { $0.rpe == 8 }, "completing fills RPE the same way")

        c.updateSet(slot(0, 1), weightKg: 60, reps: nil, rpe: 6, isWarmup: false)
        XCTAssertEqual(c.setsToSave(completingUnfinished: true)[0].rpe, 6, "a typed rating wins")
    }

    /// Discarding saves zeros and no rating: the plan's number fills a blank only on a set the session
    /// keeps, so a discarded set cannot arrive carrying an effort nobody made. A set that was done keeps
    /// the plan's rating either way.
    func testADiscardedSetTakesNoMaxRpe() {
        let c = controller()
        c.start(plan: [LiftPlanItem(exercise: "Squat", targetSets: 2, targetRepsLow: 5, targetRpe: 8)],
                programId: nil, programName: nil)
        c.advance()
        c.advance()                                               // set 1 done, nothing typed at all
        let saved = c.setsToSave(completingUnfinished: false)
        XCTAssertEqual(saved[0].rpe, 8, "done: complete, with the plan's max RPE")
        XCTAssertNil(saved[1].rpe, "never started and discarded")
        XCTAssertEqual(saved[1].reps, 0)
    }

    /// Nothing unfinished means nothing to ask, and every set saves.
    func testAFullyTypedSessionHasNothingUnfinished() {
        let c = controller()
        c.start(plan: [LiftPlanItem(exercise: "Curl", targetSets: 1)], programId: nil, programName: nil)
        c.advance()
        c.updateSet(slot(0, 1), weightKg: 12, reps: 12, rpe: nil, isWarmup: false)
        c.advance()
        XCTAssertTrue(c.unfinishedSlots.isEmpty)
        XCTAssertEqual(c.setsToSave(completingUnfinished: false).count, 1)
    }

    /// The minimised bar and the Lock Screen show a finished, untyped set's grey numbers, not a blank.
    func testTheBarShowsGreyNumbersForAnUntypedSet() {
        let c = halfDoneSession()
        XCTAssertEqual(c.setNumbers(for: slot(0, 2), system: .metric), "10 x 55 kg")
    }

    // MARK: - The program's set counts

    private func item(_ id: String, _ exercise: String, sets: Int?) -> LiftProgramItemRow {
        LiftProgramItemRow(id: id, deviceId: "d", programId: "p", ord: 0, exercise: exercise,
                           targetSets: sets, targetRepsLow: 10, targetRepsHigh: nil, targetRpe: nil,
                           targetWeightKg: 50, restSec: 60, note: "keep me")
    }

    func testOnlyLinesWhoseCountMovedAreOffered() {
        var lines = plan()
        lines[0].targetSets = 4                                   // bench 3 -> 4
        let rows = [item("bench", "Bench press", sets: 3), item("row", "Row", sets: 2)]
        XCTAssertEqual(LiftSessionController.setCountChanges(plan: lines, program: rows),
                       [.init(itemId: "bench", exercise: "Bench press", from: 3, to: 4)])
    }

    /// A line with no count starts a session with one set, so one set is no change; a line deleted
    /// from the program since the session began is never offered back.
    func testAMissingCountIsOneAndADeletedLineIsSkipped() {
        let lines = [LiftPlanItem(exercise: "Curl", targetSets: nil, programItemId: "curl"),
                     LiftPlanItem(exercise: "Gone", targetSets: 5, programItemId: "gone")]
        XCTAssertTrue(LiftSessionController.setCountChanges(
            plan: lines, program: [item("curl", "Curl", sets: nil)]).isEmpty)
    }

    func testApplyingMovesOnlyTheSetCount() {
        let rows = [item("bench", "Bench press", sets: 3), item("row", "Row", sets: 2)]
        let changed = LiftSessionController.applying(
            [.init(itemId: "bench", exercise: "Bench press", from: 3, to: 5)], to: rows)
        XCTAssertEqual(changed[0].targetSets, 5)
        XCTAssertEqual(changed[0].note, "keep me")
        XCTAssertEqual(changed[0].targetWeightKg, 50)
        XCTAssertEqual(changed[1].targetSets, 2, "an unchanged line stays as it was")
    }

    // MARK: - The program's numbers

    private func done(_ e: Int, _ s: Int, _ kg: Double?, _ reps: Int?, warmup: Bool = false,
                      started: Bool = true) -> LiftSessionController.FinishedSet {
        .init(slot: slot(e, s), weightKg: kg, reps: reps, rpe: nil, isWarmup: warmup,
              startTs: started ? 100 : nil, endTs: started ? 160 : nil, restSec: nil)
    }

    /// Each line takes its heaviest done set — more weight first, then more reps — and nothing else moves.
    func testEachProgramLineTakesItsHeaviestDoneSet() {
        let rows = [item("bench", "Bench press", sets: 3), item("row", "Row", sets: 2)]
        let sets = [done(0, 1, 60, 8), done(0, 2, 65, 6), done(0, 3, 65, 7),
                    done(1, 1, 45, 10), done(1, 2, 42.5, 12)]
        let edited = LiftSessionController.applyingHeaviestSets(sets, plan: plan(), to: rows)
        XCTAssertEqual(edited[0].targetWeightKg, 65)
        XCTAssertEqual(edited[0].targetRepsLow, 7, "equal weight: the set with more reps")
        XCTAssertEqual(edited[1].targetWeightKg, 45, "a lighter back-off set does not pull the program down")
        XCTAssertEqual(edited[1].targetRepsLow, 10)
        XCTAssertEqual(edited[0].targetSets, 3)
        XCTAssertEqual(edited[0].note, "keep me")
    }

    /// Only sets actually done carry new numbers: a warm-up, a discarded zero and a set completed at
    /// finish without being started (grey numbers, not new ones) leave the program as it was.
    func testSetsThatWereNotDoneLeaveTheProgramAlone() {
        let rows = [item("bench", "Bench press", sets: 3), item("row", "Row", sets: 2)]
        let sets = [done(0, 1, 80, 5, warmup: true), done(0, 2, 0, 0),
                    done(1, 1, 90, 3, started: false)]
        XCTAssertEqual(LiftSessionController.applyingHeaviestSets(sets, plan: plan(), to: rows), rows)
    }

    /// A bodyweight set keeps the line's weight; a leftover rep-range top below the new count is dropped;
    /// a line with no program behind it, or deleted since, is skipped.
    func testMissingNumbersAndMissingLinesAreLeftAlone() {
        var rows = [item("bench", "Bench press", sets: 3)]
        rows[0].targetRepsHigh = 12
        let edited = LiftSessionController.applyingHeaviestSets([done(0, 1, nil, 15)], plan: plan(), to: rows)
        XCTAssertEqual(edited[0].targetWeightKg, 50, "no weight on the set, so the line's weight stays")
        XCTAssertEqual(edited[0].targetRepsLow, 15)
        XCTAssertNil(edited[0].targetRepsHigh, "12 would sit below the new 15")

        let unowned = [LiftPlanItem(exercise: "Curl", targetSets: 1)]
        XCTAssertEqual(LiftSessionController.applyingHeaviestSets([done(0, 1, 20, 10)], plan: unowned, to: rows),
                       rows)
        XCTAssertEqual(LiftSessionController.applyingHeaviestSets([done(1, 1, 20, 10)], plan: plan(), to: rows),
                       rows, "the row line was deleted from the program: nothing to write")
    }

    /// The hub reloads on this: a saved session must announce itself, and a discarded one must not.
    func testSavingASessionIsAnnouncedButDiscardingIsNot() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: nil)
        c.discard()
        XCTAssertEqual(c.savedSessions, 0)
        c.start(plan: plan(), programId: nil, programName: nil)
        c.finishedSaving()
        XCTAssertEqual(c.savedSessions, 1)
    }
}
