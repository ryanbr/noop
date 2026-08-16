import XCTest
@testable import Strand

/// Proximity ordering + dedup of the standard-HR discovery list (`StandardHRSource.upsertByProximity`):
/// strongest RSSI first, and the same peripheral updates in place. Pure — no CoreBluetooth. Twin of the
/// Kotlin `StandardHrProximityTest`.
final class StandardHRProximityTests: XCTestCase {

    private func strap(_ id: UUID, _ rssi: Int) -> StandardHRSource.DiscoveredStrap {
        StandardHRSource.DiscoveredStrap(id: id, name: "s", rssi: rssi)
    }

    func testSortsByProximityStrongestFirst() {
        let a = UUID(), b = UUID(), c = UUID()
        var list: [StandardHRSource.DiscoveredStrap] = []
        list = StandardHRSource.upsertByProximity(list, strap(a, -80))
        list = StandardHRSource.upsertByProximity(list, strap(b, -50))
        list = StandardHRSource.upsertByProximity(list, strap(c, -65))
        XCTAssertEqual(list.map(\.id), [b, c, a])   // -50 > -65 > -80 → closest first
    }

    func testSamePeripheralUpdatesInPlaceWithNewestRssiAndReorders() {
        let a = UUID(), b = UUID()
        var list: [StandardHRSource.DiscoveredStrap] = []
        list = StandardHRSource.upsertByProximity(list, strap(a, -80))
        list = StandardHRSource.upsertByProximity(list, strap(b, -60))
        list = StandardHRSource.upsertByProximity(list, strap(a, -40))   // A re-seen, now closer
        XCTAssertEqual(list.count, 2)                                    // updated in place, no duplicate
        XCTAssertEqual(list.map(\.id), [a, b])                           // A jumps ahead of B
        XCTAssertEqual(list.first(where: { $0.id == a })?.rssi, -40)     // newest RSSI kept
    }
}
