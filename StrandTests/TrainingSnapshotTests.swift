import XCTest
@testable import Strand

final class TrainingSnapshotTests: XCTestCase {
    func testSnapshotEqualityIgnoresEncodingOrderButKeepsVisibleActionChanges() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let training = TrainingDisplay(id: "run", kind: "workout", title: "Run", clockStart: now)
        let snapshot = TrainingSnapshot(favorites: TrainingFavorite.defaults, sessions: [training],
                                        labels: ["pause": "Pause", "resume": "Resume"])
        var copy = try JSONDecoder().decode(TrainingSnapshot.self, from: JSONEncoder().encode(snapshot))
        copy.labels = ["resume": "Resume", "pause": "Pause"]
        XCTAssertEqual(snapshot, copy)
        copy.sessions[0].pausedAt = now.addingTimeInterval(10)
        XCTAssertNotEqual(snapshot, copy)
        copy = snapshot
        copy.sessions[0].confirmationToken = "new"
        copy.sessions[0].confirmationUntil = now.addingTimeInterval(30)
        XCTAssertNotEqual(snapshot, copy)
        copy = snapshot
        copy.sessions[0].error = "Save failed"
        XCTAssertNotEqual(snapshot, copy)
        copy = snapshot
        copy.favorites[0].name = "New favorite"
        XCTAssertNotEqual(snapshot, copy)
        copy = snapshot
        copy.labels["pause"] = "Pause training"
        XCTAssertNotEqual(snapshot, copy)
    }

    @MainActor
    func testFavoriteConfigurationWaitsForLaunchGatesAndIsConsumedOnce() {
        let router = NavRouter()
        router.openTrainingFavorites()
        XCTAssertFalse(router.consumeTrainingFavoritesRequest(isReady: false))
        XCTAssertEqual(router.requestedDestination, .trainingFavorites)
        XCTAssertTrue(router.consumeTrainingFavoritesRequest(isReady: true))
        XCTAssertNil(router.requestedDestination)
        XCTAssertFalse(router.consumeTrainingFavoritesRequest(isReady: true))
        router.openDevices()
        XCTAssertFalse(router.consumeTrainingFavoritesRequest(isReady: true))
        XCTAssertEqual(router.requestedDestination, .devices)
    }

    func testWorkoutIconKeepsRawSportAndReadsOlderSnapshots() throws {
        let old = Data(#"{"id":"run","kind":"workout","title":"Laufen","clockStart":0}"#.utf8)
        var display = try JSONDecoder().decode(TrainingDisplay.self, from: old)
        XCTAssertNil(display.sport)
        display.sport = "Running"
        let restored = try JSONDecoder().decode(TrainingDisplay.self, from: JSONEncoder().encode(display))
        XCTAssertEqual(restored.sport, "Running")
        XCTAssertEqual(restored.title, "Laufen")
    }

    func testEndConfirmationIsBoundToTheSessionTokenAndThirtySeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let confirmation = TrainingEndConfirmation(sessionID: "first", now: now)
        XCTAssertTrue(confirmation.accepts(sessionID: "first", token: confirmation.token, now: now.addingTimeInterval(29)))
        XCTAssertFalse(confirmation.accepts(sessionID: "second", token: confirmation.token, now: now))
        XCTAssertFalse(confirmation.accepts(sessionID: "first", token: "old", now: now))
        XCTAssertFalse(confirmation.accepts(sessionID: "first", token: confirmation.token, now: now.addingTimeInterval(30)))
    }

    func testConfirmationSurvivesRestartButExpiredAndFutureSnapshotsDoNot() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let confirmation = TrainingEndConfirmation(sessionID: "first", now: now)
        var display = TrainingDisplay(id: "first", kind: "workout", title: "Run", clockStart: now,
                                      confirmationUntil: confirmation.until, confirmationToken: confirmation.token)
        display = try JSONDecoder().decode(TrainingDisplay.self, from: JSONEncoder().encode(display))
        let restored = try XCTUnwrap(TrainingEndConfirmation(restoring: display, now: now.addingTimeInterval(15)))
        XCTAssertTrue(restored.accepts(sessionID: "first", token: confirmation.token, now: now.addingTimeInterval(29)))
        XCTAssertNil(TrainingEndConfirmation(restoring: display, now: now.addingTimeInterval(30)))
        display.confirmationUntil = now.addingTimeInterval(100)
        XCTAssertNil(TrainingEndConfirmation(restoring: display, now: now))
    }

    func testThreeFavoritesRoundTripAndRejectCorruptSlots() throws {
        let suite = "training-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var favorites = TrainingFavorite.load(from: defaults)
        XCTAssertEqual(favorites.count, 3)
        XCTAssertEqual(favorites[0].sport, "Strength")
        XCTAssertEqual(favorites[1].sport, "Running")
        XCTAssertNil(favorites[2].sport)
        favorites[2] = .init(id: 2, name: "Upper A", programID: "p")
        TrainingFavorite.save(favorites, into: defaults)
        XCTAssertEqual(TrainingFavorite.load(from: defaults), favorites)
        TrainingFavorite.save(Array(favorites.prefix(2)), into: defaults)
        XCTAssertEqual(TrainingFavorite.load(from: defaults), favorites)
        defaults.set(Data("[{\"id\":999,\"name\":\"x\"}]".utf8), forKey: TrainingFavorite.storageKey)
        XCTAssertEqual(TrainingFavorite.load(from: defaults), TrainingFavorite.defaults)
    }
}
