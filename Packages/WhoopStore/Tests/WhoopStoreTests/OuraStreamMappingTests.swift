import XCTest
import WhoopProtocol
import OuraProtocol
@testable import WhoopStore

final class OuraStreamMappingTests: XCTestCase {
    private let ts = 1_750_000_000

    // MARK: - HR 0x55 -> hr:[HRSample]

    func testHRMapsToHRStreamStampedAtArrival() {
        let s = OuraStreamMapping.streams(from: [
            .hr(OuraHR(ringTimestamp: 100, bpm: 58, ibiMs: 1034)),
            .hr(OuraHR(ringTimestamp: 101, bpm: 60, ibiMs: 1000)),
        ], at: ts)
        XCTAssertEqual(s.hr.map { $0.bpm }, [58, 60])
        XCTAssertEqual(s.hr.map { $0.ts }, [ts, ts])
        // The HR push also carries one IBI, but RR comes only from .ibi events -> no double-count.
        XCTAssertTrue(s.rr.isEmpty)
    }

    // MARK: - IBI 0x44/0x60 -> rr:[RRInterval]

    func testIBIMapsToRRStream() {
        let s = OuraStreamMapping.streams(from: [
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 820)),
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 815, amplitude: 42)),
        ], at: ts)
        XCTAssertEqual(s.rr.map { $0.rrMs }, [820, 815])
        XCTAssertEqual(s.rr.map { $0.ts }, [ts, ts])
        XCTAssertTrue(s.hr.isEmpty)
    }

    // MARK: - HRV 0x5D -> events[OURA_HRV] with RAW, units-neutral payload (no fabricated rmssd_ms)

    func testHRVMapsToEventWithRawNeutralPayload() {
        let s = OuraStreamMapping.streams(from: [
            .hrv(OuraHRV(ringTimestamp: 100, timeMs: 5000, b1: 47, b2: 3)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 1)
        let ev = s.events[0]
        XCTAssertEqual(ev.kind, OuraStreamMapping.hrvEventKind)
        XCTAssertEqual(ev.kind, "OURA_HRV")
        XCTAssertEqual(ev.ts, ts)
        // HONEST: the ring's OWN raw tag fields only; the b1/b2 byte -> ms scale is not Tier-A, so we
        // NEVER surface a fabricated rmssd_ms. Keys + values match the Kotlin twin exactly.
        XCTAssertNil(ev.payload["rmssd_ms"], "must not fabricate rmssd_ms")
        XCTAssertEqual(ev.payload["time_ms"], .int(5000))
        XCTAssertEqual(ev.payload["b1"], .int(47))
        XCTAssertEqual(ev.payload["b2"], .int(3))
    }

    // MARK: - Motion 0x47 -> events[OURA_MOTION]

    func testMotionMapsToOuraMotionEvent() {
        let s = OuraStreamMapping.streams(from: [
            .motionEvent(OuraMotionEvent(ringTimestamp: 100, orientation: 5, motionSeconds: 21,
                                         avgX: -96, avgY: 0, avgZ: -1024, lowIntensity: 42, highIntensity: 63)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 1)
        let ev = s.events[0]
        XCTAssertEqual(ev.kind, OuraStreamMapping.motionEventKind)
        XCTAssertEqual(ev.kind, "OURA_MOTION")
        XCTAssertEqual(ev.ts, ts)
        // The ring's OWN per-window motion summary; keys/values must match the Kotlin twin exactly.
        XCTAssertEqual(ev.payload["orientation"], .int(5))
        XCTAssertEqual(ev.payload["motion_seconds"], .int(21))
        XCTAssertEqual(ev.payload["x"], .int(-96))
        XCTAssertEqual(ev.payload["y"], .int(0))
        XCTAssertEqual(ev.payload["z"], .int(-1024))
        XCTAssertEqual(ev.payload["low_intensity"], .int(42))
        XCTAssertEqual(ev.payload["high_intensity"], .int(63))
    }

    func testMotionShortRecordOmitsIntensityKeys() {
        // A short (4-byte) record decodes with nil low/high — the keys are ABSENT, never faked to 0.
        let s = OuraStreamMapping.streams(from: [
            .motionEvent(OuraMotionEvent(ringTimestamp: 100, orientation: 1, motionSeconds: 0,
                                         avgX: 80, avgY: 0, avgZ: 0, lowIntensity: nil, highIntensity: nil)),
        ], at: ts)
        let ev = s.events[0]
        XCTAssertEqual(ev.payload["motion_seconds"], .int(0))
        XCTAssertNil(ev.payload["low_intensity"], "absent intensity must not be faked")
        XCTAssertNil(ev.payload["high_intensity"], "absent intensity must not be faked")
    }

    // MARK: - SpO2 -> spo2:[SpO2Sample]

    func testSpO2MapsToSpO2StreamPreservingUnit() {
        let s = OuraStreamMapping.streams(from: [
            .spo2(OuraSpO2(ringTimestamp: 100, value: 970, unit: "raw")),
            .spo2(OuraSpO2(ringTimestamp: 101, value: 12345, unit: "dc_raw")),
        ], at: ts)
        XCTAssertEqual(s.spo2.map { $0.red }, [970, 12345])
        XCTAssertEqual(s.spo2.map { $0.ir }, [0, 0])
        XCTAssertEqual(s.spo2.map { $0.unit }, ["raw", "dc_raw"])
        // Single-sample records (count == 1) keep the record's own second, exactly as before #1070.
        XCTAssertEqual(s.spo2.map { $0.ts }, [ts, ts])
    }

    // #1070: `spo2Sample` is keyed (deviceId, ts). A 0x6F record's 13 per-second samples used to be
    // written at the record's single `ts`, so twelve collided away on insert and the night was stored at
    // 1/13 resolution — permanently, since the ring trims its banked history once the offload is acked.
    func testSpO2PerSampleRecordGetsThirteenDistinctSeconds() {
        let n = 13
        let events = (0..<n).map {
            OuraEvent.spo2(OuraSpO2(ringTimestamp: 100, value: 950 + $0, unit: "raw", index: $0, count: n))
        }
        let s = OuraStreamMapping.streams(from: events, at: ts)

        XCTAssertEqual(s.spo2.count, n)
        // Thirteen DISTINCT seconds: nothing can collide on the primary key.
        XCTAssertEqual(Set(s.spo2.map { $0.ts }).count, n, "every sample must land on its own second")
        // Laid BACKWARD at 1 s from the record anchor, so the LAST sample keeps the record's own ts.
        XCTAssertEqual(s.spo2.map { $0.ts }, Array((ts - n + 1)...ts))
        XCTAssertEqual(s.spo2.last?.ts, ts, "the record anchor is unchanged: it is the last sample")
        // Order is preserved, so sample i still carries sample i's value.
        XCTAssertEqual(s.spo2.map { $0.red }, (0..<n).map { 950 + $0 })
    }

    func testSpO2AdjacentRecordsTileAtTheNominalCadence() {
        // Packets arrive ~13 s apart carrying 13 values, so back-laying tiles the interval exactly:
        // at the NOMINAL cadence consecutive records produce a gapless, non-overlapping series.
        // The tight tail is covered separately below.
        let n = 13
        let first = (0..<n).map {
            OuraEvent.spo2(OuraSpO2(ringTimestamp: 100, value: 950, unit: "raw", index: $0, count: n))
        }
        let second = (0..<n).map {
            OuraEvent.spo2(OuraSpO2(ringTimestamp: 113, value: 960, unit: "raw", index: $0, count: n))
        }
        let a = OuraStreamMapping.streams(from: first, at: ts).spo2.map { $0.ts }
        let b = OuraStreamMapping.streams(from: second, at: ts + 13).spo2.map { $0.ts }
        XCTAssertEqual(Set(a).intersection(Set(b)).count, 0, "adjacent records must not overlap")
        XCTAssertEqual(a + b, Array((ts - n + 1)...(ts + 13)), "and must tile without a gap")
    }

    func testSpO2TightCadenceOverlapsByExactlyOneSecond() {
        // The cadence has a tight tail (p10 12 s). Back-laying 13 samples from a record only 12 s after
        // the previous one makes the newer record's FIRST second equal the older record's LAST — one
        // sample lost at that boundary on the (deviceId, ts) key. That is bounded and expected, not a
        // regression: measured over a real overnight it costs 0.84 % of samples, against 92.3 % before.
        // This test pins the bound at ONE second so a future change to the lay cannot widen it silently.
        let n = 13
        let first = (0..<n).map {
            OuraEvent.spo2(OuraSpO2(ringTimestamp: 100, value: 950, unit: "raw", index: $0, count: n))
        }
        let second = (0..<n).map {
            OuraEvent.spo2(OuraSpO2(ringTimestamp: 112, value: 960, unit: "raw", index: $0, count: n))
        }
        let a = OuraStreamMapping.streams(from: first, at: ts).spo2.map { $0.ts }
        let b = OuraStreamMapping.streams(from: second, at: ts + 12).spo2.map { $0.ts }
        XCTAssertEqual(Set(a).intersection(Set(b)), [ts], "exactly one second overlaps, the older anchor")
        XCTAssertEqual(Set(a).union(Set(b)).count, 2 * n - 1, "so 25 distinct seconds carry 26 samples")
    }

    // MARK: - Temp 0x46/0x75 -> skinTemp:[SkinTempSample] (centi-degree-C, parity with Kotlin)

    func testTempMapsToSkinTempAsCentiC() {
        let s = OuraStreamMapping.streams(from: [
            .temp(OuraTemp(ringTimestamp: 100, celsius: 33.25)),
        ], at: ts)
        XCTAssertEqual(s.skinTemp.count, 1)
        // Centi-degree-C: the codebase-wide raw convention (AnalyticsEngine divides raw by 100).
        // 33.25 °C -> 3325. The Kotlin twin must produce the IDENTICAL raw integer for the same celsius.
        XCTAssertEqual(s.skinTemp[0].raw, 3325)
        XCTAssertEqual(s.skinTemp[0].unit, "centi_c")
        XCTAssertEqual(s.skinTemp[0].ts, ts)
    }

    // MARK: - Sleep phase -> events[OURA_SLEEP_PHASE]

    func testSleepPhaseMapsToEventWithPhaseCode() {
        // Raw codes persist per open_oura's validated mapping (deep=0, light=1, rem=2, awake=3). Each
        // code arrives with its RECONSTRUCTED ts (30 s-spaced by OuraHypnogramAssembler upstream), so
        // the mapping stores the given ts verbatim — no synthetic index offset.
        let s = OuraStreamMapping.streams(from: [
            .sleepPhase(OuraSleepPhase(ringTimestamp: 100, index: 0, stage: .deep)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: 100, index: 1, stage: .rem)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 2)
        XCTAssertTrue(s.events.allSatisfy { $0.kind == OuraStreamMapping.sleepPhaseEventKind })
        XCTAssertEqual(s.events.map { $0.payload["phase"] }, [.int(0), .int(2)])
        XCTAssertEqual(s.events.map { $0.payload["index"] }, [.int(0), .int(1)])
        XCTAssertEqual(s.events.map { $0.ts }, [ts, ts], "ts is stored verbatim; spacing happens upstream")
    }

    // MARK: - Battery -> battery:[BatterySample]

    func testBatteryMapsToBatterySample() {
        let s = OuraStreamMapping.streams(from: [
            .battery(OuraBattery(percent: 74, voltageMv: 4012, charging: false)),
        ], at: ts)
        XCTAssertEqual(s.battery.count, 1)
        XCTAssertEqual(s.battery[0].soc, 74)
        XCTAssertEqual(s.battery[0].mv, 4012)
        XCTAssertEqual(s.battery[0].charging, false)
        XCTAssertEqual(s.battery[0].ts, ts)
    }

    func testBatteryWithoutVoltageOrChargingStaysNil() {
        let s = OuraStreamMapping.streams(from: [
            .battery(OuraBattery(percent: 50)),
        ], at: ts)
        XCTAssertEqual(s.battery[0].soc, 50)
        XCTAssertNil(s.battery[0].mv)
        XCTAssertNil(s.battery[0].charging)
    }

    // MARK: - Honest-data invariant: Tier-B + non-stream events never land in Streams

    func testTierBAndDiagnosticEventsAreDropped() {
        let s = OuraStreamMapping.streams(from: [
            .tierB(OuraTierBSummary(tag: 0x6A, ringTimestamp: 100, rawPayload: [1, 2, 3], kind: "sleep_summary")),
            .motion(OuraMotion(ringTimestamp: 100, index: 0, state: .active)),
            .state(OuraState(ringTimestamp: 100, stateCode: 1)),
            .timeSync(OuraTimeSync(ringTimestamp: 100, epochMs: 1_750_000_000_000, tzOffsetSeconds: 0)),
            .rtcBeacon(OuraRtcBeacon(ringTimestamp: 100, unixSeconds: 1_750_000_000)),
            .debugText(ringTimestamp: 100, text: "console"),
            // 0x50 activity/MET (PR #960): decoded but Tier-B/unvalidated - in particular it must never
            // mint a `steps` row (MET is not a step count; the per-source day-owner rules stay intact).
            .activityInfo(OuraActivityInfo(ringTimestamp: 100, state: 0x41, met: [1.8, 1.9])),
        ], at: ts)
        XCTAssertTrue(s.isEmpty, "Tier-B and diagnostic events must not produce any durable stream row")
        XCTAssertTrue(s.steps.isEmpty, "activity/MET must never fabricate a steps row")
    }

    // MARK: - Batching a record's events into one insert (#1072, root cause for #823)

    /// The defect's shape: the store's `ord` counter is batch-local, so a record's beats only get a
    /// real emission order if they reach the store TOGETHER. Grouping is by the resolved second.
    func testBatchedGroupsOneRecordsBeatsIntoASingleBatch() {
        let beats = [812, 795, 840, 801, 833]
        let batches = OuraStreamMapping.batched(beats.map {
            (event: OuraEvent.ibi(OuraIBI(ringTimestamp: 100, ibiMs: $0)), ts: ts)
        })
        XCTAssertEqual(batches.count, 1, "one record's beats must be ONE batch, not five")
        XCTAssertEqual(batches[0].ts, ts)
        XCTAssertEqual(batches[0].events.count, beats.count)
        // Emission order inside the batch is the whole point — it is what `ord` will record.
        let rr = OuraStreamMapping.streams(from: batches[0].events, at: batches[0].ts).rr
        XCTAssertEqual(rr.map { $0.rrMs }, beats)
    }

    /// Two records anchored to different seconds stay separate batches, in the order they arrived —
    /// `ord` numbers beats within a second, so merging distinct seconds would mean nothing.
    func testBatchedKeepsDistinctTimestampsSeparateAndInArrivalOrder() {
        let batches = OuraStreamMapping.batched([
            (event: .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 800)), ts: ts + 3),
            (event: .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 810)), ts: ts + 3),
            (event: .ibi(OuraIBI(ringTimestamp: 200, ibiMs: 900)), ts: ts),
        ])
        XCTAssertEqual(batches.map { $0.ts }, [ts + 3, ts],
                       "timestamps keep first-appearance order, they are not re-sorted")
        XCTAssertEqual(batches.map { $0.events.count }, [2, 1])
    }

    /// Same-second events that arrive interleaved with other seconds still land in one batch, and
    /// their relative order is preserved — the store may never see a second's beats twice.
    func testBatchedFoldsInterleavedSameSecondEventsIntoOneBatch() {
        let batches = OuraStreamMapping.batched([
            (event: .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 800)), ts: ts),
            (event: .ibi(OuraIBI(ringTimestamp: 200, ibiMs: 900)), ts: ts + 1),
            (event: .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 810)), ts: ts),
        ])
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(OuraStreamMapping.streams(from: batches[0].events, at: ts).rr.map { $0.rrMs },
                       [800, 810])
    }

    func testBatchedOnEmptyInputYieldsNoBatches() {
        XCTAssertTrue(OuraStreamMapping.batched([]).isEmpty)
    }

    // MARK: - Empty batch + multi-signal batch

    func testEmptyBatchYieldsEmptyStreams() {
        XCTAssertTrue(OuraStreamMapping.streams(from: [], at: ts).isEmpty)
    }

    func testMixedBatchPopulatesEachStreamIndependently() {
        let s = OuraStreamMapping.streams(from: [
            .hr(OuraHR(ringTimestamp: 1, bpm: 55, ibiMs: 1090)),
            .ibi(OuraIBI(ringTimestamp: 1, ibiMs: 1090)),
            .hrv(OuraHRV(ringTimestamp: 1, timeMs: 0, b1: 40, b2: 1)),
            .spo2(OuraSpO2(ringTimestamp: 1, value: 965)),
            .temp(OuraTemp(ringTimestamp: 1, celsius: 34.0)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: 1, index: 0, stage: .light)),
            .battery(OuraBattery(percent: 88)),
        ], at: ts)
        XCTAssertEqual(s.hr.count, 1)
        XCTAssertEqual(s.rr.count, 1)
        XCTAssertEqual(s.spo2.count, 1)
        XCTAssertEqual(s.skinTemp.count, 1)
        XCTAssertEqual(s.battery.count, 1)
        // HRV + sleep-phase both ride the events stream.
        XCTAssertEqual(s.events.count, 2)
        // Streams never decoded by the Oura source stay empty (honest, never faked).
        XCTAssertTrue(s.resp.isEmpty)
        XCTAssertTrue(s.gravity.isEmpty)
        XCTAssertTrue(s.steps.isEmpty)
        XCTAssertTrue(s.ppgHr.isEmpty)
    }
}
