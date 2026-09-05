import Foundation

/// A redacted description of what a strap ADVERTISED, for the #1635 pairing-mode question.
///
/// The one thing no strap log can currently answer is the question the field report put back to the
/// thread: *was the strap in pairing mode during any of those refusals?* A strap that accepts pairing
/// almost certainly advertises differently from one that refuses, but the scan path reads only the
/// device name and discards the rest, so the evidence is thrown away at the moment it exists.
///
/// It is also the ONLY diagnostic on this path that still works unbonded. The event census and the
/// battery-pack read both ride characteristics that need an encrypted link, so on the strap we are
/// actually trying to debug they are silent by construction. An advertisement arrives before any of it.
///
/// STRUCTURE, NOT PAYLOAD. The local name can carry a person's name ("<Name>'s Whoop" is what WHOOP
/// sets by default), service data can carry a serial, and manufacturer data is opaque. So this reports
/// what is PRESENT and how big it is and never a byte of any of it — enough to tell two advertising
/// modes apart, which is the whole question, and carrying nothing identifying.
///
/// Kotlin twin: `ScanAdvertisementSummary`.
public enum ScanAdvertisementSummary {

    /// - Parameters:
    ///   - localNameLength: the local name's SIZE, which can differ between advertising modes and,
    ///     unlike the name itself, identifies nobody.
    public static func line(flags: Int?,
                            serviceUuids: [String],
                            serviceDataLengths: [String: Int],
                            manufacturerDataLengths: [Int: Int],
                            txPower: Int?,
                            localNameLength: Int?,
                            connectable: Bool) -> String {
        var parts: [String] = []
        parts.append("flags=" + (flags.map { String(format: "0x%02x", $0) } ?? "none"))
        parts.append("connectable=\(connectable)")
        parts.append("svc=" + (serviceUuids.isEmpty ? "none" : serviceUuids.sorted().joined(separator: ",")))
        parts.append("svcData=" + (serviceDataLengths.isEmpty ? "none"
            : serviceDataLengths.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)B" }.joined(separator: ",")))
        parts.append("mfg=" + (manufacturerDataLengths.isEmpty ? "none"
            : manufacturerDataLengths.sorted { $0.key < $1.key }
                .map { String(format: "0x%04x:%dB", $0.key, $0.value) }.joined(separator: ",")))
        parts.append("tx=" + (txPower.map(String.init) ?? "none"))
        parts.append("nameLen=" + (localNameLength.map(String.init) ?? "none"))
        return "[adv] " + parts.joined(separator: " ")
    }
}
