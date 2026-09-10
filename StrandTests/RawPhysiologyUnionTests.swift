import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

final class RawPhysiologyUnionTests: XCTestCase {
    func testRRMergePreservesDistinctSameTimestampBeatsAndDedupesExactIdentityActiveFirst() {
        let active = [RRInterval(ts: 100, rrMs: 800, ord: 8, seq: 0),
                      RRInterval(ts: 100, rrMs: 800, ord: 9, seq: 1)]
        let canonical = [RRInterval(ts: 100, rrMs: 800, ord: 1, seq: 0),
                         RRInterval(ts: 101, rrMs: 810, ord: 2, seq: 0)]
        let merged = Repository.mergeRRByIdentity([active, canonical])
        XCTAssertEqual(merged.map { "\($0.ts):\($0.rrMs):\($0.seq)" },
                       ["100:800:0", "100:800:1", "101:810:0"])
        XCTAssertEqual(merged.first?.ord, 8, "active source wins only the exact duplicate")
    }

    func testSingleSourceRRIsReturnedUnchanged() {
        let rows = [RRInterval(ts: 101, rrMs: 810, ord: 4, seq: 2),
                    RRInterval(ts: 100, rrMs: 800, ord: 3, seq: 1)]
        XCTAssertEqual(Repository.mergeRRByIdentity([rows]), rows)
    }

    func testRRUnionSortsByTimestampThenSequenceBeforeValueAndOrder() {
        let rows = Repository.mergeRRByIdentity([
            [RRInterval(ts: 100, rrMs: 700, ord: 0, seq: 1)],
            [RRInterval(ts: 100, rrMs: 900, ord: 9, seq: 0),
             RRInterval(ts: 100, rrMs: 800, ord: nil, seq: 0)],
        ])
        XCTAssertEqual(rows.map { "\($0.seq):\($0.rrMs):\($0.ord.map(String.init) ?? "nil")" },
                       ["0:800:nil", "0:900:9", "1:700:0"])
    }

    @MainActor
    func testRRFacadeUnionsReAddedStrapAndCanonical() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800)]), deviceId: "my-whoop")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 101, rrMs: 810)]), deviceId: "whoop-new")
        repo.adoptActiveDeviceId("whoop-new")
        let rows = await repo.rrIntervals(from: 90, to: 110)
        XCTAssertEqual(rows.map(\.ts), [100, 101])
    }

    @MainActor
    func testRawFacadeIncludesAnotherRegisteredWhoopNotCurrentlyActive() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "whoop-a", brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.hr], status: .archived, addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: "whoop-b", brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.hr], status: .active, addedAt: 2, lastSeenAt: 2))
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 61)]), deviceId: "whoop-a")
        _ = try await store.insert(Streams(hr: [HRSample(ts: 200, bpm: 72)]), deviceId: "whoop-b")
        let repo = Repository(deviceId: "whoop-b")
        repo.setStoreForTesting(store)
        let rows = await repo.hrSamples(from: 90, to: 210)
        XCTAssertEqual(rows.map(\.bpm), [61, 72])

        let timeline = await repo.timelineSeries(metric: .hr, from: 90, to: 210, targetPoints: 600)
        XCTAssertEqual(timeline.points.map { Int($0.value) }, [61, 72],
                       "default Deep Timeline must use the same all-WHOOP raw resolver")
    }

    @MainActor
    func testSessionMotionUsesHistoricalOwnerBeforeCurrentActiveComputedSource() async throws {
        let store = try await WhoopStore.inMemory()
        let session = CachedSleepSession(startTs: 1_000, endTs: 5_000, efficiency: 0.9,
                                         restingHr: 52, avgHrv: 60, stagesJSON: nil)
        _ = try await store.upsertSleepSessions([session], deviceId: "my-whoop")
        _ = try await store.upsertSleepSessions([session], deviceId: "my-whoop-noop")
        _ = try await store.persistSessionMotion(deviceId: "my-whoop-noop", sessionStart: 1_000,
                                                 motionEpochs: [0.1, 0.2])
        _ = try await store.upsertSleepSessions([session], deviceId: "whoop-new-noop")
        _ = try await store.persistSessionMotion(deviceId: "whoop-new-noop", sessionStart: 1_000,
                                                 motionEpochs: [9.0])
        let repo = Repository(deviceId: "whoop-new")
        repo.setStoreForTesting(store)
        let motion = await repo.sessionMotions(sessions: [session])
        XCTAssertEqual(motion[1_000] ?? [], [0.1, 0.2])
    }

    /// The batched read resolves EVERY session, not just the first.
    ///
    /// The per-session shape this replaced asked the store once per session per candidate device; it now
    /// takes one windowed read per device and resolves each block against that. The failure a batched
    /// version can have is a partial map: a span or page bound that covers the first night and quietly
    /// drops the rest, which looks exactly like "those nights have no motion" rather than like a bug.
    /// Three nights spread across the window, each with its own series, so a truncation is visible.
    @MainActor
    func testSessionMotionsResolvesEveryNightInOneBatch() async throws {
        let store = try await WhoopStore.inMemory()
        let starts = [1_000, 200_000, 900_000]
        let sessions = starts.map {
            CachedSleepSession(startTs: $0, endTs: $0 + 4_000, efficiency: 0.9,
                               restingHr: 52, avgHrv: 60, stagesJSON: nil)
        }
        _ = try await store.upsertSleepSessions(sessions, deviceId: "my-whoop")
        _ = try await store.upsertSleepSessions(sessions, deviceId: "my-whoop-noop")
        for (i, start) in starts.enumerated() {
            _ = try await store.persistSessionMotion(deviceId: "my-whoop-noop", sessionStart: start,
                                                     motionEpochs: [Double(i) + 0.5])
        }
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)

        let motion = await repo.sessionMotions(sessions: sessions)
        XCTAssertEqual(motion.count, starts.count, "a night dropped by the batch reads as having no motion")
        for (i, start) in starts.enumerated() {
            XCTAssertEqual(motion[start] ?? [], [Double(i) + 0.5], "night at \(start) got another night's series")
        }
    }

    /// Provenance and the probe must agree, or the fast path is a behaviour change wearing a perf label.
    ///
    /// The stored block carries the device it was read from and skips the ownership probe; the same block
    /// with that field stripped falls back to the probe. Both must resolve to the same motion. They do
    /// because the search normalises whichever id it finds to its `-noop` twin, and the computed ids are
    /// exactly the raw ids under that suffix, so both namespaces land on one source.
    @MainActor
    func testProvenanceAndTheOwnerProbeResolveTheSameMotion() async throws {
        let store = try await WhoopStore.inMemory()
        let session = CachedSleepSession(startTs: 1_000, endTs: 5_000, efficiency: 0.9,
                                         restingHr: 52, avgHrv: 60, stagesJSON: nil)
        _ = try await store.upsertSleepSessions([session], deviceId: "my-whoop")
        _ = try await store.upsertSleepSessions([session], deviceId: "my-whoop-noop")
        _ = try await store.persistSessionMotion(deviceId: "my-whoop-noop", sessionStart: 1_000,
                                                 motionEpochs: [0.3, 0.4])
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)

        // As the store hands it back: provenance present, no probe.
        let stored = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: 10_000, limit: 8)
        XCTAssertEqual(stored.first?.deviceId, "my-whoop")
        let viaProvenance = await repo.sessionMotions(sessions: stored)

        // The same block with provenance stripped: the probe resolves it instead.
        let viaProbe = await repo.sessionMotions(sessions: [session])

        XCTAssertEqual(viaProvenance[1_000] ?? [], [0.3, 0.4])
        XCTAssertEqual(viaProbe[1_000] ?? [], viaProvenance[1_000] ?? [],
                       "the shortcut and the probe disagreed about the same night")
    }

    @MainActor
    func testArchivedStrapNightsTeachHabitualMidsleep() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "whoop-old", brand: "WHOOP", model: "4.0",
            sourceKind: .liveBLE, capabilities: [.sleep], status: .archived, addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: "whoop-new", brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.sleep], status: .active, addedAt: 2, lastSeenAt: 2))
        let firstStart = Int(Date().timeIntervalSince1970) - 20 * 86_400
        let nights = (0..<SleepStageTotals.habitualMinDays).map { day in
            let start = firstStart + day * 86_400
            return CachedSleepSession(startTs: start, endTs: start + 8 * 3600, efficiency: 0.9,
                                      restingHr: 52, avgHrv: 60, stagesJSON: nil)
        }
        _ = try await store.upsertSleepSessions(nights, deviceId: "whoop-old")
        let repo = Repository(deviceId: "whoop-new")
        repo.setStoreForTesting(store)
        let habitual = await repo.habitualMidsleepSec()
        XCTAssertNotNil(habitual,
                        "retained nights from an archived strap must remain in the habitual learner")
    }

    @MainActor
    func testAICoachStressIndexReadsRRFromNonCurrentRegisteredStrap() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "whoop-old", brand: "WHOOP", model: "4.0",
            sourceKind: .liveBLE, capabilities: [.hrv], status: .archived, addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: "whoop-new", brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.hrv], status: .active, addedAt: 2, lastSeenAt: 2))
        let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) + 60
        let beats = (0..<24).map { RRInterval(ts: base + $0, rrMs: 780 + ($0 % 5) * 10) }
        _ = try await store.insert(Streams(rr: beats), deviceId: "whoop-old")
        let repo = Repository(deviceId: "whoop-new")
        repo.setStoreForTesting(store)
        let line = await AICoachEngine(repo: repo).stressIndexLine()
        XCTAssertNotNil(line, "coach stress context must use the same all-WHOOP R-R timeline as Stress")
    }
}
