import Foundation

/// Decodes a `GET_BATTERY_PACK_INFO` (command 151) COMMAND_RESPONSE — the WHOOP 5.0/MG battery pack's
/// charge, serial and Bluetooth address, read THROUGH the strap (a 4.0 has no pack command). noop already
/// probes `GET_EXTENDED_BATTERY_INFO` (98), but the 5/MG reply to 98 is an undecoded stub; 151 is the
/// command that actually carries the pack's fuel gauge.
///
/// The field offsets are re-derived (clean-room, project rule: real captures, never invented offsets) from
/// two captured 5/MG frames — one strap with a pack attached, then physically removed — so this is an
/// UNVALIDATED CANDIDATE pending broader hardware confirmation. Pure + deterministic, unit-tested against
/// those frames without a strap; the Kotlin `BatteryPackInfo` is its byte-identical twin.
public enum BatteryPackInfo {

    public struct Info: Equatable, Sendable {
        /// Whether a pack is attached. The command answers SUCCESS either way; a removed pack sends a
        /// zeroed block with the present flag clear, which is the ONLY thing that tells the two apart — so
        /// an absent reply must clear the card, never keep a stale charge.
        public let present: Bool
        /// State of charge (%), tenths precision, or nil when no pack is attached.
        public let socPct: Double?
        /// The pack's own serial (ASCII), or nil when absent.
        public let serial: String?
        /// The pack's Bluetooth address as lowercase hex — identity, not a reading. nil when absent.
        public let btAddr: String?

        public init(present: Bool, socPct: Double?, serial: String?, btAddr: String?) {
            self.present = present; self.socPct = socPct; self.serial = serial; self.btAddr = btAddr
        }
    }

    /// The response-command byte sits at `cmdOff` (10 on WHOOP 5/MG — the only family with a pack; a 4.0's
    /// 6 is accepted only so a caller can pass it, though 4.0 never answers 151). Returns nil when the
    /// frame is not a well-formed 151 SUCCESS response. The caller is expected to have CRC-gated the frame
    /// (the framing layer already does), as the sibling probes assume.
    public static func decode(frame: [UInt8], cmdOff: Int = 10) -> Info? {
        // Layout relative to cmdOff, pinned to the captures: +0 resp-cmd (151), +2 result (1 = SUCCESS),
        // +4 present flag, +5 BT address (6 bytes), +11 serial (16-byte ASCII, NUL-terminated),
        // +27 SoC (u16 little-endian, tenths of a percent).
        guard cmdOff >= 0, frame.count > cmdOff + 4 else { return nil }
        guard Int(frame[cmdOff]) == 151, Int(frame[cmdOff + 2]) == 1 else { return nil }
        let present = frame[cmdOff + 4] == 1
        guard present else { return Info(present: false, socPct: nil, serial: nil, btAddr: nil) }

        let btStart = cmdOff + 5
        let serStart = cmdOff + 11
        let socStart = cmdOff + 27
        guard frame.count >= socStart + 2 else { return nil }

        let btAddr = frame[btStart..<btStart + 6].map { String(format: "%02x", $0) }.joined()
        let serBytes = Array(frame[serStart..<serStart + 16].prefix { $0 != 0 })
        let serial = serBytes.isEmpty ? nil : String(bytes: serBytes, encoding: .ascii)
        let raw = Int(frame[socStart]) | (Int(frame[socStart + 1]) << 8)
        let socPct = Double(raw) / 10.0
        return Info(present: true, socPct: socPct, serial: serial, btAddr: btAddr)
    }
}
