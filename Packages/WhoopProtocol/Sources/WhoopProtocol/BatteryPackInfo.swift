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
        /// Whether a pack is attached. From `decode` (5/MG, cmd 151) this is a REAL flag: a removed pack
        /// sends a zeroed block with the flag clear, which is the only thing that tells the two apart, so
        /// an absent reply must clear the card. From `decodeExtended` (4.0, cmd 98) it only means "a
        /// voltage decoded" — cmd 98 has no presence flag and its voltage may be the strap's, so it's ~always
        /// true. Real 4.0 pack presence must come from the attach/detach events, NOT this field.
        public let present: Bool
        /// State of charge (%), tenths precision, or nil when no pack is attached.
        public let socPct: Double?
        /// The pack's own serial (ASCII), or nil when absent.
        public let serial: String?
        /// The pack's Bluetooth address as lowercase hex — identity, not a reading. nil when absent.
        public let btAddr: String?
        /// WHOOP 4.0 only: the pack VOLTAGE in millivolts. A 4.0 has no fuel-gauge command, so its pack is
        /// read via GET_EXTENDED_BATTERY_INFO (98) which reports voltage, NOT a charge %. nil on 5/MG.
        public let voltageMv: Int?

        public init(present: Bool, socPct: Double?, serial: String?, btAddr: String?, voltageMv: Int? = nil) {
            self.present = present; self.socPct = socPct; self.serial = serial
            self.btAddr = btAddr; self.voltageMv = voltageMv
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

    /// WHOOP 4.0 path. A 4.0 has no `GET_BATTERY_PACK_INFO` (151); its pack is read via
    /// `GET_EXTENDED_BATTERY_INFO` (98), which reports the pack VOLTAGE (mV) — NOT a charge %. The
    /// voltage sits at payload bytes 7..8 (little-endian), i.e. `frame[cmdOff+8..cmdOff+9]`, confirmed on
    /// WHOOP4 (#592: a 3970 mV capture); `cmdOff` is 6 on WHOOP4. This is the same offset noop's
    /// `ExtendedBatteryProbe` reads. Returns an Info carrying only `voltageMv`, or nil when the frame is
    /// not a 98 response with a voltage payload.
    ///
    /// NOTE on `present`: cmd 98 carries no present/absent flag (unlike 151), so `present` here just marks
    /// "a voltage decoded" and is ~always true — it is NOT a reliable "pack attached" signal. A 4.0 UI must
    /// take pack presence from the attach/detach events and use this only for the voltage reading.
    public static func decodeExtended(frame: [UInt8], cmdOff: Int = 6) -> Info? {
        // Need the voltage bytes to fall inside the payload (before the 4-byte CRC32 trailer): the payload
        // ends at frame.count - 4, so byte cmdOff+9 must be < that ⇒ frame.count >= cmdOff + 14.
        guard cmdOff >= 0, frame.count >= cmdOff + 14, Int(frame[cmdOff]) == 98 else { return nil }
        let mv = Int(frame[cmdOff + 8]) | (Int(frame[cmdOff + 9]) << 8)
        // 0 mV is not a real pack reading (no pack / empty answer) — report absence rather than "0.00 V".
        guard mv > 0 else { return Info(present: false, socPct: nil, serial: nil, btAddr: nil) }
        return Info(present: true, socPct: nil, serial: nil, btAddr: nil, voltageMv: mv)
    }
}
