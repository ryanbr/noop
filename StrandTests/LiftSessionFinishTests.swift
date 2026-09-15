import XCTest
@testable import Strand
import WhoopStore

/// Finishing a session: what saves, and whether the program keeps a changed set count.
///
/// Asked for after a real session, 15 Sep 2026: grey numbers stay grey during the session, finishing
/// asks once whether the sets without typed numbers are completed with them or left out ("the user
/// might not complete all the workout, just a couple of exercises"), and a set count changed with ⊕/⊖
/// reaches the program only if the user says so.
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

    /// A session run face-down, every set advanced on the strap and nothing typed. Discarding then
    /// leaves NOTHING: this is the precondition `LiftSessionView.save` guards on, because filing it
    /// wrote a session with no sets and a manual workout the engine would fill strain into, so an
    /// hour that recorded nothing read back as a workout. Completing still saves all five.
    func testAFaceDownSessionDiscardingSavesNothingAtAll() {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        for _ in 0..<10 { c.advance() }                           // every set worked, none typed
        XCTAssertEqual(c.unfinishedSlots.count, 5, "nothing typed, so every slot is unentered")
        XCTAssertTrue(c.setsToSave(completingUnfinished: false).isEmpty,
                      "discarding an all-untyped session must leave no set to file")
        XCTAssertEqual(c.setsToSave(completingUnfinished: true).count, 5,
                       "completing still files every set with its grey numbers")
    }

    func testUnfinishedSetsAreTheUntypedAndTheNeverStarted() {
        XCTAssertEqual(halfDoneSession().unfinishedSlots,
                       [slot(0, 2), slot(0, 3), slot(1, 1), slot(1, 2)])
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

    func testDiscardingLeavesEveryUnfinishedSetOut() {
        let saved = halfDoneSession().setsToSave(completingUnfinished: false)
        XCTAssertEqual(saved.map(\.slot), [slot(0, 1)])
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
        XCTAssertNil(row1.rpe, "RPE is never invented")
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
