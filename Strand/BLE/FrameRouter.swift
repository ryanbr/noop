import Foundation
import WhoopProtocol
import StrandAnalytics

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?
    /// Which family's framing to decode with. Set per connection by BLEManager. WHOOP 5.0/MG frames
    /// use the CRC16/offset-8 envelope; the biometric field decode for puffin is still a stub, so
    /// WHOOP 5 custom frames currently surface only their envelope (live HR/battery come from the
    /// standard 0x2A37/0x2A19 profiles instead).
    var family: DeviceFamily = .whoop4

    public init(state: LiveState) {
        self.state = state
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    /// Parse-then-forward shim (#47). Kept so existing callers/tests that pass raw bytes are unchanged;
    /// the live BLE seam now parses ONCE and calls `handle(parsed:frame:)` directly.
    public func handle(frame: [UInt8]) {
        handle(parsed: parseFrame(frame, family: family), frame: frame)
    }

    /// #47: the caller parses the frame ONCE at the BLE seam and threads the result here, so a live
    /// WHOOP4 frame is decoded once instead of 2–3× (router + clock-correlation + collector). `frame` is
    /// still passed for the byte-level sub-decoders below.
    public func handle(parsed: ParsedFrame, frame: [UInt8]) {
        #if DEBUG
        // Guard the "parse once == parse per consumer" invariant in dev/test builds only (assert is stripped
        // from Release): a threading bug (wrong family / stale frame) trips here, never on a user's wrist.
        assert(parsed == parseFrame(frame, family: family),
               "FrameRouter.handle: threaded ParsedFrame != fresh parse (#47 parse-once invariant)")
        #endif
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if parsed.crcOK == false { return }

        // #987: stamp frame liveness for the Connection readout's "last frame" row. A plain (non-
        // published, see LiveState) Int write, so the raw flood costs no re-renders here.
        state.noteFrameRouted()

        // live perf: only republish when the value actually changed. The type-43 raw flood arrives
        // continuously and repeats the SAME frame type, and each `@Published` write fires
        // `objectWillChange` → a full LiveView.body re-eval (these frames are separate BLE
        // notifications, so SwiftUI can't coalesce them). Guarding collapses a steady flood to one
        // re-eval per genuine change instead of one per frame.
        if state.lastFrameType != parsed.typeName {
            // Connection test mode: one tagged line per genuine frame-TYPE transition (not per frame - the
            // existing change-guard naturally throttles it), so a report shows the live frame cadence. Gated
            // zero-cost: the .connection bool is read before any string is built, and we only ever reach here
            // on a real type change, so the raw flood is collapsed exactly as the perf guard intends.
            if TestCentre.active(.connection) {
                state.append(log: "frameTiming type=\(parsed.typeName) t=\(Int(Date().timeIntervalSince1970))s",
                             domain: .connection)
            }
            state.lastFrameType = parsed.typeName
        }

        switch parsed.typeName {
        case "REALTIME_DATA", "REALTIME_RAW_DATA":
            // Reject 0 / out-of-range spikes from realtime streams; AppModel medians the rest.
            // Some firmware exposes live BPM only on the R10/R11 raw stream after acknowledging
            // BLE_REALTIME_HR_ON, so the UI can consume it even though persistence still ignores raw43.
            // live perf: skip the publish when HR is unchanged — the raw flood carries the same HR
            // byte across many frames, so an unguarded write re-renders the whole console for nothing.
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220, state.heartRate != hr {
                state.heartRate = hr
                // Sleep & Rest test mode (Group E): bank the live HR sample for the readout's HR-density
                // figure. Gated on the zero-cost active() Bool, so this is a no-op when the mode is off.
                if TestCentre.active(.sleep) {
                    state.recordSleepLiveHr(ts: Int(Date().timeIntervalSince1970), bpm: hr)
                }
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            // setRRIntervals also feeds the Live console's rolling rrRecent buffer.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.setRRIntervals(rr)
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }
            // #592: GET_EXTENDED_BATTERY_INFO / GET_BATTERY_LEVEL responses may carry pack voltage.
            if let mv = parsed.parsed["battery_mV"]?.intValue {
                state.batteryMv = mv
            }
            // Firmware version from the connect handshake: WHOOP 4.0 decodes `fw_harvard`
            // (REPORT_VERSION_INFO), WHOOP 5/MG decodes `fw_version` (GET_HELLO). Take whichever the
            // decoder produced; one branch covers both families. It's stable for the connection, so
            // only republish on a real change. Surfaced on the Devices card.
            if let fw = parsed.parsed["fw_version"]?.stringValue ?? parsed.parsed["fw_harvard"]?.stringValue,
               state.strapFirmware != fw {
                state.strapFirmware = fw
                // Persist so the debug export can name the firmware offline (state clears on disconnect).
                UserDefaults.standard.set(fw, forKey: "noop.lastFirmware")
            }
            // Advertising-name replies (WHOOP 4.0 / Harvard). GET (cmd 76) carries the current name in
            // its payload; SET (cmd 77) carries only a result byte. The schema has no field decode for
            // either, so pull them straight from the frame bytes. The COMMAND_RESPONSE inner is
            // [type,seq,cmd,origin_seq,result,payload…] starting at offset 4, with crc32 at `length`.
            // cmdName carries a "(rawValue)" suffix (Schema.enumName appends it, e.g.
            // "GET_ALARM_TIME(67)"), so match by prefix like every other cmdName consumer in the
            // codebase - never by equality, which is silently dead.
            // Reboot ack (#166): log the COMMAND_RESPONSE result for a user reboot on BOTH families. This is
            // the accept/reject signal — the same one that exposed 5/MG haptics rejection (result=0x03) — so
            // a 5/MG owner's strap log confirms whether the (unverified) puffin reboot frame is accepted
            // (0x00) or rejected. Log-only. A reboot that's accepted may drop the link before/after this ack.
            // POWER_CYCLE_STRAP is matched too: it's the 4.0 reboot probe's candidate B (#235), and its
            // result byte is exactly what tells "opcode rejected (recognized, wrong args)" from "ignored".
            if let cmd = parsed.cmdName, cmd.hasPrefix("REBOOT_STRAP") || cmd.hasPrefix("POWER_CYCLE_STRAP") {
                let r = Self.commandResultByte(in: frame)
                let rhex = r.map { String(format: "0x%02x", UInt8(truncatingIfNeeded: $0)) } ?? "none"
                let verdict = r == nil ? "no result byte" : (r == 0 ? "accepted" : "REJECTED")
                state.append(log: "reboot: strap acked result=\(rhex) (\(verdict))")
            }
            if family == .whoop4, let cmd = parsed.cmdName {
                if cmd.hasPrefix("GET_ADVERTISING_NAME_HARVARD") {
                    if let name = Self.advertisingName(in: frame), !name.isEmpty {
                        state.advertisingName = name
                    }
                } else if cmd.hasPrefix("SET_ADVERTISING_NAME_HARVARD") {
                    state.renameStatus = Self.renameAck(for: Self.commandResultByte(in: frame))
                } else if cmd.hasPrefix("GET_ALARM_TIME") {
                    // Arm-readback diagnostic (#401 close-out): armStrapAlarm follows every WHOOP 4.0 arm
                    // with GET_ALARM_TIME (67) so the log proves what the STRAP believes is armed, not
                    // just what we sent. LOG-ONLY, never gates behaviour: the 4.0 response layout is
                    // undocumented, so the decode is defensive (SET-mirror form first, bare u32 second,
                    // plausibility-gated) and an unrecognised payload still logs its raw hex - which is
                    // exactly as diagnostic. Labelled "strap reports", not "verified" (one firmware's
                    // answer format must never mislead a triage).
                    if let epoch = Self.armedAlarmEpoch(in: frame) {
                        // #34: log the RAW response bytes alongside the decoded epoch (previously only the
                        // decode-FAILURE branch below carried them). A successful-but-mismatched decode — the
                        // strap reporting a plausible epoch that never matches what we armed, the corrupted-
                        // register signature — needs the raw frame to tell a genuinely-stored stale alarm from
                        // a misdecode of a fixed response field. Log-only; the decode/behaviour is unchanged.
                        let raw = Self.commandResponsePayloadHex(in: frame) ?? "empty"
                        state.append(log: "Alarm: strap reports armed for \(Self.alarmLocalTime(epoch: epoch)) (epoch \(epoch)) [raw \(raw)]")
                        // #34: persist what the strap reports so the debug export can show sent-vs-reported.
                        let d = UserDefaults.standard
                        d.set(Int(epoch), forKey: "alarm.lastReportedEpoch")
                        d.set(Date().timeIntervalSince1970, forKey: "alarm.lastReportedAt")
                        // #34: count CONSECUTIVE rejections (reported ≠ what we last sent) — the signature of
                        // a corrupted strap alarm register. A matching readback resets it, so a transient
                        // (first read stale, then correct) never trips the warning; only a persistent refusal
                        // climbs. SmartAlarmView surfaces the warning at ≥2; the debug export shows the count.
                        // Observability only — never gates the BLE arm.
                        if let sent = d.object(forKey: "alarm.lastArmSentEpoch") as? Int {
                            d.set(abs(Int(epoch) - sent) > 120 ? d.integer(forKey: "alarm.rejectStreak") + 1 : 0,
                                  forKey: "alarm.rejectStreak")
                        }
                    } else if Self.readbackReportsNoAlarm(in: frame) {
                        // #34 (issue comment 2026-07-12): the strap's "nothing armed" sentinel — the epoch
                        // field decodes to 0. This is NOT an undocumented layout; it's the strap telling us
                        // it has no alarm stored, so an arm we just sent did NOT persist. Calling this
                        // "unrecognised payload" (the old branch) hid the single most diagnostic signal in a
                        // "didn't buzz" report: SET went out, strap kept nothing. Name it plainly. Log-only.
                        let raw = Self.commandResponsePayloadHex(in: frame) ?? "empty"
                        state.append(log: "Alarm: strap reports NO alarm currently stored (epoch 0) — the arm did not persist on the strap (raw \(raw))")
                    } else {
                        state.append(log: "Alarm: strap answered the alarm readback with an unrecognised payload (raw \(Self.commandResponsePayloadHex(in: frame) ?? "empty")) - layout undocumented, log-only")
                    }
                } else if cmd.hasPrefix("SET_ALARM_TIME") {
                    // #34 (issue comment 2026-07-12): the strap's OWN answer to the arm we just sent — the
                    // accept/reject datum that was previously thrown away. armStrapAlarm logs "armed" the
                    // instant the SET goes out, which only proves NOOP transmitted the frame; if the firmware
                    // drops it the GET_ALARM_TIME readback then reads back epoch 0 (a silently-unpersisted
                    // alarm — the exact signature in this report). Logging the raw result byte lets a future
                    // report distinguish a strap that accepted the arm from one that rejected it. LOG-ONLY,
                    // never gates behaviour. The WHOOP 4.0 result-code meaning is UNVERIFIED (the 5/MG puffin
                    // table is 0=FAILURE 1=SUCCESS 2=PENDING 3=UNSUPPORTED, but the 4.0 reboot probe assumed
                    // 0=accepted), so this claims NO verdict — it surfaces the byte, nothing more.
                    let r = Self.commandResultByte(in: frame)
                    let rhex = r.map { String(format: "0x%02x", UInt8(truncatingIfNeeded: $0)) } ?? "none"
                    state.append(log: "Alarm: strap answered the arm (SET_ALARM_TIME) with result=\(rhex) — log-only, 4.0 result-code meaning unverified")
                }
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                // #92: don't surface the live-HR stream toggle (BLE_REALTIME_HR_ON/OFF) in "Last
                // Event" — it's internal plumbing that fires on every connect and just confuses
                // users. Every other event (wrist, double-tap, battery, bonded…) still shows.
                if !ev.hasPrefix("BLE_REALTIME_HR") {
                    state.lastEvent = ev
                }
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                // Belt-and-suspenders: a BLE_BONDED event confirms the link is bonded.
                // (BLEManager also sets bonded=true when the confirmed write succeeds.)
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
                // BATTERY_LEVEL events carry the only charging flag the strap reports (wire
                // observation: u8 bit0, ~every 8 min on captured links). Flag only — battery %
                // keeps its family-specific source (#77). No freshness gate needed here: this
                // path never sees historical replay (backfill skips handle(frame:), see below).
                if ev.hasPrefix("BATTERY_LEVEL"),
                   let ch = parsed.parsed["battery_charging"]?.intValue {
                    state.charging = (ch != 0)
                }
                // #592: the same battery event carries pack voltage (mv@21) — surface it on the Devices card.
                if ev.hasPrefix("BATTERY_LEVEL"), let mv = parsed.parsed["battery_mV"]?.intValue {
                    state.batteryMv = mv
                }
                // The same pushed BATTERY_LEVEL event also carries the real SoC% (soc@17/10, what history
                // already banks) — drive the LIVE battery % from it too, not only from the polled
                // GET_BATTERY_LEVEL command-response. Otherwise a stalled/late poll (or a fresh LiveState
                // after relaunch) blanks the % to "—" while charging — read from THIS same event — keeps
                // updating (the WHOOP 4.0 report). Live-only path (backfill skips this router), so no replay
                // guard is needed; the family-specific #77 concern was the 0x2A19 stub, a different source.
                if ev.hasPrefix("BATTERY_LEVEL"), let pct = parsed.parsed["battery_pct"]?.doubleValue {
                    state.setBattery(pct)
                }
                // The strap raises CHARGING_ON(7)/CHARGING_OFF(8) the instant a pack goes on or comes off —
                // flip the pill directly instead of waiting on the ~8-min BATTERY_LEVEL cadence above. Live-
                // only like those blocks (backfill skips this router), so no replay guard is needed. Ported
                // from tanarchytan/noop @72ac14d9. Twin of the Kotlin WhoopBleClient handler.
                if ev.hasPrefix("CHARGING_ON") {
                    state.charging = true
                } else if ev.hasPrefix("CHARGING_OFF") {
                    state.charging = false
                }
                // Physical inputs the strap exposes — live only (this path never sees historical
                // replay, which goes through the Backfiller). Event strings are "NAME(rawValue)".
                if ev.hasPrefix("DOUBLE_TAP") {
                    state.onDoubleTap?()
                } else if ev.hasPrefix("WRIST_ON") {
                    if !state.worn { state.worn = true; state.onWristChange?(true) }
                } else if ev.hasPrefix("WRIST_OFF") {
                    if state.worn { state.worn = false; state.onWristChange?(false) }
                } else if ev.hasPrefix("STRAP_DRIVEN_ALARM_EXECUTED") {
                    // Fire observability (#401 close-out): Android has always logged this line
                    // (WhoopBleClient.handleFrame); iOS/macOS silently ran the callback, which is why a
                    // "did it actually buzz?" report could never be settled from a strap log ("log
                    // successes" forensics rule). With the armed line (armStrapAlarm) and the readback
                    // line (GET_ALARM_TIME) this makes every future report one-log decidable. The re-arm
                    // below writes a fresh "armed" line, so the two read as one sequence, not a bug.
                    state.append(log: "Alarm: strap-driven wake fired (event 57), re-arming the next day's instant")
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "alarm.lastFiredAt")  // #34 debug export
                    // The strap fired its firmware smart alarm → re-arm the next day's instant (the
                    // alarm is a single absolute time with no recurrence). Belt-and-suspenders to the
                    // daily/foreground re-arm in AppModel, since this event isn't always observed.
                    state.onSmartAlarmFired?()
                }
            }

        default:
            break
        }
    }

    // MARK: - Advertising-name decode (WHOOP 4.0 / Harvard)

    /// Offset of the inner `[type][seq][cmd][origin_seq][result][payload…]` in a WHOOP 4.0 frame:
    /// SOF(1) + length(2) + crc8(1). Mirrors `WhoopCommand.frame` / `parseFrame`.
    private static let whoop4InnerOffset = 4

    /// Extract the advertising name from a GET_ADVERTISING_NAME COMMAND_RESPONSE: printable ASCII from
    /// the payload that follows [type,seq,cmd,origin_seq,result] (payload starts at inner+5), up to the
    /// crc32 trailer at `length`. Mirrors the whoop-rename prototype's `extract_name`. nil if too short.
    static func advertisingName(in frame: [UInt8]) -> String? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)        // crc32 starts here
        let start = whoop4InnerOffset + 5                        // skip type,seq,cmd,origin_seq,result
        guard length <= frame.count, start < length else { return nil }
        let printable = frame[start..<length].filter { $0 >= 32 && $0 < 127 }
        return String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The result byte of a COMMAND_RESPONSE: inner offset + 4 ([type,seq,cmd,origin_seq] then result).
    static func commandResultByte(in frame: [UInt8]) -> Int? {
        let idx = whoop4InnerOffset + 4
        return idx < frame.count ? Int(frame[idx]) : nil
    }

    // MARK: - Alarm-readback decode (WHOOP 4.0, GET_ALARM_TIME cmd 67 - #401 close-out)

    /// The payload of a WHOOP 4.0 COMMAND_RESPONSE: the bytes after [type,seq,cmd,origin_seq,result]
    /// (payload starts at inner+5) up to the crc32 trailer at `length`. Same envelope walk as
    /// `advertisingName(in:)`. nil when the frame is too short to carry any payload.
    nonisolated static func commandResponsePayload(in frame: [UInt8]) -> [UInt8]? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)        // crc32 starts here
        let start = whoop4InnerOffset + 5                        // skip type,seq,cmd,origin_seq,result
        guard length <= frame.count, start < length else { return nil }
        return Array(frame[start..<length])
    }

    /// Space-separated lowercase hex of a COMMAND_RESPONSE payload, for the raw-hex diagnostic fallback
    /// when a readback payload doesn't decode. nil when the frame carries no payload.
    nonisolated static func commandResponsePayloadHex(in frame: [UInt8]) -> String? {
        guard let payload = commandResponsePayload(in: frame), !payload.isEmpty else { return nil }
        return payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Plausibility gate for a readback epoch: a real armed alarm is near-now, so anything outside
    /// 2017..2100 (1_500_000_000 to 4_102_444_800) is garbage or a strap with no alarm armed - the
    /// caller falls back to the raw-hex line rather than logging a misleading date. Bounds inclusive.
    nonisolated static func isPlausibleAlarmEpoch(_ epoch: UInt32) -> Bool {
        // Both bounds fit UInt32 (max 4_294_967_295), so the range infers as ClosedRange<UInt32>.
        (1_500_000_000...4_102_444_800).contains(epoch)
    }

    /// Extract the armed-alarm epoch from a GET_ALARM_TIME (cmd 67) COMMAND_RESPONSE, defensively.
    /// The WHOOP 4.0 response layout is UNDOCUMENTED, so this tries the two shapes the firmware could
    /// plausibly answer with - the SET_ALARM_TIME mirror (`[form 0x01][u32 LE epoch]…`, matching the
    /// 9-byte payload we arm with) first, then a bare leading u32 LE - and accepts a candidate only when
    /// it passes `isPlausibleAlarmEpoch`. Anything else returns nil and the caller logs raw hex instead.
    /// Pure and CoreBluetooth-free so golden tests pin it (AlarmReadbackDecodeTests).
    nonisolated static func armedAlarmEpoch(in frame: [UInt8]) -> UInt32? {
        guard let payload = commandResponsePayload(in: frame) else { return nil }
        func u32le(at i: Int) -> UInt32? {
            guard payload.count >= i + 4 else { return nil }
            return UInt32(payload[i])
                | (UInt32(payload[i + 1]) << 8)
                | (UInt32(payload[i + 2]) << 16)
                | (UInt32(payload[i + 3]) << 24)
        }
        if payload.first == 0x01, let e = u32le(at: 1), isPlausibleAlarmEpoch(e) { return e }
        if let e = u32le(at: 0), isPlausibleAlarmEpoch(e) { return e }
        return nil
    }

    /// True when a GET_ALARM_TIME readback explicitly reports NO alarm stored — the epoch field decodes
    /// to 0 in the same shapes `armedAlarmEpoch` reads (SET-mirror `[0x01][u32=0]` first, then a bare
    /// leading `u32=0`). This is the strap's "nothing armed" sentinel, distinct from a genuinely
    /// unparseable payload: an arm the strap silently dropped reads back as epoch 0, so labelling it
    /// "unrecognised" hid the real signal (#34). Only consulted AFTER `armedAlarmEpoch` returns nil, so a
    /// plausible armed epoch never reaches here. Pure/CoreBluetooth-free so AlarmReadbackDecodeTests pin it.
    nonisolated static func readbackReportsNoAlarm(in frame: [UInt8]) -> Bool {
        guard let payload = commandResponsePayload(in: frame) else { return false }
        func u32le(at i: Int) -> UInt32? {
            guard payload.count >= i + 4 else { return nil }
            return UInt32(payload[i])
                | (UInt32(payload[i + 1]) << 8)
                | (UInt32(payload[i + 2]) << 16)
                | (UInt32(payload[i + 3]) << 24)
        }
        if payload.first == 0x01, let e = u32le(at: 1) { return e == 0 }
        if let e = u32le(at: 0) { return e == 0 }
        return false
    }

    /// Local wall-clock render for the readback log line, matching armStrapAlarm's "EEE HH:mm zzz"
    /// format so the armed + strap-reports lines read as one sequence.
    nonisolated static func alarmLocalTime(epoch: UInt32) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm zzz"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// Human-readable ack for a SET_ADVERTISING_NAME result byte (same codes as the prototype:
    /// 0 Failure, 1 Success, 2 Pending, 3 Unsupported).
    static func renameAck(for result: Int?) -> String {
        switch result {
        case 1:  return "Renamed, your strap reboots to apply the new name."
        case 0:  return "The strap rejected the rename (failure)."
        case 2:  return "Rename pending…"
        case 3:  return "This strap firmware doesn't support renaming."
        default: return "Rename sent - re-scan to confirm the new name."
        }
    }

    /// Live-gesture freshness window (s). A DOUBLE_TAP / WRIST_ON / WRIST_OFF fires its live handler only
    /// if its event_timestamp is within this of `now` — so a *replayed historical* gesture during a
    /// backfill offload (old ts) is ignored, but a real-time one fires even mid-sync.
    static let liveGestureWindowSeconds = 45

    /// Parse an EVENT frame and fire ONLY the live physical-gesture handlers (double-tap / wrist) iff the
    /// event is recent. Called for offload frames during backfill — where `handle(frame:)` is skipped —
    /// so a real-time gesture still works mid-offload (#69: the 5/MG offload runs for minutes). `now`
    /// MUST be in the SAME clock domain as event_timestamp (the strap's RTC): the caller passes the
    /// strap's own clock-now (BLEManager.strapClockNow), so the gate is robust to a grossly-stale strap
    /// RTC (fix #72) — a live gesture is ~now in the strap's clock, a historical replay is old in it.
    /// Deliberately does NOT touch lastEvent / sync trigger / bonded / battery — those stay on the normal
    /// handle(frame:) path, so backfill UI behaviour is otherwise unchanged.
    func dispatchLiveGestureIfFresh(frame: [UInt8], now: Int = Int(Date().timeIntervalSince1970)) {
        // #47: this fires for EVERY frame on the OFFLOAD path (thousands of type-47 records over a
        // multi-minute sync) purely to catch a rare EVENT gesture. Cheap type-only pre-check skips the full
        // CRC + FieldBuilder decode for non-EVENT frames — byte-identical: an EVENT frame still gets the
        // full parse + CRC guard below; a non-EVENT frame was discarded at the `typeName == "EVENT"` guard
        // anyway. Family-aware (WHOOP4 type @[4], 5/MG @[8]).
        guard frameTypeName(frame, family: family) == "EVENT" else { return }
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok, parsed.crcOK != false else { return }
        guard parsed.typeName == "EVENT", let ev = parsed.parsed["event"]?.stringValue else { return }
        guard let ts = parsed.parsed["event_timestamp"]?.intValue, ts > 0 else { return }   // fail closed
        guard abs(now - ts) <= FrameRouter.liveGestureWindowSeconds else { return }
        if ev.hasPrefix("DOUBLE_TAP") {
            state.onDoubleTap?()
        } else if ev.hasPrefix("WRIST_ON") {
            if !state.worn { state.worn = true; state.onWristChange?(true) }
        } else if ev.hasPrefix("WRIST_OFF") {
            if state.worn { state.worn = false; state.onWristChange?(false) }
        }
    }
}
