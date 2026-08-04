import Foundation

// MARK: - WHOOP MG ECG ("Labrador") packet decode + command construction
//
// The WHOOP MG carries ECG electrodes in its conductive clasp (a plain WHOOP 5.0 does not — see
// `Whoop5Variant`). The strap's ECG subsystem is called "Labrador" in the protocol tables, and it is a
// SEPARATE realtime data type from the R-numbered `StrapSensorData` layouts this package already decodes:
// there is a FILTERED stream (live, display-ready) and a RAW stream (persisted on the strap for later
// offload). Both carry the same 17-byte status header; they differ only in what follows it.
//
// Provenance — and the line this file does not cross.
//
// The four command NUMBERS are already in this repo's own protocol table
// (`Resources/whoop_protocol.json`, `CommandNumber`), carried over from the upstream whoomp/goose
// reverse-engineering credited in ATTRIBUTION.md:
//     123 (0x7B) SELECT_WRIST · 124 (0x7C) TOGGLE_LABRADOR_DATA_GENERATION
//     125 (0x7D) TOGGLE_LABRADOR_RAW_SAVE · 139 (0x8B) TOGGLE_LABRADOR_FILTERED
// The packet FIELD LAYOUTS and the command PAYLOAD shapes below are protocol facts sourced from static
// analysis of the official iOS client (per the #822 precedent: facts are admissible with attribution;
// implementation expression is not). Nothing here is copied — every line is NOOP's own code, in NOOP's
// own style, and no WHOOP code, firmware or asset is present.
//
// What is NOT established, and is therefore never asserted:
//   • The packet TYPE byte these records arrive under. No capture exists, and the repo's `PacketType`
//     table has no Labrador entry. So this file decodes a PAYLOAD, and the app layer discovers the type
//     empirically by running `plausibleFilteredPayload` over unclassified frames and logging the hits.
//   • The `WristSelection` raw values. `right` is listed first in the client's enum, so right=0/left=1 is
//     the natural reading — but it is an INFERENCE, not an attested fact, and it is labelled as such
//     everywhere it surfaces (including in the UI, because picking the wrong one writes the wrong
//     persistent value to the strap).
//   • The `heartKeyProgress` "timed out" sentinel. The client's type is a union of a percentage and a
//     timed-out case; the sentinel VALUE is not attested, so an out-of-range byte is carried raw rather
//     than renamed into a state we cannot prove it means.
//   • Any clinical meaning whatsoever. `ArrhythmiaCheckResult` is computed ON-STRAP by an embedded
//     third-party classifier and simply arrives in every packet. NOOP decodes the byte. NOOP is not a
//     medical device and this value is not a diagnosis — see DISCLAIMER.md and the UI copy.
//
// The Kotlin twin is `com.noop.protocol.Whoop5Ecg` — keep the two byte-identical.

// MARK: - Enums

/// Per-packet signal-quality grade. Wire order defines the raw value.
public enum EcgSignalQuality: UInt8, Equatable, Sendable, CaseIterable {
    case unknown = 0
    case low = 1
    case medium = 2
    case high = 3

    public var label: String {
        switch self {
        case .unknown: return "unknown"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

/// The on-strap classifier's verdict, as carried in every Labrador packet.
///
/// This is DECODE ONLY. NOOP does not compute it, cannot validate it, and must never present it as a
/// finding — see the file header and the non-medical framing in the app layer. The enum's declaration
/// order is its raw value.
public enum EcgArrhythmiaCheckResult: UInt8, Equatable, Sendable, CaseIterable {
    case notComplete = 0
    case normalSinusRhythm = 1
    case signalUnreadable = 2
    case bradycardia = 3
    case afibDetected = 4
    case tachycardia = 5
    case inconclusive = 6

    /// The bare protocol token, for logs and diagnostics. Deliberately NOT a user-facing string: any
    /// surface a person reads has to carry the not-a-diagnosis framing with it, which is the app layer's
    /// job, not this enum's.
    public var token: String {
        switch self {
        case .notComplete: return "notComplete"
        case .normalSinusRhythm: return "normalSinusRhythm"
        case .signalUnreadable: return "signalUnreadable"
        case .bradycardia: return "bradycardia"
        case .afibDetected: return "afibDetected"
        case .tachycardia: return "tachycardia"
        case .inconclusive: return "inconclusive"
        }
    }
}

/// Where the on-strap classifier is in its run.
public enum EcgArrhythmiaCheckStatus: UInt8, Equatable, Sendable, CaseIterable {
    case notRunning = 0
    case inProgress = 1
    case checkComplete = 2

    public var token: String {
        switch self {
        case .notRunning: return "notRunning"
        case .inProgress: return "inProgress"
        case .checkComplete: return "checkComplete"
        }
    }
}

/// Classifier progress. The source type is a union of a percentage and a "timed out" case, but the
/// sentinel VALUE for the latter is not attested — so 0...100 decodes as a percentage and every other
/// byte is carried raw rather than promoted into a state we cannot prove.
public enum EcgHeartKeyProgress: Equatable, Sendable {
    case percent(UInt8)
    case unmapped(UInt8)

    public init(raw: UInt8) {
        self = raw <= 100 ? .percent(raw) : .unmapped(raw)
    }

    public var raw: UInt8 {
        switch self {
        case .percent(let v), .unmapped(let v): return v
        }
    }

    /// The percentage when the byte is in range, nil otherwise.
    public var percentValue: UInt8? {
        if case .percent(let v) = self { return v }
        return nil
    }
}

// MARK: - Shared status header

/// The 17-byte status block both Labrador packets open with, in wire order.
///
/// Multi-byte fields are little-endian, matching every other 5/MG field in this package.
public struct EcgStatusHeader: Equatable, Sendable {
    public let signalQuality: EcgSignalQuality
    /// Raw quality byte, kept so a value outside the known enum is never lost.
    public let signalQualityRaw: UInt8
    public let statusFlags: UInt8
    public let heartKeyStarted: Bool
    public let heartKeyIsRunning: Bool
    public let heartKeyIsStoppedAndComplete: Bool
    public let heartKeyLeadsAreOn: Bool
    public let heartKeyArrhythmiaCheckResult: EcgArrhythmiaCheckResult?
    /// Raw classifier byte. Non-nil `heartKeyArrhythmiaCheckResult` means it mapped; otherwise this is
    /// the only faithful record of what the strap sent.
    public let heartKeyArrhythmiaCheckResultRaw: UInt8
    public let heartKeyArrhythmiaCheckStatus: EcgArrhythmiaCheckStatus?
    public let heartKeyArrhythmiaCheckStatusRaw: UInt8
    public let heartKeyProgress: EcgHeartKeyProgress
    public let heartKeyUnreadableReason: UInt8
    public let heartKeyAverageHR: UInt8
    public let heartKeyHR: UInt8
    public let heartKeyHRV: UInt16
    public let heartKeyStressScore: UInt8
    public let numberOfECGSamples: UInt16

    /// Parse the header from the start of `payload`. Returns nil when fewer than 17 bytes are present.
    public init?(payload: [UInt8]) {
        guard payload.count >= Whoop5Ecg.headerLength else { return nil }
        let q = payload[0]
        signalQualityRaw = q
        signalQuality = EcgSignalQuality(rawValue: q) ?? .unknown
        statusFlags = payload[1]
        heartKeyStarted = payload[2] != 0
        heartKeyIsRunning = payload[3] != 0
        heartKeyIsStoppedAndComplete = payload[4] != 0
        heartKeyLeadsAreOn = payload[5] != 0
        heartKeyArrhythmiaCheckResultRaw = payload[6]
        heartKeyArrhythmiaCheckResult = EcgArrhythmiaCheckResult(rawValue: payload[6])
        heartKeyArrhythmiaCheckStatusRaw = payload[7]
        heartKeyArrhythmiaCheckStatus = EcgArrhythmiaCheckStatus(rawValue: payload[7])
        heartKeyProgress = EcgHeartKeyProgress(raw: payload[8])
        heartKeyUnreadableReason = payload[9]
        heartKeyAverageHR = payload[10]
        heartKeyHR = payload[11]
        heartKeyHRV = UInt16(payload[12]) | (UInt16(payload[13]) << 8)
        heartKeyStressScore = payload[14]
        numberOfECGSamples = UInt16(payload[15]) | (UInt16(payload[16]) << 8)
    }
}

// MARK: - Packets

/// The live ECG stream packet (`toggleRealtimeFilteredECG` / TOGGLE_LABRADOR_FILTERED, 0x8B).
///
/// 17 fields in wire order: the shared status header, then `numberOfECGSamples` signed 16-bit samples,
/// then whatever trailing bytes the envelope carried. The sample UNIT and SCALE are not attested, so the
/// array is named `filteredECGDataRaw` and no µV conversion is applied anywhere.
public struct FilteredLabradorPacket: Equatable, Sendable {
    public let header: EcgStatusHeader
    public let filteredECGDataRaw: [Int16]
    public let padding: [UInt8]

    public init(header: EcgStatusHeader, filteredECGDataRaw: [Int16], padding: [UInt8]) {
        self.header = header
        self.filteredECGDataRaw = filteredECGDataRaw
        self.padding = padding
    }
}

/// The persisted ECG record (`toggleSaveRawECG` / TOGGLE_LABRADOR_RAW_SAVE, 0x7D).
///
/// 20 fields in wire order: the same status header, then an OPAQUE raw-sample blob, then the leads-off
/// diagnostic arrays. The blob's bytes-per-sample is `rawECGDataRaw.count / numberOfECGSamples` — which
/// means the blob's LENGTH is not itself on the wire, so a decode needs that width supplied or resolved
/// (see `rawBytesPerSampleCandidates`).
public struct RawLabradorPacket: Equatable, Sendable {
    public let header: EcgStatusHeader
    /// Opaque. The container width and encoding are unattested, so the bytes are carried verbatim.
    public let rawECGDataRaw: [UInt8]
    public let numberOfLeadsOffSamples: UInt8
    public let leadsOffIRaw: [UInt16]
    public let leadsOffQRaw: [UInt16]
    public let padding: [UInt8]

    /// Bytes per raw sample for this record, or nil when the packet carried no samples to divide by.
    public var bytesPerSample: Int? {
        let n = Int(header.numberOfECGSamples)
        guard n > 0 else { return nil }
        return rawECGDataRaw.count / n
    }

    public init(header: EcgStatusHeader, rawECGDataRaw: [UInt8], numberOfLeadsOffSamples: UInt8,
                leadsOffIRaw: [UInt16], leadsOffQRaw: [UInt16], padding: [UInt8]) {
        self.header = header
        self.rawECGDataRaw = rawECGDataRaw
        self.numberOfLeadsOffSamples = numberOfLeadsOffSamples
        self.leadsOffIRaw = leadsOffIRaw
        self.leadsOffQRaw = leadsOffQRaw
        self.padding = padding
    }
}

// MARK: - Decode + command construction

public enum Whoop5Ecg {

    /// Bytes in the shared status header that both packets open with.
    public static let headerLength = 17

    /// Offset of the inner record's data in a puffin frame: `[0]SOF [1]fmt [2-3]len [4-5]hdr [6-7]crc16
    /// [8]type [9]seq [10]cmd [11...]data`. The same constant the #592/#690 probes use as `cmdOff + 1`.
    public static let puffinPayloadStart = 11

    /// Trailing bytes tolerated after the last decoded field. The puffin inner record is padded to a
    /// 4-byte boundary (`puffinCommandFrame`'s pad4), so a well-formed record leaves at most 3 spare
    /// bytes. Callers scanning an unfamiliar layout can widen it.
    public static let defaultMaxPadding = 3

    // MARK: Commands
    //
    // All four share the shape `{revision: UInt8, arg, padding}`. `revision` is the leading inner byte the
    // 5/MG command family already uses (CLIENT_HELLO and SET_CONFIG both lead with 0x01 — see
    // `Whoop5Config.frame`), and the struct's trailing `padding` is exactly what `puffinCommandFrame`'s
    // pad4 supplies, the same mechanism the 12-byte haptics body relies on (#48).

    /// SELECT_WRIST (123 / 0x7B).
    ///
    /// ⚠️ PERSISTENT DEVICE CONFIG. Unlike the three toggles below, this writes strap state that survives
    /// a disconnect, so it is kept as its own deliberate, separately-confirmed user action and is never
    /// bundled into a one-tap flow. Reversible — send it again with the other wrist.
    public static let selectWristCmd: UInt8 = 123

    /// TOGGLE_LABRADOR_DATA_GENERATION (124 / 0x7C) — the client's `mainControlECGDataGeneration`.
    public static let mainControlEcgDataGenerationCmd: UInt8 = 124

    /// TOGGLE_LABRADOR_RAW_SAVE (125 / 0x7D) — the client's `toggleSaveRawECG`.
    public static let toggleSaveRawEcgCmd: UInt8 = 125

    /// TOGGLE_LABRADOR_FILTERED (139 / 0x8B) — the client's `toggleRealtimeFilteredECG`.
    public static let toggleRealtimeFilteredEcgCmd: UInt8 = 139

    /// The `revision` byte every one of these commands leads with.
    public static let commandRevision: UInt8 = 0x01

    /// Which wrist the strap is worn on.
    ///
    /// ⚠️ The raw values are INFERRED, not attested: `right` is listed first in the client's enum, so
    /// right=0/left=1 is the natural reading. Since this command writes PERSISTENT strap state, a wrong
    /// inference writes a wrong persistent value — so every surface that offers it says so.
    public enum WristSelection: UInt8, Equatable, Sendable, CaseIterable {
        case right = 0
        case left = 1

        public var token: String { self == .right ? "right" : "left" }
    }

    /// The `mainControlECGDataGeneration` argument.
    public enum ControlSignal: UInt8, Equatable, Sendable, CaseIterable {
        case stop = 0
        case start = 1
        case restart = 2

        public var token: String {
            switch self {
            case .stop: return "stop"
            case .start: return "start"
            case .restart: return "restart"
            }
        }
    }

    /// The two-byte command payload every Labrador command carries: `[revision, arg]`. The trailing
    /// `padding` field of the command struct is supplied by `puffinCommandFrame`'s pad4.
    public static func commandPayload(arg: UInt8) -> [UInt8] { [commandRevision, arg] }

    public static func selectWristPayload(_ wrist: WristSelection) -> [UInt8] {
        commandPayload(arg: wrist.rawValue)
    }

    public static func togglePayload(on: Bool) -> [UInt8] {
        commandPayload(arg: on ? 1 : 0)
    }

    public static func controlPayload(_ signal: ControlSignal) -> [UInt8] {
        commandPayload(arg: signal.rawValue)
    }

    /// The complete puffin frame for one Labrador command, ready for the 5/MG command characteristic.
    /// The app sends through `BLEManager.send(_:payload:)` (which builds the identical bytes); these
    /// builders exist so the exact wire form is pinned by a test and mirrored in Kotlin.
    public static func commandFrame(cmd: UInt8, arg: UInt8, seq: UInt8) -> [UInt8] {
        puffinCommandFrame(cmd: cmd, seq: seq, payload: commandPayload(arg: arg))
    }

    public static func selectWristFrame(_ wrist: WristSelection, seq: UInt8) -> [UInt8] {
        commandFrame(cmd: selectWristCmd, arg: wrist.rawValue, seq: seq)
    }

    public static func toggleRealtimeFilteredEcgFrame(on: Bool, seq: UInt8) -> [UInt8] {
        commandFrame(cmd: toggleRealtimeFilteredEcgCmd, arg: on ? 1 : 0, seq: seq)
    }

    public static func toggleSaveRawEcgFrame(on: Bool, seq: UInt8) -> [UInt8] {
        commandFrame(cmd: toggleSaveRawEcgCmd, arg: on ? 1 : 0, seq: seq)
    }

    public static func mainControlEcgDataGenerationFrame(_ signal: ControlSignal, seq: UInt8) -> [UInt8] {
        commandFrame(cmd: mainControlEcgDataGenerationCmd, arg: signal.rawValue, seq: seq)
    }

    /// Whether this Labrador command, **sent with this argument**, can make the strap emit ECG data on
    /// the REALTIME channel — the only channel a fixed listen window can observe.
    ///
    /// This is the predicate every "the strap accepted it and then produced nothing" claim rests on, so
    /// it lives here — pure, mirrored in Kotlin, and tested on both platforms — rather than in an app
    /// layer where only one platform would check it.
    ///
    /// The ARGUMENT is half the answer. Three of the four opcodes gate a data path and all three are
    /// toggles, so `toggleRealtimeFilteredEcg(0)` turns the stream **off** and can no more produce data
    /// than `selectWrist` can. A run built only from such commands has asked for nothing, and its silence
    /// is the expected outcome rather than a finding.
    ///
    /// Conservative by construction — three cases return `false`:
    ///
    /// - `selectWrist` configures which wrist the strap is worn on. It starts nothing, on either
    ///   argument.
    /// - `toggleSaveRawEcg` names flash, not a live channel (`RAW_SAVE`), and the name is the only
    ///   evidence anyone in this repo has about where its output lands. Counting it as observable would
    ///   let a raw-save-only run be read as "accepted and then silent", which a realtime window cannot
    ///   support — that is hypothesis (b) in #891, still open.
    /// - Any opcode outside the family, which includes an UNSOLICITED reply whose sent argument is not
    ///   known.
    ///
    /// A `false` can only ever weaken a verdict, never strengthen one, so an omission here fails safe.
    public static func requestsRealtimeData(cmd: UInt8, arg: UInt8) -> Bool {
        switch cmd {
        case toggleRealtimeFilteredEcgCmd:
            return arg != 0
        case mainControlEcgDataGenerationCmd:
            return arg == ControlSignal.start.rawValue || arg == ControlSignal.restart.rawValue
        default:
            return false
        }
    }

    // MARK: Filtered decode

    /// Decode a `FilteredLabradorPacket` from the inner record's PAYLOAD (i.e. the bytes after
    /// `[type][seq][cmd]`).
    ///
    /// Fails closed on a short header, and on a `numberOfECGSamples` the buffer cannot actually hold —
    /// a count that disagrees with the bytes present is a decode error, never a truncated best effort.
    public static func decodeFiltered(payload: [UInt8]) -> FilteredLabradorPacket? {
        guard let header = EcgStatusHeader(payload: payload) else { return nil }
        let n = Int(header.numberOfECGSamples)
        let end = headerLength + n * 2
        guard end <= payload.count else { return nil }
        var samples = [Int16]()
        samples.reserveCapacity(n)
        for i in 0..<n {
            let off = headerLength + i * 2
            samples.append(Int16(bitPattern: UInt16(payload[off]) | (UInt16(payload[off + 1]) << 8)))
        }
        return FilteredLabradorPacket(header: header,
                                      filteredECGDataRaw: samples,
                                      padding: Array(payload[end...]))
    }

    /// CRC-gated decode straight off a complete 5/MG frame. The frame must pass BOTH puffin CRCs — a
    /// frame that fails is rejected before any field is read, per the BLE safety contract.
    ///
    /// `payloadStart` defaults to the standard puffin inner-data offset. It is a parameter, not a
    /// constant, because the packet TYPE these records arrive under is not yet attested (see the file
    /// header), so a capture may show a different body offset.
    public static func decodeFilteredFrame(_ frame: [UInt8],
                                           payloadStart: Int = puffinPayloadStart) -> FilteredLabradorPacket? {
        guard let payload = innerPayload(frame, payloadStart: payloadStart) else { return nil }
        return decodeFiltered(payload: payload)
    }

    // MARK: Raw decode

    /// Decode a `RawLabradorPacket` from the inner record's PAYLOAD with an explicit sample width.
    ///
    /// `bytesPerSample` has to be supplied because the raw blob's length is NOT on the wire: the client
    /// derives the width by dividing the blob it already holds by `numberOfECGSamples`, which a
    /// byte-stream decoder cannot do until it knows where the blob ends. `rawBytesPerSampleCandidates`
    /// enumerates the widths a given buffer admits.
    public static func decodeRaw(payload: [UInt8], bytesPerSample: Int) -> RawLabradorPacket? {
        guard bytesPerSample > 0, let header = EcgStatusHeader(payload: payload) else { return nil }
        let n = Int(header.numberOfECGSamples)
        // `bytesPerSample` is caller-supplied on a public API, and `numberOfECGSamples` comes off the
        // wire — so BOTH the product and the following add are checked rather than assumed. Either would
        // trap in Swift and wrap to a NEGATIVE index in the Kotlin twin; a decode failure is the correct
        // outcome, not a crash. (`n = 1, bytesPerSample = .max` overflows only on the ADD, so checking
        // the multiply alone is not enough.)
        let (blobLength, mulOverflow) = n.multipliedReportingOverflow(by: bytesPerSample)
        guard !mulOverflow else { return nil }
        let (rawEnd, addOverflow) = headerLength.addingReportingOverflow(blobLength)
        guard !addOverflow else { return nil }
        // The leads-off count byte must itself be inside the buffer.
        guard rawEnd >= headerLength, rawEnd < payload.count else { return nil }
        let leadsOffCount = Int(payload[rawEnd])
        let iStart = rawEnd + 1
        let qStart = iStart + leadsOffCount * 2
        let qEnd = qStart + leadsOffCount * 2
        guard qEnd <= payload.count else { return nil }

        var leadsOffI = [UInt16]()
        var leadsOffQ = [UInt16]()
        leadsOffI.reserveCapacity(leadsOffCount)
        leadsOffQ.reserveCapacity(leadsOffCount)
        for i in 0..<leadsOffCount {
            let io = iStart + i * 2
            let qo = qStart + i * 2
            leadsOffI.append(UInt16(payload[io]) | (UInt16(payload[io + 1]) << 8))
            leadsOffQ.append(UInt16(payload[qo]) | (UInt16(payload[qo + 1]) << 8))
        }
        return RawLabradorPacket(header: header,
                                 rawECGDataRaw: Array(payload[headerLength..<rawEnd]),
                                 numberOfLeadsOffSamples: payload[rawEnd],
                                 leadsOffIRaw: leadsOffI,
                                 leadsOffQRaw: leadsOffQ,
                                 padding: Array(payload[qEnd...]))
    }

    /// Every sample width in `widths` that yields a structurally consistent raw record leaving at most
    /// `maxPadding` trailing bytes.
    ///
    /// This is a DISAMBIGUATION helper, not a claim: when it returns more than one width the buffer
    /// genuinely does not determine the answer, and the honest move is to keep the bytes and wait for a
    /// capture rather than pick the prettiest candidate.
    public static func rawBytesPerSampleCandidates(payload: [UInt8],
                                                   widths: [Int] = [1, 2, 3, 4],
                                                   maxPadding: Int = defaultMaxPadding) -> [Int] {
        widths.filter { width in
            guard let packet = decodeRaw(payload: payload, bytesPerSample: width) else { return false }
            return packet.padding.count <= maxPadding
        }
    }

    /// Decode a raw record only when the buffer admits exactly ONE sample width. Ambiguous or
    /// inconsistent buffers return nil rather than a guess.
    public static func decodeRaw(payload: [UInt8],
                                 widths: [Int] = [1, 2, 3, 4],
                                 maxPadding: Int = defaultMaxPadding) -> RawLabradorPacket? {
        let candidates = rawBytesPerSampleCandidates(payload: payload, widths: widths, maxPadding: maxPadding)
        guard candidates.count == 1 else { return nil }
        return decodeRaw(payload: payload, bytesPerSample: candidates[0])
    }

    /// CRC-gated raw decode straight off a complete 5/MG frame, with an explicit sample width.
    public static func decodeRawFrame(_ frame: [UInt8], bytesPerSample: Int,
                                      payloadStart: Int = puffinPayloadStart) -> RawLabradorPacket? {
        guard let payload = innerPayload(frame, payloadStart: payloadStart) else { return nil }
        return decodeRaw(payload: payload, bytesPerSample: bytesPerSample)
    }

    // MARK: Discovery

    /// A cheap structural triage for "could these bytes be a filtered Labrador payload?".
    ///
    /// Used by the app layer to hunt for the packet TYPE byte, which is not attested: while an ECG probe
    /// is armed, every unclassified 5/MG frame is run through this and the hits are logged with their
    /// type. It is a HEURISTIC — four booleans, three enum ranges and a length agreement — not a
    /// classifier, and nothing downstream may treat a hit as proof.
    public static func plausibleFilteredPayload(_ payload: [UInt8],
                                                maxPadding: Int = defaultMaxPadding) -> Bool {
        guard let header = EcgStatusHeader(payload: payload) else { return false }
        guard header.signalQualityRaw <= 3,
              header.heartKeyArrhythmiaCheckResult != nil,
              header.heartKeyArrhythmiaCheckStatus != nil else { return false }
        // The four booleans are Bool-typed on the wire, so anything but 0/1 rules the buffer out.
        guard payload[2] <= 1, payload[3] <= 1, payload[4] <= 1, payload[5] <= 1 else { return false }
        let n = Int(header.numberOfECGSamples)
        guard n > 0 else { return false }
        let end = headerLength + n * 2
        return end <= payload.count && payload.count - end <= maxPadding
    }

    /// The frame-level form of `plausibleFilteredPayload`, CRC-gated. This is what the app layer runs
    /// over unclassified 5/MG frames while an ECG probe is armed.
    public static func plausibleFilteredFrame(_ frame: [UInt8],
                                              payloadStart: Int = puffinPayloadStart,
                                              maxPadding: Int = defaultMaxPadding) -> Bool {
        guard let payload = innerPayload(frame, payloadStart: payloadStart) else { return false }
        return plausibleFilteredPayload(payload, maxPadding: maxPadding)
    }

    /// The inner record's payload from a complete 5/MG frame, or nil when the frame fails either CRC or
    /// is too short. Every frame-level entry point in this file goes through here, so no Labrador field
    /// is ever read out of an unverified frame.
    public static func innerPayload(_ frame: [UInt8], payloadStart: Int = puffinPayloadStart) -> [UInt8]? {
        let check = verifyFrame(frame, family: .whoop5)
        guard check.ok, let declaredLength = check.length else { return nil }
        let payloadEnd = declaredLength + 8 - 4          // start of the CRC32 trailer
        guard payloadStart >= 0, payloadEnd <= frame.count, payloadStart < payloadEnd else { return nil }
        return Array(frame[payloadStart..<payloadEnd])
    }
}
