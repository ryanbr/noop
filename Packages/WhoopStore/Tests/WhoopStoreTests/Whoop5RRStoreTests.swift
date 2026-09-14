import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class Whoop5RRStoreTests: XCTestCase {
    private let id = "my-whoop"
    private func registry(_ store: WhoopStore, model: String, brand: String = "WHOOP") throws {
        try store.registryWriter.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET model = ?, brand = ? WHERE id = ?",
                           arguments: [model, brand, id])
        }
    }
    private func read(_ store: WhoopStore, from: Int = 0, to: Int = 1000, limit: Int = 100) async throws -> [RRInterval] {
        try await store.rrIntervals(deviceId: id, from: from, to: to, limit: limit)
    }

    /// The date the "this night cannot be scored" explanation names comes from this read, so it has to
    /// agree with what scoring actually accepts: labelled scoring transports only, suspect stamps
    /// excluded, and nil rather than a fabricated epoch when nothing scorable has been banked yet.
    /// Same assertions as the Kotlin `firstScorableTimestampMatchesWhatScoringAccepts`.
    func testFirstScorableTimestampMatchesWhatScoringAccepts() async throws {
        let store = try await WhoopStore.inMemory()
        try registry(store, model: "5.0 MG")
        // Legacy unlabelled beats only: nothing here can be scored, so there is no first scorable day.
        _ = try await store.insert(Streams(rr: (100..<110).map { RRInterval(ts: $0, rrMs: 1000) }), deviceId: id)
        var first = try await store.firstScorableWhoop5RRTimestamp(deviceId: id)
        XCTAssertNil(first)
        // The lower bound sees those same rows: they WERE recorded, they just cannot be read.
        var recorded = try await store.firstRecordedRRTimestamp(deviceId: id)
        XCTAssertEqual(recorded, 100)
        // A type-40 live beat (6) is labelled but is NOT a scoring transport, so it must not count.
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 200, rrMs: 1000, srcChannel: .whoop5Realtime)]),
                                   deviceId: id)
        first = try await store.firstScorableWhoop5RRTimestamp(deviceId: id)
        XCTAssertNil(first)
        // A future-stamped beat is excluded from scoring (#1073), so it cannot name the day either.
        let device = id
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO rrInterval(deviceId, ts, rrMs, seq, synced, ord, srcChannel, tsSuspect)
                VALUES (?, 300, 1000, 0, 0, 0, 7, 1)
                """, arguments: [device])
        }
        first = try await store.firstScorableWhoop5RRTimestamp(deviceId: id)
        XCTAssertNil(first)
        // The first genuinely scorable beat, and then an earlier one, which must win.
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 900, rrMs: 1000, srcChannel: .whoop5Standard)]),
                                   deviceId: id)
        first = try await store.firstScorableWhoop5RRTimestamp(deviceId: id)
        XCTAssertEqual(first, 900)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 400, rrMs: 1000, srcChannel: .whoop5Historical)]),
                                   deviceId: id)
        first = try await store.firstScorableWhoop5RRTimestamp(deviceId: id)
        XCTAssertEqual(first, 400)
        // The lower bound ignores the channel entirely and still refuses the suspect stamp.
        recorded = try await store.firstRecordedRRTimestamp(deviceId: id)
        XCTAssertEqual(recorded, 100)
        // Another device's beats never leak into either answer.
        let other = try await store.firstScorableWhoop5RRTimestamp(deviceId: "someone-else")
        XCTAssertNil(other)
        let otherRecorded = try await store.firstRecordedRRTimestamp(deviceId: "someone-else")
        XCTAssertNil(otherRecorded)
    }

    func testHistoricalCanonicalOwnerAfterRePairingUsesActiveWhoop5Policy() async throws {
        let store = try await WhoopStore.inMemory()
        try registry(store, model: "WHOOP")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 1024)]), deviceId: "my-whoop")
        let strict = try await store.isWhoop5RRSource(deviceId: "my-whoop", unlabelledAliasOfWhoop5: true)
        XCTAssertTrue(strict)
        let guarded = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: 1000, limit: 100,
                                                 unlabelledAliasOfWhoop5: true)
        XCTAssertTrue(guarded.isEmpty)
        let withheld = try await store.legacyWhoop5RRWithheld(
            deviceId: "my-whoop", from: 0, to: 1000, unlabelledAliasOfWhoop5: true)
        XCTAssertTrue(withheld, "the canonical alias must expose the same strict-window status as its read")
        try registry(store, model: "4.0")
        let confirmedFour = try await store.isWhoop5RRSource(deviceId: "my-whoop", unlabelledAliasOfWhoop5: true)
        XCTAssertFalse(confirmedFour)
        let legacy = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: 1000, limit: 100,
                                                unlabelledAliasOfWhoop5: true)
        XCTAssertEqual(legacy.map(\.rrMs), [1024])
    }

    func testOrdinaryReadsAndFingerprintsFollowActiveAliasPolicy() async throws {
        let store = try await WhoopStore.inMemory()
        try registry(store, model: "WHOOP")
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        for (owner, model) in [("old-four", "4.0"), ("new-five", "5.0 MG")] {
            try registry.add(PairedDevice(id: owner, brand: "WHOOP", model: model,
                sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .paired, addedAt: 1, lastSeenAt: 1))
        }
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 1000)]), deviceId: id)
        try registry.setActive("old-four")
        let global = try await store.analysisFingerprint()
        let day = try await store.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        let legacy = try await read(store)
        XCTAssertEqual(legacy.map(\.rrMs), [1000])
        try registry.setActive("new-five")
        let guarded = try await read(store)
        XCTAssertTrue(guarded.isEmpty, "ordinary callers must resolve the alias from the active registry")
        let changedGlobal = try await store.analysisFingerprint()
        let changedDay = try await store.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        XCTAssertNotEqual(global, changedGlobal)
        XCTAssertNotEqual(day, changedDay)
        try self.registry(store, model: "4.0")
        let confirmedFour = try await read(store)
        XCTAssertEqual(confirmedFour.map(\.rrMs), [1000])
    }

    func testOwnerPolicyExcludesMixedLegacyWithoutChangingStoredRows() async throws {
        let s = try await WhoopStore.inMemory()
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 1000)]), deviceId: id)
        try registry(s, model: "5.0 MG")
        var rows = try await read(s)
        XCTAssertTrue(rows.isEmpty)
        try registry(s, model: "4.0")
        rows = try await read(s)
        XCTAssertEqual(rows.map(\.rrMs), [1000])
        try registry(s, model: "WHOOP")
        rows = try await read(s)
        XCTAssertEqual(rows.map(\.rrMs), [1000])
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 101, rrMs: 977, srcChannel: .whoop5Standard)]), deviceId: id)
        rows = try await read(s)
        XCTAssertEqual(rows.map(\.rrMs), [977], "wire evidence resolves an unknown registry")
        try registry(s, model: "5.0 MG", brand: "Oura")
        rows = try await read(s)
        XCTAssertEqual(rows.map(\.rrMs), [1000, 977], "stray tags cannot override a different device brand")
        let stored = try await s.rrRowsWithChannelForTest(deviceId: id)
        XCTAssertEqual(stored.count, 2, "source policy never rewrites or removes legacy intervals")
    }

    func testLegacyWithheldStatusUsesTheExactScoringWindowAndSourcePolicy() async throws {
        let s = try await WhoopStore.inMemory()
        try registry(s, model: "5.0 MG")
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 1000)]), deviceId: id)
        let withheld = try await s.legacyWhoop5RRWithheld(deviceId: id, from: 100, to: 200)
        XCTAssertTrue(withheld)
        let outside = try await s.legacyWhoop5RRWithheld(deviceId: id, from: 101, to: 200)
        XCTAssertFalse(outside,
                       "legacy rows outside the exact read window cannot protect a score")
        try await s.dbWriter.write { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE deviceId = ? AND ts = 100",
                           arguments: [self.id])
        }
        let quarantined = try await s.legacyWhoop5RRWithheld(deviceId: id, from: 100, to: 200)
        XCTAssertFalse(quarantined, "quarantined rows are excluded exactly like the scoring read")
        try await s.dbWriter.write { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = NULL WHERE deviceId = ? AND ts = 100",
                           arguments: [self.id])
        }

        _ = try await s.insert(Streams(rr: [RRInterval(ts: 150, rrMs: 990,
                                                       srcChannel: .whoop5Standard)]), deviceId: id)
        let labelled = try await s.legacyWhoop5RRWithheld(deviceId: id, from: 100, to: 200)
        XCTAssertFalse(labelled,
                       "any scorable labelled transport ends legacy protection")

        try registry(s, model: "4.0")
        let whoop4 = try await s.legacyWhoop5RRWithheld(deviceId: id, from: 100, to: 149)
        XCTAssertFalse(whoop4)
        try registry(s, model: "5.0 MG", brand: "Oura")
        let otherBrand = try await s.legacyWhoop5RRWithheld(deviceId: id, from: 100, to: 149)
        XCTAssertFalse(otherBrand)
    }

    func testSourceSelectionPrecedesLimitAndSharesBoundsAndQuarantine() async throws {
        let s = try await WhoopStore.inMemory()
        try registry(s, model: "5.0 MG")
        let rows = (100..<200).map { RRInterval(ts: $0, rrMs: 1000, srcChannel: .whoop5Standard) }
            + [RRInterval(ts: 200, rrMs: 900, srcChannel: .whoop5Historical),
               RRInterval(ts: 201, rrMs: 800, srcChannel: .whoop5Realtime)]
        _ = try await s.insert(Streams(rr: rows), deviceId: id)
        var selected = try await read(s, limit: 1)
        XCTAssertEqual(selected.map(\.rrMs), [900], "historical source must be chosen before LIMIT")
        selected = try await read(s, to: 199, limit: 1)
        XCTAssertEqual(selected.map(\.rrMs), [1000], "history outside this interval cannot select its source")
        try await s.registryWriter.write { db in try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts = 200") }
        selected = try await read(s, limit: 1)
        XCTAssertEqual(selected.map(\.rrMs), [1000], "suspect-only history cannot suppress the valid fallback")
        selected = try await read(s, from: 201)
        XCTAssertTrue(selected.isEmpty, "native realtime is diagnostic, not the durable scoring fallback")
    }

    func testZeroInsertPromotionRestoresHistoricalOrderAndInvalidatesBothCaches() async throws {
        let s = try await WhoopStore.inMemory()
        try registry(s, model: "5.0 MG")
        let legacy = [700, 900, 900, 800].map { RRInterval(ts: 100, rrMs: $0) }
        _ = try await s.insert(Streams(rr: legacy), deviceId: id)
        let beforeGlobal = try await s.analysisFingerprint()
        let beforeDay = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        let history = [900, 700, 900, 800].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Historical) }
        let inserted = try await s.insert(Streams(rr: history), deviceId: id)
        XCTAssertEqual(inserted.rr, 0)
        let selected = try await read(s)
        XCTAssertEqual(selected.map(\.rrMs), [900, 700, 900, 800])
        XCTAssertEqual(selected.map(\.ord), [0, 1, 2, 3])
        XCTAssertEqual(selected.map(\.seq), [0, 0, 1, 0])
        let afterGlobal = try await s.analysisFingerprint()
        let afterDay = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        XCTAssertNotEqual(beforeGlobal, afterGlobal)
        XCTAssertNotEqual(beforeDay, afterDay)
        let replayed = try await s.insert(Streams(rr: history), deviceId: id)
        XCTAssertEqual(replayed.rr, 0)
        let replayGlobal = try await s.analysisFingerprint()
        let replayDay = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        XCTAssertEqual(afterGlobal, replayGlobal)
        XCTAssertEqual(afterDay, replayDay)
    }

    func testInterleavedTransportsCannotChangeHistoricalSequenceOrOrder() async throws {
        let s = try await WhoopStore.inMemory()
        let pairs: [(Int, RRSourceChannel)] = [(700, .whoop5Standard), (900, .whoop5Historical),
            (900, .whoop5Standard), (700, .whoop5Historical), (900, .whoop5Historical), (800, .whoop5Historical)]
        let n = try await s.insert(Streams(rr: pairs.map { RRInterval(ts: 100, rrMs: $0.0, srcChannel: $0.1) }), deviceId: id)
        XCTAssertEqual(n.rr, 4, "exact keys coalesce but history promotes their source and order")
        let selected = try await read(s)
        XCTAssertEqual(selected.map(\.rrMs), [900, 700, 900, 800])
        XCTAssertEqual(selected.map(\.ord), [0, 1, 2, 3])
        XCTAssertEqual(selected.map(\.seq), [0, 0, 1, 0])
    }

    func testStandardWinsNativeAndLegacyCollisionsInBothArrivalOrders() async throws {
        for lowerSource: RRSourceChannel? in [nil, .whoop5Realtime] {
            for standardFirst in [false, true] {
                let s = try await WhoopStore.inMemory()
                try registry(s, model: "5.0 MG")
                let lower = [700, 900, 900, 800].map { RRInterval(ts: 100, rrMs: $0, srcChannel: lowerSource) }
                let standard = [900, 700, 900, 800].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Standard) }
                let first = try await s.insert(Streams(rr: standardFirst ? standard : lower), deviceId: id)
                XCTAssertEqual(first.rr, 4)
                let g0 = try await s.analysisFingerprint()
                let d0 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
                let second = try await s.insert(Streams(rr: standardFirst ? lower : standard), deviceId: id)
                XCTAssertEqual(second.rr, 0)
                let selected = try await read(s)
                XCTAssertEqual(selected.map(\.rrMs), [900, 700, 900, 800])
                XCTAssertEqual(selected.map(\.ord), [0, 1, 2, 3])
                XCTAssertEqual(selected.map(\.seq), [0, 0, 1, 0])
                XCTAssertEqual(selected.map(\.srcChannel), Array(repeating: .whoop5Standard, count: 4))
                let g1 = try await s.analysisFingerprint()
                let d1 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
                XCTAssertEqual(g0 == g1, standardFirst, "zero-insert source promotion must invalidate global analysis")
                XCTAssertEqual(d0 == d1, standardFirst, "zero-insert source promotion must invalidate the cached day")
                for replay in [lower, standard] {
                    let n = try await s.insert(Streams(rr: replay), deviceId: id)
                    XCTAssertEqual(n.rr, 0)
                }
                let g2 = try await s.analysisFingerprint()
                let d2 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
                XCTAssertEqual(g1, g2)
                XCTAssertEqual(d1, d2)
                let history = [800, 900, 700, 900].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Historical) }
                let promoted = try await s.insert(Streams(rr: history), deviceId: id)
                XCTAssertEqual(promoted.rr, 0)
                let g3 = try await s.analysisFingerprint()
                let d3 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
                XCTAssertNotEqual(g2, g3)
                XCTAssertNotEqual(d2, d3)
                for replay in [standard, lower, history] {
                    let n = try await s.insert(Streams(rr: replay), deviceId: id)
                    XCTAssertEqual(n.rr, 0)
                }
                let final = try await read(s)
                XCTAssertEqual(final.map(\.rrMs), [800, 900, 700, 900])
                XCTAssertEqual(final.map(\.ord), [0, 1, 2, 3])
                XCTAssertEqual(final.map(\.srcChannel), Array(repeating: .whoop5Historical, count: 4))
                let g4 = try await s.analysisFingerprint()
                let d4 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
                XCTAssertEqual(g3, g4)
                XCTAssertEqual(d3, d4)
            }
        }
    }

    func testPromotionDoesNotRelabelOuraAndRegistryOnlyChangesInvalidateCaches() async throws {
        let s = try await WhoopStore.inMemory()
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .greenQuality)]), deviceId: id)
        let standard = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Standard)]), deviceId: id)
        XCTAssertEqual(standard.rr, 0)
        let n = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Historical)]), deviceId: id)
        XCTAssertEqual(n.rr, 0)
        let stored = try await s.rrRowsWithChannelForTest(deviceId: id)
        XCTAssertEqual(stored.map(\.srcChannel), [1])
        let g0 = try await s.analysisFingerprint()
        let d0 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        try registry(s, model: "5.0 MG")
        let g1 = try await s.analysisFingerprint()
        let d1 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        XCTAssertNotEqual(g0, g1)
        XCTAssertNotEqual(d0, d1)
        try await s.registryWriter.write { db in try db.execute(sql: "UPDATE pairedDevice SET lastSeenAt = 999") }
        let g2 = try await s.analysisFingerprint()
        let d2 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
        XCTAssertEqual(g1, g2, "routine last-seen writes do not force rescoring")
        XCTAssertEqual(d1, d2)
    }

    func testFirstTagOutsideDayAndSuspectPromotionInvalidateOwnerPolicyCaches() async throws {
        for suspect in [false, true] {
            let s = try await WhoopStore.inMemory()
            try registry(s, model: "WHOOP")
            _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800),
                                               RRInterval(ts: 2000, rrMs: 900)]), deviceId: id)
            if suspect {
                try await s.registryWriter.write { db in
                    try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts = 2000")
                }
            }
            let g0 = try await s.analysisFingerprint()
            let d0 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
            let before = try await read(s)
            XCTAssertEqual(before.map(\.rrMs), [800])
            let n = try await s.insert(Streams(rr: [RRInterval(ts: 2000, rrMs: 900,
                                                              srcChannel: .whoop5Historical)]), deviceId: id)
            XCTAssertEqual(n.rr, 0)
            let after = try await read(s)
            XCTAssertTrue(after.isEmpty)
            let g1 = try await s.analysisFingerprint()
            let d1 = try await s.dayStreamFingerprint(deviceId: id, from: 0, to: 1000)
            XCTAssertNotEqual(g0, g1, "even a suspect tag changes the unknown owner's source policy")
            XCTAssertNotEqual(d0, d1, "owner policy applies to cached days outside the tagged interval")
        }
    }
}
