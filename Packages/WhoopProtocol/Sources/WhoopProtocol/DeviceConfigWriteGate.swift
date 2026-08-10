import Foundation

/// #891 / #103: the ONE device-config key this app may write beyond the Broadcast-HR flag —
/// `enable_raw_data_w_ecg` — and the key-aware allowlist that keeps every other key off the wire.
///
/// ## Where the key came from
///
/// The strap listed it itself. `START_DEVICE_CONFIG_KEY_EXCHANGE(115)` + `SEND_NEXT_DEVICE_CONFIG(116)`
/// — the read-only enumeration pair `ConfigKeySweep` builds — was answered by a WHOOP 5 MG with
/// `revision=1 count=7`, and the walk ran to a clean `index=255 validKey=false` terminator listing:
///
/// ```
/// sigproc_wear_detect            enable_rfid                    max_collection_backlog
/// cont_collection_mode           whoop_live_hr_in_adv_ind_pkt   whoop_live_2_hrm_devices
/// enable_raw_data_w_ecg
/// ```
///
/// Six of those seven were unknown to this codebase. Nothing here is guessed: the names are the strap's
/// own, read off its own enumeration.
///
/// ## Why this key, and why now
///
/// #891 records that all three TOGGLE_LABRADOR (ECG) commands — 139, 125, 124 — answer `SUCCESS(1)` on a
/// WHOOP 5 MG and produce **zero** ECG packets in a 30-second listen. What the echoed byte those replies
/// carry actually MEANS is still open: arg-echo is refuted (SELECT_WRIST was sent 0 and answered 1) and
/// blanket payload-echo is refuted (GET_BATTERY_LEVEL sends `[0x00]` and answers 0x2F), but "read-back of
/// stored state" remains an inference — a per-opcode handler echoing a constant fits every observation so
/// far just as well. Either way the practical lesson holds: a `SUCCESS` result byte is not evidence that
/// state changed.
///
/// On the same strap `enable_raw_data_w_ecg` reads `'0'`. A device-config key whose name pairs "raw data"
/// with "ecg", sitting at `'0'` on a strap whose ECG toggles accept and emit nothing, is the leading
/// candidate for the gate. **Whether flipping it actually produces ECG data is UNKNOWN.** A negative
/// result — gate flipped to `'1'`, read back as `'1'`, still no packets — is a publishable answer that
/// removes the leading hypothesis from #891, and is the outcome this path is built to establish either way.
///
/// ## Why a write is safe to offer at all
///
/// Config writes on this firmware are demonstrated, not assumed: running the existing `enable_r22_*`
/// sequence (#174) moved `enable_sig12` from `'2'` (0x32) to `'1'` (0x31), confirmed by a 121 read before
/// and after. So a `SET_DEVICE_CONFIG_VALUE(119)` write lands, and the value that comes back afterwards is
/// real rather than an echo of what was sent.
///
/// ## Read-back is the proof, not the ack
///
/// The write's own `COMMAND_RESPONSE` is **not** treated as evidence. #891 is the standing example of why:
/// `SELECT_WRIST` returns SUCCESS for a no-op and FAILURE for a real change, so a result byte says nothing
/// reliable about whether state moved. Every write from this path is therefore followed by a
/// `GET_DEVICE_CONFIG_VALUE(121)` read of the same key, and only the value that comes back is reported.
/// (Framing owed to @ryanbr on #891.)
///
/// ## The allowlist is key-aware, not just opcode-aware
///
/// Opcode 119 is shared: the Broadcast-HR flag (#181) writes through it too. An opcode-only allowlist
/// therefore cannot express "this key and no other", and before this file the 5/MG send path admitted ANY
/// device-config key while the Broadcast-HR opt-in happened to be on. `admitsSend` closes that: it parses
/// the key name out of the body and admits exactly two keys, each only while its OWN opt-in is on. The
/// five remaining enumerated keys are named in `outOfScopeKeys` and are refused unconditionally — their
/// effects are unknown and nothing here has any reason to move them.
///
/// This is the same discipline `DeviceConfigReadProbe.isReadOnlyOpcode` established for the read probes: a
/// single pure predicate that the BLE send path itself consults, so a unit test proving the predicate
/// rejects something is proving it about the real wire path and not about a parallel copy of the rule.
///
/// Pure: no CoreBluetooth, no I/O, no preferences. The app layer supplies the two opt-in booleans. The
/// Kotlin twin is `com.noop.protocol.DeviceConfigWriteGate` — keep them byte-identical.
public enum DeviceConfigWriteGate {

    // MARK: - Opcodes

    /// `SET_DEVICE_CONFIG_VALUE` (119 / 0x77) — writes ONE persistent device-config value. The only write
    /// verb this gate ever admits, and only for the two keys below.
    public static let setDeviceConfigValueCmd: UInt8 = 119

    /// `SET_FF_VALUE` (120 / 0x78) — the FEATURE-FLAG write verb (the `enable_r22_*` sequence, #174). A
    /// different namespace, and named here for exactly one reason: so `admitsSend` can be proved to refuse
    /// it. Nothing on this path may ever send it.
    public static let setFeatureFlagValueCmd: UInt8 = 120

    /// `GET_DEVICE_CONFIG_VALUE` (121 / 0x79) — the read verb the mandatory post-write read-back uses.
    /// Read-only; it is also in `DeviceConfigReadProbe.readOnlyOpcodes`.
    public static let getDeviceConfigValueCmd: UInt8 = 121

    // MARK: - Keys

    /// The key this file exists for. Written ONLY while the ECG-gate opt-in is on AND the strap has
    /// positively attested itself a WHOOP MG (`Whoop5Variant.isMG`) — a plain 5.0 has no electrodes, so
    /// the write has nothing to gate there.
    public static let ecgRawDataKey = "enable_raw_data_w_ecg"

    /// The Broadcast-HR key (#181), hardware-validated since a Garmin Edge 840 paired to it. Admitted only
    /// while ITS own opt-in is on — restated here so the gate can express one rule per key rather than one
    /// rule per opcode.
    public static let broadcastHrKey = "whoop_live_hr_in_adv_ind_pkt"

    /// The other five keys the strap's 115/116 enumeration listed. Each is refused unconditionally: their
    /// effects are undocumented and unmeasured, and `max_collection_backlog` in particular reads `"0.0"`,
    /// which is not even a flag. Listed rather than merely omitted so the refusal is testable and so a
    /// future edit that wants one of them has to delete a line deliberately.
    public static let outOfScopeKeys: [String] = [
        "sigproc_wear_detect",
        "enable_rfid",
        "max_collection_backlog",
        "cont_collection_mode",
        "whoop_live_2_hrm_devices",
    ]

    /// Every device-config key the strap enumerated, in the order it served them. Reported in the UI and
    /// used by tests; never used to build a write.
    public static let enumeratedKeys: [String] = [
        "sigproc_wear_detect",
        "enable_rfid",
        "max_collection_backlog",
        "cont_collection_mode",
        broadcastHrKey,
        "whoop_live_2_hrm_devices",
        ecgRawDataKey,
    ]

    // MARK: - Values

    /// ASCII `'1'` — the gate on.
    public static let enabledValue: UInt8 = 0x31
    /// ASCII `'0'` — the gate off, and what a subscription-free MG reads today.
    public static let disabledValue: UInt8 = 0x30

    /// The value byte for a requested state.
    public static func value(on: Bool) -> UInt8 { on ? enabledValue : disabledValue }

    /// The value byte rendered as the character the strap stores.
    public static func valueString(on: Bool) -> String { on ? "1" : "0" }

    // MARK: - Body parsing

    /// Width of the key-name field in a device-config body (`Whoop5Config.deviceConfigBody` NUL-pads to
    /// this). Shared with `DeviceConfigReadProbe.nameFieldBytes`.
    public static let nameFieldBytes = 32

    /// The key name carried by a `SET_DEVICE_CONFIG_VALUE` payload, or nil when the payload is not shaped
    /// like one.
    ///
    /// The payload the send path holds is `[0x01] + deviceConfigBody(...)`: the inner b3 byte, then the
    /// 32-byte NUL-padded name, then the value. A name is only returned when it is printable ASCII and the
    /// remainder of the field is genuine NUL padding — so a body that is short, mis-shaped, or carrying
    /// binary in the name field yields nil and is refused rather than guessed at.
    public static func keyName(inSendPayload payload: [UInt8]) -> String? {
        guard payload.count >= 1 + nameFieldBytes, payload[0] == 0x01 else { return nil }
        let field = Array(payload[1..<(1 + nameFieldBytes)])
        var name: [UInt8] = []
        for b in field {
            if b == 0 { break }
            guard (0x20...0x7E).contains(b) else { return nil }
            name.append(b)
        }
        guard !name.isEmpty else { return nil }
        // Everything after the name must be NUL, or this is not a NUL-padded name field.
        for i in name.count..<field.count where field[i] != 0 { return nil }
        return String(decoding: name, as: UTF8.self)
    }

    /// The single value byte a `SET_DEVICE_CONFIG_VALUE` payload carries immediately after the 32-byte
    /// NUL-padded name field, or nil when the payload is too short to hold one. The gate only ever writes
    /// single-character values ('0'/'1'), so this one byte is the whole value. Used to tell a turn-OFF
    /// write from a turn-ON write in `admitsSend`.
    public static func valueByte(inSendPayload payload: [UInt8]) -> UInt8? {
        guard payload.count > 1 + nameFieldBytes, payload[0] == 0x01 else { return nil }
        return payload[1 + nameFieldBytes]
    }

    // MARK: - The allowlist predicate

    /// Whether a device-config KEY may be written, given the two opt-ins and the hardware attestation.
    ///
    /// `false` for every key that is not one of the two named ones — including all five of
    /// `outOfScopeKeys`, and including any key a future edit invents. The ECG key additionally requires
    /// `isMG`: `Whoop5Variant.unknown` is not MG, so an unattested strap fails this the same way a plain
    /// 5.0 does.
    public static func isWritableKey(_ key: String,
                                     ecgGateOptIn: Bool,
                                     isMG: Bool,
                                     broadcastHrOptIn: Bool) -> Bool {
        switch key {
        case ecgRawDataKey:  return ecgGateOptIn && isMG
        case broadcastHrKey: return broadcastHrOptIn
        default:             return false
        }
    }

    /// **The send allowlist itself.** True only for `SET_DEVICE_CONFIG_VALUE(119)` carrying a well-formed
    /// body whose key passes `isWritableKey`.
    ///
    /// Every other opcode is false — explicitly including `SET_FF_VALUE(120)`, which the R22 sequence
    /// keeps its own separate clause for and which must never be reachable from here.
    public static func admitsSend(opcode: UInt8,
                                  payload: [UInt8],
                                  ecgGateOptIn: Bool,
                                  isMG: Bool,
                                  broadcastHrOptIn: Bool) -> Bool {
        guard opcode == setDeviceConfigValueCmd else { return false }
        guard let key = keyName(inSendPayload: payload) else { return false }
        // #1061: turning the Broadcast-HR flag OFF is the safe UNDO and must NEVER be gated on the opt-in.
        // The opt-in (`broadcastHrEnabled`) is bound straight to the Settings switch, so it is already false
        // by the time the user disables — gating the OFF write on it made the toggle-off path DEAD (the
        // disable was refused here, the strap stayed advertising, and the app could not clear it). Same
        // lesson the #174 R22 disable clause records for SET_FF_VALUE. So admit the Broadcast-HR OFF write
        // unconditionally; the ON write (and the ECG key, both directions) stay gated by `isWritableKey`.
        if key == broadcastHrKey, valueByte(inSendPayload: payload) == disabledValue { return true }
        return isWritableKey(key, ecgGateOptIn: ecgGateOptIn, isMG: isMG, broadcastHrOptIn: broadcastHrOptIn)
    }

    /// The read verb the post-write verification is allowed to send, and only that one. 128
    /// (`GET_FF_VALUE`) is the other namespace's read verb and is not needed here.
    public static func isReadBackOpcode(_ opcode: UInt8) -> Bool { opcode == getDeviceConfigValueCmd }

    // MARK: - Frames

    /// The `SET_DEVICE_CONFIG_VALUE(119)` payload that sets the ECG gate.
    ///
    /// Deliberately the SAME 33-byte single-value body the Broadcast-HR write has used on real hardware
    /// since #181 — `[0x01] + [name NUL-padded to 32][value]`. The strap serves multi-character values
    /// (`max_collection_backlog` reads `"0.0"`), so the READ side must handle them; but this key's observed
    /// value is a single ASCII digit and a one-character write is the shape hardware has already accepted.
    /// Writing a longer value is not needed here and is not inferred into existence.
    public static func writePayload(on: Bool) -> [UInt8] {
        [0x01] + Whoop5Config.deviceConfigBody(name: ecgRawDataKey, value: value(on: on))
    }

    /// The `GET_DEVICE_CONFIG_VALUE(121)` payload that reads the ECG gate back. Same request body the
    /// read probe uses, so both paths ask in exactly one way.
    public static func readBackPayload() -> [UInt8] {
        DeviceConfigReadProbe.requestBody(key: ecgRawDataKey)
    }
}

// MARK: - Report

/// The result of one ECG-gate write + mandatory read-back, as a copyable report.
///
/// Order-dependent and pure (`noteWriteAck` → `noteReadBack`/`noteReadBackTimeout` → `render`), so
/// `swift test` covers the whole verdict table without a strap. Kotlin twin:
/// `EcgRawDataGateReport` in `android/…/protocol/DeviceConfigWriteGate.kt`; the rendered text is
/// byte-identical across platforms so a shared strap log reads the same either side.
public struct EcgRawDataGateReport: Equatable, Sendable {

    /// What the run established. The headline, and deliberately blunt about the case that matters:
    /// a write whose ack said SUCCESS but whose read-back did not move is `.unchanged`, not success.
    public enum Verdict: String, Equatable, Sendable {
        /// Read-back returned exactly the value that was requested. The only success case.
        case confirmed
        /// Read-back returned a DIFFERENT value than requested — the write did not take.
        case unchanged
        /// The strap answered the read-back but did not echo the key, so no value can be claimed.
        case notClaimed
        /// The strap refused the read-back verb, or answered FAILURE for the key.
        case refused
        /// No reply to the read-back inside its window.
        case silent
        /// A reply arrived that could not be decoded (CRC, envelope, short record).
        case undecodable
        /// The read-back has not resolved yet.
        case pending
    }

    /// The value that was requested, as the strap stores it ("1" or "0").
    public let requested: String
    /// Result code of the WRITE's own COMMAND_RESPONSE, when one arrived. Recorded, never trusted.
    public private(set) var writeResultCode: Int?
    /// The value the read-back actually returned. nil means "no value claimed", never "zero".
    public private(set) var storedValue: String?
    /// Result code of the READ-BACK's COMMAND_RESPONSE.
    public private(set) var readBackResultCode: Int?
    /// Raw read-back record bytes as hex, always reported whatever else decodes.
    public private(set) var readBackRecordHex: String?
    /// Trace lines, one per round-trip.
    public private(set) var trace: [String] = []
    /// The verdict so far.
    public private(set) var verdict: Verdict = .pending

    public init(on: Bool) {
        self.requested = DeviceConfigWriteGate.valueString(on: on)
        trace.append("SET_DEVICE_CONFIG_VALUE(119) key=\"\(DeviceConfigWriteGate.ecgRawDataKey)\" value='\(requested)' sent")
    }

    /// Record the write's own ack. It is logged and NOT used to decide anything: #891 established that a
    /// SUCCESS result code does not prove state changed.
    public mutating func noteWriteAck(resultCode: Int?) {
        writeResultCode = resultCode
        let label = resultCode.map { "\(FeatureFlagProbe.resultLabel($0))(\($0))" } ?? "(unlabelled)"
        trace.append("write ack → result=\(label) — recorded, not treated as proof; the read-back below is the proof")
    }

    /// Record the decoded read-back and reach a verdict.
    public mutating func noteReadBack(_ r: DeviceConfigReadProbe.ValueResponse) {
        readBackResultCode = r.resultCode
        readBackRecordHex = r.recordHex
        // The gate stores a single ASCII digit ('0'/'1'), so the one byte after the echoed name field is
        // the whole value — read it with the shared read-probe's single-byte accessor. (Multi-character
        // device-config values like max_collection_backlog="0.0" belong to the read probe, not this gate.)
        let stored = r.value(for: DeviceConfigWriteGate.ecgRawDataKey)
            .flatMap { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : nil }
        storedValue = stored
        var line = "GET_DEVICE_CONFIG_VALUE(121) key=\"\(DeviceConfigWriteGate.ecgRawDataKey)\""
        if let c = r.resultCode { line += " → result=\(FeatureFlagProbe.resultLabel(c))(\(c))" } else { line += " →" }
        if let stored { line += " value='\(stored)'" }
        line += " record=[\(r.recordHex)]"
        trace.append(line)

        if r.isUnsupported || r.isFailure {
            verdict = .refused
        } else if let stored {
            verdict = stored == requested ? .confirmed : .unchanged
        } else {
            verdict = .notClaimed
        }
    }

    /// Record a read-back reply that could not be decoded.
    public mutating func noteReadBackFailure(_ f: DeviceConfigReadProbe.ParseFailure) {
        let why: String
        switch f {
        case .crc:          why = "CRC failed — frame rejected (never decoded)"
        case .envelope:     why = "not a COMMAND_RESPONSE envelope"
        case .wrongCommand: why = "COMMAND_RESPONSE for a different command"
        case .truncated:    why = "record too short to hold a response"
        }
        trace.append("read-back reply not decoded: \(why)")
        verdict = .undecodable
    }

    /// Record the strap answering nothing at all to the read-back.
    public mutating func noteReadBackTimeout(seconds: Int) {
        trace.append("GET_DEVICE_CONFIG_VALUE(121) → no COMMAND_RESPONSE within \(seconds)s")
        verdict = .silent
    }

    /// One-line summary, suitable for a Settings row.
    public var summary: String {
        switch verdict {
        case .confirmed:
            return "Strap now reports \(DeviceConfigWriteGate.ecgRawDataKey)='\(requested)' (read back, not just acked)."
        case .unchanged:
            return "Write did NOT take: asked for '\(requested)', strap still reports '\(storedValue ?? "?")'."
        case .notClaimed:
            return "Strap answered the read-back but did not echo the key, so no value is claimed."
        case .refused:
            return "Strap refused the read-back for this key — the stored value is unknown."
        case .silent:
            return "No reply to the read-back — the stored value is unknown."
        case .undecodable:
            return "The read-back reply did not decode — the stored value is unknown."
        case .pending:
            return "Waiting for the read-back…"
        }
    }

    /// The full copyable report.
    public func render() -> String {
        var sb = "#891 ECG RAW-DATA GATE — WHOOP MG\n"
        sb += "Key: \(DeviceConfigWriteGate.ecgRawDataKey) (the strap's own 115/116 enumeration listed it)\n"
        sb += "Wrote '\(requested)' via SET_DEVICE_CONFIG_VALUE(119), then read it back with "
        sb += "GET_DEVICE_CONFIG_VALUE(121). SET_FF_VALUE(120) is never sent from this path, and no other "
        sb += "device-config key is writable from it.\n"
        sb += "\nVerdict: \(verdict.rawValue) — \(summary)\n"
        sb += "\nExchange:\n"
        for line in trace { sb += "  " + line + "\n" }
        sb += "\nWhether this gate actually produces ECG data is UNKNOWN. If it now reads '1' and a "
        sb += "TOGGLE_LABRADOR listen still yields zero packets, that is a real result for #891 — please "
        sb += "share this report there either way.\n"
        return sb
    }
}
