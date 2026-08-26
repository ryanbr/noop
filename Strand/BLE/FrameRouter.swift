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
    var family: DeviceFamily = .whoop4 {
        // #900: a fresh connection is a fresh capture session — re-arm the per-command raw-frame dump so
        // each connect can re-capture the disputed COMMAND_RESPONSE prefix once. `family` is set fresh per
        // connection by BLEManager (connectCore), so this is the per-session reset hook.
        didSet { rawDumpedRespCmds.removeAll(); loggedFirmwareGate = nil }
    }

    /// #900: resp command names (e.g. "GET_BATTERY_LEVEL(26)") whose raw COMMAND_RESPONSE frame has already
    /// been dumped this connection. The provenance dump fires once per command per session so a 4.0's
    /// per-poll battery reads don't flood the strap log. Reset when `family` is set at connect.
    /// #1634: last firmware-gate line logged, so a stable per-connection value is not repeated on every
    /// hello. Cleared alongside the other per-connection routing state.
    private var loggedFirmwareGate: String?

    private var rawDumpedRespCmds: Set<String> = []

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

            // #1634: the 5/MG hello decoded no firmware. The guards fail closed by design, so this is the
            // only place that can say WHY - a different generation byte vs a MOVED offset. Logged once per
            // connection (the value is stable), so a capture from an undecoded strap carries the evidence.
            if let gate = parsed.parsed["fw_gate"]?.stringValue, loggedFirmwareGate != gate {
                loggedFirmwareGate = gate
                state.append(log: gate, domain: .connection)
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
                // bhelm/noop#4: read the result at the FAMILY's offset (4.0 @8, 5/MG @12) and judge it with
                // the family's own polarity. 5/MG's CommandResult table is 1=SUCCESS / 0=FAILURE (BodyLocation
                // Probe, MG vectors), so a raw byte at the fixed 4.0 offset read the inner *type* byte on 5/MG
                // and printed REJECTED on a successful reboot — the Kotlin twin already judged the decoded
                // result name and was correct. 4.0's result-code meaning stays the probe's (unverified) 0=accepted.
                let r = Self.commandResultByte(in: frame, family: family)
                let rhex = r.map { String(format: "0x%02x", UInt8(truncatingIfNeeded: $0)) } ?? "none"
                let accepted = (family == .whoop5) ? (r == 1) : (r == 0)
                let verdict = r == nil ? "no result byte" : (accepted ? "accepted" : "REJECTED")
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
                } else if cmd.hasPrefix("GET_HELLO_HARVARD"), TestCentre.active(.connection) {
                    // #1303: capture aid for WHOOP-4.0 stable-serial identity. The strap serial lives in this
                    // GET_HELLO_HARVARD (cmd 35) response. This used to dump the payload RAW, which answered
                    // the question — the serial is the 9-char alnum run at offset 14 — but a captured 4.0
                    // response is 131 bytes carrying TWO alnum runs, and the second (offset 24, 54 chars) is
                    // the device key. Reporters attach strap logs to public issues, and Test Centre is
                    // normally enabled BECAUSE they were asked for one, so the gate below selects for the
                    // logs most likely to be shared rather than the least.
                    //
                    // The structural probe answers the same question without that: it reports every printable
                    // run by offset and length, and quotes only alnum runs 6...20 chars. The serial (9) is
                    // still shown; the key (54) falls outside and is withheld by the probe rather than by
                    // this caller, so the rule cannot be got wrong here. `knownNameOffset: -1` because 16 is
                    // the 5/MG device-name offset and means nothing in a cmd-35 payload — passing it would
                    // mislabel whatever run happened to start there. Log-only; decodes/persists nothing.
                    let helloPay = Self.commandResponsePayload(in: frame) ?? []
                    state.append(log: HelloIdentityProbe.report(payload: helloPay,
                                                                block: "HELLO_HARVARD(35)",
                                                                knownNameOffset: -1)
                                 + " — locate the strap serial offset (#1303)")
                }
            }
            // #1303: the 5/MG half of the same hunt. The 4.0 aid above is 4.0-only — correctly, since a
            // 5/MG never answers cmd 35 — so this family had no capture at all, and it needs one just as
            // much: a stable per-strap id is what multi-strap identity waits on, and the pack serial from
            // cmd 151 identifies a REMOVABLE PART rather than the strap wearing it.
            //
            // No new traffic is sent. GET_HELLO already arrives on every connect and is already decoded —
            // for the device name and the firmware version — and the rest of the block is discarded. If
            // the serial is in there, it has been arriving all along.
            //
            // Reports STRUCTURE, not the block: the same response carries a session token the decoder
            // deliberately never reads, so `HelloIdentityProbe` prints only serial-shaped runs and
            // withholds the rest. Test Centre → Connection gated on top of that, so nothing here reaches a
            // default (shareable) strap log. Log-only; decodes and persists nothing.
            if family == .whoop5, let cmd = parsed.cmdName,
               cmd.hasPrefix("GET_HELLO("),          // not GET_HELLO_HARVARD — Schema appends "(145)"
               TestCentre.active(.connection),
               let pay = Self.commandResponsePayload(in: frame, family: family) {
                state.append(log: HelloIdentityProbe.report(payload: pay) + " — locate the strap serial (#1303)")
            }
            // #900: surface a non-SUCCESS COMMAND_RESPONSE on BOTH families (a result=UNSUPPORTED here is how
            // the MG haptics rejection #48 would show), and — the key part — annotate a reply that DELIVERED
            // ITS VALUE rather than reporting a bare failure. The 4.0 GET_BATTERY_LEVEL replies on record carry
            // a zeroed [seq][result] prefix, so a battery read that returned a good percentage logs as
            // "FAILURE(0)"; a failure line next to a gauge reading 42% is the artefact that gets quoted as a
            // fault that isn't there — that is how #900 started. The line still prints (hiding it would hide the
            // anomaly), it just no longer reads as a failure. Twin of the Kotlin WhoopBleClient annotation (#923).
            if let result = parsed.parsed["result"]?.stringValue, !result.hasPrefix("SUCCESS") {
                let cmdName = parsed.cmdName ?? "?"
                let note: String
                if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                    note = " (the reply still carried a value: battery \(String(format: "%.1f", pct))%"
                         + " — the result byte on this reply is not established, see #900)"
                } else {
                    note = ""
                }
                state.append(log: "Command response: \(cmdName) → \(result)\(note)")
                // #900: dump the FULL raw frame once per command per connection, so a normal (shareable)
                // strap-log export carries the disputed [seq][result] prefix bytes with known provenance — the
                // one capture the issue is blocked on. Full frame (not the post-prefix payload, which hides
                // those very bytes); matches the GET_DATA_RANGE raw-frame line (#451) and the format #900's
                // fixtures are quoted in. Rate-limited: a 4.0 hits this branch on every battery poll.
                // …with ONE command held back, DEFENSIVELY. A WHOOP 4.0 `GET_HELLO_HARVARD(35)` response is
                // 131 bytes whose body carries the strap's DEVICE KEY (the 54-char alnum run at offset 24,
                // beside the serial at 14), and this dump is ungated — "normal (shareable)" is the point of
                // it. On the captures on record cmd 35 answers SUCCESS, so it does not reach this branch at
                // all today; the skip is not fixing an observed leak. It exists because the branch's own
                // premise is that a 4.0 misreports its result: the documented zeroed-[seq][result] artefact
                // is exactly why GET_BATTERY_LEVEL lands here while carrying a good value, and nothing makes
                // cmd 35 immune to the same artefact on another firmware. One command whose body is a secret
                // is the one #900 can spare — it needs the PREFIX provenance, which every other command
                // reaching here supplies. Cmd 35's content stays covered, structurally and with the key
                // withheld, by the HelloIdentityProbe line above. Twin of the Android skip.
                if !rawDumpedRespCmds.contains(cmdName), !cmdName.hasPrefix("GET_HELLO_HARVARD") {
                    rawDumpedRespCmds.insert(cmdName)
                    state.append(log: "  raw frame (#900 — [seq][result] provenance): \(Self.fullFrameHex(frame))")
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

    /// The result byte of a COMMAND_RESPONSE: the family's inner offset + 4 ([type,seq,cmd,origin_seq]
    /// then result). WHOOP 4.0's inner starts at offset 4 (result @8); WHOOP 5/MG's starts at 8 (result
    /// @12 — the "+4 shift", Framing/Interpreter). Defaults to `.whoop4` so the WHOOP-4-only callers
    /// (rename, alarm-SET ack) stay untouched; only the both-families reboot ack passes the live family
    /// (bhelm/noop#4 — reading @8 on a 5/MG frame hit the inner type byte, not the result).
    static func commandResultByte(in frame: [UInt8], family: DeviceFamily = .whoop4) -> Int? {
        let inner = (family == .whoop5) ? 8 : whoop4InnerOffset
        let idx = inner + 4
        return idx < frame.count ? Int(frame[idx]) : nil
    }

    // MARK: - Alarm-readback decode (WHOOP 4.0, GET_ALARM_TIME cmd 67 - #401 close-out)

    /// The payload of a COMMAND_RESPONSE: the bytes after [type,seq,cmd,origin_seq,result] (payload
    /// starts at inner+5) up to the crc32 trailer at `length`. Same envelope walk as
    /// `advertisingName(in:)`. nil when the frame is too short to carry any payload.
    ///
    /// `family` defaults to `.whoop4` so every existing caller (alarm readback, advertising name, the
    /// cmd-35 dump) is untouched, exactly as `commandResultByte` does — and for the same reason it had
    /// to: the inner starts at 4 on a WHOOP 4.0 and at 8 on a 5/MG, so reading a 5/MG frame at the 4.0
    /// offset returns four bytes of envelope dressed as payload rather than failing visibly.
    nonisolated static func commandResponsePayload(in frame: [UInt8],
                                                   family: DeviceFamily = .whoop4) -> [UInt8]? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)        // crc32 starts here
        let inner = (family == .whoop5) ? 8 : whoop4InnerOffset
        let start = inner + 5                                    // skip type,seq,cmd,origin_seq,result
        guard length <= frame.count, start < length else { return nil }
        return Array(frame[start..<length])
    }

    /// Space-separated lowercase hex of a COMMAND_RESPONSE payload, for the raw-hex diagnostic fallback
    /// when a readback payload doesn't decode. nil when the frame carries no payload.
    nonisolated static func commandResponsePayloadHex(in frame: [UInt8]) -> String? {
        guard let payload = commandResponsePayload(in: frame), !payload.isEmpty else { return nil }
        return payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// #900: the entire frame (0xAA SOF through the crc32 trailer) as contiguous lowercase hex — the
    /// provenance format #900's fixtures are quoted in (e.g. "aa0f00c324141a0000…"). Unlike
    /// `commandResponsePayloadHex`, this keeps the [type,seq,cmd,origin_seq,result] prefix, which is the
    /// exact region #900 needs to inspect. Mirrors the Android `frame.joinToString("") { "%02x" }` dump.
    nonisolated static func fullFrameHex(_ frame: [UInt8]) -> String {
        frame.map { String(format: "%02x", $0) }.joined()
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
