import XCTest
@testable import Strand
import WhoopStore

/// An exercise added while the session runs (Utku, 21 Sep 2026): it joins at the end as one set planned at
/// 0 kg × 0 reps, works like any other line, survives a relaunch, and reaches the program only when
/// finishing is told to keep the changes.
@MainActor
final class LiftSessionAddExerciseTests: XCTestCase {

    private let t0 = 1_700_000_000

    private func plan() -> [LiftPlanItem] {
        [LiftPlanItem(exercise: "Bench press", primaryMuscle: .chest, targetSets: 2,
                      restSec: 60, targetRepsLow: 10, targetWeightKg: 50, programItemId: "bench")]
    }

    private func slot(_ e: Int, _ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: e, setIndex: s) }

    private func controller() -> LiftSessionController {
        LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
    }

    /// The program behind `plan()`: one line, id "bench".
    private func programRows() -> [LiftProgramItemRow] {
        [LiftProgramItemRow(id: "bench", deviceId: "d", programId: "p", ord: 0, exercise: "Bench press",
                            targetSets: 2, targetRepsLow: 10, targetRepsHigh: nil, targetRpe: 8,
                            targetWeightKg: 50, restSec: 60, note: "Pause")]
    }

    override func tearDown() {
        LiftSessionPersistence.clear()
        super.tearDown()
    }

    // MARK: - The engine

    func testAnAddedExerciseJoinsAtTheEndWithOneSet() {
        var engine = LiftSessionEngine(plan: plan(), startTs: t0)
        XCTAssertTrue(engine.addExercise(LiftPlanItem(exercise: "Cable fly", targetSets: 4)))
        XCTAssertEqual(engine.plan.map(\.exercise), ["Bench press", "Cable fly"])
        XCTAssertEqual(engine.plan[1].targetSets, 1, "a line starts with one set, whatever it was given")
        XCTAssertEqual(engine.slots(forExercise: 1), [slot(1, 1)])
        XCTAssertEqual(engine.unperformedSlots.count, 3)
    }

    /// With everything planned done, the session waits at 0:00 — and the added set is where the next tap goes.
    func testTheNextTapReachesAnExerciseAddedAfterEverythingElseWasDone() {
        var engine = LiftSessionEngine(plan: plan(), startTs: t0)
        for i in 1...5 { engine.advance(now: t0 + i * 100) }     // both bench sets, both rests, then on
        XCTAssertTrue(engine.allCompleted)
        XCTAssertEqual(engine.stage, .resting(slot(0, 2), endsAt: t0 + 500), "sheet complete: waiting")

        engine.addExercise(LiftPlanItem(exercise: "Cable fly"))
        XCTAssertFalse(engine.allCompleted)
        XCTAssertEqual(engine.upcomingSlot, slot(1, 1))
        engine.advance(now: t0 + 600)
        XCTAssertEqual(engine.stage, .working(slot(1, 1)))
    }

    func testAddingAnExerciseCanBeUndone() {
        var engine = LiftSessionEngine(plan: plan(), startTs: t0)
        engine.addExercise(LiftPlanItem(exercise: "Cable fly"))
        engine.undo()
        XCTAssertEqual(engine.plan.map(\.exercise), ["Bench press"])
    }

    func testNothingIsAddedToAFinishedSessionOrPastTheBound() {
        var finished = LiftSessionEngine(plan: plan(), startTs: t0)
        finished.finish(now: t0 + 10)
        XCTAssertFalse(finished.addExercise(LiftPlanItem(exercise: "Cable fly")))
        XCTAssertEqual(finished.plan.count, 1)

        let full = (0..<LiftSessionEngine.maxExercises).map { LiftPlanItem(exercise: "E\($0)") }
        var atBound = LiftSessionEngine(plan: full, startTs: t0)
        XCTAssertFalse(atBound.addExercise(LiftPlanItem(exercise: "One more")))
        XCTAssertEqual(atBound.plan.count, LiftSessionEngine.maxExercises)
    }

    // MARK: - The controller

    /// Planned at 0 kg × 0 reps with no max RPE (0 is not on the 1–10 scale) and the default rest, so its
    /// row shows zeros until numbers are typed; marked as added, with the id its program line would take.
    func testTheAddedLineIsPlannedAtZeroWithTheIdItsProgramLineWouldTake() throws {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        XCTAssertTrue(c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [.chest, .frontDelts]))

        let line = try XCTUnwrap(c.engine?.plan.last)
        XCTAssertEqual(line.exercise, "Cable fly")
        XCTAssertEqual(line.primaryMuscle, .chest)
        XCTAssertEqual(line.secondaryMuscles, [.frontDelts], "a primary is never also a secondary")
        XCTAssertEqual(line.targetSets, 1)
        XCTAssertEqual(line.targetWeightKg, 0)
        XCTAssertEqual(line.targetRepsLow, 0)
        XCTAssertNil(line.targetRpe)
        XCTAssertEqual(line.restSec, LiftPlanItem.defaultRestSec)
        XCTAssertTrue(line.addedInSession)
        XCTAssertNotNil(line.programItemId)
        XCTAssertFalse(try XCTUnwrap(c.engine?.plan.first).addedInSession)

        XCTAssertEqual(c.carry(for: slot(1, 1)), LiftSetCarry(weightKg: 0, reps: 0))
        XCTAssertEqual(c.setNumbers(for: slot(1, 1), system: .metric), "0 x 0 kg")
    }

    /// An exercise done before shows last time's numbers in grey, like every other line.
    func testAnExerciseDoneBeforeShowsLastTimesNumbers() {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [])
        c.setLastSession(["Cable fly": [1: LiftSetCarry(weightKg: 15, reps: 12)]])
        XCTAssertEqual(c.carry(for: slot(1, 1)), LiftSetCarry(weightKg: 15, reps: 12))
    }

    /// Done without typing, the set saves its zeros — which counts as not performed: out of every figure,
    /// fillable under Edit sets. Typed numbers save as typed.
    func testTheAddedSetSavesWhatWasTypedElseZeros() {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [])
        c.start(slot(1, 1))
        c.advance()                                                     // done, nothing typed
        c.addSet(toExercise: 1)
        c.start(slot(1, 2))
        c.updateSet(slot(1, 2), weightKg: 17.5, reps: 12, rpe: nil, isWarmup: false)
        c.advance()

        let saved = c.setsToSave(completingUnfinished: false).filter { $0.slot.exerciseIndex == 1 }
        XCTAssertEqual(saved.map(\.weightKg), [0, 17.5])
        XCTAssertEqual(saved.map(\.reps), [0, 12])
        XCTAssertEqual(saved.map(\.rpe), [nil, nil], "no max RPE to fill a blank rating")
    }

    // MARK: - Relaunch

    /// A crash or an iOS restart must not lose the added line, nor forget it was added.
    func testAnAddedExerciseSurvivesARelaunch() throws {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [.frontDelts])
        let id = try XCTUnwrap(c.engine?.plan.last?.programItemId)

        let resumed = controller()
        resumed.resumeSaved()
        let line = try XCTUnwrap(resumed.engine?.plan.last)
        XCTAssertEqual(line.exercise, "Cable fly")
        XCTAssertTrue(line.addedInSession)
        XCTAssertEqual(line.programItemId, id)
        XCTAssertEqual(line.secondaryMuscles, [.frontDelts])
        XCTAssertFalse(try XCTUnwrap(resumed.engine?.plan.first).addedInSession)
    }

    /// A session nobody added to encodes exactly as before, so the snapshot is not rewritten for nothing.
    func testASessionWithNothingAddedWritesNoAddedField() throws {
        let engine = LiftSessionEngine(plan: plan(), startTs: t0)
        let data = try XCTUnwrap(LiftSessionPersistence.encode(LiftSessionPersistence.snapshot(
            engine: engine, programId: "p", programName: "Upper A", pendingValues: [:], pendingWarmups: [])))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("addedInSession"))
    }

    // MARK: - Finishing

    /// "Update program": the new exercise becomes a line at the end, with the session's set count and its
    /// heaviest done set; nothing else set. The existing line takes its heaviest set, as always.
    func testKeepingTheChangesAddsTheExerciseToTheProgram() throws {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [])
        c.addSet(toExercise: 1)
        c.start(slot(1, 1))
        c.updateSet(slot(1, 1), weightKg: 15, reps: 12, rpe: nil, isWarmup: false)
        c.advance()
        c.start(slot(1, 2))
        c.updateSet(slot(1, 2), weightKg: 17.5, reps: 10, rpe: nil, isWarmup: false)
        c.advance()
        c.finish()
        let engine = try XCTUnwrap(c.engine)

        let after = LiftSessionController.programAfterSession(
            c.setsToSave(completingUnfinished: false), plan: engine.plan, program: programRows(),
            keepingChanges: true, programId: "p", deviceId: "d")
        XCTAssertEqual(after.map(\.exercise), ["Bench press", "Cable fly"])
        XCTAssertEqual(after[0], programRows()[0], "bench was never done, so its line is untouched")
        let added = after[1]
        XCTAssertEqual(added.id, engine.plan[1].programItemId)
        XCTAssertEqual(added.programId, "p")
        XCTAssertEqual(added.deviceId, "d")
        XCTAssertEqual(added.ord, 1)
        XCTAssertEqual(added.targetSets, 2)
        XCTAssertEqual(added.targetWeightKg, 17.5, "its heaviest done set")
        XCTAssertEqual(added.targetRepsLow, 10)
        XCTAssertNil(added.targetRepsHigh)
        XCTAssertNil(added.targetRpe)
        XCTAssertNil(added.restSec)
        XCTAssertNil(added.note)
    }

    /// Nothing typed for it: the new line is written as 0 kg × 0 reps, to be filled in later.
    func testAnAddedExerciseWithNothingTypedJoinsTheProgramAtZero() throws {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: nil, secondaryMuscles: [])
        c.finish()
        let engine = try XCTUnwrap(c.engine)

        let after = LiftSessionController.programAfterSession(
            c.setsToSave(completingUnfinished: true), plan: engine.plan, program: programRows(),
            keepingChanges: true, programId: "p", deviceId: "d")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[1].targetSets, 1)
        XCTAssertEqual(after[1].targetWeightKg, 0)
        XCTAssertEqual(after[1].targetRepsLow, 0)
    }

    /// "Keep as it was": the program gains nothing, and the heaviest-set rule still applies to its lines.
    func testKeepingTheProgramAsItWasAddsNothing() throws {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.advance()
        c.updateSet(slot(0, 1), weightKg: 55, reps: 8, rpe: nil, isWarmup: false)
        c.advance()
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [])
        c.addSet(toExercise: 0)
        c.finish()
        let engine = try XCTUnwrap(c.engine)

        let after = LiftSessionController.programAfterSession(
            c.setsToSave(completingUnfinished: false), plan: engine.plan, program: programRows(),
            keepingChanges: false, programId: "p", deviceId: "d")
        XCTAssertEqual(after.map(\.exercise), ["Bench press"])
        XCTAssertEqual(after[0].targetWeightKg, 55)
        XCTAssertEqual(after[0].targetRepsLow, 8)
        XCTAssertEqual(after[0].targetSets, 2, "the changed count is not kept either")
    }

    /// The added line is not a set-count change of a line the program has, and a changed count on an
    /// existing line still moves with it.
    func testAnAddedLineIsNotReportedAsASetCountChange() throws {
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [])
        c.addSet(toExercise: 1)
        c.addSet(toExercise: 0)
        let engine = try XCTUnwrap(c.engine)

        let changes = LiftSessionController.setCountChanges(plan: engine.plan, program: programRows())
        XCTAssertEqual(changes, [.init(itemId: "bench", exercise: "Bench press", from: 2, to: 3)])
        let after = LiftSessionController.programAfterSession(
            [], plan: engine.plan, program: programRows(), keepingChanges: true, programId: "p", deviceId: "d")
        XCTAssertEqual(after.map(\.targetSets), [3, 2])
    }

    /// New lines go after the program's LAST line, whatever its `ord`, in the order they were added.
    func testNewLinesFollowTheProgramsLastLineInTheOrderAdded() throws {
        var rows = programRows()
        rows[0].ord = 7
        let c = controller()
        c.start(plan: plan(), programId: "p", programName: "Upper A")
        c.addExercise("Cable fly", primaryMuscle: .chest, secondaryMuscles: [])
        c.addExercise("Dips", primaryMuscle: .triceps, secondaryMuscles: [])
        let engine = try XCTUnwrap(c.engine)

        let after = LiftSessionController.programAfterSession(
            [], plan: engine.plan, program: rows, keepingChanges: true, programId: "p", deviceId: "d")
        XCTAssertEqual(after.map(\.exercise), ["Bench press", "Cable fly", "Dips"])
        XCTAssertEqual(after.map(\.ord), [7, 8, 9])
    }
}
