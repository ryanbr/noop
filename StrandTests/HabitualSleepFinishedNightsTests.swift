import XCTest
import WhoopStore
@testable import Strand

/// The sleep habits every day is scored against are learned from finished nights only, so the night still
/// being synced cannot change them pass after pass and drop the whole day cache.
@MainActor
final class HabitualSleepFinishedNightsTests: XCTestCase {
    func testTonightsGrowingSessionIsNotLearnedFrom() async throws {
        let store = try await WhoopStore.inMemory()
        let midnight = 1_789_603_200   // 2026-09-17 00:00 UTC
        let nights = (1...5).map { back in
            CachedSleepSession(startTs: midnight - back * 86_400 + 3_600, endTs: midnight - back * 86_400 + 30_600,
                               efficiency: 0.9, restingHr: 55, avgHrv: 80, stagesJSON: nil)
        }
        _ = try await store.upsertSleepSessions(nights, deviceId: "my-whoop-noop")
        func learn() async -> (Int?, [Double]) {
            await IntelligenceEngine.computeHabitualSleep(
                store: store, importedId: "my-whoop", computedId: "my-whoop-noop",
                windowStart: midnight - 30 * 86_400, windowEnd: midnight + 86_400,
                finishedBefore: midnight, offsetSec: 0)
        }
        let before = await learn()

        // Tonight, first synced to 04:00, then again once it reached 09:30.
        for end in [midnight + 14_400, midnight + 34_200] {
            _ = try await store.upsertSleepSessions(
                [CachedSleepSession(startTs: midnight + 1_800, endTs: end, efficiency: 0.95, restingHr: 54,
                                    avgHrv: 85, stagesJSON: nil)], deviceId: "my-whoop-noop")
            let now = await learn()
            XCTAssertEqual(now.0, before.0)
            XCTAssertEqual(now.1, before.1)
        }
        XCTAssertEqual(before.1.count, 5)
    }
}
