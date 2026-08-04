import XCTest
import WhoopProtocol
@testable import WhoopStore

final class ReadTests: XCTestCase {
    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)
        let s = Streams(
            hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                 HRSample(ts: 300, bpm: 62)],
            rr: [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)],
            events: [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                payload: ["k": .int(9)])],
            battery: [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
        _ = try await store.insert(s, deviceId: "dev1")
        // Decoy on another device — must never appear in dev1 reads.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 200, bpm: 99)]), deviceId: "other")
        return store
    }

    func testHrSamplesRangeOrderLimitAndDeviceScope() async throws {
        let store = try await seeded()
        let all = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(all, [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                             HRSample(ts: 300, bpm: 62)])
        let windowed = try await store.hrSamples(deviceId: "dev1", from: 150, to: 250, limit: 100)
        XCTAssertEqual(windowed, [HRSample(ts: 200, bpm: 61)])     // inclusive range
        let limited = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 2)
        XCTAssertEqual(limited.count, 2)                            // ascending, first 2
        XCTAssertEqual(limited.first?.ts, 100)
    }

    // #836 — the idle-tick gate's change-detector: (count, maxTs) scoped to the device + window, no rows.
    func testHrFingerprintCountMaxTsRangeAndDeviceScope() async throws {
        let store = try await seeded()
        // dev1 has hr ts 100/200/300 → full window is (count 3, maxTs 300).
        let full = try await store.hrFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(full.maxTs, 300)
        // Inclusive sub-window [150,250] sees only ts 200 → (1, 200).
        let windowed = try await store.hrFingerprint(deviceId: "dev1", from: 150, to: 250)
        XCTAssertEqual(windowed.count, 1)
        XCTAssertEqual(windowed.maxTs, 200)
        // The decoy on "other" (single ts 200) is device-scoped, never folded into dev1.
        let other = try await store.hrFingerprint(deviceId: "other", from: 0, to: 1000)
        XCTAssertEqual(other.count, 1)
        XCTAssertEqual(other.maxTs, 200)
        // Empty window COALESCEs to (0, 0), never nil.
        let empty = try await store.hrFingerprint(deviceId: "dev1", from: 5000, to: 6000)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.maxTs, 0)
    }

    func testHrBucketsAveragePerBucketOrderedAndDeviceScoped() async throws {
        let store = try await seeded()
        // 200s buckets over dev1's ts 100/200/300 (bpm 60/61/62):
        //   ts100 → bucket 0   → mean 60
        //   ts200, ts300 → bucket 200 → mean (61+62)/2 = 61.5
        let buckets = try await store.hrBuckets(deviceId: "dev1", from: 0, to: 1000, bucketSeconds: 200)
        XCTAssertEqual(buckets, [HRBucket(ts: 0, bpm: 60), HRBucket(ts: 200, bpm: 61.5)])
        // The decoy on "other" (ts200, bpm99) must never bleed into dev1's bucket.
        let other = try await store.hrBuckets(deviceId: "other", from: 0, to: 1000, bucketSeconds: 200)
        XCTAssertEqual(other, [HRBucket(ts: 200, bpm: 99)])
    }

    /// Both same-second beats survive the v24 key. Since #823 the read order is EMISSION order, and
    /// `seeded()` happens to insert these two ascending — so the expectation is unchanged, but it now
    /// holds because 800 was sent first, not because 800 < 820.
    func testRrIntervalsReturnsBothTiedRows() async throws {
        let store = try await seeded()
        let rr = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(rr, [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)])
    }

    // MARK: - hrWindowStats (#836)

    /// The bug this exists for: the average must count PPG-derived seconds, exactly as the chart does.
    /// A WHOOP 5 banks v26 PPG instead of v18 HR per second, so a PPG-heavy workout charted a full trace
    /// while a measured-only aggregate fell under the caller's 60-sample floor and Avg HR rendered blank.
    func testHrWindowStatsCountsPpgDerivedSeconds() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // 20 measured seconds, 400 PPG seconds, 5 of them overlapping measured ones.
        var hr: [HRSample] = [], ppg: [PpgHrSample] = []
        for t in 0..<20 { hr.append(HRSample(ts: t, bpm: 120)) }
        for t in 15..<415 { ppg.append(PpgHrSample(ts: t, bpm: 140, conf: 0.8)) }
        _ = try await store.insert(Streams(hr: hr, ppgHr: ppg), deviceId: "dev1")

        let stats = try await store.hrWindowStats(primaryId: "dev1", secondaryId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(stats.n, 415, "measured ∪ PPG, with the 5 overlapping seconds counted once")
        XCTAssertEqual(stats.max, 140)

        // It must agree with what the chart read returns — that agreement IS the fix.
        let charted = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1_000, limit: 100_000)
        XCTAssertEqual(stats.n, charted.count)
        let meanOfChart = Double(charted.reduce(0) { $0 + $1.bpm }) / Double(charted.count)
        XCTAssertEqual(try XCTUnwrap(stats.avg), meanOfChart, accuracy: 1e-9)
    }

    /// A measured second must never be double-counted by its own PPG estimate (the anti-join).
    func testHrWindowStatsDoesNotDoubleCountOverlappingSeconds() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: (0..<10).map { HRSample(ts: $0, bpm: 100) },
                    ppgHr: (0..<10).map { PpgHrSample(ts: $0, bpm: 180, conf: 0.9) }),
            deviceId: "dev1")
        let stats = try await store.hrWindowStats(primaryId: "dev1", secondaryId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(stats.n, 10, "every second is measured; no PPG row may be added")
        XCTAssertEqual(try XCTUnwrap(stats.avg), 100, accuracy: 1e-9)
        XCTAssertEqual(stats.max, 100, "the PPG 180s must not become the peak")
    }

    /// The parity half of #836: no row limit. Reducing `hrSamples(limit: 8000)` reported the mean of a
    /// long session's FIRST 8000 samples; Kotlin aggregated the whole window. Now both do.
    func testHrWindowStatsHasNoEightThousandRowCap() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // 3 h at 1 Hz with HR stepping up: the first 8000 s average BELOW the true whole-session mean.
        let n = 10_800
        let hr = (0..<n).map { HRSample(ts: $0, bpm: $0 < 8_000 ? 120 : 170) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "dev1")

        let stats = try await store.hrWindowStats(primaryId: "dev1", secondaryId: "dev1", from: 0, to: 20_000)
        XCTAssertEqual(stats.n, n, "the whole window, not a capped page of it")
        let trueMean = (120.0 * 8_000 + 170.0 * 2_800) / Double(n)
        XCTAssertEqual(try XCTUnwrap(stats.avg), trueMean, accuracy: 1e-9)
        XCTAssertEqual(Int(try XCTUnwrap(stats.avg).rounded()), 133)
        // What the old capped reduce would have reported, and why it was wrong.
        XCTAssertNotEqual(Int(try XCTUnwrap(stats.avg).rounded()), 120)
    }

    /// Empty window: nil rather than a fabricated zero, so the caller's `avg == nil` guard still fires.
    func testHrWindowStatsEmptyWindowIsNil() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let stats = try await store.hrWindowStats(primaryId: "dev1", secondaryId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(stats.n, 0)
        XCTAssertNil(stats.avg)
        XCTAssertNil(stats.max)
    }

    /// A device with no PPG at all (WHOOP 4, or a 5 that banked v18 throughout) must be unchanged by the
    /// union — the guarantee that this fix cannot move numbers it has no business moving.
    func testHrWindowStatsWithNoPpgMatchesMeasuredOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: (0..<100).map { HRSample(ts: $0, bpm: 90 + $0 % 7) }), deviceId: "dev1")
        let stats = try await store.hrWindowStats(primaryId: "dev1", secondaryId: "dev1", from: 0, to: 1_000)
        let measured = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1_000, limit: 100_000)
        XCTAssertEqual(stats.n, measured.count)
        XCTAssertEqual(try XCTUnwrap(stats.avg),
                       Double(measured.reduce(0) { $0 + $1.bpm }) / Double(measured.count), accuracy: 1e-9)
        XCTAssertEqual(stats.max, measured.map(\.bpm).max())
    }

    // MARK: - hrWindowStats across two device ids (#856)

    /// The control that matters: passing the SAME id twice must be byte-identical to the single-id
    /// read this replaced, because that is what makes the change invisible to a single-WHOOP install.
    func testSameIdTwiceMatchesTheSingleIdRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: (0..<40).map { HRSample(ts: $0, bpm: 90 + $0 % 5) }), deviceId: "dev1")
        let stats = try await store.hrWindowStats(primaryId: "dev1", secondaryId: "dev1",
                                                  from: 0, to: 1_000)
        let rows = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1_000, limit: 100_000)
        XCTAssertEqual(stats.n, rows.count)
        XCTAssertEqual(try XCTUnwrap(stats.avg),
                       Double(rows.reduce(0) { $0 + $1.bpm }) / Double(rows.count), accuracy: 1e-9)
        XCTAssertEqual(stats.max, rows.map(\.bpm).max())
    }

    /// A second banked under BOTH ids is counted ONCE, with the primary's value. A naive
    /// `deviceId IN (…)` would count it twice — inflating n and skewing avg, plausibly enough that
    /// nothing would look wrong.
    func testOverlappingSecondsAreCountedOnceWithPrimaryWinning() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "A", mac: nil, name: nil)
        try await store.upsertDevice(id: "B", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: (0..<10).map { HRSample(ts: $0, bpm: 100) }), deviceId: "A")
        _ = try await store.insert(Streams(hr: (5..<20).map { HRSample(ts: $0, bpm: 200) }), deviceId: "B")

        let stats = try await store.hrWindowStats(primaryId: "A", secondaryId: "B", from: 0, to: 100)
        // ts 0..9 from A at 100, ts 10..19 from B at 200 — the 5..9 overlap resolves to A.
        XCTAssertEqual(stats.n, 20, "each second counted once; a naive IN(...) would give 25")
        XCTAssertEqual(try XCTUnwrap(stats.avg), 150.0, accuracy: 1e-9)
        XCTAssertEqual(stats.max, 200)
    }

    /// Precedence is the argument order, not the data: swapping the ids swaps which value wins the
    /// overlap, while the count stays the same.
    func testPrecedenceFollowsArgumentOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "A", mac: nil, name: nil)
        try await store.upsertDevice(id: "B", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: (0..<10).map { HRSample(ts: $0, bpm: 100) }), deviceId: "A")
        _ = try await store.insert(Streams(hr: (5..<20).map { HRSample(ts: $0, bpm: 200) }), deviceId: "B")

        let bFirst = try await store.hrWindowStats(primaryId: "B", secondaryId: "A", from: 0, to: 100)
        XCTAssertEqual(bFirst.n, 20, "same rows either way")
        // B now wins ts 5..9, so only ts 0..4 read 100.
        XCTAssertEqual(try XCTUnwrap(bFirst.avg), (5.0 * 100 + 15.0 * 200) / 20, accuracy: 1e-9)
    }

    /// The #841 PPG anti-join still holds PER ID: a measured second is never doubled by its own
    /// estimate, and a PPG-only second on the secondary still fills a gap the primary does not cover.
    func testPpgAntiJoinHoldsPerIdAcrossBothLegs() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "A", mac: nil, name: nil)
        try await store.upsertDevice(id: "B", mac: nil, name: nil)
        // A: measured 0..9 AND a PPG estimate on the same seconds — the anti-join must drop the PPG.
        _ = try await store.insert(
            Streams(hr: (0..<10).map { HRSample(ts: $0, bpm: 100) },
                    ppgHr: (0..<10).map { PpgHrSample(ts: $0, bpm: 180, conf: 0.9) }), deviceId: "A")
        // B: PPG only, on seconds A does not cover.
        _ = try await store.insert(
            Streams(ppgHr: (10..<15).map { PpgHrSample(ts: $0, bpm: 130, conf: 0.9) }), deviceId: "B")

        let stats = try await store.hrWindowStats(primaryId: "A", secondaryId: "B", from: 0, to: 100)
        XCTAssertEqual(stats.n, 15, "A's 10 measured (PPG suppressed) + B's 5 PPG-only")
        XCTAssertEqual(stats.max, 130, "A's 180 PPG estimates must not survive its own measured rows")
    }

    func testEventsDecodePayload() async throws {
        let store = try await seeded()
        let evs = try await store.events(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(evs, [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                        payload: ["k": .int(9)])])
    }

    func testBatterySamples() async throws {
        let store = try await seeded()
        let bat = try await store.batterySamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(bat, [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
    }

    func testStorageStats() async throws {
        let store = try await seeded()
        // Add one of each biometric stream so the count proves all 8 tables are summed.
        _ = try await store.insert(
            Streams(spo2: [SpO2Sample(ts: 400, red: 1, ir: 2)],
                    skinTemp: [SkinTempSample(ts: 400, raw: 930)],
                    resp: [RespSample(ts: 400, raw: 3073)],
                    gravity: [GravitySample(ts: 400, x: 0.1, y: 0.2, z: 0.3)]),
            deviceId: "dev1")
        try await store.enqueueRawBatch(
            RawBatchMeta(batchId: "b1", deviceId: "dev1",
                         clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1,
                         startTs: 0, endTs: 0, frameCount: 1, byteSize: 4),
            frames: [[0xAA, 0x00, 0x01, 0x02]])
        let stats = try await store.storageStats()
        // dev1: 3 hr + 2 rr + 1 event + 1 battery + 1 spo2 + 1 skinTemp + 1 resp + 1 gravity = 11
        // other: 1 hr = 1 → 12 decoded rows across all 8 tables.
        XCTAssertEqual(stats.decodedRows, 12)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 4)
    }
}
