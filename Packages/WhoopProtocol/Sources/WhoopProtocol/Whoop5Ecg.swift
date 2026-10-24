import Foundation

// MARK: - WHOOP MG ECG ("Labrador") packet decode + command construction
//
// The WHOOP MG carries ECG electrodes in its conductive clasp (a plain WHOOP 5.0 does not — see
// `Whoop5Variant`). The strap's ECG subsystem is called "Labrador" in the protocol tables, and it is a
// SEPARATE realtime data type from the R-numbered `StrapSensorData` layouts this package already decodes:
// there is a FILTERED stream (live, display-ready, data revision 17) and a RAW stream (persisted on the
// strap for later offload, data revision 16).
//
// They do NOT share a status block. The filtered record's layout is `LabradorR17`, read from the inner
// record at the offsets the official parser uses. `EcgStatusHeader` below is the earlier client-derived
// reading; it survives only on the RAW path, whose body layout nothing here can yet confirm.
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

/// The 17-byte status block the RAW (revision 16) record is read with, in wire order.
///
/// Multi-byte fields are little-endian, matching every other 5/MG field in this package.
///
/// NOT the filtered record's layout, though it was written believing it was: see `LabradorR17`. Whether
/// the raw record really opens this way is still unconfirmed, so this stays where it is rather than
/// being corrected to something equally unproven.
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
/// Decoded by `Whoop5Ecg.parseR17` into a `LabradorR17`, whose offsets are read from the INNER record
/// (the type byte onwards), not from the payload after it.

/// R17 `inner[14]` — the on-strap classifier's state/transition bits plus electrode presence.
public struct EcgLabradorFlags: Equatable, Sendable {
    public let raw: UInt8
    public init(raw: UInt8) { self.raw = raw }

    /// bit 0 — entering classifier state 1.
    public var enteringStateOne: Bool { raw & 0x01 != 0 }
    /// bit 1 — the current classifier state IS 1. An ordinary active frame carries this set; a valid
    /// active frame with it clear is the explicit-restart case, not a contact loss.
    public var currentStateOne: Bool { raw & 0x02 != 0 }
    /// bit 2 — the 1 → 2 state transition, set on the terminal frame.
    public var stateTransitionOneToTwo: Bool { raw & 0x04 != 0 }
    /// bit 3 — electrode contact, debounced on the strap. This is the bit `heartKeyLeadsAreOn` was
    /// reaching for at the wrong offset.
    public var presence: Bool { raw & 0x08 != 0 }

    /// The set bits by name, in bit order. Bits above 3 are reported as unknown rather than named.
    public var tokens: [String] {
        var out = [String]()
        if enteringStateOne { out.append("entering_state_1") }
        if currentStateOne { out.append("state_1") }
        if stateTransitionOneToTwo { out.append("transition_1_2") }
        if presence { out.append("presence") }
        let unknown = raw & ~0x0F
        if unknown != 0 { out.append(String(format: "unknown_bits_0x%02x", Int(unknown))) }
        return out
    }
}

/// R17 `inner[18]` — why the strap called a reading unreadable. Bits above 3 are reported as unknown
/// rather than given a meaning.
public struct EcgUnreadableMask: Equatable, Sendable {
    public let raw: UInt8
    public init(raw: UInt8) { self.raw = raw }

    public var lowAmplitude: Bool { raw & 0x01 != 0 }
    public var significantNoise: Bool { raw & 0x02 != 0 }
    public var unstableSignal: Bool { raw & 0x04 != 0 }
    public var notEnoughData: Bool { raw & 0x08 != 0 }

    /// The set bits by name, in bit order.
    public var reasons: [String] {
        var out = [String]()
        if lowAmplitude { out.append("low_amplitude") }
        if significantNoise { out.append("significant_noise") }
        if unstableSignal { out.append("unstable_signal") }
        if notEnoughData { out.append("not_enough_data") }
        let unknown = raw & ~0x0F
        if unknown != 0 { out.append(String(format: "unknown_bits_0x%02x", Int(unknown))) }
        return out
    }
}

/// One Labrador revision-17 packet — the strap's live filtered-ECG cycle.
///
/// Offsets are into the INNER record, counted from the packet-type byte. On a 5/MG frame that byte is at
/// `Whoop5Ecg.rawTypeOffset` (8), so `inner[k]` is `frame[8 + k]`: fixed fields occupy `inner[0...25]`
/// and the samples start at `inner[26]` — `frame[34]`, which is exactly the waveform offset the
/// type-43 constants in this file were already observing on hardware.
///
/// `samples` are 100 Hz filtered signed i16 little-endian values as transmitted. No rescaling is applied
/// and no anatomical lead or polarity is claimed. `variabilityRaw` has no proven unit.
public struct LabradorR17: Equatable, Sendable {
    /// `inner[0]`: 43 (REALTIME_RAW_DATA, the live path) or 47 (HISTORICAL_DATA, a stored copy).
    public let packetType: UInt8
    /// `inner[2]` — a packet-context marker the consumer ignores. Kept raw rather than named.
    public let headerSecondary: UInt8
    public let sequence: UInt32          // inner[3...6]  u32 LE
    public let strapSeconds: UInt32      // inner[7...10] u32 LE
    public let subseconds: UInt16        // inner[11...12] u16 LE, 1/32768 s
    public let signalQuality: EcgSignalQuality
    public let signalQualityRaw: UInt8   // inner[13]
    public let flags: EcgLabradorFlags   // inner[14]
    /// `inner[15]` — the classifier result code. Non-nil when it maps to a known case.
    public let arrhythmiaCheckResult: EcgArrhythmiaCheckResult?
    public let arrhythmiaCheckResultRaw: UInt8
    public let classifierState: UInt8    // inner[16]; 2 is terminal
    public let progress: EcgHeartKeyProgress  // inner[17]; 100 terminal, 255 invalid
    public let unreadable: EcgUnreadableMask  // inner[18]
    public let averageHR: UInt8          // inner[19] — the final/stored heart rate
    public let liveHR: UInt8             // inner[20] — the current heart rate
    /// `inner[21...22]` u16 LE, or nil when the wire carried the unavailable sentinel.
    public let variabilityRaw: UInt16?
    public let reserved: UInt8           // inner[23]
    public let sampleCount: UInt16       // inner[24...25] u16 LE
    public let samples: [Int16]
    /// Aligned bytes after the sample block, byte-exact, meaning unassigned.
    public let tail: [UInt8]

    public init(packetType: UInt8, headerSecondary: UInt8, sequence: UInt32, strapSeconds: UInt32,
                subseconds: UInt16, signalQuality: EcgSignalQuality, signalQualityRaw: UInt8,
                flags: EcgLabradorFlags, arrhythmiaCheckResult: EcgArrhythmiaCheckResult?,
                arrhythmiaCheckResultRaw: UInt8, classifierState: UInt8, progress: EcgHeartKeyProgress,
                unreadable: EcgUnreadableMask, averageHR: UInt8, liveHR: UInt8, variabilityRaw: UInt16?,
                reserved: UInt8, sampleCount: UInt16, samples: [Int16], tail: [UInt8]) {
        self.packetType = packetType
        self.headerSecondary = headerSecondary
        self.sequence = sequence
        self.strapSeconds = strapSeconds
        self.subseconds = subseconds
        self.signalQuality = signalQuality
        self.signalQualityRaw = signalQualityRaw
        self.flags = flags
        self.arrhythmiaCheckResult = arrhythmiaCheckResult
        self.arrhythmiaCheckResultRaw = arrhythmiaCheckResultRaw
        self.classifierState = classifierState
        self.progress = progress
        self.unreadable = unreadable
        self.averageHR = averageHR
        self.liveHR = liveHR
        self.variabilityRaw = variabilityRaw
        self.reserved = reserved
        self.sampleCount = sampleCount
        self.samples = samples
        self.tail = tail
    }

    /// Electrode contact, from the flags byte.
    public var presence: Bool { flags.presence }

    /// The strap's completion condition.
    public var isTerminal: Bool { progress.raw == 100 || classifierState == 2 }

    /// The strap's invalid/abort sentinel.
    public var isInvalid: Bool { progress.raw == 255 }

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

/// The flash-banked raw ECG record: type 47 HISTORICAL_DATA, data revision 16, exactly 1584 bytes.
///
/// `TOGGLE_LABRADOR_RAW_SAVE(125)=1` banks the generation to flash as these, which arrive in the ordinary
/// history offload rather than on a live channel. That delivery path is why every 30-second realtime listen
/// in #891 reported silence while the strap was in fact recording.
///
/// Carries wire structure only: 500 three-byte slots holding signed 18-bit samples plus two flag bits, and
/// a fixed lead-off diagnostic trailer. It establishes no volts per count and nothing clinical.
public struct LabradorR16: Equatable, Sendable {
    public let packetType: UInt8         // inner[0]
    public let headerSecondary: UInt8    // inner[2]
    public let sequence: UInt32          // inner[3...6]  u32 LE — the record index
    public let strapSeconds: UInt32      // inner[7...10] u32 LE
    public let subseconds: UInt16        // inner[11...12] u16 LE, 1/32768 s
    public let signalQuality: EcgSignalQuality
    public let signalQualityRaw: UInt8   // inner[13]
    public let flags: EcgLabradorFlags   // inner[14]
    public let arrhythmiaCheckResult: EcgArrhythmiaCheckResult?
    public let arrhythmiaCheckResultRaw: UInt8  // inner[15]
    public let classifierState: UInt8    // inner[16]
    public let progress: EcgHeartKeyProgress    // inner[17]
    public let unreadable: EcgUnreadableMask    // inner[18]
    public let averageHR: UInt8          // inner[19]
    /// `inner[20]`. OBSERVED to remain zero on R16, where R17 carries the live rate. Reported as it
    /// arrives rather than asserted zero: the decoder states the wire, not the observation.
    public let liveHR: UInt8
    public let variabilityRaw: UInt16?   // inner[21...22], nil on the unavailable sentinel
    public let reserved: UInt8           // inner[23]
    public let sampleCount: UInt16       // inner[24...25] u16 LE, capacity 500

    /// Signed 18-bit samples, `sampleCount` of them, in wire order. Range `-131072 ... 131071`.
    public let samples: [Int32]

    /// The tag byte of each decoded slot, byte-exact and one per entry in `samples`.
    ///
    /// Kept whole rather than split into booleans so nothing is discarded: it carries flag 7, flag 6, the
    /// uninterpreted reserved bits 2-5, and the sample's own high bits 17-16. Use `flag6(at:)`,
    /// `flag7(at:)` and `reservedBits(at:)` to read it.
    public let sampleTags: [UInt8]

    /// `inner[1526]`, verbatim. Capacity is `r16LeadsOffSlots`; a larger value is an anomaly and is
    /// reported rather than clamped, because clamping would invent a count the strap never sent.
    public let leadsOffCountRaw: UInt8

    /// All 11 fixed I-channel halfwords. Fixed offsets, so these are present whatever the count says.
    ///
    /// Assembled LITTLE-ENDIAN, which is a candidate reading and not an attested one. `docs/PROTOCOL_ECG.md`
    /// gives these a signed diagnostic meaning and no byte order, and the waveform slots in the same record
    /// are big-endian, so the record is not uniformly one or the other. Little-endian is what every other
    /// multi-byte field in this status region uses, which makes it the consistent reading rather than a
    /// measured one. `Whoop5EcgR16Tests` pins the reading against explicit bytes so a change to it is a
    /// visible decision; `sampleTags` and `leadsOffCountRaw` are the fields that are genuinely byte-exact.
    /// Nothing in the tree derives a number from these, so the open question costs no output today.
    public let leadsOffIRaw: [UInt16]

    /// All 11 fixed Q-channel halfwords, on the same unattested little-endian reading as `leadsOffIRaw`.
    public let leadsOffQRaw: [UInt16]

    /// `inner[1571]`, the record's alignment byte, carried so a caller can see it really was zero.
    public let alignmentByte: UInt8

    public init(packetType: UInt8, headerSecondary: UInt8, sequence: UInt32, strapSeconds: UInt32,
                subseconds: UInt16, signalQuality: EcgSignalQuality, signalQualityRaw: UInt8,
                flags: EcgLabradorFlags, arrhythmiaCheckResult: EcgArrhythmiaCheckResult?,
                arrhythmiaCheckResultRaw: UInt8, classifierState: UInt8, progress: EcgHeartKeyProgress,
                unreadable: EcgUnreadableMask, averageHR: UInt8, liveHR: UInt8, variabilityRaw: UInt16?,
                reserved: UInt8, sampleCount: UInt16, samples: [Int32], sampleTags: [UInt8],
                leadsOffCountRaw: UInt8, leadsOffIRaw: [UInt16], leadsOffQRaw: [UInt16],
                alignmentByte: UInt8) {
        self.packetType = packetType
        self.headerSecondary = headerSecondary
        self.sequence = sequence
        self.strapSeconds = strapSeconds
        self.subseconds = subseconds
        self.signalQuality = signalQuality
        self.signalQualityRaw = signalQualityRaw
        self.flags = flags
        self.arrhythmiaCheckResult = arrhythmiaCheckResult
        self.arrhythmiaCheckResultRaw = arrhythmiaCheckResultRaw
        self.classifierState = classifierState
        self.progress = progress
        self.unreadable = unreadable
        self.averageHR = averageHR
        self.liveHR = liveHR
        self.variabilityRaw = variabilityRaw
        self.reserved = reserved
        self.sampleCount = sampleCount
        self.samples = samples
        self.sampleTags = sampleTags
        self.leadsOffCountRaw = leadsOffCountRaw
        self.leadsOffIRaw = leadsOffIRaw
        self.leadsOffQRaw = leadsOffQRaw
        self.alignmentByte = alignmentByte
    }

    /// Electrode contact, from the flags byte.
    public var presence: Bool { flags.presence }

    /// The strap's completion condition.
    public var isTerminal: Bool { progress.raw == 100 || classifierState == 2 }

    /// The strap's invalid/abort sentinel.
    public var isInvalid: Bool { progress.raw == 255 }

    /// False when the lead-off count exceeds the slots the wire actually carries.
    public var leadsOffCountWithinCapacity: Bool {
        Int(leadsOffCountRaw) <= Whoop5Ecg.r16LeadsOffSlots
    }

    /// Flag 6 of a slot, which the firmware supplies PER SAMPLE.
    /// Kotlin twin: `LabradorR16.flag6`.
    public func flag6(at index: Int) -> Bool? {
        guard sampleTags.indices.contains(index) else { return nil }
        return (sampleTags[index] >> 6) & 1 == 1
    }

    /// Flag 7 of a slot.
    ///
    /// The bit is genuinely in every slot, but its VALUE is replicated from a slower lead-state stream, so
    /// 500 of them are not 500 independent contact measurements. `leadStateGroup(at:)` says which single
    /// measurement a slot's bit came from; treating this as a per-sample contact channel is the misreading
    /// `docs/PROTOCOL_ECG.md` warns about.
    /// Kotlin twin: `LabradorR16.flag7`.
    public func flag7(at index: Int) -> Bool? {
        guard sampleTags.indices.contains(index) else { return nil }
        return (sampleTags[index] >> 7) & 1 == 1
    }

    /// Bits 2-5 of a slot's tag byte, uninterpreted. Retained because nothing establishes what they mean.
    /// Kotlin twin: `LabradorR16.reservedBits`.
    public func reservedBits(at index: Int) -> UInt8? {
        guard sampleTags.indices.contains(index) else { return nil }
        return (sampleTags[index] >> 2) & 0x0f
    }

    /// Which lead-state entry a sample's flag 7 was replicated from, or nil when the grouping is not
    /// established for this record.
    ///
    /// Defined ONLY for the attested 500-raw / 10-slower case. The groups are 51, then eight of 50, then
    /// 49 — the boundary sample keeps the EARLIER entry before the index advances, so entry 0 covers
    /// samples 0...50 and not 0...49. Ten equal groups of 50 is the wrong answer. Rather than guess a
    /// divisor for a shape nothing attests, this returns nil: for a zero count, for any other count, and
    /// for a short record. A real strap sends a lead-state count of 11 often enough that a guessed
    /// divisor would misreport live records.
    /// Kotlin twin: `LabradorR16.leadStateGroup`.
    public func leadStateGroup(at index: Int) -> Int? {
        guard Int(leadsOffCountRaw) == Whoop5Ecg.r16LeadStateGroupCount,
              Int(sampleCount) == Whoop5Ecg.r16MaxSamples,
              samples.indices.contains(index) else { return nil }
        let divisor = Whoop5Ecg.r16MaxSamples / Whoop5Ecg.r16LeadStateGroupCount
        return index == 0 ? 0 : (index - 1) / divisor
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
    /// `right = 1`, `left = 2` — one-based, NOT the client's zero-based declaration order.
    ///
    /// The previous `right = 0 / left = 1` was read off that order and shipped as an acknowledged
    /// inference. It was wrong in exactly the way `ControlSignal`'s was (#896): the wire values for this
    /// family start at 1, and 0 is not a member. Corrected against the official Android 5.458.0 Labrador
    /// parser and the 50.41.1.0 firmware constructor, cross-checked against a third-party implementation
    /// that drives a physical MG through a complete reading.
    ///
    /// This command writes PERSISTENT strap state, so the old values did not merely fail — they wrote a
    /// wrong persistent selection, or were refused outright, on every strap that ran the probe.
    public enum WristSelection: UInt8, Equatable, Sendable, CaseIterable {
        case right = 1
        case left = 2

        public var token: String { self == .right ? "right" : "left" }
    }

    /// The `mainControlECGDataGeneration` argument.
    ///
    /// ⚠️ These raw values are ATTESTED ON ONE DEVICE, and they are NOT the vendor client's declaration
    /// order. The previous `stop = 0 / start = 1 / restart = 2` was read off that order and shipped
    /// unverified (#896). On a WHOOP MG (`WS50_r00`, fw `50.39.1.0`) each argument was sent on its own
    /// while watching the type-43 stream rather than the ack:
    ///
    ///   - `0` is REFUSED — the strap answers `FAILURE(0)` and generation is unchanged, so there is no
    ///     case for it here and nothing can send it.
    ///   - `1` STOPS generation.
    ///   - `2` STARTS it. The type-43 stream only follows once `TOGGLE_LABRADOR_FILTERED (139)` is on, so
    ///     the working turn-on order is `139 = 1` then `124 = 2`. 139 gates the STREAM rather than the
    ///     front end: with 139 closed, `124 = 2` still made the strap's own console log
    ///     `MAX86176: Set ECG ON` while no packets arrived (8 sends, 8 console lines, #891).
    ///
    /// One device, one firmware. #1100 ran `WS50_r03` / `50.40.1.0` and nothing here says the two agree.
    /// Whether `2` is a plain start or a stop-then-start is NOT distinguishable from a stream that was
    /// already off, so the case is named for what it achieves rather than for the client's third name.
    public enum ControlSignal: UInt8, Equatable, Sendable, CaseIterable {
        case stop = 1
        case start = 2

        public var token: String {
            switch self {
            case .stop: return "stop"
            case .start: return "start"
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
            // Only the START value. `ControlSignal.stop` (1) halts generation, so a run whose last act
            // was that one asked for nothing and its silence is the expected outcome, not a finding.
            return arg == ControlSignal.start.rawValue
        default:
            return false
        }
    }

    // MARK: Filtered decode

    /// Decode a `LabradorR17` from a complete INNER record — the bytes from the packet-type byte
    /// onwards, which on a 5/MG frame means `frame[8...]`.
    ///
    /// Accepts only a type-43 (or, with `allowStored`, type-47) record of data revision 17 whose declared
    /// sample block fits: fixed fields through `inner[25]` present, `sampleCount <= 100`, and
    /// `26 + 2 * sampleCount` bytes available. No fixed total length is required; bytes past the sample
    /// block land in `tail`. CRC validity is the caller's business — `r17FromFrame` enforces it.
    /// Kotlin twin: `Whoop5Ecg.parseR17`.
    public static func parseR17(inner: [UInt8], allowStored: Bool = false) -> LabradorR17? {
        guard inner.count >= r17FixedLength else { return nil }
        let type = inner[0]
        guard type == rawRecordType || (allowStored && type == storedRecordType) else { return nil }
        guard inner[1] == r17Revision else { return nil }
        let count = Int(u16le(inner, 24))
        guard count <= r17MaxSamples else { return nil }
        let end = r17SampleStart + count * 2
        guard inner.count >= end else { return nil }

        var samples = [Int16]()
        samples.reserveCapacity(count)
        for i in 0..<count {
            let off = r17SampleStart + i * 2
            samples.append(Int16(bitPattern: u16le(inner, off)))
        }
        let variability = u16le(inner, 21)
        let quality = inner[13]
        return LabradorR17(
            packetType: type,
            headerSecondary: inner[2],
            sequence: u32le(inner, 3),
            strapSeconds: u32le(inner, 7),
            subseconds: u16le(inner, 11),
            signalQuality: EcgSignalQuality(rawValue: quality) ?? .unknown,
            signalQualityRaw: quality,
            flags: EcgLabradorFlags(raw: inner[14]),
            arrhythmiaCheckResult: EcgArrhythmiaCheckResult(rawValue: inner[15]),
            arrhythmiaCheckResultRaw: inner[15],
            classifierState: inner[16],
            progress: EcgHeartKeyProgress(raw: inner[17]),
            unreadable: EcgUnreadableMask(raw: inner[18]),
            averageHR: inner[19],
            liveHR: inner[20],
            variabilityRaw: variability == r17VariabilityUnavailable ? nil : variability,
            reserved: inner[23],
            sampleCount: UInt16(count),
            samples: samples,
            tail: Array(inner[end...]))
    }

    /// Decode a `LabradorR16` from a complete INNER record — the bytes from the packet-type byte onwards,
    /// which on a 5/MG frame means `frame[8...]`.
    ///
    /// Accepts only a type-47 record of data revision 16 whose inner length is exactly `r16InnerLength`.
    /// The length is REQUIRED rather than derived, unlike R17: every region after the waveform sits at a
    /// FIXED offset, so a short buffer cannot be decoded by shrinking the sample block — it would read the
    /// lead-off arrays from inside the waveform. A declared `sampleCount` above `r16MaxSamples` is an
    /// anomaly and is refused.
    ///
    /// CRC validity is the caller's business; `r16FromFrame` enforces it.
    /// Kotlin twin: `Whoop5Ecg.parseR16`.
    public static func parseR16(inner: [UInt8]) -> LabradorR16? {
        guard inner.count == r16InnerLength else { return nil }
        guard inner[0] == storedRecordType, inner[1] == r16Revision else { return nil }
        let count = Int(u16le(inner, 24))
        guard count <= r16MaxSamples else { return nil }

        var samples = [Int32]()
        var tags = [UInt8]()
        samples.reserveCapacity(count)
        tags.reserveCapacity(count)
        for i in 0..<count {
            let o = r16SampleStart + i * r16SampleSlotBytes
            let tag = inner[o]
            // Big-endian pair under a tag byte whose low two bits are the sample's high bits. Reading this
            // as little-endian i16 is the misdecode that puts a ~65,000-count cliff at every zero crossing.
            let raw18 = (Int(tag & 0x03) << 16) | (Int(inner[o + 1]) << 8) | Int(inner[o + 2])
            samples.append(Int32(raw18 >= r16SampleSignThreshold ? raw18 - r16SampleModulus : raw18))
            tags.append(tag)
        }

        var leadsI = [UInt16]()
        var leadsQ = [UInt16]()
        leadsI.reserveCapacity(r16LeadsOffSlots)
        leadsQ.reserveCapacity(r16LeadsOffSlots)
        for i in 0..<r16LeadsOffSlots {
            leadsI.append(u16le(inner, r16LeadsOffIStart + i * 2))
            leadsQ.append(u16le(inner, r16LeadsOffQStart + i * 2))
        }

        let variability = u16le(inner, 21)
        let quality = inner[13]
        return LabradorR16(
            packetType: inner[0],
            headerSecondary: inner[2],
            sequence: u32le(inner, 3),
            strapSeconds: u32le(inner, 7),
            subseconds: u16le(inner, 11),
            signalQuality: EcgSignalQuality(rawValue: quality) ?? .unknown,
            signalQualityRaw: quality,
            flags: EcgLabradorFlags(raw: inner[14]),
            arrhythmiaCheckResult: EcgArrhythmiaCheckResult(rawValue: inner[15]),
            arrhythmiaCheckResultRaw: inner[15],
            classifierState: inner[16],
            progress: EcgHeartKeyProgress(raw: inner[17]),
            unreadable: EcgUnreadableMask(raw: inner[18]),
            averageHR: inner[19],
            liveHR: inner[20],
            variabilityRaw: variability == r17VariabilityUnavailable ? nil : variability,
            reserved: inner[23],
            sampleCount: UInt16(count),
            samples: samples,
            sampleTags: tags,
            leadsOffCountRaw: inner[r16LeadsOffCountOffset],
            leadsOffIRaw: leadsI,
            leadsOffQRaw: leadsQ,
            alignmentByte: inner[r16AlignmentOffset])
    }

    /// CRC-gated decode straight off a complete 5/MG frame. The frame must pass BOTH puffin CRCs — a frame
    /// that fails is rejected before any field is read, per the BLE safety contract.
    /// Kotlin twin: `Whoop5Ecg.r16FromFrame`.
    public static func r16FromFrame(_ frame: [UInt8]) -> LabradorR16? {
        guard let inner = innerPayload(frame, payloadStart: rawTypeOffset) else { return nil }
        return parseR16(inner: inner)
    }

    /// A one-line, non-identifying summary of an R16 record, or nil when `frame` is not a CRC-valid one.
    ///
    /// Exists so a maintainer reading a strap log or a `whoop-decode` dump can tell at a glance whether a
    /// banked reading actually carried a waveform, which is the question #891 spent three months unable to
    /// answer. Counts and flags only: no serial, no wall clock, no sample values, so it is safe to paste
    /// into an issue. The strap's own record index and clock are already in every history log line.
    ///
    /// Kotlin twin: `Whoop5Ecg.r16SummaryLine`.
    public static func r16SummaryLine(_ frame: [UInt8]) -> String? {
        guard isR16Record(frame), let p = r16FromFrame(frame) else { return nil }
        let n = Int(p.sampleCount)
        var contact = 0, leadFlag = 0, reservedNonZero = 0
        for i in 0..<n {
            if p.flag6(at: i) == true { contact += 1 }
            if p.flag7(at: i) == true { leadFlag += 1 }
            if (p.reservedBits(at: i) ?? 0) != 0 { reservedNonZero += 1 }
        }
        let grouping = p.leadStateGroup(at: 0) == nil ? "unavailable" : "51/50x8/49"
        var out = "R16 idx=\(p.sequence) t=\(p.strapSeconds) q=\(p.signalQualityRaw)"
        out += " prog=\(p.progress.raw) state=\(p.classifierState)"
        out += p.isTerminal ? " terminal" : (p.isInvalid ? " invalid" : " running")
        out += " samples=\(n) flag6=\(contact)/\(n) flag7=\(leadFlag)/\(n)"
        out += " reservedNonZero=\(reservedNonZero) leadOff=\(p.leadsOffCountRaw)"
        if !p.leadsOffCountWithinCapacity { out += "(over capacity)" }
        out += " grouping=\(grouping)"
        return out
    }

    /// True for a frame shaped like an R16 record. Shape only — says nothing about CRC.
    /// Kotlin twin: `Whoop5Ecg.isR16Record`.
    public static func isR16Record(_ frame: [UInt8]) -> Bool {
        frame.count == r16RecordLength
            && frame[rawTypeOffset] == storedRecordType
            && frame[rawTypeOffset + 1] == r16Revision
    }

    /// Kotlin twin: `Whoop5Ecg.u16le`.
    private static func u16le(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    /// Kotlin twin: `Whoop5Ecg.u32le`.
    private static func u32le(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    /// CRC-gated decode straight off a complete 5/MG frame. The frame must pass BOTH puffin CRCs — a
    /// frame that fails is rejected before any field is read, per the BLE safety contract.
    ///
    /// `payloadStart` defaults to the standard puffin inner-data offset. It is a parameter, not a
    /// constant, because the packet TYPE these records arrive under is not yet attested (see the file
    /// header), so a capture may show a different body offset.
    /// Kotlin twin: `Whoop5Ecg.r17FromFrame`.
    public static func r17FromFrame(_ frame: [UInt8], allowStored: Bool = false) -> LabradorR17? {
        // Through `innerPayload` with the INNER record's own start offset, not `frame[rawTypeOffset...]`.
        // It is the one seam that both CRC-gates the frame and stops at the CRC32 trailer; slicing to the
        // end of the buffer instead would hand four envelope bytes to `tail` and call them record bytes.
        guard let inner = innerPayload(frame, payloadStart: rawTypeOffset) else { return nil }
        return parseR17(inner: inner, allowStored: allowStored)
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

    // MARK: - The type-43 REALTIME_RAW_DATA record: the live ECG sample carrier (#891/#1100)
    //
    // OBSERVED on one WHOOP MG (WS50_r00, fw 50.39.1.0), not attested by any vendor document: once
    // TOGGLE_LABRADOR_FILTERED(139)=1 has opened the master gate, the strap emits fixed-size 240-byte
    // REALTIME_RAW_DATA (type 43) records whose body carries an i16-LE series.
    //
    // Twin of the Kotlin `Whoop5Ecg` helpers of the same names. Android grew the ECG app layer that consumes
    // these first; the decode is a PROTOCOL fact, so it lands on both platforms together rather than living
    // only where it happens to be called today. Nothing here decodes a status field, an HR, or a rhythm
    // classification — only the sample series and a byte-fill count. Callers gate on the frame's CRC first.

    /// Every REALTIME_RAW_DATA record OBSERVED on the MG was exactly this long.
    public static let rawRecordLength = 240

    /// Frame offset of the inner record's type byte on 5/MG (`[8]type [9]seq [10]cmd`).
    public static let rawTypeOffset = 8

    /// The inner record type byte for REALTIME_RAW_DATA.
    public static let rawRecordType: UInt8 = 43

    /// The inner record type byte for HISTORICAL_DATA — a STORED R17, which the live turn-on path never
    /// enables. `parseR17` accepts it only when asked to.
    public static let storedRecordType: UInt8 = 47

    // MARK: The revision-17 layout
    //
    // Offsets into the INNER record, from the packet-type byte. `inner[k]` is `frame[rawTypeOffset + k]`.
    // Source-closed against the official Android 5.458.0 Labrador parser and the 50.41.1.0 firmware
    // constructor, and corroborated here by `rawWaveformStart`: the waveform offset OBSERVED on an MG
    // (34) is exactly `rawTypeOffset + r17SampleStart`, which is what says these two readings of the
    // same record agree.

    /// `inner[1]` — the data revision that makes a record an R17.
    public static let r17Revision: UInt8 = 17

    /// Fixed fields occupy `inner[0...25]`; the sample block follows.
    public static let r17FixedLength = 26

    /// First sample byte, `inner[26]`.
    public static let r17SampleStart = 26

    /// Wire capacity: 100 i16 samples per packet.
    public static let r17MaxSamples = 100

    /// `0xffff` at `inner[21...22]` means the variability value is unavailable.
    public static let r17VariabilityUnavailable: UInt16 = 0xffff

    // MARK: The revision-16 layout
    //
    // The flash-banked record that `TOGGLE_LABRADOR_RAW_SAVE(125)=1` produces. It arrives in the ordinary
    // history offload as a type-47 HISTORICAL_DATA frame of data revision 16, not on a live channel, which
    // is why a realtime listen never saw it (#891).
    //
    // Offsets are INNER, like the R17 block above; `docs/PROTOCOL_ECG.md` states the same layout in FRAME
    // offsets, which are these plus `rawTypeOffset`. The status region is byte-identical to R17 and is read
    // with the same expressions here; `Whoop5EcgR16Tests` pins the two decoders against one header rather
    // than sharing a reader, because `parseR17` is the live path and is not refactored for this.
    //
    // Everything here is wire structure and coding only. It establishes no volts per count, no sample rate,
    // and nothing clinical.

    /// `inner[1]` — the data revision that makes a record an R16.
    public static let r16Revision: UInt8 = 16

    /// A whole R16 FRAME is exactly this long, envelope and CRC32 trailer included.
    public static let r16RecordLength = 1584

    /// The inner record's length once the 8-byte envelope and the 4-byte CRC32 trailer are removed.
    public static let r16InnerLength = 1572

    /// Wire capacity: 500 waveform slots per record.
    public static let r16MaxSamples = 500

    /// First waveform byte, `inner[26]` — the same offset as `r17SampleStart`, because the two revisions
    /// share their status header. Pinned equal by a test rather than aliased, so each stays a literal the
    /// parity scanner can verify against its Kotlin twin by value.
    public static let r16SampleStart = 26

    /// Each waveform slot is three bytes: one tag byte then a big-endian pair. NOT little-endian i16, and
    /// NOT a signed 24-bit sample.
    public static let r16SampleSlotBytes = 3

    /// `inner[1526]` — the lead-off diagnostic count.
    public static let r16LeadsOffCountOffset = 1526

    /// Lead-off diagnostic slots actually present on the wire, per channel. FIXED: the arrays do not move
    /// when either count is smaller, so a `header + count * width` formula locates them incorrectly.
    public static let r16LeadsOffSlots = 11

    /// `inner[1527]` — first I-channel halfword.
    public static let r16LeadsOffIStart = 1527

    /// `inner[1549]` — first Q-channel halfword.
    public static let r16LeadsOffQStart = 1549

    /// `inner[1571]` — the record's single zero alignment byte, never a sample and never a diagnostic.
    public static let r16AlignmentOffset = 1571

    /// Sample values are signed 18-bit two's complement, so `raw18` at or above this subtracts
    /// `r16SampleModulus`. The resulting range is `-131072 ... 131071`.
    public static let r16SampleSignThreshold = 131_072

    /// The 18-bit modulus used to sign-extend `raw18`.
    public static let r16SampleModulus = 262_144

    /// The lead-state array count for which the flag-7 grouping is ESTABLISHED. Other nonzero counts are
    /// not attested as input to that rule, and a zero count omits flag-7 insertion entirely.
    public static let r16LeadStateGroupCount = 10

    /// First body byte considered by `realtimeRawBodyNonZeroBytes` — excludes the constant sub-header.
    public static let rawBodyStart = 24

    /// First waveform byte. Bytes 24..33 are a constant 5x i16 sub-header that is NOT waveform.
    public static let rawWaveformStart = 34

    /// One past the last body byte; the remaining 4 bytes are the frame's CRC32 trailer.
    public static let rawBodyEnd = 236

    /// One past the last WAVEFORM byte. Bytes 234..235 are the record's two-byte alignment word, which is
    /// never a sample: `docs/PROTOCOL_ECG.md` says so outright ("its last word is alignment, not data"), and
    /// `parseR17` reaches the same boundary from the other direction by bounding the declared count at
    /// `r17MaxSamples`. Reading on to `rawBodyEnd` instead harvests that word as a 101st sample, once per
    /// record, at a fixed position — a per-record periodic artifact, which is the #194 shape exactly.
    ///
    /// A literal, like every other offset here, so the parity scanner can verify it against the Kotlin twin
    /// by value. `Whoop5EcgRawRecordTests` pins it to `rawWaveformStart + r17MaxSamples * 2` instead, which
    /// is the check an expression would only have made locally.
    public static let rawWaveformEnd = 234

    /// Samples one record carries: 100. Load-bearing beyond arithmetic — a fixed sample count per record is
    /// exactly the shape that makes autocorrelation manufacture a peak at the record period, so anything
    /// estimating a rate from these samples must exclude this lag. See the #194 withdrawal for what
    /// happens when that is not done.
    ///
    /// This and `r17MaxSamples` are two readings of the same record length, and they disagreed by one for
    /// as long as this was `(rawBodyEnd - rawWaveformStart) / 2`. Their equality is pinned by a test rather
    /// than by deriving one from the other, because a literal is what the parity scanner can verify against
    /// the Kotlin twin by value.
    public static let samplesPerRawRecord = 100

    /// Non-zero body bytes above which a record is treated as carrying a waveform rather than baseline.
    public static let rawBodyActiveNonZeroBytes = 20

    /// True for a frame shaped like a REALTIME_RAW_DATA record. Shape only — says nothing about CRC.
    public static func isRealtimeRawRecord(_ frame: [UInt8]) -> Bool {
        frame.count == rawRecordLength && frame[rawTypeOffset] == rawRecordType
    }

    /// The record's i16-LE sample series, or nil when `frame` is not a REALTIME_RAW_DATA record.
    ///
    /// Signed two's-complement, little-endian, exactly `samplesPerRawRecord` values, stopping before the
    /// alignment word at `rawWaveformEnd`. Zero samples are returned as zeros and never trimmed: for a
    /// research artifact a trailing run of zeros is evidence about the record, not padding to be tidied
    /// away. That is why the alignment word has to be excluded STRUCTURALLY rather than by dropping
    /// trailing zeros — the word is zero-valued, so a trim would hide it while also editing real data.
    public static func realtimeRawSamples(_ frame: [UInt8]) -> [Int]? {
        guard isRealtimeRawRecord(frame) else { return nil }
        var out = [Int]()
        out.reserveCapacity(samplesPerRawRecord)
        var i = rawWaveformStart
        while i + 1 < rawWaveformEnd {
            let raw = Int(frame[i]) | (Int(frame[i + 1]) << 8)
            out.append(raw >= 0x8000 ? raw - 0x10000 : raw)
            i += 2
        }
        return out
    }

    /// Non-zero bytes in the body region, or nil when `frame` is not a REALTIME_RAW_DATA record.
    public static func realtimeRawBodyNonZeroBytes(_ frame: [UInt8]) -> Int? {
        guard isRealtimeRawRecord(frame) else { return nil }
        var n = 0
        for i in rawBodyStart..<rawBodyEnd where frame[i] != 0 { n += 1 }
        return n
    }

    /// ONE definition of "this record carries a waveform", so every consumer agrees about the same record.
    ///
    /// What it cannot tell you: a flat record means the electrode circuit is open OR generation is off. It is
    /// a byte-fill observation, never a statement about the wearer.
    public static func realtimeRawSignalPresent(_ frame: [UInt8]) -> Bool? {
        guard let n = realtimeRawBodyNonZeroBytes(frame) else { return nil }
        return n > rawBodyActiveNonZeroBytes
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
