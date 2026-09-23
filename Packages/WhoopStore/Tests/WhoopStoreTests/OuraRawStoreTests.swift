import XCTest
import GRDB
@testable import WhoopStore

final class OuraRawStoreTests: XCTestCase {
    func testUpsertIsIdempotentByNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        let first = OuraRawRow(endpoint: "sleep", documentId: "abc", day: "2026-01-01",
                               payloadJSON: #"{"id":"abc","v":1}"#, fetchedAt: 100)
        let n1 = try await store.upsertOuraRaw([first], deviceId: "oura-api")
        XCTAssertEqual(n1, 1)

        // Re-pull the same document id with a newer payload → overwrite in place, still one row.
        let second = OuraRawRow(endpoint: "sleep", documentId: "abc", day: "2026-01-01",
                                payloadJSON: #"{"id":"abc","v":2}"#, fetchedAt: 200)
        _ = try await store.upsertOuraRaw([second], deviceId: "oura-api")

        let rows = try await store.ouraRaw(deviceId: "oura-api", endpoint: "sleep")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.payloadJSON, #"{"id":"abc","v":2}"#)
        XCTAssertEqual(rows.first?.fetchedAt, 200)
        let sleepCount = try await store.ouraRawCount(deviceId: "oura-api", endpoint: "sleep")
        XCTAssertEqual(sleepCount, 1)
        // A different endpoint is a different partition.
        let dailySleepCount = try await store.ouraRawCount(deviceId: "oura-api", endpoint: "daily_sleep")
        XCTAssertEqual(dailySleepCount, 0)
    }

    func testReadOrdersPageArchivesByFetchedAtWhenDayIsNil() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertOuraRaw([
            OuraRawRow(endpoint: "sleep", documentId: "newest", day: nil,
                       payloadJSON: "{}", fetchedAt: 300),
            OuraRawRow(endpoint: "sleep", documentId: "oldest", day: nil,
                       payloadJSON: "{}", fetchedAt: 100),
            OuraRawRow(endpoint: "sleep", documentId: "middle", day: nil,
                       payloadJSON: "{}", fetchedAt: 200),
        ], deviceId: "oura-api")

        let rows = try await store.ouraRaw(deviceId: "oura-api", endpoint: "sleep")
        XCTAssertEqual(rows.map(\.documentId), ["oldest", "middle", "newest"])
        XCTAssertEqual(rows.map(\.fetchedAt), [100, 200, 300])
    }

    func testDeleteOuraRawRemovesAllForDevice() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertOuraRaw([
            OuraRawRow(endpoint: "sleep", documentId: "a", day: "2026-01-01", payloadJSON: "{}", fetchedAt: 1),
            OuraRawRow(endpoint: "workout", documentId: "b", day: "2026-01-01", payloadJSON: "{}", fetchedAt: 1),
        ], deviceId: "oura-api")
        let deleted = try await store.deleteOuraRaw(deviceId: "oura-api")
        XCTAssertEqual(deleted, 2)
        let remainingCount = try await store.ouraRawCount(deviceId: "oura-api", endpoint: "sleep")
        XCTAssertEqual(remainingCount, 0)
    }
}
