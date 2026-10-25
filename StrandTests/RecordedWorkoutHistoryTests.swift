import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class RecordedWorkoutHistoryTests: XCTestCase {
    private func row(start: Int, sport: String = "Running", source: String = "manual", kcal: Double? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1_800, sport: sport, source: source,
                   durationS: 1_600, energyKcal: kcal, avgHr: nil, maxHr: nil, strain: strain,
                   distanceM: 4_000, zonesJSON: "kept", notes: "kept", steps: 2_000)
    }

    func testLedgerRoundTripIsIdempotentScopedAndExpiresWithoutDeletingWorkouts() throws {
        let suite = "test.recordedHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Int(Date().timeIntervalSince1970) - 2_000
        let workout = row(start: start)
        let pause = DateInterval(start: Date(timeIntervalSince1970: Double(start + 200)), duration: 200)
        RecordedWorkoutHistory.remember(workout, deviceId: "strap-a", pauses: [pause], into: defaults)
        RecordedWorkoutHistory.remember(workout, deviceId: "strap-a", pauses: [pause], into: defaults)
        let entry = try XCTUnwrap(RecordedWorkoutHistory.load(from: defaults).first)
        XCTAssertEqual(RecordedWorkoutHistory.load(from: defaults).count, 1)
        XCTAssertTrue(entry.matches(workout, deviceId: "strap-a"))
        XCTAssertFalse(entry.matches(workout, deviceId: "strap-b"))
        XCTAssertFalse(entry.matches(row(start: start, source: "whoop"), deviceId: "strap-a"))
        XCTAssertFalse(entry.matches(row(start: start, sport: "Strength"), deviceId: "strap-a"))
        XCTAssertTrue(RecordedWorkoutHistory.load(from: defaults, now: workout.endTs + RecordedWorkoutHistory.retentionSeconds + 1).isEmpty)
        XCTAssertEqual(workout.durationS, 1_600)
        let input = [199, 200, 399, 400, 401].map { HRSample(ts: start + $0, bpm: 140) }
        XCTAssertEqual(entry.activeSamples(input).map(\.ts), [start + 199, start + 200, start + 201])
    }

    func testSuccessiveSyncChunksEnrichRecordedSessionsAndPreserveManualEntries() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: RecordedWorkoutHistory.defaultsKey)
        defer {
            if let original { defaults.set(original, forKey: RecordedWorkoutHistory.defaultsKey) }
            else { defaults.removeObject(forKey: RecordedWorkoutHistory.defaultsKey) }
        }
        defaults.removeObject(forKey: RecordedWorkoutHistory.defaultsKey)
        let device = "test-history-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let store = try await WhoopStore(path: path)
        let repo = Repository(deviceId: device, store: store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "canonical-test")
        let profile = UserProfile(weightKg: 75, heightCm: 180, age: 30, sex: "male")
        let start = Int(Date().timeIntervalSince1970) - 3_600
        let recorded = row(start: start)
        let entered = row(start: start, sport: "Cycling", kcal: 300, strain: 5)
        _ = try await store.upsertWorkouts([recorded, entered], deviceId: device)
        RecordedWorkoutHistory.remember(recorded, deviceId: device, pauses: [])
        await engine.rescoreManualWorkouts(store: store, profile: profile, restingHR: 60)
        let emptyRows = try await store.workouts(deviceId: device, from: start, to: start + 1_800, limit: 10)
        XCTAssertEqual(emptyRows.first { $0.sport == "Running" }, recorded, "no HR must leave the session intact")
        _ = try await store.insert(Streams(hr: (0..<1_200).map { HRSample(ts: start + $0, bpm: 150) }), deviceId: device)
        try execute("CREATE TRIGGER fail_rescore BEFORE INSERT ON workout BEGIN SELECT RAISE(FAIL, 'test disk error'); END", path: path)
        await engine.rescoreManualWorkouts(store: store, profile: profile, restingHR: 60)
        try execute("DROP TRIGGER fail_rescore", path: path)
        await engine.rescoreManualWorkouts(store: store, profile: profile, restingHR: 60)
        let partialRows = try await store.workouts(deviceId: device, from: start, to: start + 1_800, limit: 10)
        let partial = try XCTUnwrap(partialRows.first { $0.sport == "Running" })
        XCTAssertGreaterThan(partial.energyKcal ?? 0, 5, "later chunks must remain eligible above the old 5 kcal threshold")
        XCTAssertNotNil(partial.strain)
        _ = try await store.insert(Streams(hr: (1_200...1_800).map { HRSample(ts: start + $0, bpm: 150) }), deviceId: device)
        await engine.rescoreManualWorkouts(store: store, profile: profile, restingHR: 60)
        let fullRows = try await store.workouts(deviceId: device, from: start, to: start + 1_800, limit: 10)
        let full = try XCTUnwrap(fullRows.first { $0.sport == "Running" })
        XCTAssertGreaterThan(full.energyKcal ?? 0, partial.energyKcal ?? 0)
        XCTAssertEqual(full.durationS, recorded.durationS)
        XCTAssertEqual(full.endTs, recorded.endTs)
        XCTAssertEqual(full.distanceM, 4_000)
        XCTAssertEqual(full.notes, "kept")
        XCTAssertEqual(full.zonesJSON, "kept")
        XCTAssertEqual(full.steps, 2_000)
        XCTAssertEqual(fullRows.first { $0.sport == "Cycling" }, entered)
        await engine.rescoreManualWorkouts(store: store, profile: profile, restingHR: 60)
        let unchanged = try await store.workouts(deviceId: device, from: start, to: start + 1_800, limit: 10)
        XCTAssertEqual(unchanged, fullRows)
        let override = row(start: start, kcal: 20, strain: full.strain)
        await repo.saveManualWorkout(override, replacing: full)
        XCTAssertFalse(RecordedWorkoutHistory.load().contains { $0.matches(full, deviceId: device) })
        await engine.rescoreManualWorkouts(store: store, profile: profile, restingHR: 60)
        let edited = try await store.workouts(deviceId: device, from: start, to: start + 1_800, limit: 10)
        XCTAssertEqual(edited.first { $0.sport == "Running" }, override, "explicit edits must survive subsequent scoring")
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
