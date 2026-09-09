import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Invariant I2 — a day's scores come from exactly ONE source. This proves the wired read path end to
/// end: two devices have HR for the SAME UTC day, the resolver picks the owner (the active strap wins
/// over an import), and reading the owner's HR returns ONLY the owner's samples — never the other
/// device's. Mirrors `IntelligenceEngine.resolveDayOwner` + the per-day stream read it feeds.
final class DayOwnerReadIntegrationTests: XCTestCase {

    /// 2026-06-15 00:00:00 UTC. The night window the engine reads spans [dayStart-30h, dayStart+12h];
    /// we seed HR squarely inside it (a few hours past midnight) under each device.
    private let dayStart = 1_781_481_600          // 2026-06-15 00:00:00 UTC
    private let day = "2026-06-15"

    /// Build candidates exactly as `IntelligenceEngine.resolveDayOwner` does, then resolve.
    ///
    /// This mirrors the SHIPPED shape, which is the only thing that makes an integration test worth
    /// having: probe in (priority, original index) order and stop at the first candidate with data,
    /// using the scalar `hasHrInWindow` presence check rather than fetching a row from the union read.
    /// It used to build every candidate and hand the lot to `DayOwnerResolver.resolve`, which is what
    /// production did before; left alone it would still have passed while quietly testing a path
    /// nothing takes any more.
    private func resolveOwner(store: WhoopStore, registry: DeviceRegistryStore,
                              from: Int, to: Int) async throws -> String? {
        if let locked = try registry.dayOwner(day)?.deviceId { return locked }
        let activeId = try registry.activeDeviceId() ?? "my-whoop"
        let ranked: [(id: String, priority: Int)] = try registry.all()
            .filter { $0.status != .archived }
            .map { d in
                let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
                // Mirrors IntelligenceEngine.resolveDayOwner: activity-file rides rank BELOW whole-day
                // imports.
                let priority: Int
                if d.id == activeId { priority = 0 }
                else if d.sourceKind == .activityFile { priority = 3 }
                else if isImport { priority = 2 }
                else { priority = 1 }
                return (d.id, priority)
            }
            .enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)
        for c in ranked {
            if (try? await store.hasHrInWindow(deviceId: c.id, from: from, to: to)) == true { return c.id }
        }
        return nil
    }

    func testActiveStrapOwnsDayAndReadReturnsOnlyItsSamples() async throws {
        let store = try await WhoopStore.inMemory()    // migration v15 seeds active 'my-whoop'
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        // A second source: an Oura CLOUD IMPORT (priority 2), paired but not active.
        try registry.add(PairedDevice(id: "oura-import", brand: "Oura", model: "Oura (import)",
                                      sourceKind: .cloudImport, capabilities: [.hr, .sleep],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))

        // Seed HR for BOTH devices on the SAME UTC day, with distinguishable bpm so the read's source
        // is unambiguous: WHOOP @ 55 bpm, Oura @ 99 bpm, both a few hours after midnight.
        let base = dayStart + 3 * 3_600
        let whoopHR = (0..<300).map { HRSample(ts: base + $0, bpm: 55) }
        let ouraHR  = (0..<300).map { HRSample(ts: base + $0, bpm: 99) }
        _ = try await store.insert(Streams(hr: whoopHR), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: ouraHR),  deviceId: "oura-import")

        let from = dayStart - 30 * 3_600
        let to = dayStart + 12 * 3_600

        // I2 resolution: the active strap (priority 0) wins over the import (priority 2).
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "my-whoop", "the active strap must own a day it has data for")

        // Read the day's HR under the resolved owner — it must be PURELY the owner's samples.
        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertEqual(read.count, whoopHR.count)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 55 }, "owner read leaked the other device's samples")
        XCTAssertFalse(read.contains { $0.bpm == 99 }, "Oura (non-owner) samples must never appear")
    }

    /// A locked dayOwnership override beats priority: even though the active WHOOP has data, a lock to
    /// the import makes the import own the day, and the read returns only the import's samples.
    func testLockedOwnerOverridesAndReadFollowsIt() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "oura-import", brand: "Oura", model: "Oura (import)",
                                      sourceKind: .cloudImport, capabilities: [.hr],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))

        let base = dayStart + 3 * 3_600
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 55) }), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 99) }), deviceId: "oura-import")

        try registry.setDayOwner(day: day, deviceId: "oura-import", locked: true)

        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "oura-import", "a locked override must win over the active strap")

        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 99 }, "read must follow the locked owner")
    }

    /// #137 (B1): on a STRAP-LESS day — the active WHOOP collected NO HR — an imported activity file's
    /// HR (source "activity-file", an `.activityFile` device) makes it the day owner, so `dayHr` reads the
    /// ride's HR and the day Effort ring can light. This is the whole point of registering `activity-file`
    /// as a candidate: with the strap absent it's the only source with data, so priority-3 still wins (an
    /// owner is the lowest-priority candidate that HAS data, not merely the lowest priority).
    /// On a day the strap DID collect HR, the strap (priority 0) would win instead — proven by the first
    /// test above — so imported HR only ever surfaces where there's no strap data to override it.
    func testActivityFileOwnsStrapLessDayAndReadReturnsItsHR() async throws {
        let store = try await WhoopStore.inMemory()    // migration v15 seeds active 'my-whoop' (no data yet)
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        // The activity-file import device, exactly as DataSourcesView registers it (#137 B1).
        try registry.add(PairedDevice(id: "activity-file", brand: "Workout files", model: "",
                                      sourceKind: .activityFile, capabilities: [.hr],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))

        // ONLY the imported ride has HR this day; the active strap has none (strap-less day).
        let base = dayStart + 3 * 3_600
        let rideHR = (0..<300).map { HRSample(ts: base + $0, bpm: 132) }
        _ = try await store.insert(Streams(hr: rideHR), deviceId: "activity-file")

        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "activity-file",
                       "with no strap HR, the imported file (priority 3, has data) must own the day")

        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertEqual(read.count, rideHR.count)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 132 }, "the day read must return the imported ride's HR")
    }

    /// #137 tie-break: on a strap-less day where BOTH a whole-day WHOOP import (priority 2) and an
    /// activity-file ride (priority 3) have HR, the whole-day import must OWN the day — a 90-minute ride
    /// can never displace a full-day source. This is why `activity-file` is a distinct `.activityFile`
    /// kind ranked below `.fileImport`/`.cloudImport`, rather than sharing priority 2 where a stable-sort
    /// tie would let array order decide.
    func testWholeDayImportBeatsActivityFileRideOnStrapLessDay() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        // A whole-day WHOOP CSV import (priority 2) and the ride (priority 3), both paired, neither active.
        try registry.add(PairedDevice(id: "whoop-import", brand: "WHOOP", model: "WHOOP (import)",
                                      sourceKind: .fileImport, capabilities: [.hr],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: "activity-file", brand: "Workout files", model: "",
                                      sourceKind: .activityFile, capabilities: [.hr],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))

        // Both sources carry HR for the SAME strap-less day, distinguishable by bpm.
        let base = dayStart + 3 * 3_600
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 132) }),
                                   deviceId: "activity-file")
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + 3_600 + $0, bpm: 58) }),
                                   deviceId: "whoop-import")

        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "whoop-import",
                       "a whole-day import (priority 2) must beat the activity-file ride (priority 3)")

        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 58 }, "the day read must follow the whole-day import, not the ride")
    }

    /// Single-device install (the default): only the seeded active 'my-whoop' is paired. The owner
    /// MUST resolve to 'my-whoop' so behaviour is byte-identical to the pre-I2 code.
    func testSingleDeviceResolvesToWhoopUnchanged() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        let base = dayStart + 3 * 3_600
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 55) }), deviceId: "my-whoop")

        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "my-whoop", "single-device install must resolve to the seeded WHOOP")

        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertEqual(read.count, 300)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 55 })
    }
}
