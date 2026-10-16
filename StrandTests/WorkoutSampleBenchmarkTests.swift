import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

@MainActor
final class WorkoutSampleBenchmarkTests: XCTestCase {
    func testReleaseBenchmark() async throws {
        guard !_isDebugAssertConfiguration() else { throw XCTSkip("Run this benchmark in Release.") }
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: ActiveWorkoutPersistence.defaultsKey)
        let previousModel = AppModel.shared
        defer {
            AppModel.shared = previousModel
            if let original { defaults.set(original, forKey: ActiveWorkoutPersistence.defaultsKey) }
            else { defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey) }
        }
        let model = AppModel()
        model.bpm = 150
        for count in [0, 600, 3_600, 7_200] {
            let start = 1_700_000_000
            let seed = (0..<count).map { HRSample(ts: start + $0, bpm: 110 + $0 % 65) }
            var scoreTimes: [Double] = [], encodeTimes: [Double] = [], captureTimes: [Double] = []
            var mergeTimes: [Double] = [], mainTimes: [Double] = []
            for trial in 0..<106 {
                var samples = seed
                // Every nonempty scoring call has a new fingerprint, as the live window does.
                if count > 0 { samples[count - 1] = HRSample(ts: start + count + trial, bpm: 150) }
                var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: Double(start)))
                workout.samples = samples
                workout.sessionID = "synthetic-benchmark"
                let (score, scoringMs) = timed {
                    StrainScorer.strain(samples, maxHR: Double(model.profile.hrMax),
                                       method: PuffinExperiment.effortMethod, sex: model.profile.sex) ?? 0
                }
                workout.liveStrain = score
                let snapshot = ActiveWorkoutPersistence.Snapshot(
                    startSec: start, sport: workout.sport, samples: samples,
                    avgHr: workout.avgHr, peakHr: workout.peakHr, liveStrain: score,
                    pausedDurationSec: 0, sessionID: workout.sessionID,
                    pausedForPulseLoss: false, completedPauses: [])
                let (data, encodingMs) = timed { ActiveWorkoutPersistence.encode(snapshot) }
                XCTAssertNotNil(data)
                model.activeWorkout = workout
                let date = Date(timeIntervalSince1970: Double(start + count + trial + 1))
                let (_, captureMs) = timed { model.captureWorkoutSample(at: date) }
                let work = AppModel.WorkoutSampleWork(revision: model.workoutSampleRevision,
                    snapshot: model.activeWorkout!.snapshot, hrMax: Double(model.profile.hrMax),
                    method: PuffinExperiment.effortMethod, sex: model.profile.sex)
                let result = work.process()
                let (_, mergeMs) = timed { model.applyWorkoutSample(work, result: result) }
                await model.workoutSampleTask?.value
                XCTAssertEqual(model.activeWorkout?.samples.count, count + 1)
                if trial >= 5 {
                    scoreTimes.append(scoringMs)
                    encodeTimes.append(encodingMs)
                    captureTimes.append(captureMs)
                    mergeTimes.append(mergeMs)
                    mainTimes.append(captureMs + mergeMs)
                }
            }
            print("WORKOUT_BENCHMARK samples=\(count) score=\(summary(scoreTimes)) encode=\(summary(encodeTimes)) capture=\(summary(captureTimes)) merge=\(summary(mergeTimes)) main=\(summary(mainTimes))")
            if count == 7_200 {
                XCTAssertLessThan(mainTimes.sorted()[Int(ceil(Double(mainTimes.count) * 0.95)) - 1], 2,
                                  "Remaining capture + result merge must stay under 2 ms p95.")
            }
        }
    }

    private func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = ObjectiveC.autoreleasepool(invoking: body)
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func summary(_ times: [Double]) -> String {
        let sorted = times.sorted()
        return String(format: "%.4f/%.4f", sorted[sorted.count / 2], sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1])
    }
}
