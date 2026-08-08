import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// #1150: a Bluetooth-only strap (no WHOOP/Apple-Health import) banks every night under the COMPUTED
/// ("-noop") source, so the imported-only session read the analytics funnel used returned nothing and the
/// funnel reported "no sleep session in the last 14 days to analyze" even though computed session rows
/// existed. `Repository.computedSleepSessions` is the fallback the funnel now consults when the imported
/// read is empty (see `DebugDataDiagnostics.funnelLines` / Android `AndroidDiagnostics.funnelLines`). These
/// pin: (i) the imported read is empty while computed rows exist, (ii) the fallback returns them
/// oldest→newest so `.last` is the newest night, and (iii) a re-added strap's "<uuid>-noop" sessions are
/// reachable once the active id is adopted (the engine writes computed under `<activeStrapId>-noop`).
final class FunnelComputedSleepFallbackTests: XCTestCase {

    private let canonicalId = "my-whoop"
    private let newId = "whoop-ABC123"   // the id a re-added strap gets (AddDeviceWizard: "whoop-<uuid>")

    private func session(startTs: Int, endTs: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: 0.9, restingHr: 52,
                           avgHrv: 70, stagesJSON: nil, stagingSparse: true)
    }

    /// The core regression: computed-only nights (all under "-noop") are invisible to the imported read, but
    /// the computed fallback surfaces them, sorted so `.last` is the newest — what the funnel's newest-night
    /// walk relies on.
    @MainActor
    func testComputedOnlyNightsSurfaceViaFallbackSorted() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")

        let now = Int(Date().timeIntervalSince1970)
        let older = now - 3 * 86_400
        let newer = now - 1 * 86_400
        // Insert NEWEST-first so a naive read would mis-order; the fallback must sort ascending by onset.
        _ = try await store.upsertSleepSessions([
            session(startTs: newer, endTs: newer + 7 * 3_600),
            session(startTs: older, endTs: older + 7 * 3_600),
        ], deviceId: canonicalId + "-noop")

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        let imported = await repo.sleepSessions(from: now - 14 * 86_400, to: now, limit: 200)
        XCTAssertTrue(imported.isEmpty,
                      "computed nights are NOT under the imported source — this is the false-negative condition")

        let computed = await repo.computedSleepSessions(from: now - 14 * 86_400, to: now, limit: 200)
        XCTAssertEqual(computed.count, 2, "both computed nights must surface via the fallback")
        XCTAssertEqual(computed.map(\.startTs), [older, newer],
                       "oldest→newest so `.last` is the newest night the funnel analyses")
    }

    /// The re-added-strap case (the Kotlin active-id parity concern, mirrored): the engine writes computed
    /// sessions under "<activeStrapId>-noop", so a fallback pinned to the canonical sibling alone would miss
    /// a re-added strap's nights. After the active id is adopted the computed union reaches the strap's sibling.
    @MainActor
    func testFallbackReachesReAddedStrapComputedSibling() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        let now = Int(Date().timeIntervalSince1970)
        let night = now - 2 * 86_400
        _ = try await store.upsertSleepSessions([session(startTs: night, endTs: night + 7 * 3_600)],
                                                deviceId: newId + "-noop")

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        // Before the re-add the computed union reads the canonical sibling only → the strap's night is unseen.
        let before = await repo.computedSleepSessions(from: now - 14 * 86_400, to: now, limit: 200)
        XCTAssertTrue(before.isEmpty,
                      "with only the canonical id active, the re-added strap's computed night is not yet reachable")

        repo.adoptActiveDeviceId(newId)
        let after = await repo.computedSleepSessions(from: now - 14 * 86_400, to: now, limit: 200)
        XCTAssertEqual(after.count, 1,
                       "after adopting the active id the fallback reaches the strap's '<uuid>-noop' sibling")
        XCTAssertEqual(after.first?.startTs, night)
    }
}
