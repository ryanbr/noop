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
    ///   - localNameLength: the local name's SIZE IN UTF-8 BYTES (see `localNameLength(_:)`), which can
    ///     differ between advertising modes and, unlike the name itself, identifies nobody.
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
        let svc = serviceUuids.map(canonicalUuid).sorted()
        parts.append("svc=" + (svc.isEmpty ? "none" : svc.joined(separator: ",")))
        // Normalise BEFORE sorting: the canonical form reorders keys that the short form would not.
        let svcData = serviceDataLengths.map { (canonicalUuid($0.key), $0.value) }.sorted { $0.0 < $1.0 }
        parts.append("svcData=" + (svcData.isEmpty ? "none"
            : svcData.map { "\($0.0):\($0.1)B" }.joined(separator: ",")))
        parts.append("mfg=" + (manufacturerDataLengths.isEmpty ? "none"
            : manufacturerDataLengths.sorted { $0.key < $1.key }
                .map { String(format: "0x%04x:%dB", $0.key, $0.value) }.joined(separator: ",")))
        parts.append("tx=" + (txPower.map(String.init) ?? "none"))
        parts.append("nameLen=" + (localNameLength.map(String.init) ?? "none"))
        return "[adv] " + parts.joined(separator: " ")
    }

    /// Expand an assigned short Bluetooth UUID to its canonical 128-bit form; pass anything else through.
    ///
    /// CoreBluetooth renders an assigned 16-bit UUID as "180d" and a 32-bit one as "0000180d", where
    /// Android's `UUID.toString()` always expands to the full base UUID. Unnormalised, the same strap
    /// advertising Heart Rate Service logs a different string on each platform, so an iOS capture cannot
    /// be compared against an Android one — which is exactly what this line exists to allow. Normalising
    /// inside `line` rather than at the call site means neither platform's scan path can forget to do it.
    ///
    /// A no-op on Android, whose input is already 128-bit; it lives in both twins so the two formatters
    /// stay behaviourally identical rather than agreeing only by accident of their inputs.
    static func canonicalUuid(_ s: String) -> String {
        switch s.count {
        case 4: return "0000\(s)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(s)-0000-1000-8000-00805f9b34fb"
        default: return s
        }
    }

    /// The local name's size in UTF-8 BYTES — what the advertisement actually carries.
    ///
    /// NOT `String.count`. Swift counts grapheme clusters and Java's `String.length` counts UTF-16 code
    /// units, so a strap named "Whoop 🎉" reported 7 on iOS and 8 on Android — the same divergence, and
    /// for the same reason, as the short-UUID spelling this file already canonicalises. Names carry
    /// emoji and accents routinely (WHOOP seeds the name from the account holder), so this was not a
    /// theoretical case.
    ///
    /// Bytes rather than either platform's string model because the AD local-name field IS a UTF-8 byte
    /// run: it is the physically meaningful number, and it is identical on both platforms by
    /// construction instead of by one imitating the other.
    public static func localNameLength(_ name: String?) -> Int? {
        name.map { $0.utf8.count }
    }

}
