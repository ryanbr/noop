import XCTest
import GRDB
@testable import WhoopStore

final class ScaffoldTests: XCTestCase {
    func testGRDBIsLinkedAndUsable() throws {
        // Proves the GRDB dependency resolved and a DB can be opened.
        let queue = try DatabaseQueue()
        let answer = try queue.read { db in try Int.fetchOne(db, sql: "SELECT 42") }
        XCTAssertEqual(answer, 42)
    }

    func testLibraryVersionMarkerPresent() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 10)
    }
}
