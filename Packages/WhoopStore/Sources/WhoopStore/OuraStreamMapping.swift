import Foundation
import WhoopProtocol
import OuraProtocol

/// Pure, testable mapping from a batch of decoded `OuraEvent` (emitted by `OuraProtocol.OuraDriver`)
/// onto the datastore's `Streams` shape, so the isolated live Oura source (`OuraLiveSource` in the app
/// target) can persist its samples through the SAME `StreamStore.insert` path the WHOOP pipeline uses,
/// keyed by the ring's own `deviceId`, without duplicating row-construction logic in the app target
/// where it can't be unit-tested. Parallels `StandardHRMapping`.
///
/// Honest-data invariant (hard): we surface only the ring's decoded raw signals + its own open event
/// tags (HR/IBI/HRV/SpO2/temp/sleep-phase/battery). We NEVER read or surface Oura's encrypted readiness
/// or sleep scores. NOOP computes its own Charge/Rest downstream from these per-device streams. The
/// `OuraHRV` 0x5D tag is the ring's OWN RMSSD-derived HRV signal (OURA_PROTOCOL.md s6.9), not a readiness
/// score; NOOP also independently reconstructs RMSSD from the IBI streams for its own scoring.
///
/// Timestamping: the live source streams a batch and stamps every row at the arrival wall-clock `ts`
/// (unix seconds), exactly as `StandardHRMapping.samples(...at:)` does. The decoded events carry only a
/// ring-clock `ringTimestamp` (a `(session << 16) | counter` value, NOT wall-clock), so anchoring is the
/// transport's job; the mapping stays pure and deterministic by taking the wall-clock `ts` as input. A
/// signal that could not be decoded never reaches this layer (the decoders return nil upstream), so a
/// missing stream stays empty here, never faked (Huami precedent).
///
/// Tier-B (UNVERIFIED) events are dropped: only Tier-A decoded signals map into `Streams`, so an
/// unverified summary can never silently feed scoring.
public enum OuraStreamMapping {
    /// WhoopEvent.kind for the ring's own HRV 0x5D tag. The payload carries the RAW decoded fields
    /// (`time_ms`/`b1`/`b2`) only, never a fabricated `rmssd_ms` (the b1/b2 byte -> ms scale is not
    /// Tier-A; see OURA_PROTOCOL.md s6.9). Must match the Kotlin twin (OuraStreamMapping.kt) exactly.
    public static let hrvEventKind = "OURA_HRV"
    /// WhoopEvent.kind for a decoded sleep-phase code (2-bit: awake/light/deep/rem).
    public static let sleepPhaseEventKind = "OURA_SLEEP_PHASE"
    /// WhoopEvent.kind for a decoded 0x47 motion_events window (open_oura `decode_motion`). The payload
    /// carries the ring's OWN per-window motion summary — `orientation` / `motion_seconds` / `x` / `y` / `z`
    /// (avg accel ×8) / `low_intensity` / `high_intensity` (the last two absent on a short record). This is
    /// INSTRUMENTATION: an honest activity signal, never scored and never fed to the sleep stager (0x47 is
    /// movement-gated — a shape mismatch for the gravity-stillness stager, #804). Must match the Kotlin twin.
    public static let motionEventKind = "OURA_MOTION"

    /// Build a `Streams` from a batch of decoded Oura events, all stamped at the arrival wall-clock `ts`
    /// (unix seconds). Pure → unit-testable. Section-4 table:
    ///   - `.hr`         (0x55 live-HR push)            → `hr:[HRSample]`
    ///   - `.ibi`        (0x44/0x60 IBI)                → `rr:[RRInterval]`
    ///   - `.hrv`        (0x5D HRV tag, raw int8 b1/b2)  → `events:[WhoopEvent(kind: OURA_HRV)]`
    ///   - `.spo2`       (0x6F/0x70/0x77)              → `spo2:[SpO2Sample]`, carrying the decoder's own
    ///     `unit` tag. NOT all one quantity: 0x6F/0x70 are firmware-computed PERCENTAGES (tagged `"raw"`,
    ///     a legacy channel label — see `OuraDecoders.decodeSpO2PerSample`), while 0x77 is a genuine raw
    ///     DC channel tagged `"dc_raw"`. Both land in `SpO2Sample.red`; neither is written to `spo2Pct`.
    ///   - `.temp`       (0x46/0x75)                    → `skinTemp:[SkinTempSample(raw_adc)]`
    ///   - `.sleepPhase` (0x4E/0x5A 2-bit codes)        → `events:[WhoopEvent(kind: OURA_SLEEP_PHASE)]`
    ///   - `.battery`                                   → `battery:[BatterySample]`
    /// Every other event case (`.motion`, `.state`, `.timeSync`, `.rtcBeacon`, `.debugText`, `.tierB`,
    /// `.activityInfo`) is intentionally not folded into a durable stream here. In particular the 0x50
    /// activity/MET decode NEVER mints a `steps` row: the formula is third-party and unvalidated (Tier B,
    /// OURA_PROTOCOL.md s6.13), and MET is not a step count - fabricating one would break the honest-data
    /// invariant and the per-source day-owner rules.
    public static func streams(from events: [OuraEvent], at ts: Int) -> Streams {
        var out = Streams()
        for e in events {
            switch e {
            case .hr(let v):
                // Honest HR: surface only the ring's decoded BPM. The push also carries one IBI, but the
                // dedicated `.ibi` events are the R-R source, so we do not synthesise an RR row from the HR
                // push here to avoid double-counting the same interval.
                out.hr.append(HRSample(ts: ts, bpm: v.bpm))

            case .ibi(let v):
                // Carry the decoder's OWN channel tag onto the durable row (#1071). The ring reports the
                // same heartbeats on more than one tag — 0x80 green-quality all night, 0x6E only while an
                // SpO2 measurement runs — and both decode to `.ibi`, so an untagged store held roughly TWO
                // complete copies of every night (measured 2.06x beats and 2.17x sum(rrMs)/wall-clock over
                // one 488-min window). Both rows are real measurements, so neither is dropped here; the
                // scoring READ (`Reads.rrIntervals`) picks one channel and the other stays on disk as its
                // cross-check. Nil stays nil — a channel is never guessed.
                out.rr.append(RRInterval(ts: ts, rrMs: v.ibiMs, srcChannel: rrChannel(v.channel)))

            case .hrv(let v):
                // The ring's own 0x5D tag, carried RAW for diagnostics/parity. The two int8 fields
                // (b1/b2) plus the sample's relative time offset are surfaced under units-neutral keys.
                // We do NOT mint an `rmssd_ms` here: the int8 b1/b2 byte -> millisecond scaling is NOT
                // Tier-A (OURA_PROTOCOL.md s6.9 leaves it unpinned), so labelling a raw byte as a
                // millisecond RMSSD would fabricate units (honest-data invariant). NOOP's own scoring
                // RMSSD is reconstructed from the IBI stream (`rr`), never from this open tag. Keys and
                // values are IDENTICAL to the Kotlin twin (OuraStreamMapping.kt) so both platforms emit
                // byte-for-byte the same OURA_HRV payload.
                out.events.append(WhoopEvent(ts: ts, kind: hrvEventKind, payload: [
                    "time_ms": .int(v.timeMs),
                    "b1": .int(v.b1),
                    "b2": .int(v.b2),
                ]))

            case .spo2(let v):
                // Oura reports a single SpO2 channel; `SpO2Sample` is the WHOOP-shaped two-channel raw row,
                // so we record the decoded value on `red` and leave `ir` at 0 (no second channel). `unit`
                // carries the decoder's own scale tag ("raw"/"dc_raw") so downstream never assumes a %.
                //
                // Each sample gets its OWN second. `spo2Sample` is keyed (deviceId, ts), so the 13 samples
                // of one 0x6F record written at the record's single `ts` collided and only the first
                // survived — 92% of an overnight silently discarded, and unrecoverable because the ring
                // trims its banked history once the offload is acked (#1070). The samples are one per
                // second (measured: 13 values per packet at a 13 s median packet interval, p10 12 / p90 14,
                // so they tile the interval at exactly 1 Hz), and they are laid BACKWARD from the record
                // time — the record envelope marks the WRITE moment, so the LAST sample keeps the record's
                // own `ts` and the anchor semantics are unchanged. Same derivation standard the
                // hypnogram assembler is held to (see `.sleepPhase` below, which lays a burst's codes
                // backward at the documented 30 s epoch from its anchored end, precisely so every code
                // is a distinct row): a documented cadence plus a record anchor, never a guessed one.
                // `count == 1` (0x7B, and any single-sample record) yields offset 0, i.e. exactly the
                // previous behaviour. PARITY: the Kotlin twin computes the IDENTICAL second.
                //
                // This is collision-RARE, not collision-proof. The cadence has a tight tail (p10 12 s),
                // and a 12 s gap between two 13-sample records makes the newer record's FIRST second
                // equal the older record's last, costing one sample at that boundary. Measured over the
                // same overnight: 204 of 1,877 adjacent pairs overlap, by exactly 1 s each, so 204 of
                // 24,405 samples (0.84 %) are lost — against 92.3 % before. `spo2Sample` inserts
                // `ON CONFLICT DO NOTHING`, so the survivor is the older record's last sample, which is
                // the anchor-exact one; what is dropped is the newer record's most back-extrapolated
                // sample. Sub-second timestamps would be needed to keep both, and the row key is seconds.
                let sampleTs = ts - max(0, v.count - 1 - v.index)
                out.spo2.append(SpO2Sample(ts: sampleTs, red: v.value, ir: 0, unit: v.unit))

            case .temp(let v):
                // The decoder yields degrees C. The durable `SkinTempSample.raw` is an integer in the
                // codebase-wide CENTI-degree-C convention: the WHOOP @73 historical path stores raw at
                // this scale and the analytics reader (AnalyticsEngine.skinTempFunnel) divides raw by 100
                // to recover °C. We store the SAME centi-°C scale so an Oura night reads on the SAME gates
                // as a WHOOP night with no scorer change, and tag the unit so the convention is explicit
                // and never silently assumed. PARITY: the Kotlin twin stores the SAME celsius * 100, so a
                // given decoded celsius yields an IDENTICAL raw integer on both platforms.
                out.skinTemp.append(SkinTempSample(ts: ts, raw: Int((v.celsius * 100).rounded()), unit: "centi_c"))

            case .sleepPhase(let v):
                // Each code arrives with its RECONSTRUCTED time as `ts` (OuraHypnogramAssembler lays the
                // burst's codes backward at the documented 30 s SleepNet epoch from the anchored burst
                // end — the record envelope marks the analysis WRITE moment, not the sleep). 30 s spacing
                // makes every code a distinct (deviceId, ts, kind) row; the earlier provisional
                // `ts + index` offset is gone (it would double-shift reconstructed codes). The raw 2-bit
                // code persists unchanged; `index` (position within the wire record) is kept for audit.
                out.events.append(WhoopEvent(ts: ts, kind: sleepPhaseEventKind, payload: [
                    "phase": .int(v.stage.rawValue),
                    "index": .int(v.index),
                ]))

            case .battery(let v):
                out.battery.append(BatterySample(
                    ts: ts,
                    soc: Double(v.percent),
                    mv: v.voltageMv,
                    charging: v.charging))

            case .motionEvent(let m):
                // 0x47 motion window → an OURA_MOTION event carrying the ring's OWN per-window summary. This
                // is INSTRUMENTATION on the honest activity signal, NOT a gravity stream: 0x47 is
                // movement-gated (no still samples), a shape mismatch for the gravity-stillness `SleepStager`
                // (#804), so it is NEVER folded into `gravitySample` and NEVER scored. It rides the SAME
                // event-table path as OURA_HRV / OURA_SLEEP_PHASE (the ring's other per-record signals), one
                // row per window at its own anchored `ts`. Keys IDENTICAL to the Kotlin twin. `low_/
                // high_intensity` are omitted on a short record (absent, never faked to 0).
                var payload: [String: ParsedValue] = [
                    "orientation": .int(m.orientation),
                    "motion_seconds": .int(m.motionSeconds),
                    "x": .int(m.avgX), "y": .int(m.avgY), "z": .int(m.avgZ),
                ]
                if let lo = m.lowIntensity { payload["low_intensity"] = .int(lo) }
                if let hi = m.highIntensity { payload["high_intensity"] = .int(hi) }
                out.events.append(WhoopEvent(ts: ts, kind: motionEventKind, payload: payload))

            case .motion, .state, .timeSync, .rtcBeacon, .debugText, .tierB, .activityInfo:
                // Not a durable per-device stream row (timeSync/rtcBeacon anchor the transport's clock;
                // motion/state/debug are diagnostics; Tier-B / .activityInfo are UNVERIFIED and must
                // never feed scoring or the steps stream).
                continue
            }
        }
        return out
    }

    /// Group already-stamped events into ONE batch per timestamp, keeping the order they arrived in
    /// (and the first-appearance order of the timestamps themselves). Pure → unit-testable.
    ///
    /// This exists because `StreamStore.insert`'s `seq` / `ord` counters are **batch-local by design**:
    /// `ord` is a beat's position among the beats that share its second *within one insert*, which is
    /// the only place emission order is still known (v30, #823). A transport that hands the store one
    /// event per insert therefore restarts the counter on every beat and writes `ord = 0` on every row
    /// — measured on a real database as 575,630 of 575,630 rows (#1072). With `ord` tied, the read falls
    /// through to `(rrMs, seq)`, i.e. a second's beats come back sorted by VALUE, and RMSSD — built
    /// entirely from successive differences — is biased down by construction.
    ///
    /// One record's beats all carry that record's own ring time, so grouping by the resolved timestamp
    /// is what hands the store a record's beats together. Order is the only property callers may rely
    /// on: events keep their relative order inside a batch, so `ord` counts in emission order.
    public static func batched(_ stamped: [(event: OuraEvent, ts: Int)]) -> [(ts: Int, events: [OuraEvent])] {
        var order: [Int] = []
        var byTs: [Int: [OuraEvent]] = [:]
        for s in stamped {
            if byTs[s.ts] == nil {
                order.append(s.ts)
                byTs[s.ts] = []
            }
            byTs[s.ts]?.append(s.event)
        }
        return order.map { (ts: $0, events: byTs[$0] ?? []) }
    }

    /// Translate the protocol layer's `OuraIBIChannel` to the store's `RRSourceChannel` (#1071).
    ///
    /// Two enums rather than one because `OuraProtocol` deliberately does not depend on `WhoopProtocol`
    /// (it is the pure, Linux-buildable ring decoder). They pin the SAME raw values, and the mapping is
    /// written out case by case rather than as `RRSourceChannel(rawValue:)` so that adding a case on one
    /// side without the other is a COMPILE error instead of a silent nil. Exposed for the parity test.
    public static func rrChannel(_ c: OuraIBIChannel?) -> RRSourceChannel? {
        switch c {
        case .greenQuality:  return .greenQuality
        case .spo2Ibi:       return .spo2Ibi
        case .ibiAmplitude:  return .ibiAmplitude
        case .ibiBare:       return .ibiBare
        case nil:            return nil
        }
    }
}
