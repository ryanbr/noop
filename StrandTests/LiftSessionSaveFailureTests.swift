import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class LiftSessionSaveFailureTests: XCTestCase {
    func testFailedWriteRetainsSessionAndRetryDoesNotDuplicateItsRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("training.sqlite").path
        let store = try await WhoopStore(path: path)
        let repo = Repository(deviceId: "training-test", store: store)
        let controller = LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
        defer {
            controller.discard()
        }
        controller.start(plan: [.init(exercise: "Row", targetSets: 2, restSec: 90)], programId: nil, programName: nil)
        controller.advance()
        controller.advance()
        controller.sessionRpeText = "7"
        let id = controller.sessionID
        let start = try XCTUnwrap(controller.engine?.startTs)
        try execute("CREATE TRIGGER fail_training_save BEFORE INSERT ON workout BEGIN SELECT RAISE(FAIL, 'test disk error'); END", path: path)
        do {
            _ = try await controller.save(repo: repo, completingUnfinished: false, sessionRpe: nil)
            XCTFail("the database rejected the workout write")
        } catch {}
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(controller.engine?.isPaused == true)
        XCTAssertEqual(LiftSessionPersistence.load()?.sessionID, id)
        let partiallySaved = try await store.liftSets(sessionId: id)
        XCTAssertEqual(partiallySaved.count, 2)
        XCTAssertEqual(partiallySaved.filter { $0.startTs != nil }.count, 1)
        XCTAssertTrue(controller.removeSet(fromExercise: 0))
        try execute("DROP TRIGGER fail_training_save", path: path)
        _ = try await controller.save(repo: repo, completingUnfinished: false, sessionRpe: nil)
        _ = try await controller.save(repo: repo, completingUnfinished: false, sessionRpe: nil)
        let sessions = try await store.liftSessions(deviceId: "training-test", fromTs: start, toTs: start)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, id)
        XCTAssertEqual(sessions.first?.sessionRpe, 7)
        let sets = try await store.liftSets(sessionId: id)
        XCTAssertEqual(sets.count, 1, "a pending set removed after a failed save must not remain in storage")
        XCTAssertEqual(sets.filter { $0.startTs != nil }.count, 1, "an open set is never invented as completed")
        controller.finishedSaving()
        XCTAssertNil(controller.engine)
        XCTAssertNil(LiftSessionPersistence.load())
    }
    // Use macOS's SQLite CLI: GRDB is linked in the host app, not directly in the test bundle.
    private func execute(_ sql: String, path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

}
