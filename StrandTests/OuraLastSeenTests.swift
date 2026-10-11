import Combine
import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class OuraLastSeenTests: XCTestCase {
    func testAuthenticatedSessionsRefreshOnlyTheObservedRing() async throws {
        let store = try await WhoopStore.inMemory()
        let registryStore = DeviceRegistryStore(dbQueue: store.registryWriter)
        for id in ["oura-observed", "oura-other"] {
            try registryStore.add(PairedDevice(id: id, brand: "Oura", model: "Oura Ring 3",
                sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        }
        let registry = DeviceRegistry(store: registryStore)
        let phases = PassthroughSubject<OuraLiveSource.LinkPhase, Never>()
        var clock = 100
        let subscription = SourceCoordinator.ouraSightings(phases.eraseToAnyPublisher())
            .sink { _ in registry.touchLastSeen("oura-observed", at: clock) }
        func seen(_ id: String) throws -> Int {
            try XCTUnwrap(registryStore.all().first { $0.id == id }).lastSeenAt
        }

        // A failed connection reaches authentication but supplies no successful ring reply.
        for phase in [OuraLiveSource.LinkPhase.connecting, .authenticating, .disconnected] {
            phases.send(phase)
        }
        XCTAssertEqual(try seen("oura-observed"), 1)
        phases.send(.authenticated)
        XCTAssertEqual(try seen("oura-observed"), 100)
        XCTAssertEqual(registry.devices.first { $0.id == "oura-observed" }?.lastSeenAt, 100)
        XCTAssertEqual(try seen("oura-other"), 1)

        clock = 200
        phases.send(.authenticated)
        XCTAssertEqual(try seen("oura-observed"), 100, "duplicate publication is not a new session")
        phases.send(.disconnected)
        phases.send(.authenticating)
        phases.send(.authenticated)
        XCTAssertEqual(try seen("oura-observed"), 200, "a reconnect refreshes even without new history")

        subscription.cancel()
        clock = 300
        phases.send(.disconnected)
        phases.send(.authenticated)
        XCTAssertEqual(try seen("oura-observed"), 200, "a torn-down source must no longer record sightings")
    }

    func testAlreadyAuthenticatedSourceIsSeenOnSubscription() {
        let phases = CurrentValueSubject<OuraLiveSource.LinkPhase, Never>(.authenticated)
        var sightings = 0
        let subscription = SourceCoordinator.ouraSightings(phases.eraseToAnyPublisher())
            .sink { _ in sightings += 1 }
        XCTAssertEqual(sightings, 1)
        withExtendedLifetime(subscription) {}
    }
}
