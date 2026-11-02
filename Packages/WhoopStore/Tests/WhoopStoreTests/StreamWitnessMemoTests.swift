import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// `dayHrFingerprint`, `gravityFingerprint` and `dayStreamFingerprint` answer from `StreamWitnessMemo` while
/// their window stands still (#2314). Answering when it should have recounted re-serves a stale night;
/// recounting when it could have answered gives back the disk reads the memo exists to save. Every test
/// here holds one of those ends: an answer always equals a fresh count, and a night nothing reached reads
/// only the rowid frontier.
final class StreamWitnessMemoTests: XCTestCase {
    private let night = (from: 1_790_000_000, to: 1_790_000_000 + 12 * 3600)

    private struct Witnesses: Equatable { let hr: String; let gravity: String; let day: String }

    /// A registry-confirmed WHOOP 5 owner with a night of HR, R-R and gravity, and HR from another device.
    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: "dev1", brand: "WHOOP", model: "5.0 MG", sourceKind: .liveBLE, capabilities: [.hr],
            status: .active, addedAt: 1, lastSeenAt: 1))
        let ts = Array(stride(from: night.from + 60, to: night.to, by: 600))
        _ = try await store.insert(Streams(hr: ts.map { HRSample(ts: $0, bpm: 60) },
                                           rr: ts.map { RRInterval(ts: $0, rrMs: 1000) },
                                           gravity: ts.map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }),
                                   deviceId: "dev1")
        _ = try await store.insert(Streams(hr: [HRSample(ts: night.from + 30, bpm: 70)]), deviceId: "other")
        return store
    }

    /// The three witnesses of one window, the way the pass reads them.
    private func witnesses(_ store: WhoopStore, _ deviceId: String = "dev1", from: Int? = nil,
                           to: Int? = nil) async throws -> Witnesses {
        let f = from ?? night.from, t = to ?? night.to
        let hr = try await store.dayHrFingerprint(deviceId: deviceId, from: f, to: t)
        let gravity = try await store.gravityFingerprint(deviceId: deviceId, from: f, to: t)
        let day = try await store.dayStreamFingerprint(deviceId: deviceId, from: f, to: t)
        return Witnesses(hr: "\(hr.count):\(hr.maxTs)", gravity: "\(gravity.count):\(gravity.maxTs)", day: day)
    }

    /// The same three counted fresh, with no memo in the way.
    private func recounted(_ store: WhoopStore, _ deviceId: String = "dev1", from: Int? = nil,
                           to: Int? = nil) async throws -> Witnesses {
        let f = from ?? night.from, t = to ?? night.to
        let hr = try await store.hrFingerprint(deviceId: deviceId, from: f, to: t)
        let gravity = try await store.gravityCountInTest(deviceId: deviceId, from: f, to: t)
        let day = try await store.referenceFingerprintInTest(deviceId: deviceId, from: f, to: t)
        return Witnesses(hr: "\(hr.count):\(hr.maxTs)", gravity: "\(gravity.count):\(gravity.maxTs)", day: day)
    }

    /// The point of the memo: asking again about a night nothing reached walks no window, only each
    /// stream's right edge. A beat that lands recounts the witness that counts its stream, and only that one.
    func testAnUnchangedNightReadsOnlyTheRowidFrontier() async throws {
        let store = try await seeded()
        let first = try await witnesses(store)
        var second: Witnesses?
        let idle = try await queryPlans(store) { second = try await self.witnesses(store) }
        XCTAssertEqual(first, second)
        let idleReads = idle.filter { ReadTests.streamTable(in: $0) != nil }
        XCTAssertTrue(idleReads.contains { $0.hasSuffix("(rowid>?)") }, "no frontier read in the plan: \(idle)")
        for line in idleReads {
            XCTAssertTrue(ReadTests.isRowidSeek(line), "an unchanged night walked a stream again: \(line)")
        }

        _ = try await store.insert(Streams(rr: [RRInterval(ts: night.from + 90, rrMs: 900)]), deviceId: "dev1")
        var third: Witnesses?
        let landed = try await queryPlans(store) { third = try await self.witnesses(store) }
        XCTAssertNotEqual(second?.day, third?.day)
        let freshAfterLanding = try await recounted(store)
        XCTAssertEqual(third, freshAfterLanding)
        let windowReads = landed.filter { ReadTests.streamTable(in: $0) != nil && $0.contains("ts>") }
        XCTAssertTrue(windowReads.contains { $0.contains("rrInterval") }, "the landed beat was not recounted: \(landed)")
        XCTAssertFalse(windowReads.contains { $0.hasPrefix("SEARCH hrSample") },
                       "an R-R beat recounted the HR witness: \(landed)")
    }

    /// A strap offloads an old night after newer ones were scored, so its rows take rowids above all of
    /// them. Only that night moves, and another device's rows in a night are not its owner's.
    func testALateOffloadOfAnOldNightMovesThatNightOnly() async throws {
        let store = try await seeded()
        let older = (from: night.from - 86_400, to: night.from - 1)
        _ = try await store.insert(Streams(hr: [HRSample(ts: older.from + 100, bpm: 55)]), deviceId: "dev1")
        let olderBefore = try await witnesses(store, from: older.from, to: older.to)
        let nightBefore = try await witnesses(store)

        _ = try await store.insert(Streams(hr: [HRSample(ts: older.from + 200, bpm: 56)],
                                           rr: [RRInterval(ts: older.from + 200, rrMs: 950)],
                                           gravity: [GravitySample(ts: older.from + 200, x: 0, y: 0, z: 1)]),
                                   deviceId: "dev1")
        let olderAfter = try await witnesses(store, from: older.from, to: older.to)
        XCTAssertNotEqual(olderBefore.hr, olderAfter.hr)
        XCTAssertNotEqual(olderBefore.gravity, olderAfter.gravity)
        XCTAssertNotEqual(olderBefore.day, olderAfter.day)
        let freshOlder = try await recounted(store, from: older.from, to: older.to)
        XCTAssertEqual(olderAfter, freshOlder)
        let nightAfterBackfill = try await witnesses(store)
        XCTAssertEqual(nightBefore, nightAfterBackfill)

        _ = try await store.insert(Streams(hr: [HRSample(ts: night.from + 90, bpm: 80)],
                                           rr: [RRInterval(ts: night.from + 90, rrMs: 900)]), deviceId: "other")
        let nightAfterOtherDevice = try await witnesses(store)
        XCTAssertEqual(nightBefore, nightAfterOtherDevice)
    }

    /// Two writes change a stored beat without landing a row: the source promotion when the strap's
    /// history re-delivers a beat, and the fill flag when a 500 ms beat is replayed after its second's heart
    /// rate arrived. Neither moves a rowid, so the journal must carry them.
    func testInPlaceEditsRecountTheNight() async throws {
        let store = try await seeded()
        let before = try await witnesses(store)
        let promotion = try await store.insert(
            Streams(rr: [RRInterval(ts: night.from + 60, rrMs: 1000, srcChannel: .whoop5Historical)]), deviceId: "dev1")
        XCTAssertEqual(promotion.rr, 0, "the promotion must not land a row, or the frontier alone would see it")
        let promoted = try await witnesses(store)
        XCTAssertNotEqual(before.day, promoted.day)
        let freshPromoted = try await recounted(store)
        XCTAssertEqual(promoted, freshPromoted)

        let fillTs = night.from + 7_205
        let fill = Streams(rr: [RRInterval(ts: fillTs, rrMs: 500, srcChannel: .whoop5Standard)])
        _ = try await store.insert(fill, deviceId: "dev1")
        _ = try await store.insert(Streams(hr: [HRSample(ts: fillTs, bpm: 60)]), deviceId: "dev1")
        let unflagged = try await witnesses(store)
        let marksBeforeReplay = try await store.fillMarkCountInTest().suspect
        XCTAssertEqual(marksBeforeReplay, 0)
        let replay = try await store.insert(fill, deviceId: "dev1")
        XCTAssertEqual(replay.rr, 0)
        let marksAfterReplay = try await store.fillMarkCountInTest().suspect
        XCTAssertEqual(marksAfterReplay, 1)
        let flagged = try await witnesses(store)
        XCTAssertNotEqual(unflagged.day, flagged.day)
        let freshFlagged = try await recounted(store)
        XCTAssertEqual(flagged, freshFlagged)
    }

    /// A wipe can delete a table's newest row, and SQLite hands that rowid to the next insert: the frontier
    /// reads the same before and after, and the new row sits at it rather than above it. Only the journal's
    /// removal bracket can tell. The re-key of an adoption and a heal's deletes are bracketed the same way.
    func testRemovalsRecountEvenWhenTheirRowidIsReused() async throws {
        let store = try await seeded()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: night.from + 90, rrMs: 900)]), deviceId: "ring")
        let top = try await store.rrTopRowidInTest()
        let before = try await witnesses(store)
        try registry.deleteAllData(deviceId: "ring")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: night.from + 95, rrMs: 905)]), deviceId: "dev1")
        let reusedTop = try await store.rrTopRowidInTest()
        XCTAssertEqual(top, reusedTop, "the fixture must reuse the freed rowid, or it proves nothing")
        let after = try await witnesses(store)
        XCTAssertNotEqual(before.day, after.day)
        let freshAfterWipe = try await recounted(store)
        XCTAssertEqual(after, freshAfterWipe)

        try registry.add(PairedDevice(id: "oura-uuid", brand: "Oura", model: "Ring 4", sourceKind: .liveBLE,
                                      capabilities: [.hr], status: .active, addedAt: 1, lastSeenAt: 1))
        _ = try await store.insert(Streams(hr: [HRSample(ts: night.from + 120, bpm: 58)],
                                           rr: [RRInterval(ts: night.from + 120, rrMs: 1030)]), deviceId: "oura-uuid")
        let serialBefore = try await witnesses(store, "oura-serial")
        XCTAssertTrue(try registry.adoptSerialIdentity(from: "oura-uuid", to: "oura-serial"))
        let serialAfter = try await witnesses(store, "oura-serial")
        XCTAssertNotEqual(serialBefore.hr, serialAfter.hr)
        XCTAssertNotEqual(serialBefore.day, serialAfter.day)
        let freshSerial = try await recounted(store, "oura-serial")
        XCTAssertEqual(serialAfter, freshSerial)

        // The heal must not delete the newest rows, or the frontier going backwards would give it away.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)], rr: [RRInterval(ts: 100, rrMs: 800)]),
                                   deviceId: "dev1")
        _ = try await store.insert(Streams(hr: [HRSample(ts: night.from + 150, bpm: 61)],
                                           rr: [RRInterval(ts: night.from + 150, rrMs: 990)]), deviceId: "dev1")
        let implausible = try await witnesses(store, from: 0, to: 1000)
        try await store.healImplausibleTimestamps(now: night.to, todayLocalDayKey: "2026-09-21")
        let healed = try await witnesses(store, from: 0, to: 1000)
        XCTAssertNotEqual(implausible.hr, healed.hr)
        XCTAssertNotEqual(implausible.day, healed.day)
        let freshHealed = try await recounted(store, from: 0, to: 1000)
        XCTAssertEqual(healed, freshHealed)
    }

    /// Not a path the app has, since every stream delete is bracketed: a delete nobody noted that takes a
    /// table's newest row still re-bases the memo, because the frontier went backwards.
    func testAFrontierThatWentBackwardsRecountsEverything() async throws {
        let store = try await seeded()
        let before = try await witnesses(store)
        try await store.executeInTest("DELETE FROM rrInterval WHERE rowid = (SELECT MAX(rowid) FROM rrInterval)")
        let after = try await witnesses(store)
        XCTAssertNotEqual(before.day, after.day)
        let fresh = try await recounted(store)
        XCTAssertEqual(after, fresh)
    }

    /// Random interleavings of every write the memo has to see, on two devices and overlapping windows, an
    /// old night's backfill included. After every write each window's three witnesses must equal a fresh
    /// count.
    func testEveryAnswerEqualsAFreshCountUnderRandomWrites() async throws {
        var rng = SplitMixInTest(seed: 0x2314)
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let base = 1_790_000_000
        try await store.seedFingerprintRowsInTest(rng: &rng, base: base, beats: 2_000)
        var windows = (0..<6).map { (base - 3600 + $0 * 43_200, base - 3600 + ($0 + 1) * 43_200 - 1) }
        windows.append((base, base + 54 * 3600))
        windows.append((base + 3600, base + 3600))
        func check(_ label: String) async throws {
            for device in ["my-whoop", "ring"] {
                for (from, to) in windows {
                    let memo = try await witnesses(store, device, from: from, to: to)
                    let fresh = try await recounted(store, device, from: from, to: to)
                    XCTAssertEqual(memo, fresh, "\(label) \(device) [\(from), \(to)]")
                }
            }
        }
        try await check("seeded")
        for step in 0..<48 {
            let op = Int(rng.next() % 6)
            let device = rng.next() % 3 == 0 ? "ring" : "my-whoop"
            let ts = base - 3600 + Int(rng.next() % 250_000)
            switch op {
            case 0:
                try await store.seedFingerprintRowsInTest(rng: &rng, base: base, beats: 40)
            case 1:
                _ = try await store.insert(Streams(hr: (0..<20).map { HRSample(ts: ts + $0, bpm: 50 + $0) },
                                                   gravity: [GravitySample(ts: ts, x: 0, y: 0, z: 1)]),
                                           deviceId: device)
            case 2:
                if let beat = try await store.legacyBeatInTest(deviceId: "my-whoop", offset: Int(rng.next() % 500)) {
                    _ = try await store.insert(Streams(rr: [RRInterval(ts: beat.ts, rrMs: beat.rrMs,
                                                                       srcChannel: .whoop5Historical)]),
                                               deviceId: "my-whoop")
                }
            case 3:
                let fill = Streams(rr: [RRInterval(ts: ts, rrMs: 500, srcChannel: .whoop5Standard)])
                _ = try await store.insert(fill, deviceId: "my-whoop")
                _ = try await store.insert(Streams(hr: [HRSample(ts: ts, bpm: 60)]), deviceId: "my-whoop")
                _ = try await store.insert(fill, deviceId: "my-whoop")
            case 4:
                try registry.deleteAllData(deviceId: device)
            default:
                let model = rng.next() % 2 == 0 ? "WHOOP 4.0" : "WHOOP 5.0 / MG"
                try await store.executeInTest("UPDATE pairedDevice SET model = ? WHERE id = 'my-whoop'", [model])
            }
            try await check("step \(step) op \(op)")
        }
    }
}

extension WhoopStore {
    func gravityCountInTest(deviceId: String, from: Int, to: Int) throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, from, to]) else { return (0, 0) }
            return (row["c"], row["m"])
        }
    }

    func rrTopRowidInTest() throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM rrInterval") ?? 0 }
    }

    /// A stored beat with no source label, which a historical re-delivery promotes in place.
    func legacyBeatInTest(deviceId: String, offset: Int) throws -> (ts: Int, rrMs: Int)? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND srcChannel IS NULL AND seq = 0
                ORDER BY ts LIMIT 1 OFFSET ?
                """, arguments: [deviceId, offset]).map { ($0["ts"], $0["rrMs"]) }
        }
    }

    /// A write that bypasses the store's own paths, and so the memo's journal.
    func executeInTest(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws {
        try syncWrite { db in try db.execute(sql: sql, arguments: arguments) }
    }
}
