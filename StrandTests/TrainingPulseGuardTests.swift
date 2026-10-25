import XCTest
@testable import Strand

final class TrainingPulseGuardTests: XCTestCase {
    func testDisconnectionNeverPausesAndReconnectStartsANewWindow() {
        var state = TrainingPulseGuard()
        state.receive(at: 1_000)
        state.setConnected(false, at: 1_599)
        XCTAssertNil(state.deadline)
        XCTAssertFalse(state.isDue(at: 20_000))
        state.setConnected(true, at: 20_000)
        XCTAssertEqual(state.lastSampleSec, 1_000, "a connection must not masquerade as a sample")
        XCTAssertFalse(state.isDue(at: 20_599))
        XCTAssertTrue(state.isDue(at: 20_600))
        state.receive(at: 20_500)
        XCTAssertEqual(state.deadline, 21_100)
    }

    func testReconnectWithoutFirstSampleDoesNotArmAndRepeatedConnectionDoesNotExtend() {
        var state = TrainingPulseGuard()
        state.setConnected(false, at: 1_000)
        state.setConnected(true, at: 2_000)
        XCTAssertNil(state.deadline)
        state.receive(at: 2_100)
        state.setConnected(true, at: 2_699)
        XCTAssertTrue(state.isDue(at: 2_700))
    }

    func testOfflineCheckpointSurvivesRestartAndLegacySnapshotsStillDecode() throws {
        var state = TrainingPulseGuard()
        state.receive(at: 1_000)
        state.setConnected(false, at: 1_100)
        var restored = try JSONDecoder().decode(TrainingPulseGuard.self, from: JSONEncoder().encode(state.checkpoint))
        XCTAssertNil(restored.deadline)
        restored.setConnected(true, at: 30_000)
        XCTAssertEqual(restored.deadline, 30_600)
        let legacy = try JSONDecoder().decode(TrainingPulseGuard.self,
            from: Data("{\"lastSampleSec\":1000,\"recoveryAllowance\":30}".utf8))
        XCTAssertEqual(legacy.deadline, 1_630)
    }

    func testArmsOnlyAfterAReceiptAndUsesExactBoundary() {
        var guardState = TrainingPulseGuard()
        XCTAssertFalse(guardState.isDue(at: 10_000))
        guardState.receive(at: 1_000)
        XCTAssertFalse(guardState.isDue(at: 1_599))
        XCTAssertTrue(guardState.isDue(at: 1_600))
        // Equal heart rates still generate receipts; no displayed-value comparison is involved.
        guardState.receive(at: 1_500)
        XCTAssertFalse(guardState.isDue(at: 2_099))
        XCTAssertTrue(guardState.isDue(at: 2_100))
    }

    func testCorruptPersistedDeadlineCannotOverflow() throws {
        let restored = try JSONDecoder().decode(TrainingPulseGuard.self,
            from: Data("{\"lastSampleSec\":9223372036854775807,\"recoveryAllowance\":9223372036854775807}".utf8))
        XCTAssertNil(restored.deadline)
        XCTAssertFalse(restored.isDue(at: 1_000))
        XCTAssertNil(TrainingPulseGuard(lastSampleSec: Int.max - 600).deadline)
    }

    func testResumeAndCheckpointAvoidPrematurePause() throws {
        var guardState = TrainingPulseGuard()
        guardState.resume(at: 500)
        XCTAssertNil(guardState.deadline)
        guardState.receive(at: 1_000)
        let restored = try JSONDecoder().decode(TrainingPulseGuard.self, from: JSONEncoder().encode(guardState.checkpoint))
        XCTAssertFalse(restored.isDue(at: 1_629))
        XCTAssertTrue(restored.isDue(at: 1_630))
        guardState.resume(at: 1_900)
        XCTAssertEqual(guardState.deadline, 2_500)
    }

    func testLiftPauseFreezesRestAndSaveExcludesThePause() {
        var engine = LiftSessionEngine(plan: [.init(exercise: "Row", targetSets: 2, restSec: 90)], startTs: 1_000)
        engine.advance(now: 1_010)
        engine.advance(now: 1_030)
        engine.pause(now: 1_050)
        engine.pause(now: 1_100)
        XCTAssertEqual(engine.restRemaining(now: 2_000), 70)
        XCTAssertEqual(engine.elapsed(now: 2_000), 50)
        let savedSets = engine.sets
        engine.advance(now: 2_000)
        XCTAssertEqual(engine.sets, savedSets)
        engine.resume(now: 1_150)
        XCTAssertEqual(engine.restRemaining(now: 1_150), 70)
        engine.finish(now: 1_180)
        XCTAssertEqual(engine.sets[0].restSec, 50)
        XCTAssertEqual(engine.sets[0].startTs, 1_010)
        XCTAssertEqual(engine.sets[0].endTs, 1_030)
        XCTAssertEqual(engine.elapsed(now: 1_180), 80)
    }

    func testFinishingDuringPauseNeverInventsASetOrRestTime() {
        var engine = LiftSessionEngine(plan: [.init(exercise: "Row", targetSets: 2, restSec: 90)], startTs: 1_000)
        engine.advance(now: 1_010)
        engine.advance(now: 1_030)
        engine.pause(now: 1_050)
        engine.finish(now: 3_000)
        XCTAssertEqual(engine.sets.count, 1)
        XCTAssertEqual(engine.sets[0].restSec, 20)
        XCTAssertEqual(engine.elapsed(now: 3_000), 50)
    }

    func testLiftPauseSnapshotRoundTripAndUndo() throws {
        var engine = LiftSessionEngine(plan: [.init(exercise: "Row", targetSets: 2, restSec: 90)], startTs: 1_700_000_000)
        engine.advance(now: 1_700_000_010)
        engine.pause(now: 1_700_000_020)
        let snapshot = LiftSessionPersistence.snapshot(engine: engine, programId: nil, programName: nil, pendingValues: [:], pendingWarmups: [])
        let decoded = try XCTUnwrap(LiftSessionPersistence.decode(LiftSessionPersistence.encode(snapshot)))
        var restored = LiftSessionPersistence.engine(from: decoded)
        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.stageElapsed(now: 1_700_001_000), 10)
        restored.resume(now: 1_700_000_120)
        restored.advance(now: 1_700_000_130)
        restored.undo()
        XCTAssertEqual(restored.stageElapsed(now: 1_700_000_140), 30)
    }
}
