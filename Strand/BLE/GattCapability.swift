import Foundation

/// What the strap's GATT tree actually contains — the Swift twin of `gattTreeLines`.
///
/// NOOP has never asked a strap what it exposes: every characteristic is looked up by a UUID someone
/// hardcoded, so anything a 5/MG offers that nobody guessed has never been visible, on the one protocol
/// still being reverse-engineered.
///
/// Twinned rather than left Android-only because nothing prevents it here. CoreBluetooth exposes
/// `peripheral.services`, `service.characteristics` and `characteristic.properties`, so unlike the
/// bond-state and pairing helpers — which have no Apple equivalent at all — this was a gap rather than a
/// constraint. It needs no field evidence either: it sends nothing, reads only the already-discovered
/// local cache, and cannot provoke the teardown that writing to an encrypted characteristic can.
///
/// Takes the property bitmask as a raw `UInt` and does NOT import CoreBluetooth, deliberately. That keeps
/// it compilable on Linux, which is what lets the Kotlin side pin its output against this file's actual
/// stdout instead of against a reading of it — the byte-identical check the parity contract asks for is
/// only worth anything if it can be run.
enum GattCapability {
    // The BLE characteristic-property bits, which are wire constants and identical on both platforms.
    private static let broadcast: UInt = 0x01
    private static let read: UInt = 0x02
    private static let writeNoResponse: UInt = 0x04
    private static let write: UInt = 0x08
    private static let notify: UInt = 0x10
    private static let indicate: UInt = 0x20
    private static let signedWrite: UInt = 0x40
    private static let extended: UInt = 0x80

    /// The property bitmask as names. Order and spelling match the Kotlin twin exactly; "none" for empty.
    ///
    /// Renders only the eight standard bits. CoreBluetooth additionally exposes
    /// `notifyEncryptionRequired` (0x100) and `indicateEncryptionRequired` (0x200), which Android has no
    /// equivalent for — and which are genuinely interesting for the #1635 question of whether this strap
    /// demands an encrypted link. They are left out ON PURPOSE: rendering them here would make the two
    /// platforms print different text for the same strap. If the encryption flags are wanted on Apple they
    /// belong in their own line, not smuggled into a twinned one.
    static func propertyNames(_ properties: UInt) -> String {
        var names: [String] = []
        if properties & broadcast != 0 { names.append("Broadcast") }
        if properties & read != 0 { names.append("Read") }
        if properties & writeNoResponse != 0 { names.append("WriteNoResponse") }
        if properties & write != 0 { names.append("Write") }
        if properties & notify != 0 { names.append("Notify") }
        if properties & indicate != 0 { names.append("Indicate") }
        if properties & signedWrite != 0 { names.append("SignedWrite") }
        if properties & extended != 0 { names.append("Extended") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    /// One line per characteristic, grouped by service. `services` is `(uuid, [(uuid, rawProperties)])`.
    static func treeLines(_ services: [(String, [(String, UInt)])]) -> [String] {
        if services.isEmpty { return ["GATT tree: no services discovered"] }
        var out = ["GATT tree: \(services.count) service(s)"]
        for (svc, chars) in services {
            out.append("  service \(svc) (\(chars.count) char)")
            for (uuid, props) in chars {
                out.append("    \(uuid) props=0x\(String(props, radix: 16)) (\(propertyNames(props)))")
            }
        }
        return out
    }
}
