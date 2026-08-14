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

    // MARK: - HRV 0x5D -> events[OURA_HRV] with honest hr_bpm / rmssd_ms (layout pinned)

    func testHRVMapsToEventWithHrAndRmssd() {
        let s = OuraStreamMapping.streams(from: [
            .hrv(OuraHRV(ringTimestamp: 100, index: 0, hrBpm: 52, rmssdMs: 47)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 1)
        let ev = s.events[0]
        XCTAssertEqual(ev.kind, OuraStreamMapping.hrvEventKind)
        XCTAssertEqual(ev.kind, "OURA_HRV")
        // #1167: a 1-pair record's single bucket is the span [ts-300, ts) — its five minutes END at the
        // record time, so it is stamped 300 s before it.
        XCTAssertEqual(ev.ts, ts - 300)
        // The byte->unit scaling is now pinned (u8 bpm, u8 ms), so the fields are honestly labelled.
        // Keys + values match the Kotlin twin exactly.
        XCTAssertEqual(ev.payload["pair_index"], .int(0))
        XCTAssertEqual(ev.payload["hr_bpm"], .int(52))
        XCTAssertEqual(ev.payload["rmssd_ms"], .int(47))
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

    // MARK: - HRV 0x5D -> events (per-bucket 5-min timestamps)

    // Each 5-min bucket must land on its OWN timestamp: the event key is (deviceId, ts, kind), so pairs
    // sharing the record `ts` would collide on insert and only one survive. #1167: the record's FIRST pair
    // is its OLDEST bucket and the record `ts` marks the END of the covered span, so pair `index` sits
    // `(count - index) * 300` s before `ts` and the LAST pair's five minutes end exactly at `ts`.
    // Twin of the Kotlin OuraStreamMapping test.
    func testHRVMultiBucketGetsDistinctFiveMinTimestamps() {
        let s = OuraStreamMapping.streams(from: [
            .hrv(OuraHRV(ringTimestamp: 100, index: 0, hrBpm: 52, rmssdMs: 47, count: 3)),
            .hrv(OuraHRV(ringTimestamp: 100, index: 1, hrBpm: 54, rmssdMs: 44, count: 3)),
            .hrv(OuraHRV(ringTimestamp: 100, index: 2, hrBpm: 55, rmssdMs: 41, count: 3)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 3)
        // Distinct, 300 s apart, ascending in time, ending at the record time.
        XCTAssertEqual(s.events.map { $0.ts }, [ts - 900, ts - 600, ts - 300])
        XCTAssertEqual(Set(s.events.map { $0.ts }).count, 3)
        XCTAssertEqual(s.events.map { $0.payload["pair_index"] }, [.int(0), .int(1), .int(2)])
        XCTAssertEqual(s.events.map { $0.payload["hr_bpm"] }, [.int(52), .int(54), .int(55)])
        XCTAssertEqual(s.events.map { $0.payload["rmssd_ms"] }, [.int(47), .int(44), .int(41)])
    }

    // #1167 + #1131 together: a dropped `00 00` pad must still be COUNTED, or every surviving bucket in
    // that record slides. Here the record had 4 pairs and the decoder dropped index 1, so the survivors
    // must keep the exact slots they would have had with the pad present — a 300 s hole at `ts - 600`,
    // NOT three buckets closing up. This is the mid-record shape observed in the field on 2026-08-08.
    func testHRVDroppedPaddingPairStillConsumesItsSlot() {
        let s = OuraStreamMapping.streams(from: [
            .hrv(OuraHRV(ringTimestamp: 100, index: 0, hrBpm: 52, rmssdMs: 47, count: 4)),
            // index 1 was the `00 00` pad — never emitted by the decoder.
            .hrv(OuraHRV(ringTimestamp: 100, index: 2, hrBpm: 55, rmssdMs: 41, count: 4)),
            .hrv(OuraHRV(ringTimestamp: 100, index: 3, hrBpm: 56, rmssdMs: 39, count: 4)),
        ], at: ts)
        XCTAssertEqual(s.events.map { $0.ts }, [ts - 1200, ts - 600, ts - 300])
        XCTAssertEqual(s.events.map { $0.payload["pair_index"] }, [.int(0), .int(2), .int(3)])
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
            // 0x7E/0x7F real_steps_features: decoded but Tier-B - must never mint a `steps` row either.
            // Ground truth showed no field is a count; they are model inputs (see OuraRealStepsFields).
            .realStepsFields(OuraRealStepsFields(tag: 0x7E, ringTimestamp: 100, fields: Array(0..<14))),
        ], at: ts)
        XCTAssertTrue(s.isEmpty, "Tier-B and diagnostic events must not produce any durable stream row")
        XCTAssertTrue(s.steps.isEmpty, "activity/MET/real_steps must never fabricate a steps row")
    }

    // MARK: - 0x6A sleep_period_info → respiration instrumentation

    /// `breath` becomes ONE `resp` row, in milli-bpm, at the record's own ts — and nothing else about
    /// the record reaches a durable stream. The other fields are the whole reason the record was
    /// dropped wholesale before: `averageHrBpm` at a ~5-min cadence would sit in the same series as the
    /// beat-derived HR channel with no way to tell them apart afterwards.
    func testSleepPeriodInfoMapsBreathToRespirationAndNothingElse() {
        let s = OuraStreamMapping.streams(from: [
            .sleepPeriodInfo(OuraSleepPeriodInfo(ringTimestamp: 100, averageHrBpm: 53.0, hrTrend: -0.625,
                                                 mzci: 3.75, dzci: 1.75, breathsPerMin: 14.375,
                                                 breathVariability: 4.625, motionCount: 0, sleepState: 1,
                                                 cv: 0.25)),
        ], at: ts)
        XCTAssertEqual(s.resp.count, 1)
        XCTAssertEqual(s.resp[0].ts, ts)
        XCTAssertEqual(s.resp[0].raw, 14_375, "breath is stored in milli-bpm, exactly (14.375 → 14375)")
        XCTAssertEqual(s.resp[0].unit, "milli_bpm")
        XCTAssertTrue(s.hr.isEmpty, "0x6A average_hr must never land in the beat-derived HR series")
        XCTAssertTrue(s.rr.isEmpty)
        XCTAssertTrue(s.events.isEmpty, "no event row: breath is a stream value, the rest stays in the log")
        XCTAssertTrue(s.steps.isEmpty)
        XCTAssertTrue(s.skinTemp.isEmpty)
        XCTAssertTrue(s.spo2.isEmpty)
    }

    /// Every value the wire can express survives the round trip exactly — the point of the milli scale.
    /// The field is a `u8 / 8`, so the whole alphabet is 0…31.875 bpm in 0.125 steps.
    func testEveryWireBreathValueRoundTripsExactly() {
        for byte in 0...255 {
            let bpm = Double(byte) / 8.0
            let s = OuraStreamMapping.streams(from: [
                .sleepPeriodInfo(OuraSleepPeriodInfo(ringTimestamp: 100, averageHrBpm: 53.0, hrTrend: 0,
                                                     mzci: 0, dzci: 0, breathsPerMin: bpm,
                                                     breathVariability: 0, motionCount: 0, sleepState: 0,
                                                     cv: 0)),
            ], at: ts)
            XCTAssertEqual(s.resp[0].raw, byte * 125, "raw must be the wire byte × 125, losslessly")
            XCTAssertEqual(OuraRespScale.breathsPerMin(raw: s.resp[0].raw), bpm, accuracy: 1e-12)
        }
    }

    /// Each record keeps its OWN anchored second, so a night's ~5-min windows land where they were
    /// measured. The rows are keyed (deviceId, ts), so two records sharing a second would collapse to
    /// one — the failure mode that cost 92 % of an overnight's SpO2 before #1070.
    func testSleepPeriodInfoRecordsKeepTheirOwnTimestamps() {
        let batches = [(ts, 14.375), (ts + 296, 14.5), (ts + 592, 15.0)]
        var rows: [RespSample] = []
        for (at, bpm) in batches {
            rows += OuraStreamMapping.streams(from: [
                .sleepPeriodInfo(OuraSleepPeriodInfo(ringTimestamp: 100, averageHrBpm: 53.0, hrTrend: 0,
                                                     mzci: 0, dzci: 0, breathsPerMin: bpm,
                                                     breathVariability: 0, motionCount: 0, sleepState: 0,
                                                     cv: 0)),
            ], at: at).resp
        }
        XCTAssertEqual(rows.map(\.ts), [ts, ts + 296, ts + 592])
        XCTAssertEqual(rows.map(\.raw), [14_375, 14_500, 15_000])
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
            .hrv(OuraHRV(ringTimestamp: 1, index: 0, hrBpm: 40, rmssdMs: 1)),
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
