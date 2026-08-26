import Foundation

// Whoop5Variant.swift — WHOOP MG vs plain WHOOP 5.0 hardware discrimination (#520).
//
// DELIBERATELY ORTHOGONAL to `DeviceFamily`. `DeviceFamily.whoop5` describes the WIRE PROTOCOL
// (CRC16-Modbus header, puffin packet types) and MG and 5.0 are byte-identical there — every
// framing/interpreter switch must keep treating them as one family. This type describes the
// HARDWARE instead: an MG carries the ECG-conductive clasp, a 5.0 does not. Keeping the two apart
// means a capability gate (ECG, and later BP) can never accidentally change how a frame is parsed.
//
// Pure: no CoreBluetooth, no I/O. The app layer supplies the two strings (see below) and this
// decides. The Kotlin twin is com.noop.protocol.Whoop5Variant — keep them byte-identical.
//
// Provenance: the serial prefixes and the 5.0 hardware-revision string are protocol FACTS
// (uncopyrightable), corroborated by community reverse-engineering discussed in #520. They are
// read from the standard BLE Device Information Service, not from any WHOOP code.

/// Which WHOOP 5-generation hardware a connection is talking to.
///
/// `DeviceFamily.whoop5` still governs all framing/decode; this only gates hardware capability.
public enum Whoop5Variant: String, Sendable, CaseIterable {
    /// WHOOP MG — has the ECG-conductive clasp.
    case mg
    /// WHOOP 5.0 — no ECG electrodes.
    case fiveZero
    /// Not identified yet, contradictory evidence, or a non-WHOOP strap. NEVER a guess.
    case unknown

    /// Short display label ("MG" / "5.0" / "—"). UI strings live in the app layer's catalogs;
    /// this is the bare token for logs + diagnostics.
    public var label: String {
        switch self {
        case .mg: return "MG"
        case .fiveZero: return "5.0"
        case .unknown: return "—"
        }
    }

    /// True only when the strap is a POSITIVELY identified MG. `.unknown` is not MG, so an
    /// MG-only feature stays gated off until the hardware actually attests to it.
    public var isMG: Bool { self == .mg }

    /// The serial prefix that attests an MG (BLE DIS Serial Number String, `0x2A25`).
    static let mgSerialPrefix = "5AM"
    /// The serial prefix that attests a plain 5.0.
    static let fiveZeroSerialPrefix = "5AG"
    /// The observed 5.0 Hardware Revision String (`0x2A27`), e.g. "WG50_r52". The MG's own
    /// hardware-revision string is NOT yet attested on real hardware, so its absence proves nothing.
    static let fiveZeroHardwareIDToken = "WG50"

    /// Resolve the variant from the strap's Device Information Service strings.
    ///
    /// - Parameters:
    ///   - serial: DIS Serial Number String (`0x2A25`), or the advertised name — a leading
    ///     "WHOOP " is tolerated so a caller can pass either.
    ///   - hardwareRevision: DIS Hardware Revision String (`0x2A27`), when it has been read.
    ///
    /// Resolution order, and why:
    ///  1. Both signals present and CONTRADICTORY (hw says 5.0, serial says MG) → `.unknown`.
    ///     We refuse to pick a winner: only the 5.0 hardware string is attested today, so a
    ///     contradiction means our model is incomplete, not that one source is authoritative.
    ///     Mis-stamping hardware is exactly what #716 cost us — an honest "unknown" is cheaper.
    ///  2. Hardware revision carrying the known 5.0 token → `.fiveZero` (device-attested).
    ///  3. Serial prefix → `.mg` / `.fiveZero`.
    ///  4. Anything else → `.unknown`. Never infer from a digit elsewhere in the name (#772).
    /// DIS 0x2A24 Model Number String, as a real WHOOP MG reports it. Read unbonded off the standard
    /// profile, so it is available on a strap that never pairs — exactly the case the prefix heuristics
    /// were failing on.
    static let modelNumberMG = "MG"

    public static func from(
        serial: String?,
        hardwareRevision: String? = nil,
        modelNumber: String? = nil
    ) -> Whoop5Variant {
        // The strap SAYING what it is beats inferring it from a prefix. A field capture showed serial
        // prefix "MGB" with hardware revision "WS50_r03" — matching neither `mgSerialPrefix` nor
        // `fiveZeroHardwareIdToken` — on a strap whose own model number said MG outright (#520).
        //
        // Only MG is claimed. No 5.0 has been observed reporting its model number, so inventing a token
        // for one would be the guess this function already refuses to make elsewhere.
        if (modelNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == modelNumberMG {
            return .mg
        }
        let hw = (hardwareRevision ?? "").uppercased()
        var s = (serial ?? "").uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("WHOOP ") { s = String(s.dropFirst("WHOOP ".count)) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        let hwSaysFiveZero = hw.contains(fiveZeroHardwareIDToken)
        let serialSaysMG = s.hasPrefix(mgSerialPrefix)

        if hwSaysFiveZero && serialSaysMG { return .unknown }   // contradiction — do not guess
        if hwSaysFiveZero { return .fiveZero }
        if serialSaysMG { return .mg }
        if s.hasPrefix(fiveZeroSerialPrefix) { return .fiveZero }
        return .unknown
    }
}
