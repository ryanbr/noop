import XCTest
@testable import Strand
import WhoopStore

/// The crash-safe snapshot of an in-flight session, and the one question that decides whether an
/// update can be installed OVER the previous build or needs a wipe: **does data written by the
/// previous build still read?**
///
/// The session snapshot is the only thing this feature persists outside SQLite (UserDefaults,
/// `noop.activeLiftSession`), so it is the only place an app-layer change can strand something the
/// old build wrote. A schema change is the other half of that question and is answered by the
/// migration, not here.
final class LiftSessionPersistenceTests: XCTestCase {

    private let t0 = 1_700_000_000

    /// A snapshot exactly as the PREVIOUS build wrote it: no `programItemId`, because the field did
    /// not exist until the set count could be changed mid-session.
    ///
    /// Written as literal JSON on purpose. Encoding it with today's `Snapshot` would only prove that
    /// today's build can read itself — the whole point is to read bytes the old build produced.
    private func snapshotJSONWithoutProgramItemId() -> Data {
        Data("""
        {
          "startSec": \(t0),
          "programId": "p1",
          "programName": "Upper A",
          "plan": [
            {"exercise": "Bench press", "secondaryMuscles": ["triceps"], "primaryMuscle": "chest",
             "targetSets": 3, "restSec": 90, "targetRepsLow": 8, "targetWeightKg": 60}
          ],
          "stage": {"kind": "resting", "item": 0, "set": 1, "endsAt": \(t0 + 130)},
          "sets": [
            {"exerciseIndex": 0, "setIndex": 1, "weightKg": 60, "reps": 8, "isWarmup": false,
             "startTs": \(t0 + 10), "endTs": \(t0 + 40)}
          ],
          "stageStartedAt": \(t0 + 40)
        }
        """.utf8)
    }

    /// A session started on the previous build and still running when the update is installed must
    /// come back whole. It is the reason today's change can go on as a plain update rather than a wipe.
    func testASessionWrittenByThePreviousBuildStillResumes() throws {
        let decoded = try XCTUnwrap(LiftSessionPersistence.decode(snapshotJSONWithoutProgramItemId()),
                                    "a snapshot from the previous build must not read as 'no session'")
        let engine = LiftSessionPersistence.engine(from: decoded)

        XCTAssertEqual(engine.startTs, t0)
        XCTAssertEqual(engine.plan.count, 1)
        XCTAssertEqual(engine.plan[0].exercise, "Bench press")
        XCTAssertEqual(engine.plan[0].targetSets, 3)
        XCTAssertEqual(engine.plan[0].primaryMuscle, .chest)
        XCTAssertEqual(engine.stage, .resting(LiftSlot(exerciseIndex: 0, setIndex: 1),
                                              endsAt: t0 + 130))
        XCTAssertEqual(engine.sets.count, 1, "the set already logged survives the update")
        XCTAssertEqual(engine.sets[0].weightKg, 60)
    }

    /// The new field is simply absent, not garbage — so the write-back is skipped for that session
    /// rather than aimed at a program line that was never identified.
    func testAResumedOldSessionCarriesNoProgramLineAndIsStillFullyUsable() throws {
        let decoded = try XCTUnwrap(LiftSessionPersistence.decode(snapshotJSONWithoutProgramItemId()))
        var engine = LiftSessionPersistence.engine(from: decoded)
        XCTAssertNil(engine.plan[0].programItemId)

        // And the set count can still be changed — the session works, the program just is not rewritten.
        XCTAssertTrue(engine.addSet(toExercise: 0))
        XCTAssertEqual(engine.plan[0].targetSets, 4)
    }

    /// Numbers typed for a set that has not happened yet must survive a crash. Losing them to a
    /// relaunch would be the same bug as losing them to a blur, with extra steps.
    func testNumbersTypedForASetNotYetPerformedSurviveARelaunch() throws {
        let plan = [LiftPlanItem(exercise: "Row", targetSets: 3, restSec: 60)]
        let engine = LiftSessionEngine(plan: plan, startTs: t0)
        let slot = LiftSlot(exerciseIndex: 0, setIndex: 3)
        let typed = LiftSessionController.PendingSetValues(weightKg: 72.5, reps: 6, rpe: nil)

        let encoded = try XCTUnwrap(LiftSessionPersistence.encode(
            LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil,
                                            pendingValues: [slot: typed],
                                            pendingWarmups: [LiftSlot(exerciseIndex: 0, setIndex: 1)])))
        let back = try XCTUnwrap(LiftSessionPersistence.decode(encoded))

        XCTAssertEqual(LiftSessionPersistence.pendingValues(from: back), [slot: typed])
        XCTAssertEqual(LiftSessionPersistence.pendingWarmups(from: back),
                       [LiftSlot(exerciseIndex: 0, setIndex: 1)])
    }

    /// A snapshot written before any of this existed carries neither, and must resume with nothing
    /// pending rather than failing to read at all.
    func testAnOldSnapshotResumesWithNothingPending() throws {
        let decoded = try XCTUnwrap(LiftSessionPersistence.decode(snapshotJSONWithoutProgramItemId()))
        XCTAssertTrue(LiftSessionPersistence.pendingValues(from: decoded).isEmpty)
        XCTAssertTrue(LiftSessionPersistence.pendingWarmups(from: decoded).isEmpty)
    }

    /// The round trip today's build performs on itself, including the new field.
    func testTodaysSnapshotRoundTripsWithTheProgramLine() throws {
        let plan = [LiftPlanItem(exercise: "Lat pulldown", primaryMuscle: .lats,
                                 targetSets: 2, restSec: 60, programItemId: "line-7")]
        var engine = LiftSessionEngine(plan: plan, startTs: t0)
        engine.advance(now: t0)
        engine.advance(now: t0 + 30)
        engine.addSet(toExercise: 0)

        let encoded = try XCTUnwrap(LiftSessionPersistence.encode(
            LiftSessionPersistence.snapshot(engine: engine, programId: "p1", programName: "Pull",
                                            pendingValues: [:], pendingWarmups: [])))
        let back = try XCTUnwrap(LiftSessionPersistence.decode(encoded))
        let rebuilt = LiftSessionPersistence.engine(from: back)

        XCTAssertEqual(rebuilt.plan[0].programItemId, "line-7",
                       "without this the added set could not be written back after a relaunch")
        XCTAssertEqual(rebuilt.plan[0].targetSets, 3, "the added set survives a crash")
        XCTAssertEqual(rebuilt.sets.count, 1)
    }
}
