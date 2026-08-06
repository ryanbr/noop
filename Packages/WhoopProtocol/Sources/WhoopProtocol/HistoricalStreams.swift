import Foundation

/// #891: packet types an offload legitimately carries that `extractHistoricalStreams` has no rows for, so
/// reaching `default:` is expected rather than a finding. Both decode to zero rows BY DESIGN — CONSOLE_LOGS
/// is strap-side debug text, METADATA is envelope bookkeeping — and counting them on every sync would bury
/// the one signal `Streams.unhandledPacketTypes` exists to surface. Nothing else is excluded, including
/// named-but-unhandled types like `HISTORICAL_IMU_DATA_STREAM(52)`: those are exactly the interesting ones.
/// Keep in lockstep with the Android `EXPECTED_UNHANDLED_HISTORICAL_TYPES`.
let expectedUnhandledHistoricalTypes: Set<String> = ["METADATA", "CONSOLE_LOGS"]

/// Shared plausibility bounds for a type-47 record's own unix timestamp (#547). A WHOOP strap with a
/// bad clock/flash (repeated trim=0xFFFFFFFF no-cursor) emits records whose decoded unix is scattered
/// garbage — far-past (2024/2029), a bogus 2027=1827642881, and even FUTURE dates. NOOP used to trust
/// these verbatim, so one polluted ~12h block got re-attributed to every day-window and a future-dated
/// record surfaced as the "last night" carry-over. We now reject any record whose ts isn't near "now".
///
/// MIN_PLAUSIBLE_UNIX = 2023-11 — the same 1.7B floor `BLEManager.strapDataBounds` already uses.
/// FUTURE_MARGIN = 1 day — a historical record can never post-date its own capture, so anything more
/// than a day ahead of wall time is a bad-clock artefact. Keep these in lockstep with the Android
/// `HistoricalStreams.kt` MIN_PLAUSIBLE_UNIX / FUTURE_MARGIN.
public let MIN_PLAUSIBLE_UNIX = 1_700_000_000   // 2023-11
public let FUTURE_MARGIN = 86_400               // 1 day

/// SESSION-RELATIVE slack (#547): how far OUTSIDE the strap's own GET_DATA_RANGE oldest/newest markers a
/// record may still be stamped before it's treated as bad-clock pollution. The strap reports its banked
/// history span [oldest, newest] for THIS sync; a real record cannot predate the oldest banked marker nor
/// post-date the newest by more than benign skew, so a record dated MONTHS off the strap's OWN window is a
/// wandering-clock artefact even when it clears the absolute 2023-11 floor (e.g. a 2024-12-25 record against
/// a 2026 strap window). 7 days absorbs marker jitter / a still-banking newest edge / DST while still
/// catching the months-off garbage. Kept in lockstep with Android `HistoricalStreams.kt` SESSION_RANGE_MARGIN.
public let SESSION_RANGE_MARGIN = 7 * 86_400    // 7 days

/// #520: the stillness cut for the `dynamic_acceleration` diagnostic. Borrowed from
/// `SleepStager.gravityStillThresholdG` (0.01 g) as a REFERENCE point, not because the two measure the
/// same thing — the stager thresholds a per-sample DELTA between consecutive gravity vectors, while this
/// field is an ABSOLUTE gravity-removed magnitude at one instant. Both approach 0 when the wrist is still,
/// so the same cut is a sensible starting point, but a matching still-fraction would not prove the two are
/// equivalent. Duplicated as a literal rather than imported — WhoopProtocol is the wire layer and must not
/// depend on StrandAnalytics. If the stager's constant moves, move this one with it.
public let dynAccelStillThresholdG = 0.01

/// True when `ts` is a plausible capture time for a historical record given `wallNow` (#547): on or
/// after the 2023-11 floor and no more than a day ahead of now. The single predicate the ingest gate
/// and the one-time DB heal both use, so both platforms reject the exact same set.
public func isPlausibleHistoricalUnix(_ ts: Int, wallNow: Int) -> Bool {
    ts >= MIN_PLAUSIBLE_UNIX && ts <= wallNow + FUTURE_MARGIN
}

/// SESSION-RELATIVE plausibility (#547): the absolute gate (`isPlausibleHistoricalUnix`) PLUS a check
/// that `ts` sits within the strap's OWN GET_DATA_RANGE markers for THIS sync, padded by
/// `SESSION_RANGE_MARGIN`. `sessionOldestUnix`/`sessionNewestUnix` are the markers the BLE client scanned
/// from the strap's range reply (nil when unknown — the replay/import/no-range paths). When BOTH markers
/// are present AND well-formed (both clear the absolute floor and oldest <= newest), a record dated far
/// before the oldest banked marker or far after the newest is rejected as wandering-clock pollution even
/// though it cleared the absolute floor. When the markers are absent or malformed this is byte-identical
/// to the absolute-only gate, so every legacy / range-less caller is unchanged. A legitimately-OLD record
/// that falls WITHIN [oldest, newest] (real history the strap actually banked) is always kept.
public func isPlausibleHistoricalUnix(_ ts: Int, wallNow: Int,
                                      sessionOldestUnix: Int?, sessionNewestUnix: Int?) -> Bool {
    guard isPlausibleHistoricalUnix(ts, wallNow: wallNow) else { return false }
    // Only apply the session-relative window when both markers are trustworthy: present, themselves above
    // the absolute floor, and correctly ordered. A wrong-epoch / partial marker must never reject real data.
    guard let oldest = sessionOldestUnix, let newest = sessionNewestUnix,
          oldest >= MIN_PLAUSIBLE_UNIX, newest >= oldest else { return true }
    return ts >= oldest - SESSION_RANGE_MARGIN && ts <= newest + SESSION_RANGE_MARGIN
}

/// The HISTORICAL_DATA record frames in `rawFrames` that NOOP cannot turn into rows — a genuine CRC
/// failure, an unmapped firmware layout (5/MG: any `hist_version` outside
/// `mappedWhoop5HistoricalVersions`), or a mapped layout whose envelope parsed but yielded no usable
/// biometrics. These are the records the strap is about to free once we ack the trim, so without an
/// archive they are lost forever while the UI reports a clean sync (#77 / #91).
///
/// Console (type-50, `frame[typeIndex] == 0x32`) frames are strap-side debug-log text that decode to
/// zero rows BY DESIGN and are never returned. 5/MG v26 (raw PPG block, hist_version 26) is also
/// skipped unconditionally (even on a CRC failure): a v26 record's payload is the optical waveform,
/// which `extractHistoricalStreams` now persists durably in its OWN stream (`Streams.ppgWaveform` /
/// WhoopStore's `ppgWaveformSample` table, issue #156 follow-up) whenever it decodes — this reject
/// archive exists for genuinely-undecodable records, and a decoded v26 record was never one of those.
/// Only genuine type-47 record frames whose payload would otherwise be silently dropped are returned.
///
/// Used by the Backfiller/BLEManager to archive undecodable history BEFORE acking the trim. Mirrors
/// the Android rejectedHistoricalRecords so one mapping toolchain re-ingests both archives.
public func rejectedHistoricalRecords(_ rawFrames: [[UInt8]], family: DeviceFamily) -> [[UInt8]] {
    // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
    // (the puffin envelope is 4 bytes longer). hist_version sits one byte past the type+seq+cmd
    // header — frame[5] (4.0) / frame[9] (5/MG) — same shift.
    let typeIndex = family == .whoop5 ? 8 : 4
    let versionIndex = family == .whoop5 ? 9 : 5
    return rawFrames.filter { f in
        // Only genuine HISTORICAL_DATA records (47). Console (50) and METADATA frames have a
        // different type byte, so they never pass this gate — they are excluded by construction.
        guard f.count > typeIndex, Int(f[typeIndex]) == 47 else { return false }
        if family == .whoop5, f.count > versionIndex, Int(f[versionIndex]) == 26 { return false }  // v26 PPG: has its own durable stream (ppgWaveform), not this reject archive
        // UNMAPPED LAYOUT (5/MG) — archive UNCONDITIONALLY, whatever it decoded.
        //
        // The decode-outcome test below is the wrong question for a layout NOOP has no field map for.
        // `decodeWhoop5Historical`'s unmapped branch reads no offsets, so anything that DOES appear in
        // `parsed` for such a record came from the envelope, not from a mapped biometric — and a record
        // that happened to yield a plausible `unix` plus a `gravity_x`/`heart_rate` used to pass the
        // screen and be kept NOWHERE, its bytes freed by the very next trim ack. That is exactly the
        // shape a novel record type (a new firmware's rollup, an on-demand capture) can take.
        //
        // This cannot flood the archive with records we already understand: v18/v20/v21/v26 are in
        // `mappedWhoop5HistoricalVersions` and never reach here. Retention for the records that DO
        // (`RawHistoryArchive.evictLines`) evicts entirely-zero-payload frames first, so a firmware that
        // banks empty placeholder records at 1 Hz cannot push out the one informative frame either.
        if family == .whoop5, isUnmappedWhoop5HistoricalRecord(f) { return true }
        let p = parseFrame(f, family: family)
        // Envelope/CRC reject: parse failed outright or the CRC32 trailer mismatched.
        if !p.ok || p.crcOK == false { return true }
        // Unmapped layout: the envelope parsed but no usable biometrics decoded. A record is genuinely
        // undecodable only if it has no timestamp, or NEITHER heart rate NOR motion. v25 (issue #30)
        // carries gravity but no per-second HR (PPG-derived), so a gravity-bearing record is real data
        // the sleep stager uses — keep it. Only HR-less AND gravity-less type-47 records are rejected.
        return p.parsed["unix"]?.intValue == nil
            || (p.parsed["heart_rate"]?.intValue == nil && p.parsed["gravity_x"]?.doubleValue == nil)
    }
}

/// Turn historical (offload) parsed frames into datastore rows. Port of
/// interpreter.extract_historical_streams.
///
/// HR/R-R come from REALTIME_RAW_DATA (type 43) headers — the canonical stream
/// during a historical backfill, where type-40 frames are absent.
/// EVENT and COMMAND_RESPONSE handling is identical to extractStreams.
/// CRC-failed and non-ok frames are skipped.
public func extractHistoricalStreams(_ parsed: [ParsedFrame],
                                     deviceClockRef: Int, wallClockRef: Int,
                                     // SESSION-RELATIVE bounds (#547): the strap's own GET_DATA_RANGE
                                     // oldest/newest markers for THIS sync. nil on the replay/import/no-range
                                     // paths — the gate then falls back to the absolute-only floor (unchanged).
                                     sessionOldestUnix: Int? = nil,
                                     sessionNewestUnix: Int? = nil,
                                     // Opt-in "HR-from-PPG sub-lag interpolation" (Test Centre → Experimental
                                     // algorithms, default false): threaded into the v26 PPG-HR estimator below.
                                     // The pure package can't read prefs, so the app-layer caller (Backfiller /
                                     // archive replay) reads PuffinExperiment.ppgHrSubLagInterpEnabled and passes
                                     // it. Default false = byte-identical to today. Mirrors the Android arg.
                                     subLagInterp: Bool = false) -> Streams {
    func wall(_ deviceTs: Int?) -> Int? {
        guard let d = deviceTs else { return nil }
        return wallClockRef + (d - deviceClockRef)
    }
    // FIX #72: type-47 `unix` and EVENT `event_timestamp` are the strap RTC's own real-unix seconds.
    // When the strap RTC is grossly stale (it sat unused for months, so its clock is months behind),
    // those land far in the past — live HR works but all offloaded history is misdated. Correct them by
    // the (wall - device) clock offset, but ONLY when the strap is grossly stale, and SNAPPED to a 5-min
    // grid so the same record re-syncs to the SAME corrected ts (offloaded rows dedupe by (deviceId, ts);
    // an un-snapped, slightly-different offset on re-sync would duplicate every row). For a normal or
    // identity clockRef the offset is ~0 (< threshold) → rawTs is returned unchanged (current behavior).
    let staleThreshold = 86_400          // 1 day
    let snapGranularity = 300            // 5 min
    let clockOffset = wallClockRef - deviceClockRef
    // The wall "now" the plausibility gate's FUTURE bound measures against. A record genuinely can't
    // post-date its own capture, so the ground truth for "future" is the LIVE wall clock. We take the
    // LATER of the live clock and `wallClockRef` so neither a synthetic/older ref (RawHistoryArchive's
    // identity `wallClockRef == 0`, unit fixtures, or a session ref a hair behind a just-captured record)
    // nor a paused live clock wrongly rejects a real record. The MIN_PLAUSIBLE_UNIX floor is unconditional
    // and still catches the far-past garbage in every caller. Genuine future garbage (pikapik's records
    // dated beyond now, the field's year-2081 overshoot) is still > now + FUTURE_MARGIN → dropped. (#547)
    let wallNow = max(wallClockRef, Int(Date().timeIntervalSince1970))
    // PRIMARY FIX (#547): a record's own decoded ts must be near "now". A bad-clock strap emits records
    // whose unix is scattered garbage (far-past, a bogus 2027, even future dates); trusted verbatim, one
    // polluted block was re-attributed to every day and a future row surfaced as "last night". Returns
    // nil for an out-of-bounds ts so EVERY call site can skip the record. Applied to BOTH the raw
    // pass-through branch and the corrected branch, so a clock-correction can never re-introduce a bad ts.
    func correctedWall(_ rawTs: Int) -> Int? {
        let candidate: Int
        if abs(clockOffset) <= staleThreshold {
            candidate = rawTs
        } else {
            // sign-aware round-half-up snap to the nearest `snapGranularity`
            let snapped = (clockOffset >= 0
                ? (clockOffset + snapGranularity / 2)
                : (clockOffset - snapGranularity / 2)) / snapGranularity * snapGranularity
            let corrected = rawTs + snapped
            // A fully-drained strap whose RTC has reset to ~epoch (year ~1971) reports a near-zero
            // deviceClockRef while its offloaded frames still carry the true-unix rawTs. clockOffset is
            // then ~decades, and this "correction" hurls every historical sample into the future
            // (observed in the field: year 2081), which silently breaks sleep & recovery because the
            // night never lands on the right day. A historical record can never post-date its own
            // capture, so when corrected overshoots wall time the offset was bogus — keep the raw ts.
            // The genuine stale case (strap behind real time) has corrected <= wallClockRef, so this
            // guard is a no-op there. (PR #471, @cataboysbusiness-debug)
            candidate = corrected <= wallClockRef + snapGranularity ? corrected : rawTs
        }
        // Final ingest gate (#547): drop the record if the resolved ts is implausible — either by the
        // absolute floor OR, when the strap's GET_DATA_RANGE markers are known, by sitting months outside
        // the strap's OWN banked window (wandering-clock pollution that clears the absolute floor). Counted
        // once per session via `droppedImplausible` so a bad-clock strap is visible in the diag/strap-log seam.
        guard isPlausibleHistoricalUnix(candidate, wallNow: wallNow,
                                        sessionOldestUnix: sessionOldestUnix,
                                        sessionNewestUnix: sessionNewestUnix) else {
            droppedImplausible += 1
            // #324: track the epoch SPAN of the dropped (bad-clock) records — the strap's OWN dated value,
            // so the Backfiller can log whether the whole poisoned range is future-dated or mixed.
            droppedOldest = min(droppedOldest ?? candidate, candidate)
            droppedNewest = max(droppedNewest ?? candidate, candidate)
            return nil
        }
        return candidate
    }
    // #547: how many records this chunk dropped for an implausible ts. Surfaced to the Backfiller via
    // `Streams.droppedImplausible` so the strap log can show a bad-clock strap (observability only).
    var droppedImplausible = 0
    // #324: oldest/newest own-timestamp among the dropped records (the poisoned-range epoch span).
    var droppedOldest: Int? = nil
    var droppedNewest: Int? = nil
    var out = Streams()
    // v26 optical-PPG records (issue #156): no measured HR/motion, just the 24 Hz waveform. Collect
    // (corrected-wall ts, samples) here and derive a per-second HR after the loop (PpgHr.derivePpgHr),
    // so the timeline stays continuous through the v26-heavy stretches that have no v18 HR summary.
    // The SAME (ts, samples) are also appended to `out.ppgWaveform` below (issue #156 follow-up) so the
    // raw waveform is durable too, not just the derived estimate this local buffer exists to produce.
    var ppgRecords: [(ts: Int, samples: [Int])] = []
    // #891: packet types that reach `default:` and are dropped. See `Streams.unhandledPacketTypes`.
    var unhandledTypes: [String: Int] = [:]
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "HISTORICAL_DATA":
            // type-47 carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
            // (FIX #72); a normal strap is unchanged (offset < threshold). The #547 ingest gate inside
            // `correctedWall` returns nil for an implausible ts (covers the v26 PPG baseTs too, since the
            // v26 waveform rides this same `unix`) — skip the whole record so no garbage-ts row is banked.
            guard let rawTs = p["unix"]?.intValue, let ts = correctedWall(rawTs) else { continue }
            // v26 PPG buffer: stash the waveform for the post-loop HR estimator AND persist the raw
            // samples themselves (issue #156 follow-up — previously ONLY the derived estimate survived,
            // the waveform that produced it was discarded here). A v26 record carries no
            // heart_rate/spo2/gravity, so it adds nothing to the branches below — handled here only.
            if let samples = p["ppg_waveform"]?.intArrayValue, !samples.isEmpty {
                ppgRecords.append((ts: ts, samples: samples))
                out.ppgWaveform.append(PpgWaveformSample(ts: ts, samples: samples))
            }
            if let bpm = p["heart_rate"]?.intValue, bpm != 0 {  // skip startup hr=0
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
            if let red = p["spo2_red"]?.intValue {
                out.spo2.append(SpO2Sample(ts: ts, red: red, ir: p["spo2_ir"]?.intValue ?? 0))
            }
            // The two AUXILIARY thermal channels (`temp_aux_1_raw@69` / `temp_aux_2_raw@71`, i16, °C =
            // value/10) ride the primary skin-temp row for the same second. Both were decoded and dropped
            // here until now. They are carried ONLY when the primary channel decoded, because that is the
            // row's key — a record whose @73 failed the decoder's 5-45 °C gate banks no skinTempSample at
            // all, and inventing one to hold an aux value would put a fabricated primary reading in the
            // store. nil for a WHOOP 4.0, whose v24/v25 layouts have no such fields.
            if let raw = p["skin_temp_raw"]?.intValue {
                out.skinTemp.append(SkinTempSample(ts: ts, raw: raw,
                                                   aux1Raw: p["temp_aux_1_raw"]?.intValue,
                                                   aux2Raw: p["temp_aux_2_raw"]?.intValue))
            }
            // step_motion_counter@57 is the WHOOP5 cumulative u16 counter — decoded but, until now,
            // dropped on macOS (Android persists it). APPROXIMATE; semantics unverified vs the app (#78).
            if let c = p["step_motion_counter"]?.intValue {
                // activity_class@63 (0=still/1=walk/2=run) rides on the same record — nil when invalid/absent.
                out.steps.append(StepSample(ts: ts, counter: c, activityClass: p["activity_class"]?.intValue))
            }
            // Band sleep_state (#175): the strap's OWN @81 high-nibble state (0 wake/1 still/2 asleep/3 up),
            // decoded but DROPPED here until now, so the whole band-state chain (persist → the H7 re-onset
            // confirm guard → Deep Timeline track) had no source. Carried VERBATIM including 0 (a real wake
            // reading, not "absent"): only 5/MG v18 records emit the key, so a WHOOP 4.0 simply adds nothing.
            // `rawByte` carries the WHOLE @81 byte beside the high-nibble `state` this row already stored,
            // so the bits the mask throws away survive: b0-1 `onwrist` and b2-3 `wake_quality` are both
            // decoded by the Interpreter and were discarded right here, and b6-7 have no interpretation at
            // all yet. `state` is unchanged, so #175 / the H7 guard / the Deep Timeline track are
            // bit-identical.
            if let st = p["sleep_state"]?.intValue {
                out.sleepState.append(SleepStateSample(ts: ts, state: st,
                                                       rawByte: p["sleep_state_byte"]?.intValue))
            }
            if let raw = p["resp_rate_raw"]?.intValue {
                out.resp.append(RespSample(ts: ts, raw: raw))
            }
            // `dynAccel` is the strap's OWN gravity-removed motion magnitude (`dynamic_acceleration@41`)
            // for this same second, riding the gravity row it belongs beside. It was decoded and dropped
            // here until now, so every second of it was lost once the offload was acked. nil for a WHOOP
            // 4.0 or a record whose f32 failed the decoder's [0, 8] g gate.
            if let gx = p["gravity_x"]?.doubleValue {
                out.gravity.append(GravitySample(ts: ts, x: gx,
                    y: p["gravity_y"]?.doubleValue ?? 0, z: p["gravity_z"]?.doubleValue ?? 0,
                    dynAccel: p["dynamic_acceleration"]?.doubleValue))
            }
            // #520 diagnostic: fold `dynamic_acceleration@41` into a summary for the strap log. Kept
            // alongside the per-second column above, not replaced by it: this is a whole-session shape
            // (count / still-fraction / min / max / mean) the Backfiller logs once, whereas the column is
            // the durable per-second series. The threshold is the stager's own cut, borrowed as a
            // reference point (the stager thresholds a per-sample delta, this is an absolute magnitude —
            // related, not the same measurement); it is passed as a literal because WhoopProtocol must
            // not depend on StrandAnalytics.
            if let dyn = p["dynamic_acceleration"]?.doubleValue {
                out.dynAccel.add(dyn, threshold: dynAccelStillThresholdG)
            }
            // Everything ELSE the v18 decoder produced for this second. Each of these was computed and
            // then dropped one line later; the strap trims its banked history the moment the offload is
            // acked, so an unbanked field is unrecoverable and can never be censused. Carried verbatim
            // under the decoder's own names, no scaling and no interpretation.
            //
            // Every lookup below is BY DECODER KEY, and every one is optional. That makes a decoder
            // rename silent: the key stops existing, the slot banks nothing, and neither the compiler
            // (the type is `Int?`) nor a runtime check (absence is a legal state here) says a word — in a
            // capture format whose only job is preserving fields before the strap trims them. Each key
            // below comes from `V18AuxSlot.decoderKey` and is written down nowhere else on this side, so
            // `testEverySlotDecoderKeyExistsInARealV18Decode` — which asserts every one still decodes off
            // a real v18 frame — is checking the same string this code reads with, not a copy of it.
            //
            // Gated on `hist_version == 18` — the exact layout these offsets were read off. Every other
            // layout adds NOTHING: a WHOOP 4.0 v24/v25 record and a 5/MG v20/v21/v26 record are untouched.
            // The gate is explicit rather than implied by which keys happen to be present, because
            // `rr_count` IS shared with the 4.0 schema and a presence-based test would start banking a
            // near-empty row for every WHOOP 4.0 second.
            if p["hist_version"]?.intValue == 18 {
                // Read through `V18AuxSlot.decoderKey` rather than repeating the key strings here. They
                // used to be two independent literals per slot — the enum's and this extractor's — and
                // `testEverySlotIsPopulatedFromARealV18Frame` exists precisely because those two can drift
                // apart while each looks right on its own. With one source there is nothing to drift: a
                // slot pointed at a retired key now fails BOTH tripwires instead of only the second.
                func slot(_ s: V18AuxSlot) -> Int? { p[s.decoderKey]?.intValue }
                let aux = V18AuxSample(
                    ts: ts,
                    recordIndex: slot(.recordIndex),
                    rrCount: slot(.rrCount),
                    cardiacFlags: slot(.cardiacFlags),
                    hrQualityFlags: slot(.hrQualityFlags),
                    heartRateAlt: slot(.heartRateAlt),
                    rrPacked: slot(.rrPacked),
                    cardiacStatus: slot(.cardiacStatus),
                    stepCadence: slot(.stepCadence),
                    statusWord: slot(.statusWord),
                    statusWord1: slot(.statusWord1),
                    statusWord2: slot(.statusWord2),
                    auxByte82: slot(.auxByte82),
                    opticalBaselineA: slot(.opticalBaselineA),
                    opticalBaselineB: slot(.opticalBaselineB),
                    opticalAmpA: slot(.opticalAmpA),
                    opticalAmpB: slot(.opticalAmpB),
                    // Banked as the float's raw 32-bit pattern, not a decoded value — the decoder gates this
                    // field to finite floats, which round-trip Double->Float exactly, so no precision is lost.
                    // Reads `doubleValue`, so it cannot use `slot(_:)` above, but the KEY still comes from
                    // the enum.
                    unknownF32Bits: p[V18AuxSlot.unknownF32At113.decoderKey]?.doubleValue.map {
                        Int(Float($0).bitPattern)
                    })
                // A record that decoded none of the slots banks no row at all — absence stays absence.
                if !aux.isEmpty { out.v18Aux.append(aux) }
            }
        case "REALTIME_RAW_DATA":
            // #547 gate: the device-epoch→wall mapping can also land out of bounds on a bad clock, so
            // drop the row unless the resulting wall ts is plausible (mirrors the type-47/EVENT gate).
            var rtTs: Int?
            if let w = wall(p["timestamp"]?.intValue) {
                if isPlausibleHistoricalUnix(w, wallNow: wallNow,
                                             sessionOldestUnix: sessionOldestUnix,
                                             sessionNewestUnix: sessionNewestUnix) { rtTs = w }
                else { droppedImplausible += 1 }
            }
            if let ts = rtTs, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let ts = rtTs, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
            // (FIX #72); a normal strap is unchanged (offset < threshold). #547 gate: skip the event
            // when `correctedWall` rejects an implausible ts so no future/far-past event is banked.
            guard let rawTs = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            guard let ts = correctedWall(rawTs) else {
                // #324: the #547 gate just dropped this event for an implausible ts. If it's an RTC-STATE
                // event (RTC_LOST / BOOT / SET_RTC), that IS the ground truth that the clock reset — capture
                // (kind, rawTs) for the strap log before discarding, so a future-dated strap's cause isn't
                // silently swallowed by the very gate the bad clock trips.
                if DroppedRtcEvent.isRtcStateKind(kind) {
                    out.droppedRtcEvents.append(DroppedRtcEvent(kind: kind, rawTs: rawTs))
                }
                continue
            }
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            // #891: this funnel has no rows for this type, so the record is dropped — count it first, or
            // an offload carrying a type nobody has mapped reports as a clean sync. See
            // `Streams.unhandledPacketTypes` for why METADATA/CONSOLE_LOGS are excluded.
            if !expectedUnhandledHistoricalTypes.contains(r.typeName) {
                unhandledTypes[r.typeName, default: 0] += 1
            }
            continue
        }
    }
    // Derive per-second HR from the collected v26 PPG bursts (issue #156). Empty when there were no v26
    // records (the WHOOP 4 / v18-only common case), so this is a no-op cost there.
    out.ppgHr = PpgHr.derivePpgHr(records: ppgRecords, subLagInterp: subLagInterp)
    out.unhandledPacketTypes = unhandledTypes     // #891 diag census (not persisted, not encoded)
    out.droppedImplausible = droppedImplausible   // #547 diag count (not persisted, not encoded)
    out.droppedImplausibleOldestTs = droppedOldest   // #324 poisoned-range epoch span (diag only)
    out.droppedImplausibleNewestTs = droppedNewest
    return out
}
