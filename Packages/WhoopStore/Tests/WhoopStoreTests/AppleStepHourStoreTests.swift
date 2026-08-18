import XCTest
import GRDB
@testable import WhoopStore

final class AppleStepHourStoreTests: XCTestCase {
    func testUpsertIsIdempotentByNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        let n1 = try await store.upsertAppleStepHours([(ts: 1_000, steps: 120)], deviceId: "apple-health")
        XCTAssertEqual(n1, 1)

        // Re-import the same hour with a revised count → overwrite in place, still one row.
        let n2 = try await store.upsertAppleStepHours([(ts: 1_000, steps: 250)], deviceId: "apple-health")
        XCTAssertEqual(n2, 1)

        let rows = try await store.appleStepHours(deviceId: "apple-health", fromTs: 0, toTs: 10_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.ts, 1_000)
        XCTAssertEqual(rows.first?.steps, 250)
    }

    func testRangeReadReturnsOldestFirstWithinBoundsInclusive() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertAppleStepHours([
            (ts: 3_600, steps: 100),   // hour 1
            (ts: 7_200, steps: 200),   // hour 2
            (ts: 10_800, steps: 300),  // hour 3
        ], deviceId: "apple-health")

        // Inclusive bounds: both edges of the range are included.
        let rows = try await store.appleStepHours(deviceId: "apple-health", fromTs: 3_600, toTs: 10_800)
        XCTAssertEqual(rows.map(\.ts), [3_600, 7_200, 10_800])
        XCTAssertEqual(rows.map(\.steps), [100, 200, 300])

        // A narrower window excludes rows outside it.
        let narrow = try await store.appleStepHours(deviceId: "apple-health", fromTs: 3_601, toTs: 10_799)
        XCTAssertEqual(narrow.map(\.ts), [7_200])

        // A different device sees no rows.
        let other = try await store.appleStepHours(deviceId: "my-whoop", fromTs: 0, toTs: 100_000)
        XCTAssertTrue(other.isEmpty)
    }

    func testUpsertPartitionsByDevice() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertAppleStepHours([(ts: 1_000, steps: 50)], deviceId: "apple-health")
        _ = try await store.upsertAppleStepHours([(ts: 1_000, steps: 999)], deviceId: "other-device")

        let mine = try await store.appleStepHours(deviceId: "apple-health", fromTs: 0, toTs: 10_000)
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.steps, 50)

        let others = try await store.appleStepHours(deviceId: "other-device", fromTs: 0, toTs: 10_000)
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(others.first?.steps, 999)
    }
}
