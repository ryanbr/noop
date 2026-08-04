import Foundation

/// #103: READ-ONLY probe of the two config **read** verbs — `GET_DEVICE_CONFIG_VALUE` (121 / 0x79) and
/// `GET_FF_VALUE` (128 / 0x80). Follow-up to the #761 enumeration probe, which asked the strap for key
/// NAMES; this asks for a key's VALUE.
///
/// ## Why
///
/// NOOP writes config two ways and reads it neither way. `SET_FF_VALUE` (120 / 0x78) writes the sixteen
/// R22 feature flags in `Whoop5Config.enableR22Sequence`; `SET_DEVICE_CONFIG_VALUE` (119 / 0x77) writes
/// the one device-config key NOOP knows (the Broadcast-HR flag, #181). Those are two *different
/// namespaces* sharing a body layout — and the 117/118 enumerate pair #761 built covers the feature-flag
/// namespace ONLY. The device-config namespace has never been read or enumerated here at all.
///
/// That matters for #103. NOOP already decodes a byte the deep record carries at offset 82 that reads as
/// real SpO2 on some straps and is flat 0x00 on others, which is what a subscription gate would look
/// like. If a config value governs it, it is far more likely to live in the device-config namespace than
/// among the sixteen flags NOOP already writes — and nobody has ever asked a strap for one.
///
/// ## What this establishes, and the honest failure case
///
/// **Both target opcodes may simply not be implemented in firmware.** The repo's own protocol table
/// (`Resources/whoop_protocol.json`, `CommandNumber`) names 121 `GET_DEVICE_CONFIG_VALUE` and 128
/// `GET_FF_VALUE`, but a name in a table is not a served verb: opcode 96 (`enterHighFreqHistoricalMode`)
/// is a standing example of a number the table carries that nothing in the wild sends. So the probe's
/// PRIMARY deliverable is a clean verdict per verb — **answered**, **rejected as UNSUPPORTED**,
/// **silent**, or **undecodable** — and "both verbs are unimplemented" is a useful, publishable result,
/// not a failure.
///
/// Those four are not interchangeable, and the verdict never treats them as such. **Only UNSUPPORTED is
/// the firmware's own answer**, so only UNSUPPORTED supports the sentence "this firmware does not serve
/// that verb". A timeout is a fact about one run and not even proof a frame reached the strap —
/// `BLEManager.send` returns without transmitting when there is no `cmdCharacteristic`, and again when
/// the 5/MG allowlist does not carry the opcode — while an undecodable reply is affirmative evidence the
/// strap DID transmit, which is the opposite of "not served". Both are reported as **unconfirmed**.
///
/// Only if a verb answers does the probe go on to read values: first the sixteen key names NOOP already
/// has (`Whoop5Config.enableR22Sequence` — their VALUES on a real strap have never been read, only
/// written), then a short list of GUESSED oxygen-related key names against the device-config namespace.
///
/// ## Read-only by construction
///
/// The probe writes command frames purely in order to read, the same shape as the Oura feature-status
/// probes NOOP already ships (`Packages/OuraProtocol/…/Commands.swift`) and as the #761 enumeration. The
/// SET verbs are named in `writeOpcodes` for exactly one reason: so the send allowlist can be expressed
/// as "`readOnlyOpcodes` only" and a unit test can prove 119/120 are rejected by it. Nothing in this file
/// or on its BLE path can form a SET frame.
///
/// ## Wire shape (a documented guess, and it fails closed)
///
/// Request: command 121 or 128 with body `[0x01]` — the inner b3 convention `CLIENT_HELLO` and the
/// SET_CONFIG family use — followed by the key name as ASCII NUL-padded to 32 bytes, the same name field
/// `Whoop5Config.payloadBody` / `deviceConfigBody` build for the SET side, minus the trailing value byte
/// a read has no reason to carry. That body shape is inferred from the SET side, not observed; if it is
/// wrong the strap answers FAILURE or nothing, which the report says plainly rather than papering over.
///
/// Response: an ordinary COMMAND_RESPONSE echoing the command byte, whose record sits behind the 2-byte
/// response header (`pay[1]` is the 5/MG result code) — the same `pay[2]` record start
/// `GET_BATTERY_LEVEL`, `GET_CLOCK` and the #761 replies all decode from. Beyond that offset **no field
/// layout is assumed**: the record is kept and reported as raw hex. A value is only ever *claimed* when
/// the reply echoes the key that was asked for inside a 32-byte NUL-padded name field, in which case the
/// byte immediately after that field is reported as the value — the SET side's own layout, checked
/// rather than assumed (`ValueResponse.value(for:)`). Note that on 5/MG the puffin envelope pads the
/// inner payload to a 4-byte boundary, so up to three trailing NULs in any record are envelope padding
/// rather than data; reading the value as "the byte after the echoed name field" rather than "the last
/// byte" is what keeps that padding out of the answer.
///
/// Everything fails closed: a frame whose CRCs don't verify, whose type isn't COMMAND_RESPONSE, or whose
/// record is too short is REJECTED rather than guessed at.
public enum DeviceConfigReadProbe {

    // MARK: - Wire constants

    /// `GET_DEVICE_CONFIG_VALUE` (121 / 0x79) — ask for one device-config value by key name. Read-only.
    /// Named in the repo's protocol table; never before sent by NOOP, and possibly unimplemented.
    public static let getDeviceConfigValueCmd: UInt8 = 121

    /// `GET_FF_VALUE` (128 / 0x80) — ask for one feature-flag value by key name. Read-only. Named in the
    /// repo's protocol table; never before sent by NOOP, and possibly unimplemented.
    public static let getFeatureFlagValueCmd: UInt8 = 128

    /// `SET_DEVICE_CONFIG_VALUE` (119 / 0x77). Listed here ONLY so the allowlist below can name what it
    /// excludes. This probe never sends it.
    public static let setDeviceConfigValueCmd: UInt8 = 119

    /// `SET_FF_VALUE` (120 / 0x78). Listed here ONLY so the allowlist below can name what it excludes.
    /// This probe never sends it.
    public static let setFeatureFlagValueCmd: UInt8 = 120

    /// The complete set of opcodes this probe may put on the wire. The BLE send path admits these two and
    /// **only** these two while a probe is in flight; `isReadOnlyOpcode` is the predicate it asks.
    public static let readOnlyOpcodes: Set<UInt8> = [getDeviceConfigValueCmd, getFeatureFlagValueCmd]

    /// The config WRITE verbs, which this probe must never emit. Kept as a named set so the read-only
    /// contract is testable as a property of the allowlist rather than as a claim in a comment.
    public static let writeOpcodes: Set<UInt8> = [setDeviceConfigValueCmd, setFeatureFlagValueCmd]

    /// The allowlist predicate itself. `false` for both SET verbs, for every opcode outside the pair, and
    /// therefore for anything a future edit might accidentally route through this path.
    public static func isReadOnlyOpcode(_ opcode: UInt8) -> Bool { readOnlyOpcodes.contains(opcode) }

    /// Width of the key-name field in the SET bodies (`Whoop5Config.payloadBody` /
    /// `deviceConfigBody` both NUL-pad the name to 32 bytes). The request mirrors it; a reply that echoes
    /// the key is read against it.
    public static let nameFieldBytes = 32

    /// Hard ceiling on round-trips in one probe, independent of how many keys the plan holds. A firmware
    /// that answers oddly must not be able to drive an unbounded write loop on the command characteristic.
    /// The full plan is 2 discovery + 16 known flags + the candidate list, comfortably under this.
    public static let maxSteps = 64

    /// The one device-config key NOOP already knows a real strap accepts: the Broadcast-HR flag written
    /// via `SET_DEVICE_CONFIG_VALUE` and hardware-validated in #181. Used as the discovery key for opcode
    /// 121 precisely because it is *known-good* — a FAILURE on this key is evidence about the verb, not
    /// about the key.
    public static let deviceConfigDiscoveryKey = "whoop_live_hr_in_adv_ind_pkt"

    /// **GUESSES.** Candidate oxygen-related key names to try against the device-config namespace. None of
    /// these has been observed on a wire, in a capture, or in any protocol table — they are constructed
    /// from the naming conventions the *known* keys follow (`enable_…`, `…_enable`, snake_case, and the
    /// `whoop_…` prefix the one known device-config key uses). They are reported as guesses everywhere
    /// they appear.
    ///
    /// This list is the one place to extend. Adding a name here adds a probe step and nothing else — the
    /// same pattern would let a future run try, say, `enable_sig13` (the undocumented `enable_sig11…` /
    /// `enable_sig12` series continued) without touching any other code.
    public static let oxygenCandidateKeys: [String] = [
        "enable_spo2",
        "enable_spo2_packets",
        "spo2_enable",
        "enable_blood_oxygen",
        "blood_oxygen_enable",
        "enable_pulse_ox",
        "enable_oxygen_packets",
        "spo2_subscription_enabled",
    ]

    /// The request body for one read: the inner b3 byte `0x01`, then the key name as ASCII NUL-padded to
    /// `nameFieldBytes`. A name longer than the field is truncated to it, exactly as the SET side does.
    public static func requestBody(key: String) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: nameFieldBytes)
        let bytes = Array(key.utf8)
        for i in 0..<min(nameFieldBytes, bytes.count) { body[i] = bytes[i] }
        return [0x01] + body
    }

    // MARK: - Decoded response

    /// Why a frame was not decoded. Distinct cases so the report can say *what* went wrong instead of
    /// silently dropping a reply. Mirrors `FeatureFlagProbe.ParseFailure`.
    public enum ParseFailure: String, Error, Equatable, Sendable {
        /// A CRC did not verify. Bad bytes never drive state (BLE safety contract §2).
        case crc
        /// Not a COMMAND_RESPONSE frame, or too short to hold the envelope.
        case envelope
        /// A COMMAND_RESPONSE for a different command.
        case wrongCommand
        /// The record is shorter than a response record can be.
        case truncated
    }

    /// One decoded config-read reply. Deliberately shallow: the record is kept RAW because no field
    /// layout for these two opcodes has ever been observed. The only structured read offered is
    /// `value(for:)`, and it only answers when the strap echoed the key back in the SET side's own
    /// 32-byte name field.
    public struct ValueResponse: Equatable, Sendable {
        /// Result code byte (`pay[1]`), labelled only on 5/MG where its meaning is pinned
        /// (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED); nil on WHOOP 4.0.
        public let resultCode: Int?
        /// The record bytes behind the 2-byte response header, exactly as received.
        public let record: [UInt8]

        public init(resultCode: Int?, record: [UInt8]) {
            self.resultCode = resultCode
            self.record = record
        }

        /// The firmware explicitly refused the verb. The single most informative outcome this probe can
        /// get, and the one that settles "is 121/128 implemented at all" in one round-trip.
        public var isUnsupported: Bool { resultCode == 3 }

        /// The firmware answered but reported failure — the verb exists, the request did not satisfy it
        /// (wrong body shape, or an unknown key).
        public var isFailure: Bool { resultCode == 0 }

        /// Raw record bytes as lowercase space-separated hex; always reported, whatever else decodes.
        public var recordHex: String { DeviceConfigReadProbe.hex(record) }

        /// Where `key` appears in the record as a NUL-padded 32-byte name field, or nil if it does not.
        /// Requires the padding to actually be NUL so a coincidental substring can't be mistaken for the
        /// name field.
        public func echoOffset(of key: String) -> Int? {
            let needle = Array(key.utf8)
            guard !needle.isEmpty, needle.count <= DeviceConfigReadProbe.nameFieldBytes else { return nil }
            let field = DeviceConfigReadProbe.nameFieldBytes
            guard record.count >= field else { return nil }
            for start in 0...(record.count - field) {
                var matched = true
                for i in 0..<needle.count where record[start + i] != needle[i] { matched = false; break }
                guard matched else { continue }
                // The rest of the field must be NUL padding, or this is not the name field.
                var padded = true
                for i in needle.count..<field where record[start + i] != 0 { padded = false; break }
                if padded { return start }
            }
            return nil
        }

        /// The value byte, reported ONLY when the strap echoed `key` in a 32-byte NUL-padded name field
        /// and the record extends one byte past it — the same `[name 32][value]` layout the SET bodies
        /// use. nil means "no value claimed", never "value is zero".
        public func value(for key: String) -> UInt8? {
            guard let off = echoOffset(of: key) else { return nil }
            let valueIndex = off + DeviceConfigReadProbe.nameFieldBytes
            guard valueIndex < record.count else { return nil }
            return record[valueIndex]
        }
    }

    // MARK: - Parsing

    /// Decode a config-read COMMAND_RESPONSE for `expecting` (121 or 128). CRC-gated: a frame whose
    /// checksums fail is rejected before any field is read.
    public static func parse(frame: [UInt8], family: DeviceFamily,
                             expecting: UInt8) -> Result<ValueResponse, ParseFailure> {
        // BLE safety contract §2: CRC-gate everything. A frame that fails either checksum is not data.
        guard verifyFrame(frame, family: family).ok else { return .failure(.crc) }
        let typeOff = family == .whoop5 ? 8 : 4
        let cmdOff = typeOff + 2
        guard frame.count > cmdOff + 4 else { return .failure(.envelope) }
        guard frame[typeOff] == commandResponseType else { return .failure(.envelope) }
        guard frame[cmdOff] == expecting else { return .failure(.wrongCommand) }
        let payStart = cmdOff + 1
        let payEnd = frame.count - 4          // strip the CRC32 trailer
        guard payEnd > payStart else { return .failure(.truncated) }
        let pay = Array(frame[payStart..<payEnd])
        guard pay.count > responseHeaderBytes else { return .failure(.truncated) }
        let resultCode: Int? = family == .whoop5 ? Int(pay[1]) : nil
        return .success(ValueResponse(resultCode: resultCode, record: Array(pay[responseHeaderBytes...])))
    }

    /// COMMAND_RESPONSE packet type (`PacketType.COMMAND_RESPONSE` = 36 / 0x24).
    static let commandResponseType: UInt8 = 36

    /// Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code.
    static let responseHeaderBytes = 2

    /// Lowercase space-separated hex, capped so one oversized record can't flood the report. The cap is
    /// reported when it bites rather than silently truncating.
    static func hex(_ bytes: [UInt8]) -> String {
        let shown = bytes.prefix(maxHexBytes)
        var out = shown.map { String(format: "%02x", $0) }.joined(separator: " ")
        if bytes.count > maxHexBytes { out += " … (\(bytes.count) bytes)" }
        return out.isEmpty ? "(empty)" : out
    }

    /// Record bytes rendered in the report before the hex is elided.
    static let maxHexBytes = 48

    /// Pad `s` on the right to `width`, used instead of a printf `%-Ns` so Swift and Kotlin render the
    /// report identically (Swift's `%s` takes a C string, Kotlin's takes a `String`).
    static func padded(_ s: String, to width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// A value byte rendered as both its character (when printable, which the SET side's ASCII digits
    /// always are) and its number.
    static func valueLabel(_ v: UInt8) -> String {
        (32...126).contains(v) ? "'\(Character(UnicodeScalar(v)))' (0x\(String(format: "%02x", v)))"
                               : "0x\(String(format: "%02x", v))"
    }
}

// MARK: - Report

/// The running result of one device-config read probe: the plan it walks, the per-verb verdict it
/// reaches, the values it manages to read, and the copyable transcript. Pure and order-dependent
/// (`nextStep` → `note…` → `nextStep` → …), so `swift test` covers the whole probe — plan, verdicts,
/// rendering — without a strap. Kotlin twin: `DeviceConfigReadProbeReport` in
/// `android/…/protocol/DeviceConfigReadProbe.kt`; the rendered text is byte-identical across platforms so
/// a shared strap log reads the same either side.
public struct DeviceConfigReadProbeReport: Equatable, Sendable {

    /// Which part of the plan a step belongs to. Drives both the ordering and the report's sections.
    public enum Group: String, Equatable, Sendable {
        /// One round-trip per verb against a key that verb should know, to establish whether it answers.
        case discovery
        /// The sixteen flag names NOOP already writes — reading their VALUES is new information.
        case knownFlag
        /// Guessed oxygen-related key names. Labelled as guesses everywhere.
        case candidate
    }

    /// One planned round-trip.
    public struct Step: Equatable, Sendable {
        public let opcode: UInt8
        public let key: String
        public let group: Group
        public init(opcode: UInt8, key: String, group: Group) {
            self.opcode = opcode
            self.key = key
            self.group = group
        }
    }

    /// What one verb has been shown to do. `untried` until its discovery step resolves.
    public enum VerbStatus: String, Equatable, Sendable {
        case untried
        /// A decodable COMMAND_RESPONSE came back and was not an explicit UNSUPPORTED.
        case answered
        /// The firmware refused the opcode (5/MG result code 3).
        case unsupported
        /// No reply inside the probe's per-step window.
        case silent
        /// A reply arrived but could not be decoded (CRC, envelope, or a short record).
        case undecodable
    }

    /// One value read (or attempted) for one key.
    public struct Reading: Equatable, Sendable {
        public let group: Group
        public let opcode: UInt8
        public let key: String
        /// The value byte, only when the strap echoed the key in a 32-byte name field. nil is "not
        /// claimed", never "zero".
        public let value: UInt8?
        public let resultCode: Int?
        public let recordHex: String
        public init(group: Group, opcode: UInt8, key: String, value: UInt8?,
                    resultCode: Int?, recordHex: String) {
            self.group = group
            self.opcode = opcode
            self.key = key
            self.value = value
            self.resultCode = resultCode
            self.recordHex = recordHex
        }
    }

    // MARK: Inputs

    /// Which family the probe ran against (labels only).
    public let family: DeviceFamily
    /// The flag names whose values to read — supplied by the caller from `Whoop5Config.enableR22Sequence`
    /// so this file never restates them.
    public let knownFlagKeys: [String]
    /// The guessed oxygen key names — supplied by the caller from `DeviceConfigReadProbe`.
    public let candidateKeys: [String]

    // MARK: Accumulated state

    /// Status of `GET_FF_VALUE` (128).
    public private(set) var featureFlagVerb: VerbStatus = .untried
    /// Status of `GET_DEVICE_CONFIG_VALUE` (121).
    public private(set) var deviceConfigVerb: VerbStatus = .untried
    /// Every reading, in the order the strap served it.
    public private(set) var readings: [Reading] = []
    /// Trace lines: one per round-trip plus any failure notes.
    public private(set) var trace: [String] = []
    /// Round-trips attempted. Bounds the walk against `DeviceConfigReadProbe.maxSteps`.
    public private(set) var steps = 0
    /// Set once the walk stopped for a reason worth naming beyond "the plan ran out".
    public private(set) var stopReason: String?
    /// Per-verb reply window, in seconds, recorded by `noteTimeout`. The verdict names the window a verb
    /// went silent through instead of converting that silence into a claim about the firmware.
    private var silenceWindow: [UInt8: Int] = [:]

    // MARK: Plan cursors

    private var phase = 0            // 0 discovery, 1 known flags, 2 candidates, 3 done
    private var cursor = 0
    /// `"opcode:key"` pairs already attempted, so discovery's key is not re-read in a later phase.
    private var attempted: Set<String> = []

    public init(family: DeviceFamily, knownFlagKeys: [String], candidateKeys: [String]) {
        self.family = family
        self.knownFlagKeys = knownFlagKeys
        self.candidateKeys = candidateKeys
    }

    // MARK: - Plan

    /// The next round-trip to send, or nil when the probe is done. Called after the previous reply has
    /// been noted, so a verb proved dead is skipped for every step it would otherwise have owned.
    public mutating func nextStep() -> Step? {
        guard steps < DeviceConfigReadProbe.maxSteps else {
            stopReason = stopReason ?? "safety cap of \(DeviceConfigReadProbe.maxSteps) round-trips reached"
            phase = 3
            return nil
        }
        while phase < 3 {
            if let step = stepInCurrentPhase() {
                cursor += 1
                let id = "\(step.opcode):\(step.key)"
                if attempted.contains(id) { continue }
                attempted.insert(id)
                steps += 1
                return step
            }
            phase += 1
            cursor = 0
        }
        return nil
    }

    /// One candidate step from the current phase, or nil when that phase is exhausted.
    private func stepInCurrentPhase() -> Step? {
        switch phase {
        case 0:
            // Discovery: one round-trip per verb, each against a key that verb has a reason to know.
            // 128 gets a flag NOOP writes; 121 gets the Broadcast-HR key, hardware-validated in #181.
            let plan: [Step] = [
                Step(opcode: DeviceConfigReadProbe.getFeatureFlagValueCmd,
                     key: knownFlagKeys.first ?? DeviceConfigReadProbe.deviceConfigDiscoveryKey,
                     group: .discovery),
                Step(opcode: DeviceConfigReadProbe.getDeviceConfigValueCmd,
                     key: DeviceConfigReadProbe.deviceConfigDiscoveryKey,
                     group: .discovery),
            ]
            guard cursor < plan.count else { return nil }
            return plan[cursor]
        case 1:
            // Known flag values, through whichever verb answered — 128 by preference (it owns the
            // feature-flag namespace), 121 as a fallback worth one look if only it survived.
            guard let verb = verbForFlags(), cursor < knownFlagKeys.count else { return nil }
            return Step(opcode: verb, key: knownFlagKeys[cursor], group: .knownFlag)
        case 2:
            // Guessed oxygen keys, through the device-config verb by preference — that namespace is the
            // one this probe exists to reach.
            guard let verb = verbForCandidates(), cursor < candidateKeys.count else { return nil }
            return Step(opcode: verb, key: candidateKeys[cursor], group: .candidate)
        default:
            return nil
        }
    }

    /// The verb to read feature-flag values through, or nil when neither answered.
    private func verbForFlags() -> UInt8? {
        if featureFlagVerb == .answered { return DeviceConfigReadProbe.getFeatureFlagValueCmd }
        if deviceConfigVerb == .answered { return DeviceConfigReadProbe.getDeviceConfigValueCmd }
        return nil
    }

    /// The verb to try guessed device-config keys through, or nil when neither answered.
    private func verbForCandidates() -> UInt8? {
        if deviceConfigVerb == .answered { return DeviceConfigReadProbe.getDeviceConfigValueCmd }
        if featureFlagVerb == .answered { return DeviceConfigReadProbe.getFeatureFlagValueCmd }
        return nil
    }

    // MARK: - Notes

    /// Record one decoded reply.
    public mutating func noteReply(_ r: DeviceConfigReadProbe.ValueResponse, for step: Step) {
        setStatus(r.isUnsupported ? .unsupported : .answered, for: step.opcode)
        let value = r.value(for: step.key)
        readings.append(Reading(group: step.group, opcode: step.opcode, key: step.key, value: value,
                                resultCode: r.resultCode, recordHex: r.recordHex))
        var line = "\(DeviceConfigReadProbeReport.opcodeLabel(step.opcode)) key=\"\(step.key)\""
        if let c = r.resultCode { line += " → result=\(FeatureFlagProbe.resultLabel(c))(\(c))" } else { line += " →" }
        if let v = value { line += " value=\(DeviceConfigReadProbe.valueLabel(v))" }
        line += " record=[\(r.recordHex)]"
        trace.append(line)
    }

    /// Record a reply that could not be decoded. The verb is marked undecodable, which retires it.
    public mutating func noteFailure(_ f: DeviceConfigReadProbe.ParseFailure, for step: Step) {
        let why: String
        switch f {
        case .crc:          why = "CRC failed — frame rejected (never decoded)"
        case .envelope:     why = "not a COMMAND_RESPONSE envelope"
        case .wrongCommand: why = "COMMAND_RESPONSE for a different command"
        case .truncated:    why = "record too short to hold a response"
        }
        setStatus(.undecodable, for: step.opcode)
        trace.append("\(DeviceConfigReadProbeReport.opcodeLabel(step.opcode)) key=\"\(step.key)\" reply not decoded: \(why)")
        stopReason = stopReason ?? why
    }

    /// Record the strap answering nothing at all within the per-step window. The verb is marked silent,
    /// which retires it — one no-reply must not cost another twenty timeouts.
    ///
    /// The window is kept, not just printed, because the verdict has to be able to say how long nothing
    /// came back for. Silence is not the firmware refusing; it does not even establish that a frame was
    /// transmitted (see the header), so it can never be reported as what the firmware serves.
    public mutating func noteTimeout(for step: Step, seconds: Int) {
        silenceWindow[step.opcode] = seconds
        setStatus(.silent, for: step.opcode)
        trace.append("\(DeviceConfigReadProbeReport.opcodeLabel(step.opcode)) key=\"\(step.key)\" → no COMMAND_RESPONSE within \(seconds)s")
    }

    /// A verb's status only ever moves off `untried`; a later step never upgrades a verdict already
    /// reached, so one lucky reply after an UNSUPPORTED cannot rewrite the headline.
    private mutating func setStatus(_ s: VerbStatus, for opcode: UInt8) {
        if opcode == DeviceConfigReadProbe.getFeatureFlagValueCmd {
            if featureFlagVerb == .untried || featureFlagVerb == .answered { featureFlagVerb = s }
        } else if opcode == DeviceConfigReadProbe.getDeviceConfigValueCmd {
            if deviceConfigVerb == .untried || deviceConfigVerb == .answered { deviceConfigVerb = s }
        }
    }

    // MARK: - Render

    /// Short opcode label used in the transcript.
    static func opcodeLabel(_ opcode: UInt8) -> String {
        opcode == DeviceConfigReadProbe.getDeviceConfigValueCmd
            ? "GET_DEVICE_CONFIG_VALUE(121)" : "GET_FF_VALUE(128)"
    }

    /// How one verb ended, worded to exactly the evidence behind it. See the file header for why the four
    /// statuses are not interchangeable; the short version is that only `unsupported` is the firmware
    /// answering, so only `unsupported` speaks for the firmware.
    private func outcome(_ status: VerbStatus, for opcode: UInt8) -> String {
        switch status {
        case .untried:     return "not asked"
        case .answered:    return "answered"
        case .unsupported: return "refused by firmware (UNSUPPORTED)"
        case .silent:
            guard let seconds = silenceWindow[opcode] else { return "served no reply — unconfirmed" }
            return "served no reply in \(seconds)s — unconfirmed"
        case .undecodable: return "replied but the frame did not decode — unconfirmed"
        }
    }

    /// One-line summary of what the probe established.
    ///
    /// "not served by this firmware" is a claim about the firmware, so it is made in exactly one case: the
    /// firmware refused BOTH verbs itself. Every other run in which nothing answered reports each verb
    /// against the evidence that verb produced, because two timeouts, one refusal plus one timeout, and a
    /// reply that failed to decode are three different findings that used to print as the same sentence.
    public var verdict: String {
        let answered = [featureFlagVerb, deviceConfigVerb].filter { $0 == .answered }.count
        if answered == 0 {
            if featureFlagVerb == .unsupported && deviceConfigVerb == .unsupported {
                return "neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121) is served by this "
                    + "firmware — rejected as UNSUPPORTED"
            }
            let ff = outcome(featureFlagVerb, for: DeviceConfigReadProbe.getFeatureFlagValueCmd)
            let dc = outcome(deviceConfigVerb, for: DeviceConfigReadProbe.getDeviceConfigValueCmd)
            return "no read verb answered — GET_FF_VALUE(128) \(ff); GET_DEVICE_CONFIG_VALUE(121) \(dc)"
        }
        let named = readings.filter { $0.value != nil }.count
        if named == 0 {
            return "\(answered) of 2 read verbs answered, but no reply echoed its key so no value is claimed"
        }
        return "\(answered) of 2 read verbs answered; read \(named) config value(s)"
    }

    /// The full copyable report.
    public func render() -> String {
        let fam = family == .whoop5 ? "WHOOP 5/MG" : "WHOOP 4.0"
        var sb = "#103 DEVICE-CONFIG READ PROBE — \(fam)\n"
        sb += "Read-only: GET_DEVICE_CONFIG_VALUE(121) + GET_FF_VALUE(128). No value is written; "
        sb += "SET_DEVICE_CONFIG_VALUE(119) and SET_FF_VALUE(120) are never sent from this path.\n"
        sb += "Follow-up to the #761 enumeration probe: that one asked for key NAMES, this asks for VALUES.\n"
        sb += "\nVerdict: \(verdict)\n"
        if let stopReason { sb += "Stopped: \(stopReason)\n" }

        sb += "\nRead verbs:\n"
        sb += "  " + DeviceConfigReadProbe.padded("GET_FF_VALUE(128)", to: 30) + featureFlagVerb.rawValue + "\n"
        sb += "  " + DeviceConfigReadProbe.padded("GET_DEVICE_CONFIG_VALUE(121)", to: 30) + deviceConfigVerb.rawValue + "\n"

        sb += section(.discovery,
                      title: "Discovery — one round-trip per verb against a key it should know",
                      empty: "(none — no reply was decoded)")
        sb += section(.knownFlag,
                      title: "Known feature-flag values (names NOOP already writes; values never read before)",
                      empty: "(none — the verb that would carry them did not answer)")
        sb += section(.candidate,
                      title: "Candidate oxygen keys — GUESSES, never observed on a wire or in any table",
                      empty: "(none — the verb that would carry them did not answer)")

        sb += "\nExchange:\n"
        for line in trace { sb += "  " + line + "\n" }
        return sb
    }

    /// One rendered section of readings.
    private func section(_ group: Group, title: String, empty: String) -> String {
        let rows = readings.filter { $0.group == group }
        var sb = "\n\(title) (\(rows.count)):\n"
        if rows.isEmpty {
            sb += "  " + empty + "\n"
            return sb
        }
        for (i, r) in rows.enumerated() {
            var line = String(format: "  %2d. ", i + 1) + DeviceConfigReadProbe.padded(r.key, to: 32)
            if let v = r.value {
                line += "= " + DeviceConfigReadProbe.valueLabel(v)
            } else if let c = r.resultCode {
                line += "— no value (result=\(FeatureFlagProbe.resultLabel(c))(\(c)))"
            } else {
                line += "— no value (the reply did not echo the key)"
            }
            sb += line + "\n"
        }
        return sb
    }
}
