import Foundation

/// The WHOOP 4.0 strap serial, read out of the `GET_HELLO_HARVARD` (cmd 35) response (#1193).
///
/// A 4.0 does not expose the DIS Serial Number String (`0x2A25`) that gives the 5/MG its stable id, so
/// until now the only 4.0 identity available was the CoreBluetooth peripheral UUID — which iOS re-mints
/// whenever the strap is re-paired or re-keyed. That is the whole of #1193: one physical strap forks
/// into a second registry row and its history is orphaned beside it.
///
/// The capture aid added for that hunt found the answer: in a 131-byte 4.0 cmd-35 response the serial is
/// the 9-character alphanumeric run at offset 14.
///
/// ## What this deliberately does NOT read
///
/// The same response carries a 54-character alphanumeric run at offset 24 which is the strap's DEVICE
/// KEY. This decoder reads a fixed 9-byte window and cannot reach it: there is no scanning, no
/// "longest alnum run", nothing that could drift onto the key as payloads vary. A key must never become
/// an id, reach a log, or leave the device, and the cheapest way to guarantee that is to never read it.
///
/// ## Why the strict shape check
///
/// The offset comes from ONE capture. If a future firmware moves the field, a fixed offset lands on
/// whatever is there instead — so a window that is not entirely `[0-9A-Za-z]` is refused rather than
/// returned. `WhoopSerialIdentity.adoptedId` then applies its own validation on top. Refusing costs a
/// strap the stable id it would have gained; returning something wrong migrates its whole history onto
/// a junk key, which is the failure this exists to prevent.
public enum Whoop4HelloSerial {

    /// Offset of the serial run inside the cmd-35 response payload.
    public static let serialOffset = 14
    /// Length of the serial run. The 54-char device key begins at offset 24, one byte past this window.
    public static let serialLength = 9

    /// The strap serial, or nil when the payload is too short or the window is not a clean alnum run.
    public static func decode(payload: [UInt8]) -> String? {
        guard payload.count >= serialOffset + serialLength else { return nil }
        var out = ""
        out.reserveCapacity(serialLength)
        for i in serialOffset..<(serialOffset + serialLength) {
            let b = payload[i]
            let isDigit = b >= 0x30 && b <= 0x39
            let isUpper = b >= 0x41 && b <= 0x5A
            let isLower = b >= 0x61 && b <= 0x7A
            guard isDigit || isUpper || isLower else { return nil }
            out.append(Character(UnicodeScalar(b)))
        }
        return out
    }
}

/// Withholds a serial until the SAME value has been seen twice (#1193).
///
/// The 5/MG adopts its DIS serial on first read, because `0x2A25` is a spec-defined field that means one
/// thing. The 4.0 offset is not that: it came off a single capture, so "the 9-char alnum run at offset 14"
/// is a strong inference rather than a documented field. If that run were per-session rather than
/// per-strap, adopting immediately would mint a new id on every connect and migrate the history each time
/// - strictly worse than the duplicate row this exists to prevent.
///
/// Two hellos carrying the same run cannot both be a fresh per-session token, which is the only failure
/// mode that does real damage. The cost is that a 4.0 adopts one connect later than a 5/MG.
///
/// Lives here, apart from the BLE classes that use it, because it is the part most likely to be wrong and
/// the part neither platform can unit-test in place.
public struct RepeatedSerialGate {
    private var candidate: String?
    private var confirmed: String?

    public init() {}

    /// The serial to adopt, or nil while it is still unconfirmed. Returns non-nil only on the transition
    /// to confirmed, so a caller may act on it directly without re-adopting on every later sighting.
    public mutating func offer(_ serial: String) -> String? {
        if confirmed == serial { return nil }        // already acted on
        guard candidate == serial else {
            candidate = serial                        // first sighting: remember, withhold
            return nil
        }
        confirmed = serial
        return serial
    }
}
