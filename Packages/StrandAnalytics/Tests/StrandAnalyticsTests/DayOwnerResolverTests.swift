import XCTest
@testable import StrandAnalytics

final class DayOwnerResolverTests: XCTestCase {
    func testActiveStrapOwnsDayItHasData() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: true),
            DayOwnerResolver.Candidate(deviceId: "oura", priority: 2, hasData: true),
        ]
        XCTAssertEqual(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: nil, candidates: candidates),
            "my-whoop"
        )
    }

    func testImportOnlyFillsGap() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: false),
            DayOwnerResolver.Candidate(deviceId: "oura", priority: 2, hasData: true),
        ]
        XCTAssertEqual(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: nil, candidates: candidates),
            "oura"
        )
    }

    func testLockedOwnerAlwaysWins() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: false),
            DayOwnerResolver.Candidate(deviceId: "oura", priority: 2, hasData: true),
        ]
        XCTAssertEqual(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: "my-whoop", candidates: candidates),
            "my-whoop"
        )
    }

    func testNoDataYieldsNil() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: false),
        ]
        XCTAssertNil(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: nil, candidates: candidates)
        )
    }

    /// #2880. Kotlin `DayOwnerResolverTest.sameStrapOwnerMostHrRowsWins` pins the same cases.
    func testSameStrapOwnerMostHrRowsWins() {
        func owner(_ active: Int, _ siblings: [(id: String, hrRows: Int)]) -> String {
            DayOwnerResolver.sameStrapOwner(activeId: "whoop-new", activeHrRows: active, siblings: siblings)
        }
        XCTAssertEqual(owner(234, [("my-whoop", 13_274)]), "my-whoop")   // the #2880 night
        XCTAssertEqual(owner(5_000, [("my-whoop", 300)]), "whoop-new")
        XCTAssertEqual(owner(100, [("my-whoop", 100)]), "whoop-new")     // tie keeps the active strap
        XCTAssertEqual(owner(10, [("a", 50), ("b", 50)]), "a")           // then the earlier sibling
        XCTAssertEqual(owner(0, []), "whoop-new")
    }
}
