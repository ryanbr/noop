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


        /// Whether this reading is safe to SHOW.
        ///
        /// The offsets here are an unvalidated candidate re-derived from two captures, so a wrong one
        /// would not fail — it would render a confident wrong number, which is the failure this project
        /// treats as worse than a blank. A fuel gauge is a percentage: anything outside 0...100 means the
        /// offset moved, and the caller must render nothing rather than the value.
        ///
        /// The fork that first shipped this hit exactly that shape from the other direction, reading a
        /// 24,881 mV "cell voltage" off a 5/MG frame — a 4.0-path field read on a family that does not
        /// answer it. A gauge that cannot be sanity-checked will eventually be believed.
        public var displayable: Bool {
            guard present, let soc = socPct else { return false }
            return soc >= 0 && soc <= 100
        }

        public init(present: Bool, socPct: Double?, serial: String?, btAddr: String?, voltageMv: Int? = nil) {
            self.present = present; self.socPct = socPct; self.serial = serial
            self.btAddr = btAddr; self.voltageMv = voltageMv
        }
    }

    /// Offset of the present flag inside the event-109 payload.
    public static let eventRecordBase = 4

    /// Where a WHOOP 5/MG EVENT frame's opaque payload begins. Mirrors `Framing.decodeEventWhoop5`.
    public static let whoop5EventPayloadStart = 16

    /// The uncatalogued 5/MG event that carries the pack record. Named here because `EventNumber` has no
    /// entry for it — it decodes as `0x6D(109)`.
    public static let packInfoEvent = 109

    /// Decode the pack RECORD itself, given the offset of its present-flag byte.
    ///
    /// Split out from `decode` because the same record reaches us by two entirely different transports: as
    /// the payload of a `GET_BATTERY_PACK_INFO` (151) COMMAND_RESPONSE, and — hardware-confirmed on WHOOP MG
    /// fw 50.39.1.0, 2026-09-01 — as the payload of the UNCATALOGUED pushed event `0x6D` (109), which the
    /// strap volunteers while a pack is attached. Only the framing around the record differs; the fields are
    /// identical, so they must not be decoded twice.
    ///
    /// Layout from `base`: +0 present, +1 BT address (6 B), +7 serial (16 B ASCII, NUL-terminated),
    /// +23 SoC (u16 little-endian, tenths of a percent). nil when the buffer is too short to hold it.
    public static func decodeRecord(_ bytes: [UInt8], base: Int) -> Info? {
        guard base >= 0, bytes.count > base else { return nil }
        let present = bytes[base] == 1
        guard present else { return Info(present: false, socPct: nil, serial: nil, btAddr: nil) }

        let btStart = base + 1
        let serStart = base + 7
        let socStart = base + 23
        guard bytes.count >= socStart + 2 else { return nil }

        let btAddr = bytes[btStart..<btStart + 6].map { String(format: "%02x", $0) }.joined()
        let serBytes = Array(bytes[serStart..<serStart + 16].prefix { $0 != 0 })
        let serial = serBytes.isEmpty ? nil : String(bytes: serBytes, encoding: .ascii)
        let raw = Int(bytes[socStart]) | (Int(bytes[socStart + 1]) << 8)
        return Info(present: true, socPct: Double(raw) / 10.0, serial: serial, btAddr: btAddr)
    }

    /// Decode the pack record from the pushed event `0x6D` (109) payload — the transport that actually works
    /// on a 5/MG. The strap sends this unprompted while a pack is attached, so it needs no command, no
    /// send-allowlist entry and no polling, and because it repeats it is a self-refreshing LEVEL signal.
    public static func decodeEventPayload(_ payload: [UInt8]) -> Info? {
        decodeRecord(payload, base: eventRecordBase)
    }

    /// Decode straight from a whole 5/MG EVENT frame, so callers never need to know where the payload
    /// starts. Callers must first check the event number is `packInfoEvent`; this does not re-check it,
    /// because the event byte lives in the frame header rather than the record.
    public static func decodeEventFrame(_ frame: [UInt8]) -> Info? {
        decodeRecord(frame, base: whoop5EventPayloadStart + eventRecordBase)
    }

    /// The response-command byte sits at `cmdOff` (10 on WHOOP 5/MG — the only family with a pack; a 4.0's
    /// 6 is accepted only so a caller can pass it, though 4.0 never answers 151). Returns nil when the
    /// frame is not a well-formed 151 SUCCESS response. The caller is expected to have CRC-gated the frame
    /// (the framing layer already does), as the sibling probes assume.
    ///
    /// NOTE this command path is retained for completeness only. On WHOOP MG fw 50.39.1.0 opcode 151 answers
    /// FAILURE(0) whether or not a pack is attached, so the feature is driven by `decodeEventFrame` instead.
    public static func decode(frame: [UInt8], cmdOff: Int = 10) -> Info? {
        // Header, pinned to the captures: +0 resp-cmd (151), +2 result (1 = SUCCESS). The record then starts
        // at +4, which is what `decodeRecord` expects as its base.
        guard cmdOff >= 0, frame.count > cmdOff + 4 else { return nil }
        guard Int(frame[cmdOff]) == 151, Int(frame[cmdOff + 2]) == 1 else { return nil }
        return decodeRecord(frame, base: cmdOff + 4)
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
