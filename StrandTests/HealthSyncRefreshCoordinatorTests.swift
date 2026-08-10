import XCTest
@testable import Strand

@MainActor
final class HealthSyncRefreshCoordinatorTests: XCTestCase {
    func testRefrescaElRepositorioDespuesDeSincronizarHealthKit() async {
        var eventos: [String] = []

        await HealthSyncRefreshCoordinator.run(
            sync: { eventos.append("sync") },
            refresh: { eventos.append("refresh") }
        )

        XCTAssertEqual(eventos, ["sync", "refresh"])
    }
}
