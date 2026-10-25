import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

@MainActor
final class WorkoutSampleProcessingTests: XCTestCase {
    func testCoalescingRetainsEverySampleAndMatchesTheOriginalStats() async {
        await withModel { model in
            var expected: [HRSample] = []
            for second in 0..<650 {
                let sample = HRSample(ts: 1_700_000_000 + second + (second / 120) * 45,
                                      bpm: second < 200 ? 150 : 110 + second % 65)
                expected.append(sample)
                model.bpm = sample.bpm
                let date = Date(timeIntervalSince1970: Double(sample.ts))
                model.captureWorkoutSample(at: date)
                model.bpm = sample.bpm + 5
                model.captureWorkoutSample(at: date)
            }
            await model.workoutSampleTask?.value
            let workout = model.activeWorkout
            XCTAssertEqual(workout?.samples, expected)
            XCTAssertEqual(workout?.avgHr, Int((Double(expected.map(\.bpm).reduce(0, +)) / Double(expected.count)).rounded()))
            XCTAssertEqual(workout?.peakHr, expected.map(\.bpm).max()! + 5)
            XCTAssertEqual(workout?.liveStrain, StrainScorer.strain(expected,
                maxHR: Double(model.profile.hrMax), method: PuffinExperiment.effortMethod, sex: model.profile.sex) ?? 0)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), workout?.snapshot)
            XCTAssertNil(model.workoutSampleTask)
        }
    }

    func testWorkerPreservesBothEffortMethodsAndTheSnapshot() async {
        await withModel { model in
            for method in [StrainScorer.Method.edwards, .banister] {
                for sex in ["male", "female"] {
                    let samples = (0..<650).map { HRSample(ts: 1_700_000_000 + $0 * 2, bpm: 110 + $0 % 65) }
                    var workout = model.activeWorkout!
                    workout.samples = samples
                    workout.avgHr = Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
                    workout.peakHr = 185
                    workout.completedPauses = [DateInterval(start: workout.start, duration: 20)]
                    let work = AppModel.WorkoutSampleWork(revision: 1, snapshot: workout.snapshot,
                                                        hrMax: 190, method: method, sex: sex)
                    let result = work.process()
                    let expected = StrainScorer.strain(samples, maxHR: 190, method: method, sex: sex) ?? 0
                    XCTAssertEqual(result.strain, expected)
                    var snapshot = workout.snapshot
                    snapshot.liveStrain = expected
                    XCTAssertEqual(ActiveWorkoutPersistence.decode(result.data), snapshot)
                }
            }
        }
    }

    func testLateResultCannotUndoPause() async {
        await withModel { model in
            let work = captureWork(model)
            let result = work.process()
            model.pauseWorkout(at: Date(timeIntervalSince1970: 1_700_000_601))
            model.applyWorkoutSample(work, result: result)
            await model.workoutSampleTask?.value
            XCTAssertTrue(model.activeWorkout?.isPaused == true)
            XCTAssertEqual(model.activeWorkout?.liveStrain, 12)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), model.activeWorkout?.snapshot)
        }
    }

    func testLateSampleResultCannotOverwriteANewerWindow() async {
        await withModel { model in
            model.persistActiveWorkout()
            let checkpoint = ActiveWorkoutPersistence.load()
            let work = captureWork(model)
            let result = work.process()
            model.bpm = 160
            model.captureWorkoutSample(at: Date(timeIntervalSince1970: 1_700_000_601))
            model.applyWorkoutSample(work, result: result)
            XCTAssertEqual(model.activeWorkout?.samples.count, 602)
            XCTAssertEqual(model.activeWorkout?.liveStrain, 12)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), checkpoint)
            await model.workoutSampleTask?.value
            XCTAssertEqual(ActiveWorkoutPersistence.load(), model.activeWorkout?.snapshot)
        }
    }

    func testLateResultCannotCrossResumeAndTheNextSampleStillIncludesTheFullWindow() async {
        await withModel { model in
            let work = captureWork(model)
            let result = work.process()
            model.pauseWorkout(at: Date(timeIntervalSince1970: 1_700_000_601))
            model.resumeWorkout(at: Date(timeIntervalSince1970: 1_700_000_631))
            model.applyWorkoutSample(work, result: result)
            XCTAssertEqual(model.activeWorkout?.liveStrain, 12)
            XCTAssertFalse(model.activeWorkout?.isPaused == true)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), model.activeWorkout?.snapshot)
            model.captureWorkoutSample(at: Date(timeIntervalSince1970: 1_700_000_632))
            await model.workoutSampleTask?.value
            XCTAssertEqual(model.activeWorkout?.samples.count, 602)
            XCTAssertEqual(model.activeWorkout?.pausedDuration, 30)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), model.activeWorkout?.snapshot)
        }
    }

    func testLateResultCannotReplaceANewSession() async {
        await withModel { model in
            let work = captureWork(model)
            let result = work.process()
            model.discardWorkout()
            model.startWorkout(sport: "Strength")
            let id = model.activeWorkout?.sessionID
            model.applyWorkoutSample(work, result: result)
            await model.workoutSampleTask?.value
            XCTAssertNotEqual(id, work.snapshot.sessionID)
            XCTAssertEqual(model.activeWorkout?.sessionID, id)
            XCTAssertEqual(model.activeWorkout?.samples.count, 0)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), model.activeWorkout?.snapshot)
        }
    }

    func testLateResultCannotResurrectAFinishedSession() async {
        await withModel { model in
            model.activeWorkout = AppModel.ActiveWorkout(start: Date())
            let work = captureWork(model)
            let result = work.process()
            do { try await model.finishWorkout() } catch { XCTFail("\(error)") }
            model.applyWorkoutSample(work, result: result)
            await model.workoutSampleTask?.value
            XCTAssertNil(model.activeWorkout)
            XCTAssertNil(ActiveWorkoutPersistence.load())
        }
    }

    func testCheckpointBanksTheLatestWindowAndRejectsAnOlderResult() async {
        await withModel { model in
            let work = captureWork(model)
            let result = work.process()
            model.persistActiveWorkout()
            XCTAssertEqual(ActiveWorkoutPersistence.load()?.samples.count, 601)
            model.applyWorkoutSample(work, result: result)
            await model.workoutSampleTask?.value
            XCTAssertEqual(model.activeWorkout?.liveStrain, 12)
            XCTAssertEqual(ActiveWorkoutPersistence.load(), model.activeWorkout?.snapshot)
            let restored = AppModel()
            XCTAssertEqual(restored.activeWorkout?.snapshot, model.activeWorkout?.snapshot)
        }
    }

    private func captureWork(_ model: AppModel) -> AppModel.WorkoutSampleWork {
        var workout = model.activeWorkout!
        workout.samples = (0..<600).map { HRSample(ts: 1_700_000_000 + $0, bpm: 150) }
        workout.avgHr = 150
        workout.peakHr = 150
        workout.liveStrain = 12
        model.activeWorkout = workout
        model.bpm = 150
        model.captureWorkoutSample(at: Date(timeIntervalSince1970: 1_700_000_600))
        return AppModel.WorkoutSampleWork(revision: model.workoutSampleRevision,
            snapshot: model.activeWorkout!.snapshot, hrMax: Double(model.profile.hrMax),
            method: PuffinExperiment.effortMethod, sex: model.profile.sex)
    }

    private func withModel(_ check: (AppModel) async -> Void) async {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: ActiveWorkoutPersistence.defaultsKey)
        let previousModel = AppModel.shared
        defer {
            AppModel.shared = previousModel
            if let original { defaults.set(original, forKey: ActiveWorkoutPersistence.defaultsKey) }
            else { defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey) }
        }
        let model = AppModel()
        model.activeWorkout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 1_700_000_000))
        await check(model)
        await model.workoutSampleTask?.value
    }
}
