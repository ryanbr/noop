import XCTest
@testable import Strand
import WhoopStore

/// Typing numbers into a set you are NOT currently doing.
///
/// Reported from a real session, 11 Sep 2026: *"you can't edit the numbers of other sets while in an
/// active set — when I type something during an active set to other sets it refreshes to the empty."*
/// It did. `LiftSessionView.write` could only edit a set that already had a RECORD, so a keystroke
/// into a pending row went nowhere; the draft made the field look like it had taken until focus left.
///
/// The engine rule underneath is not the bug and does not move: typing must never append a set, or a
/// set nobody performed becomes data. So the numbers are held in the controller and applied the
/// instant the set is recorded — the same mechanism a warm-up marked in advance already used.
@MainActor
final class LiftSessionPendingInputTests: XCTestCase {

    private func controller() -> LiftSessionController {
        LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
    }

    /// Three sets, with targets, so there is a carried plan for a typed value to beat.
    private func plan() -> [LiftPlanItem] {
        [LiftPlanItem(exercise: "Bench press", primaryMuscle: .chest, targetSets: 3,
                      restSec: 60, targetRepsLow: 10, targetWeightKg: 50)]
    }

    private func slot(_ e: Int, _ s: Int) -> LiftSlot { LiftSlot(exerciseIndex: e, setIndex: s) }

    override func tearDown() {
        LiftSessionPersistence.clear()
        super.tearDown()
    }

    // MARK: - The reported bug

    /// The exact report: set 1 is active, the user types into set 3, and it must still be there.
    func testTypingIntoAnotherSetWhileOneIsActiveIsKept() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.advance()                                               // set 1 is now active
        XCTAssertEqual(c.engine?.stage, .working(slot(0, 1)))

        c.updateSet(slot(0, 3), weightKg: 62.5, reps: 6, rpe: nil, isWarmup: false)

        XCTAssertEqual(c.enteredValues(for: slot(0, 3)).weightKg, 62.5,
                       "a number typed into another set must not evaporate")
        XCTAssertEqual(c.enteredValues(for: slot(0, 3)).reps, 6)
        XCTAssertEqual(c.engine?.stage, .working(slot(0, 1)),
                       "and typing elsewhere must not disturb the set being worked")
        XCTAssertEqual(c.engine?.sets.count, 0, "nor invent a set nobody has performed")
    }

    /// What was typed in advance is what gets recorded — it beats the carried plan, which is only
    /// the sheet's guess (this exercise earlier, last session, the program's target).
    func testWhatWasTypedInAdvanceIsWhatTheSetRecords() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.setLastSession(["Bench press": [1: LiftSetCarry(weightKg: 55, reps: 9)]])
        c.advance()                                               // set 1 active
        c.updateSet(slot(0, 1), weightKg: 70, reps: 5, rpe: nil, isWarmup: false)
        c.advance()                                               // "Set done"

        let recorded = c.engine?.recordedSet(for: slot(0, 1))
        XCTAssertEqual(recorded?.weightKg, 70, "the typed weight wins over the carried 55")
        XCTAssertEqual(recorded?.reps, 5)
        XCTAssertTrue(c.pendingValues.isEmpty, "and the held entry is consumed once applied")
    }

    /// Typing only one field must not blank the others — they keep carrying.
    func testAFieldLeftAloneStillCarries() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.setLastSession(["Bench press": [1: LiftSetCarry(weightKg: 55, reps: 9)]])
        c.advance()
        c.updateSet(slot(0, 1), weightKg: 70, reps: nil, rpe: nil, isWarmup: false)
        c.advance()

        XCTAssertEqual(c.engine?.recordedSet(for: slot(0, 1))?.weightKg, 70)
        XCTAssertEqual(c.engine?.recordedSet(for: slot(0, 1))?.reps, 9,
                       "reps nobody typed still come from the carry, not from nowhere")
    }

    /// Clearing the field puts the row back to showing the plan's grey ghost, rather than pinning an
    /// empty entry that would record a blank set.
    func testClearingTheFieldDropsTheHeldEntry() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.updateSet(slot(0, 2), weightKg: 80, reps: nil, rpe: nil, isWarmup: false)
        XCTAssertFalse(c.pendingValues.isEmpty)

        c.updateSet(slot(0, 2), weightKg: nil, reps: nil, rpe: nil, isWarmup: false)
        XCTAssertTrue(c.pendingValues.isEmpty)
        XCTAssertNil(c.enteredValues(for: slot(0, 2)).weightKg)
    }

    // MARK: - What must not change

    /// Editing a set that IS recorded still edits it in the engine, from any stage.
    func testACompletedSetIsStillEditedInPlace() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.advance()
        c.advance()                                               // set 1 recorded, resting
        c.advance()                                               // set 2 active

        c.updateSet(slot(0, 1), weightKg: 47.5, reps: 12, rpe: 8, isWarmup: false)

        XCTAssertEqual(c.engine?.recordedSet(for: slot(0, 1))?.weightKg, 47.5)
        XCTAssertEqual(c.engine?.recordedSet(for: slot(0, 1))?.rpe, 8)
        XCTAssertTrue(c.pendingValues.isEmpty,
                      "a set with a record is edited, never shadowed by a held entry")
    }

    /// The engine's rule is untouched: no amount of typing creates a set.
    func testTypingNeverInventsASet() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.updateSet(slot(0, 1), weightKg: 60, reps: 10, rpe: 9, isWarmup: false)
        c.updateSet(slot(0, 3), weightKg: 60, reps: 10, rpe: 9, isWarmup: false)
        XCTAssertEqual(c.engine?.sets.count, 0)
        XCTAssertEqual(c.engine?.completedWorkingSets, 0)
    }

    /// Typing into a slot the plan does not have is ignored rather than held forever.
    func testTypingIntoASlotOutsideThePlanIsIgnored() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.updateSet(slot(9, 1), weightKg: 60, reps: 10, rpe: nil, isWarmup: false)
        XCTAssertTrue(c.pendingValues.isEmpty)
    }

    /// A warm-up marked in advance still lands, and now travels with the numbers.
    func testAWarmUpMarkedInAdvanceStillApplies() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.advance()
        c.setWarmup(slot(0, 1), true)
        c.updateSet(slot(0, 1), weightKg: 20, reps: 15, rpe: nil, isWarmup: true)
        c.advance()

        let recorded = c.engine?.recordedSet(for: slot(0, 1))
        XCTAssertEqual(recorded?.isWarmup, true)
        XCTAssertEqual(recorded?.weightKg, 20)
        XCTAssertEqual(c.engine?.completedWorkingSets, 0, "a warm-up is still not a working set")
    }

    /// A redo drops the record and should show the ghosts again — the consumed entry must not come
    /// back and re-fill the row with numbers the user is in the middle of redoing.
    func testARedoDoesNotResurrectTheConsumedEntry() {
        let c = controller()
        c.start(plan: plan(), programId: nil, programName: "Upper A")
        c.advance()
        c.updateSet(slot(0, 1), weightKg: 70, reps: 5, rpe: nil, isWarmup: false)
        c.advance()                                               // recorded with 70 x 5
        c.start(slot(0, 1))                                       // redo: record dropped

        XCTAssertNil(c.engine?.recordedSet(for: slot(0, 1)))
        XCTAssertNil(c.enteredValues(for: slot(0, 1)).weightKg,
                     "the row is back to its ghosts, as it was before this existed")
    }
}
