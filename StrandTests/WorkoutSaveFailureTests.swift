import XCTest
import WhoopStore
import WhoopProtocol
@testable import Strand

@MainActor
final class WorkoutSaveFailureTests: XCTestCase {
    func testFailedWriteKeepsRecordedWorkoutRetryable() async throws {
        let defaults = UserDefaults.standard
        let keys = [ActiveWorkoutPersistence.defaultsKey]
        let originals = keys.map { ($0, defaults.object(forKey: $0)) }
        let previousModel = AppModel.shared
        defer {
            AppModel.shared = previousModel
            for (key, original) in originals {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("workout.sqlite").path
        let store = try await WhoopStore(path: path)
        let model = AppModel()
        model.repo.setStoreForTesting(store)
        let started = Date().addingTimeInterval(-600)
        model.activeWorkout = AppModel.ActiveWorkout(start: started, sport: "Strength")
        model.activeWorkout?.samples = [HRSample(ts: Int(started.timeIntervalSince1970), bpm: 140),
                                        HRSample(ts: Int(started.timeIntervalSince1970) + 120, bpm: 140)]
        let id = try XCTUnwrap(model.activeWorkout?.sessionID)
        try execute("CREATE TRIGGER fail_workout_save BEFORE INSERT ON workout BEGIN SELECT RAISE(FAIL, 'test disk error'); END", path: path)
        do { try await model.finishWorkout(); XCTFail("the write should fail") } catch {}
        XCTAssertEqual(model.activeWorkout?.sessionID, id)
        XCTAssertTrue(model.activeWorkout?.isPaused == true)
        XCTAssertEqual(ActiveWorkoutPersistence.load()?.sessionID, id)
        try execute("DROP TRIGGER fail_workout_save", path: path)
        try await model.finishWorkout()
        try await model.finishWorkout()
        XCTAssertNil(model.activeWorkout)
        XCTAssertNil(ActiveWorkoutPersistence.load())
        let rows = try await store.workouts(deviceId: model.deviceId, from: Int(started.timeIntervalSince1970),
                                            to: Int(Date().timeIntervalSince1970), limit: 10)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sport, "Strength")
        XCTAssertEqual(row.durationS ?? 0, 600, accuracy: 2)
        XCTAssertEqual(row.avgHr, 140)
    }

    private func execute(_ sql: String, path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
