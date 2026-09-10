import Foundation

/*
 * Hex.swift - the hex encoder the per-frame diagnostic paths use. Twin of the Kotlin `toHexLower`.
 *
 * `map { String(format: "%02x", $0) }.joined()` reads well and is fine for a one-off line, but it runs
 * `String(format:)` ONCE PER BYTE, and that bridges to NSString formatting and parses the format string
 * every time, plus a String per byte for `joined()` to concatenate. The captures write a line per frame
 * for a whole offload and a deep-buffer frame is 2140 bytes.
 *
 * A nibble lookup into one preallocated buffer does the same job with a single allocation.
 */

private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

public extension Array where Element == UInt8 {

    /// Lowercase, two digits per byte, no separator. Byte-for-byte identical to the `%02x` join it
    /// replaces, which matters because these dumps are read by existing decode tooling.
    ///
    /// Named to match the Kotlin `toHexLower` rather than `hexString`: the two produce the same bytes and
    /// a reader comparing the platforms should not have to check whether two differently-named helpers
    /// agree on case or separator.
    var hexLower: String {
        var out = [UInt8](repeating: 0, count: count * 2)
        var i = 0
        for b in self {
            out[i] = hexDigits[Int(b >> 4)]
            out[i + 1] = hexDigits[Int(b & 0x0F)]
            i += 2
        }
        return String(decoding: out, as: UTF8.self)
    }
}
