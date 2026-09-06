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

    // #1392 — the CROSS-DEVICE change-detector the re-score gate must use: NO deviceId filter, so it folds
    // EVERY device's HR (dev1's 100/200/300 + the "other" decoy's 200). This is what lets a night landing
    // under a non-"my-whoop" id (an Oura ring, an Apple Watch, a re-added WHOOP) still advance the analyze
    // watermark — the device-scoped variant read 0 rows for such an install and the gate never fired.
    func testHrFingerprintCrossDeviceFoldsEveryDevice() async throws {
        let store = try await seeded()
        let fp = try await store.hrFingerprint()   // no deviceId → across all devices
        XCTAssertEqual(fp.count, 4)                 // dev1 (3) + "other" (1)
        XCTAssertEqual(fp.maxTs, 300)               // dev1's 300 > other's 200
        // Contrast: the device-scoped variant sees only dev1's rows — the #1392 blind spot when the pinned
        // id ("my-whoop") doesn't match where the HR actually landed.
        let scoped = try await store.hrFingerprint(deviceId: "dev1", from: 0, to: 9_999_999_999)
        XCTAssertEqual(scoped.count, 3)
    }

    /// Regression: motion can arrive after HR in a historical offload. The whole-pass watermark must move
    /// for that gravity-only commit or the first partial (no-sleep) result becomes sticky.
    func testAnalysisFingerprintMovesWhenSleepCriticalGravityArrivesAfterHr() async throws {
        let store = try await seeded()
        let hrOnly = try await store.analysisFingerprint()
        _ = try await store.insert(
            Streams(gravity: [GravitySample(ts: 400, x: 0, y: 0, z: 1)]),
            deviceId: "dev1"
        )
        let withGravity = try await store.analysisFingerprint()
        XCTAssertNotEqual(hrOnly, withGravity)
        XCTAssertTrue(withGravity.contains("|g1|"))
    }

    /// #29: the per-DAY twin of the test above. `analysisFingerprint` answers "did anything change
    /// anywhere"; the `analyzeRecent` reuse cache asks "did THIS night's scored input change", and keyed on
    /// HR alone it could not see a channel that landed after HR — so a night scored from HR alone kept
    /// being re-served with no HRV in it.
    ///
    /// Each stream is committed on its own here, because the failure mode IS independent commits: every one
    /// of them must move the witness while `hrFingerprint` stays frozen.
    func testDayStreamFingerprintMovesForEveryStreamThatLandsAfterHr() async throws {
        let store = try await seeded()
        let hrBefore = try await store.hrFingerprint(deviceId: "dev1", from: 0, to: 1000)
        var previous = try await store.dayStreamFingerprint(deviceId: "dev1", from: 0, to: 1000)

        // Every arm of the witness gets an entry: an arm that silently reads a NEIGHBOURING table is
        // valid SQL and invisible to a test that never commits its stream.
        let commits: [(String, Streams)] = [
            ("ppgHr", Streams(ppgHr: [PpgHrSample(ts: 401, bpm: 62, conf: 0.9)])),
            ("rr", Streams(rr: [RRInterval(ts: 400, rrMs: 810)])),
            ("resp", Streams(resp: [RespSample(ts: 400, raw: 12)])),
            ("spo2", Streams(spo2: [SpO2Sample(ts: 400, red: 100, ir: 200)])),
            ("gravity", Streams(gravity: [GravitySample(ts: 400, x: 0, y: 0, z: 1)])),
            ("steps", Streams(steps: [StepSample(ts: 400, counter: 7)])),
            ("skin", Streams(skinTemp: [SkinTempSample(ts: 400, raw: 1290)])),
            ("sleepState", Streams(sleepState: [SleepStateSample(ts: 400, state: 2)])),
            ("event", Streams(events: [WhoopEvent(ts: 410, kind: "WRIST_OFF", payload: [:])])),
        ]
        for (label, commit) in commits {
            _ = try await store.insert(commit, deviceId: "dev1")
            let now = try await store.dayStreamFingerprint(deviceId: "dev1", from: 0, to: 1000)
            XCTAssertNotEqual(previous, now, "a \(label) row landing after HR must move the day witness")
            previous = now
        }

        // The HR witness never moved across ANY of those commits — the reason HR alone was not enough.
        let hrAfter = try await store.hrFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(hrBefore.count, hrAfter.count)
        XCTAssertEqual(hrBefore.maxTs, hrAfter.maxTs)

        // Reading twice with nothing committed in between must be identical, or the reuse cache would
        // re-score every night on every pass and give back the drain it exists to close.
        let idle = try await store.dayStreamFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(previous, idle)
    }

    /// The witness is scoped exactly like the reads it stands in for: another device's rows and rows
    /// outside the night window must not move it, or every night would invalidate on any strap's traffic.
    func testDayStreamFingerprintIsDeviceAndWindowScoped() async throws {
        let store = try await seeded()
        let base = try await store.dayStreamFingerprint(deviceId: "dev1", from: 0, to: 1000)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 400, rrMs: 810)]), deviceId: "other")
        let afterOtherDevice = try await store.dayStreamFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(base, afterOtherDevice, "another device's R-R is not this owner's night")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 5000, rrMs: 810)]), deviceId: "dev1")
        let afterOutsideWindow = try await store.dayStreamFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(base, afterOutsideWindow, "an R-R beat outside the window is not this night's input")
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
        // #1008: `ord` is the per-TIMESTAMP occurrence counter assigned at write time, so two beats
        // stamped on the same second read back as 0 then 1. Asserting it here rather than dropping to a
        // field projection pins the property the `hrv rrsample` diagnostic depends on — one delivery
        // counts 0,1,2,…, whereas a second rebuilt across two offloads repeats (0,1,0,1).
        XCTAssertEqual(rr, [RRInterval(ts: 100, rrMs: 800, ord: 0),
                            RRInterval(ts: 100, rrMs: 820, ord: 1)])
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
        // Add one of each decoded raw stream so the count proves ALL of them are summed — including the
        // ones the old hand-listed footprint omitted (stepSample, sleepStateSample, ppgHrSample,
        // ppgWaveformSample, v18AuxSample, and rawImuSample below).
        _ = try await store.insert(
            Streams(spo2: [SpO2Sample(ts: 400, red: 1, ir: 2)],
                    skinTemp: [SkinTempSample(ts: 400, raw: 930)],
                    resp: [RespSample(ts: 400, raw: 3073)],
                    gravity: [GravitySample(ts: 400, x: 0.1, y: 0.2, z: 0.3)],
                    steps: [StepSample(ts: 400, counter: 5)],
                    sleepState: [SleepStateSample(ts: 400, state: 1)],
                    ppgHr: [PpgHrSample(ts: 400, bpm: 60, conf: 0.9)],
                    ppgWaveform: [PpgWaveformSample(ts: 400, samples: [1, 2, 3])],
                    v18Aux: [V18AuxSample(ts: 400, slotValues: [1, 2])]),
            deviceId: "dev1")
        // The raw outbox is Compression-backed and absent off Darwin; the DECODED half of this count is
        // platform-neutral and still worth asserting there, so only the raw seeding is gated.
#if canImport(Compression)
        try await store.enqueueRawBatch(
            RawBatchMeta(batchId: "b1", deviceId: "dev1",
                         clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1,
                         startTs: 0, endTs: 0, frameCount: 1, byteSize: 4),
            frames: [[0xAA, 0x00, 0x01, 0x02]])
#endif
        let stats = try await store.storageStats()
        // dev1: 3 hr + 2 rr + 1 event + 1 battery + 1 spo2 + 1 skinTemp + 1 resp + 1 gravity
        //       + 1 step + 1 sleepState + 1 ppgHr + 1 ppgWaveform + 1 v18Aux = 16
        // other: 1 hr = 1 → 17 decoded rows.
        XCTAssertEqual(stats.decodedRows, 17)
#if canImport(Compression)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 4)
#endif
    }

    /// #1911: the footprint must name EVERY accumulating table, including the four the Apple probe used
    /// to omit — `ppgHr`, `sleepState`, `ppgWaveform`, `v18Aux`. Those are the ones a row-count model
    /// misprices worst (`ppgWaveformSample` is the only blob table), so leaving them out made the
    /// footprint unable to attribute the bytes it was collected to explain.
    ///
    /// Pinned against the Android key set verbatim: a maintainer comparing meta.json across platforms is
    /// comparing the same map, and a table added to one side without the other shows up here.
    func testStorageRowCountsNamesEveryAccumulatingTable() async throws {
        let store = try await WhoopStore.inMemory()
        let counts = try await store.storageRowCounts()
        let expected = ["hr", "rr", "events", "battery", "spo2", "skinTemp", "resp", "gravity",
                        "steps", "ppgHr", "sleepState", "ppgWaveform", "v18Aux"]
        XCTAssertEqual(Set(counts.keys), Set(expected),
                       "key set must match Android's WhoopRepository.storageRowCounts exactly")
        for k in expected {
            XCTAssertEqual(counts[k], 0, "\(k) starts empty in a fresh store")
        }
    }

    /// The total and the breakdown are derived from ONE list, so they cannot disagree about which tables
    /// exist. Pinned because they used to be two hand-maintained lists, and the older one had already
    /// drifted once — the comment on `storageStats` records it omitting six tables.
    func testStorageStatsTotalAgreesWithTheBreakdown() async throws {
        let store = try await seeded()
        let counts = try await store.storageRowCounts()
        let stats = try await store.storageStats()
        XCTAssertEqual(stats.decodedRows, counts.values.reduce(0, +),
                       "the summed total must equal the per-table breakdown")
    }


    /// #1911: the byte estimate must MEASURE the blob rather than assume a fixed row width.
    /// `ppgWaveformSample` is the only table here whose row size varies, and the one a per-second row
    /// model misprices worst — a footprint that treats every row as fixed-width answers the wrong question
    /// about exactly the table the question is usually about.
    ///
    /// Pinned by GROWING the blob rather than by comparing tables. My first attempt asserted that a blob
    /// row estimates larger than an all-numeric row, which is false on a fixture: with a three-sample
    /// blob `ppgWaveformSample` is three columns to `hrSample`'s four, so it estimates SMALLER. The blob
    /// dominates in production (~48 bytes per v26 strap-second), not in a seed — so the invariant worth
    /// pinning is that the blob's length reaches the estimate at all, which comparing two blob sizes
    /// establishes and comparing two tables does not.
    func testStorageByteEstimatesGrowWithBlobLength() async throws {
        func estimate(sampleCount: Int) async throws -> Int {
            let store = try await WhoopStore.inMemory()
            let samples = [Int](repeating: 7, count: sampleCount)
            _ = try await store.insert(Streams(ppgWaveform: [PpgWaveformSample(ts: 400, samples: samples)]),
                                       deviceId: "dev1")
            return try await store.storageByteEstimates()["ppgWaveform"] ?? 0
        }
        let small = try await estimate(sampleCount: 4)      // ~8 bytes packed i16
        let large = try await estimate(sampleCount: 200)    // ~400 bytes packed i16
        XCTAssertGreaterThan(small, 0, "the blob table must be estimated, not skipped")
        XCTAssertGreaterThan(large, small + 300,
                             "a 400-byte blob must estimate far above an 8-byte one, or the blob is not measured")
    }

    /// An empty table is omitted rather than reported as zero bytes, matching the row counts: absent means
    /// "nothing to attribute here", which is a different claim from a measured zero.
    func testStorageByteEstimatesOmitEmptyTables() async throws {
        let store = try await WhoopStore.inMemory()
        let bytes = try await store.storageByteEstimates()
        XCTAssertTrue(bytes.isEmpty, "a fresh store has no rows, so nothing to estimate")
    }


    /// Passing known counts must not change the answer — it only skips a second `COUNT(*)` pass. Pinned
    /// because the whole point of the parameter is that it is an optimisation, and an optimisation that
    /// quietly changes the number it optimises is worse than the scan it saves.
    func testStorageByteEstimatesAreUnchangedByPassingKnownCounts() async throws {
        let store = try await seeded()
        let counts = try await store.storageRowCounts()
        let computed = try await store.storageByteEstimates()
        let reused = try await store.storageByteEstimates(rowCounts: counts)
        XCTAssertEqual(computed, reused)
    }

    /// The raw-outbox read must agree with the aggregate it was split out of, or the probe's rawBytes
    /// silently changed meaning when it stopped counting thirteen decoded tables to get one number.
    ///
    /// They share one implementation now rather than being two copies this test compares — `syncRead` is
    /// `dbWriter.read` and nesting one inside another deadlocks, so a plain `db`-taking helper is the only
    /// way to share it. The assertion stays as the guard on that wiring.
    func testRawOutboxStatsMatchTheAggregate() async throws {
        let store = try await seeded()
        let stats = try await store.storageStats()
        let outbox = try await store.rawOutboxStats()
        XCTAssertEqual(outbox.batches, stats.rawBatches)
        XCTAssertEqual(outbox.bytes, stats.rawBytes)
    }


    /// A negative sample limit must not become an unbounded scan. SQLite reads `LIMIT -1` as "no limit",
    /// so an unchecked value would full-scan every table — the exact cost the sampling exists to avoid,
    /// reached by passing a number that looks like it would sample less rather than more.
    func testStorageByteEstimatesClampANegativeSampleLimit() async throws {
        let store = try await seeded()
        let normal = try await store.storageByteEstimates()
        let negative = try await store.storageByteEstimates(sampleRows: -1)
        XCTAssertEqual(negative.keys.sorted(), normal.keys.sorted())
        for (k, v) in negative { XCTAssertGreaterThan(v, 0, "\(k) must still estimate") }
    }

}
