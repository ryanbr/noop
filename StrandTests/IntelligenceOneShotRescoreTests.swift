import XCTest
import WhoopStore
@testable import Strand

/// A one-shot full-history rescore must wait for a pass that holds the lock, not give up until next launch.
@MainActor
final class IntelligenceOneShotRescoreTests: XCTestCase {
    func testTheOneShotWaitsForARunningPassAndThenRunsItsOwn() async throws {
        let flagKey = "test.oneShotRescore.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: flagKey) }
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")

        engine.computing = true
        let oneShot = Task { await engine.runEffortRescoreIfNeeded(historyDays: 2, flagKey: flagKey) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: flagKey), "must not mark done while another pass holds the lock")
        engine.computing = false

        let ran = await oneShot.value
        XCTAssertTrue(ran)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
        let again = await engine.runEffortRescoreIfNeeded(historyDays: 2, flagKey: flagKey)
        XCTAssertFalse(again, "a done flag is a no-op")
    }
}
