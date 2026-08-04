import Foundation

/// #174: the key-aware allowlist for `SET_FF_VALUE` (120 / 0x78) — the feature-flag WRITE verb the R22
/// enable and disable sequences share.
///
/// ## Why this exists
///
/// Before this file the 5/MG send path admitted opcode 120 on an opcode-only clause:
/// `command == .setConfig && PuffinExperiment.deepDataEnabled`. That admits **any** feature-flag key with
/// **any** value for as long as the deep-data opt-in happens to be on. The sixteen R22 keys are the only
/// ones NOOP has any business writing, and the disable path is about to double the number of values that
/// travel through that opcode, so the clause is tightened at the same time rather than widened.
///
/// This is the same discipline `DeviceConfigReadProbe.isReadOnlyOpcode` established for the read probes:
/// one pure predicate that the BLE send path itself consults, so a unit test proving the predicate rejects
/// something is proving it about the real wire path and not about a parallel copy of the rule.
///
/// ## What it admits
///
/// Two predicates, not one, because the enable and the disable directions have **different gates** as well
/// as different values:
///
/// | predicate | opcode | key | value | gate |
/// |---|---|---|---|---|
/// | `admitsEnableWrite` | 120 `SET_FF_VALUE` | one of `Whoop5Config.enableR22Sequence` | that key's own enable value | deep-data opt-in |
/// | `admitsDisableWrite` | 120 `SET_FF_VALUE` | one of `Whoop5Config.enableR22Sequence` | `featureFlagOffValue` only | a disable run in flight |
/// | anything else | — | — | — | refused |
///
/// **Why the disable direction is gated on the run and not on the pref.** `deepDataEnabled` is bound
/// straight to a SwiftUI `@AppStorage` switch, so it is already `false` by the time the user confirms they
/// want the flags cleared — gating the undo on it makes the undo unreachable from the one control a user
/// naturally reaches for. The run itself is the honest gate: it is only ever non-nil inside
/// `disableWhoop5DeepData()`, which is user-initiated, and it closes again the moment the run ends. This is
/// the same shape `isReadBackOpcode` + `r22DisableRun != nil` already uses for the 128 read-back.
///
/// Splitting the predicates also makes the invariant exact rather than approximate: **an off value on the
/// wire means a disable run is in flight**, and an enable value on the wire means the opt-in is on. A single
/// predicate admitting either value under either gate could not say that. A value outside the pair is
/// refused even for an R22 key: nothing in NOOP has a reason to write a third value, and admitting one would
/// mean a typo could put an arbitrary byte into persistent strap config. `SET_DEVICE_CONFIG_VALUE` (119) is
/// refused outright — it keeps its own clause for the Broadcast-HR flag.
///
/// Pure: no CoreBluetooth, no I/O, no preferences. The app layer supplies the opt-in boolean. The Kotlin
/// twin is `com.noop.protocol.FeatureFlagWriteGate` — keep them byte-identical.
public enum FeatureFlagWriteGate {

    // MARK: - Opcodes

    /// `SET_FF_VALUE` (120 / 0x78) — the feature-flag write verb. The only opcode this gate admits.
    public static let setFeatureFlagValueCmd: UInt8 = 120

    /// `SET_DEVICE_CONFIG_VALUE` (119 / 0x77) — the OTHER namespace's write verb. Named here for exactly
    /// one reason: so `admitsSend` can be proved to refuse it.
    public static let setDeviceConfigValueCmd: UInt8 = 119

    /// `GET_FF_VALUE` (128 / 0x80) — the read verb the mandatory post-write read-back uses. Read-only, and
    /// already in `DeviceConfigReadProbe.readOnlyOpcodes`.
    public static let getFeatureFlagValueCmd: UInt8 = 128

    // MARK: - Keys and values

    /// The sixteen keys, taken from the enable sequence rather than restated — one list, one truth.
    public static var r22Keys: [String] { Whoop5Config.enableR22Sequence.map(\.name) }

    /// The value the enable sequence writes for `key`, or nil when `key` is not an R22 flag.
    public static func enableValue(for key: String) -> UInt8? {
        Whoop5Config.enableR22Sequence.first { $0.name == key }?.value
    }

    /// Whether `value` is the ENABLE value for `key` — the only value the enable direction may write.
    public static func isEnableValue(_ value: UInt8, for key: String) -> Bool {
        guard let on = enableValue(for: key) else { return false }
        return value == on
    }

    /// Whether `key` is one of the sixteen AND `value` is the documented off value — the only pair the
    /// disable direction may write. The key check is what stops the off value reaching an arbitrary flag.
    public static func isOffValue(_ value: UInt8, for key: String) -> Bool {
        guard enableValue(for: key) != nil else { return false }
        return value == Whoop5Config.featureFlagOffValue
    }

    // MARK: - Body parsing

    /// Width of the key-name field in a feature-flag body (`Whoop5Config.payloadBody` NUL-pads to this).
    public static let nameFieldBytes = 32

    /// Total length of the feature-flag body: 32-byte name, value byte, 7 zero bytes.
    public static let bodyBytes = 40

    /// The key name and value carried by a `SET_FF_VALUE` payload, or nil when the payload is not shaped
    /// like one.
    ///
    /// The payload the send path holds is `[0x01] + payloadBody(...)`: the inner b3 byte, then the 32-byte
    /// NUL-padded name, then the value, then 7 zeroes. A name is only returned when it is printable ASCII
    /// and the remainder of the field is genuine NUL padding — so a body that is short, mis-shaped, or
    /// carrying binary in the name field yields nil and is refused rather than guessed at. Mirrors
    /// `DeviceConfigWriteGate.keyName(inSendPayload:)` on the other namespace.
    public static func keyAndValue(inSendPayload payload: [UInt8]) -> (key: String, value: UInt8)? {
        guard payload.count >= 1 + bodyBytes, payload[0] == 0x01 else { return nil }
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
        return (String(decoding: name, as: UTF8.self), payload[1 + nameFieldBytes])
    }

    // MARK: - The allowlist predicate

    /// **The enable direction's send allowlist.** True only for `SET_FF_VALUE(120)` carrying a well-formed
    /// body whose key is one of the sixteen and whose value is that key's own enable value, while the
    /// deep-data opt-in is on.
    ///
    /// Every other opcode is false — explicitly including `SET_DEVICE_CONFIG_VALUE(119)`, which keeps its
    /// own separate clause and must never be reachable from here. The off value is NOT admitted here; it
    /// belongs to `admitsDisableWrite` and its own gate.
    public static func admitsEnableWrite(opcode: UInt8, payload: [UInt8], deepDataOptIn: Bool) -> Bool {
        guard deepDataOptIn else { return false }
        guard opcode == setFeatureFlagValueCmd else { return false }
        guard let (key, value) = keyAndValue(inSendPayload: payload) else { return false }
        return isEnableValue(value, for: key)
    }

    /// **The disable direction's send allowlist.** True only for `SET_FF_VALUE(120)` carrying a well-formed
    /// body whose key is one of the sixteen and whose value is `featureFlagOffValue`, while a disable run is
    /// actually in flight.
    ///
    /// `disableRunInFlight` is `r22DisableRun != nil` at the call site — deliberately NOT the deep-data
    /// preference. The preference is already `false` by the time a user confirms the undo (the switch writes
    /// it before the confirmation dialog is raised), so gating on it makes the undo unreachable from the
    /// toggle. Gating on the run is also strictly narrower in the other direction: with the opt-in merely
    /// left on, no off value can be sent unless a run is genuinely walking its plan.
    public static func admitsDisableWrite(opcode: UInt8, payload: [UInt8], disableRunInFlight: Bool) -> Bool {
        guard disableRunInFlight else { return false }
        guard opcode == setFeatureFlagValueCmd else { return false }
        guard let (key, value) = keyAndValue(inSendPayload: payload) else { return false }
        return isOffValue(value, for: key)
    }

    /// The read verb the post-write verification is allowed to send, and only that one.
    public static func isReadBackOpcode(_ opcode: UInt8) -> Bool { opcode == getFeatureFlagValueCmd }
}

// MARK: - Report

/// #174: one R22 **disable** run — write `'0'` to the sixteen feature flags, then read every one of them
/// back and report the value the strap actually stores.
///
/// ## The shape of the run, and why it is not just sixteen writes
///
/// `Whoop5Config.featureFlagOffValue` explains why `'0'` is an inference: it is the confirmed off value in
/// the device-config namespace and shares that namespace's whole wire idiom, but no feature flag has ever
/// been *observed* holding it. So the run is staged, and the first stage is an experiment:
///
/// 1. **Probe.** Write `'0'` to ONE flag, then read it back with `GET_FF_VALUE(128)`.
/// 2. **Gate.** If the strap did not stop reporting the old value, STOP. Fifteen keys are left untouched
///    and the report says `'0'` is not how this namespace spells off — a real, publishable answer.
/// 3. **Clear.** Only on a good probe, write `'0'` to the remaining fifteen.
/// 4. **Verify.** Read all sixteen back and tabulate.
///
/// The staging is the point. A blanket sixteen-write on an inferred byte would leave a user unable to tell
/// "it worked" from "the strap ignored all of it", and would move fifteen keys to find out.
///
/// ## The ack is never the proof
///
/// Every write's own `COMMAND_RESPONSE` is recorded and **not believed**. `SELECT_WRIST` on this firmware
/// returns SUCCESS for a no-op and FAILURE for a real mutation, so a result byte says nothing reliable
/// about whether state moved. Only the value that comes back from a 128 read is reported as state, and a
/// SUCCESS ack whose read-back did not move is reported as `unchanged`, not as success. (Discipline owed
/// to #907 / #891.)
///
/// ## Three outcomes, kept apart
///
/// The read-back separates possibilities that a boolean "did it work" would blur — see the table on
/// `Whoop5Config.featureFlagOffValue`. `.cleared` (the key now holds `'0'`) and `.unset` (the key no longer
/// has a stored value at all, so 128 answers FAILURE) are BOTH successes, and the difference is the most
/// interesting thing this path can learn about the firmware, so it is reported rather than collapsed.
///
/// Pure and order-dependent (`nextStep` → `note…` → `nextStep` → …), so `swift test` covers the whole run —
/// plan, gate, verdicts, rendering — without a strap. Kotlin twin: `R22DisableReport` in
/// `android/…/protocol/R22Disable.kt`; the rendered text is byte-identical across platforms so a shared
/// strap log reads the same either side.
public struct R22DisableReport: Equatable, Sendable {

    /// The flag the probe stage writes first.
    ///
    /// `enable_sig12` is chosen because it is the ONLY key with a hardware demonstration that a write to it
    /// changes stored state: running the enable sequence moved it from `'2'` (0x32) to `'1'` (0x31),
    /// confirmed by a `GET_FF_VALUE(128)` read before and after (#423, #103). That is what makes it a clean
    /// instrument. If a `'0'` write to *this* key does not move the stored value, the failure is
    /// attributable to the VALUE rather than to the key or the verb — every other key would leave that
    /// ambiguity open. It is also the flag with the least to lose: its effect is undocumented and it gates
    /// no stream NOOP reads.
    public static let probeKey = "enable_sig12"

    /// Which stage of the run a step belongs to.
    public enum Stage: String, Equatable, Sendable {
        /// The single write that tests whether `'0'` is accepted at all.
        case probeWrite
        /// The read-back of the probe write. The gate for everything after it.
        case probeRead
        /// One of the remaining fifteen writes.
        case clearWrite
        /// A final read-back of one key.
        case verifyRead
    }

    /// One planned round-trip.
    public struct Step: Equatable, Sendable {
        public let opcode: UInt8
        public let key: String
        public let stage: Stage
        public init(opcode: UInt8, key: String, stage: Stage) {
            self.opcode = opcode
            self.key = key
            self.stage = stage
        }
        /// Whether this step puts a value on the wire (as opposed to reading one back).
        public var isWrite: Bool { stage == .probeWrite || stage == .clearWrite }
    }

    /// What one key ended up in. `.cleared` and `.unset` are both successes.
    public enum KeyOutcome: String, Equatable, Sendable {
        /// Read back as `'0'`: the key exists and now holds the off value.
        case cleared
        /// The strap answered FAILURE for the key: it no longer has a stored value. The stronger result.
        case unset
        /// Read back as something other than `'0'` — the write did not take.
        case unchanged
        /// The strap answered, but did not echo the key, so no value can be claimed.
        case notClaimed
        /// No reply inside the step's window.
        case silent
        /// A reply arrived that could not be decoded (CRC, envelope, short record).
        case undecodable
        /// The run stopped before this key was written.
        case skipped

        /// Whether this outcome means the flag is no longer set to its R22 value.
        public var isSuccess: Bool { self == .cleared || self == .unset }
    }

    /// The overall verdict.
    public enum Verdict: String, Equatable, Sendable {
        /// The run has not finished.
        case pending
        /// Every one of the sixteen came back cleared or unset.
        case allCleared
        /// Some cleared, some did not.
        case partial
        /// The probe read-back came back showing the OLD value: `'0'` is not how this firmware clears a
        /// feature flag. The one verdict that is a genuine finding about the off value.
        case offValueRejected
        /// The probe read-back produced no usable answer — silent, undecodable, or the key was not echoed.
        /// Distinct from `offValueRejected` on purpose: nothing was learned about the off value, so this
        /// must not be reported as evidence against it.
        case probeInconclusive
        /// The run refused to start because the key list does not contain `probeKey`, so the off value could
        /// not be tested on one flag before the rest were written. Nothing was sent. Distinct from
        /// `probeInconclusive`: there the probe ran and answered nothing, here it could not run at all.
        case probeUnavailable
        /// The run was abandoned (disconnect, or the caller stopped it).
        case abandoned
    }

    /// One recorded read-back.
    public struct Reading: Equatable, Sendable {
        public let key: String
        public let stage: Stage
        /// The value byte, only when the strap echoed the key in a 32-byte name field. nil is "not
        /// claimed", never "zero".
        public let value: UInt8?
        public let resultCode: Int?
        public let recordHex: String
        public let outcome: KeyOutcome
        public init(key: String, stage: Stage, value: UInt8?, resultCode: Int?,
                    recordHex: String, outcome: KeyOutcome) {
            self.key = key
            self.stage = stage
            self.value = value
            self.resultCode = resultCode
            self.recordHex = recordHex
            self.outcome = outcome
        }
    }

    // MARK: Inputs

    /// The keys to clear, in order. Taken from the enable sequence so the two can never drift.
    public let keys: [String]

    // MARK: State

    private var cursor = 0
    private var plan: [Step] = []
    private var planBuilt = false
    /// Per-key outcome, keyed by name.
    public private(set) var outcomes: [String: KeyOutcome] = [:]
    public private(set) var readings: [Reading] = []
    public private(set) var writeAcks: [String: Int] = [:]
    public private(set) var trace: [String] = []
    public private(set) var verdict: Verdict = .pending
    /// True once the probe read-back has been seen and was good.
    public private(set) var probePassed = false
    /// True once the run has decided to stop early.
    private var stopped = false

    public init(keys: [String] = Whoop5Config.enableR22Sequence.map(\.name)) {
        self.keys = keys
        trace.append("R22 disable: writing '0' (0x30) to \(keys.count) feature flags via SET_FF_VALUE(120), "
                     + "each verified with GET_FF_VALUE(128). The write acks are recorded and NOT trusted.")
        trace.append("Probe first: \(R22DisableReport.probeKey) is written and read back alone; the other "
                     + "\(max(0, keys.count - 1)) are only written if the strap stops reporting the old value.")
    }

    // MARK: Plan

    /// The next round-trip, or nil when the run is over.
    ///
    /// The plan is built lazily in two halves so the gate is expressible: the probe pair up front, and the
    /// clear+verify tail only once the probe read-back has passed.
    public mutating func nextStep() -> Step? {
        if plan.isEmpty && !planBuilt {
            planBuilt = true
            guard keys.contains(R22DisableReport.probeKey) else {
                // FAIL CLOSED. This used to plan a blanket sequential run and set `probePassed = true`,
                // which defeated the entire point of the design: the safety argument for writing an
                // INFERRED value to sixteen persistent flags is that one flag is written and read back
                // first, and a key list without the probe key cannot make that argument. Writing all
                // sixteen unprobed is the one outcome the staging exists to prevent, and `probePassed`
                // recorded a probe that never ran — so a report could claim a passed gate on a run that
                // never had one. Unreachable from either shipped call site (both use the no-arg init), but
                // fail-open on a write path is not a defensible default whatever the current call sites do.
                stopped = true
                for key in keys { outcomes[key] = .skipped }
                verdict = .probeUnavailable
                trace.append("REFUSED: the key list does not contain the probe key "
                             + "\(R22DisableReport.probeKey), so '0' cannot be tested on one flag before the "
                             + "other \(max(0, keys.count - 1)) are written. Nothing was sent.")
                return nil
            }
            plan = [
                Step(opcode: FeatureFlagWriteGate.setFeatureFlagValueCmd,
                     key: R22DisableReport.probeKey, stage: .probeWrite),
                Step(opcode: FeatureFlagWriteGate.getFeatureFlagValueCmd,
                     key: R22DisableReport.probeKey, stage: .probeRead),
            ]
        }
        if stopped { return nil }
        if cursor >= plan.count {
            // The probe pair just finished and passed — extend the plan with the rest.
            if probePassed && !plan.contains(where: { $0.stage == .clearWrite }) {
                let rest = keys.filter { $0 != R22DisableReport.probeKey }
                plan += rest.map { Step(opcode: FeatureFlagWriteGate.setFeatureFlagValueCmd, key: $0, stage: .clearWrite) }
                plan += keys.map { Step(opcode: FeatureFlagWriteGate.getFeatureFlagValueCmd, key: $0, stage: .verifyRead) }
            } else {
                return nil
            }
        }
        guard cursor < plan.count else { return nil }
        let step = plan[cursor]
        cursor += 1
        return step
    }

    // MARK: Notes

    /// Record a write's own ack. Logged, never used to decide anything.
    public mutating func noteWriteAck(resultCode: Int?, for step: Step) {
        if let resultCode { writeAcks[step.key] = resultCode }
        let label = resultCode.map { "\(FeatureFlagProbe.resultLabel($0))(\($0))" } ?? "(unlabelled)"
        trace.append("SET_FF_VALUE(120) \(step.key)='0' → ack \(label) — recorded, not proof")
    }

    /// Record a decoded read-back and score the key.
    public mutating func noteReadBack(_ r: DeviceConfigReadProbe.ValueResponse, for step: Step) {
        let value = r.value(for: step.key)
        let outcome: KeyOutcome
        if r.isUnsupported {
            outcome = .unchanged            // the verb itself is refused; nothing can be claimed cleared
        } else if r.isFailure {
            outcome = .unset                // no stored value for this key any more
        } else if let value {
            outcome = value == Whoop5Config.featureFlagOffValue ? .cleared : .unchanged
        } else {
            outcome = .notClaimed
        }
        record(Reading(key: step.key, stage: step.stage, value: value, resultCode: r.resultCode,
                       recordHex: r.recordHex, outcome: outcome), for: step)
    }

    /// Record a read-back reply that could not be decoded.
    public mutating func noteReadFailure(_ f: DeviceConfigReadProbe.ParseFailure, for step: Step) {
        let why: String
        switch f {
        case .crc:          why = "CRC failed — frame rejected (never decoded)"
        case .envelope:     why = "not a COMMAND_RESPONSE envelope"
        case .wrongCommand: why = "COMMAND_RESPONSE for a different command"
        case .truncated:    why = "record too short to hold a response"
        }
        trace.append("GET_FF_VALUE(128) \(step.key) → reply not decoded: \(why)")
        record(Reading(key: step.key, stage: step.stage, value: nil, resultCode: nil,
                       recordHex: "(undecodable)", outcome: .undecodable), for: step)
    }

    /// Record the strap answering nothing at all.
    public mutating func noteTimeout(for step: Step, seconds: Int) {
        trace.append("\(step.isWrite ? "SET_FF_VALUE(120)" : "GET_FF_VALUE(128)") \(step.key) → no COMMAND_RESPONSE within \(seconds)s")
        guard !step.isWrite else { return }   // a silent WRITE is fine; the read-back is what decides
        record(Reading(key: step.key, stage: step.stage, value: nil, resultCode: nil,
                       recordHex: "(no reply)", outcome: .silent), for: step)
    }

    /// The link dropped, or the caller stopped the run.
    public mutating func noteAbandoned(_ why: String) {
        trace.append("Run abandoned: \(why)")
        stopped = true
        for key in keys where outcomes[key] == nil { outcomes[key] = .skipped }
        verdict = .abandoned
    }

    /// Score one reading, drive the probe gate, and finalise when the plan is done.
    private mutating func record(_ reading: Reading, for step: Step) {
        readings.append(reading)
        var line = "GET_FF_VALUE(128) \(step.key)"
        if let c = reading.resultCode { line += " → result=\(FeatureFlagProbe.resultLabel(c))(\(c))" } else { line += " →" }
        if let v = reading.value { line += " value=\(DeviceConfigReadProbe.valueLabel(v))" }
        line += " record=[\(reading.recordHex)] ⇒ \(reading.outcome.rawValue)"
        trace.append(line)

        // A verify read always sets the key's outcome. A probe read sets it too, and additionally decides
        // whether the rest of the run happens at all.
        outcomes[step.key] = reading.outcome

        if step.stage == .probeRead {
            probePassed = reading.outcome.isSuccess
            if !probePassed {
                stopped = true
                for key in keys where key != step.key { outcomes[key] = .skipped }
                // ONLY an unmoved value is evidence against '0'. Silence, an undecodable frame and a reply
                // that never echoed the key all mean "no usable answer" and must not be reported as a
                // rejection of the off value.
                verdict = reading.outcome == .unchanged ? .offValueRejected : .probeInconclusive
                trace.append(probeStopExplanation(reading.outcome))
            } else {
                trace.append("Probe passed (\(reading.outcome.rawValue)) — '0' moves a feature flag on this "
                             + "firmware. Clearing the remaining \(max(0, keys.count - 1)).")
            }
        }

        if !stopped, outcomes.count == keys.count, readings.contains(where: { $0.stage == .verifyRead }) {
            let cleared = keys.filter { outcomes[$0]?.isSuccess == true }.count
            verdict = cleared == keys.count ? .allCleared : .partial
        }
    }

    /// The sentence that explains a stopped run, in the terms that make it a result rather than a failure.
    private func probeStopExplanation(_ outcome: KeyOutcome) -> String {
        switch outcome {
        case .unchanged:
            return "STOPPED: the strap still reports the old value for \(R22DisableReport.probeKey), so "
                 + "'0' (0x30) is NOT how this firmware clears a feature flag. The other \(max(0, keys.count - 1)) "
                 + "flags were left untouched. This is a real finding — please share this report on #174."
        case .notClaimed:
            return "STOPPED: the strap answered but did not echo \(R22DisableReport.probeKey), so no value "
                 + "can be claimed either way. Nothing further was written."
        case .silent, .undecodable:
            return "STOPPED: no usable read-back for \(R22DisableReport.probeKey), so whether the write "
                 + "landed is unknown. Nothing further was written."
        default:
            return "STOPPED before clearing the remaining flags."
        }
    }

    // MARK: Rendering

    /// One-line summary, suitable for a Settings row.
    public var summary: String {
        let cleared = keys.filter { outcomes[$0]?.isSuccess == true }.count
        switch verdict {
        case .pending:          return "Clearing R22 flags…"
        case .allCleared:       return "All \(keys.count) R22 flags cleared on the strap (read back, not just acked)."
        case .partial:          return "\(cleared) of \(keys.count) R22 flags cleared — the rest did not take."
        case .offValueRejected: return "The strap refused '0' for \(R22DisableReport.probeKey); the other flags were left alone."
        case .probeInconclusive: return "No usable read-back for \(R22DisableReport.probeKey) — nothing further was written."
        case .probeUnavailable: return "Refused to run: \(R22DisableReport.probeKey) is not in the key list, so the off value could not be probed first. Nothing was sent."
        case .abandoned:        return "Disable run interrupted — \(cleared) of \(keys.count) flags confirmed cleared."
        }
    }

    /// The full copyable report.
    public func render() -> String {
        var sb = "#174 R22 DEEP-DATA DISABLE — WHOOP 5/MG\n"
        sb += "Wrote '0' (0x30) via SET_FF_VALUE(120) and read every key back with GET_FF_VALUE(128).\n"
        sb += "The write acks are recorded and NOT treated as proof: on this firmware a SUCCESS result byte\n"
        sb += "does not establish that state changed. Only the read-back is reported as state.\n"
        sb += "\nVerdict: \(verdict.rawValue) — \(summary)\n"
        sb += "\nPer key:\n"
        for key in keys {
            let outcome = outcomes[key] ?? .skipped
            let reading = readings.last { $0.key == key && $0.stage == .verifyRead }
                ?? readings.last { $0.key == key }
            let was = Whoop5Config.enableR22Sequence.first { $0.name == key }
                .map { DeviceConfigReadProbe.valueLabel($0.value) } ?? "?"
            let now = reading?.value.map { DeviceConfigReadProbe.valueLabel($0) }
                ?? (outcome == .unset ? "(no stored value)" : "(not claimed)")
            sb += "  \(DeviceConfigReadProbe.padded(key, to: 30)) enable wrote \(was) → now \(now)  [\(outcome.rawValue)]\n"
        }
        sb += "\nExchange:\n"
        for line in trace { sb += "  " + line + "\n" }
        sb += "\n" + R22DisableReport.caveats
        return sb
    }

    /// The standing caveats, kept in one place so the UI, the log and the report cannot drift.
    public static let caveats = """
    What this does and does not establish:
      • '0' as the off value is INFERRED. It is the confirmed off value in the device-config namespace
        (SET_DEVICE_CONFIG_VALUE/119, hardware-validated on the Broadcast-HR flag, #181) and that namespace
        shares this one's whole wire idiom — but no feature flag had ever been observed holding '0' before
        this run. The read-back above is what turns that inference into a measurement.
      • A cleared flag is not the same as reverted BEHAVIOUR. This reports what the strap STORES. Whether
        the deep records actually stop is a separate question, answered by wearing the strap and watching
        the type-0x2F deep-buffer capture stop, not by this report.
      • This does not restore a snapshot. NOOP never read these values before first writing them, so the
        strap's pre-NOOP state is unknown. The honest claim is "cleared the flags NOOP set".
      • disable_pip_r26_packets inverts: clearing it is expected to let PIP R26 packets flow AGAIN. That is
        the pre-R22 behaviour and is intended.
    """
}
