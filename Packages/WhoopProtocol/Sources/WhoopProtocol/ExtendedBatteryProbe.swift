import Foundation

/// #592: format a `GET_EXTENDED_BATTERY_INFO` COMMAND_RESPONSE into a clean, readable, copyable report —
/// a verdict, the full raw hex on one line, an offset-labelled payload hex grid, the decoded pack voltage,
/// and a per-byte diff vs the previous capture. Pure + deterministic, so it's unit-tested without a strap.
///
/// This is the Swift twin of the Android `WhoopBleClient.formatExtendedBatteryProbe`. It lives in the pure
/// `WhoopProtocol` package (rather than app-side like the Kotlin version) so `swift test` covers it on
/// every CI run; the behaviour — and the output text — is byte-identical to the Kotlin formatter.
public enum ExtendedBatteryProbe {

    /// Returns the display text and the payload hex to persist for the next capture's diff (nil when there
    /// is no decodable payload). `cmdOff` is the response-command byte offset (6 on WHOOP4, 10 on 5/MG);
    /// the 4-byte CRC32 trailer both families carry is excluded from the payload. The voltage line is only
    /// printed for WHOOP4 — the `pay[7..8]` offset is confirmed there, but the 5/MG response to 98 is an
    /// undecoded stub, so a decoded voltage there would be a guess presented as fact.
    public static func format(frame: [UInt8], cmdOff: Int, isWhoop5: Bool, prevPayloadHex: String?) -> (text: String, payloadHex: String?) {
        let fam = isWhoop5 ? "WHOOP 5/MG" : "WHOOP 4.0"
        let payStart = cmdOff + 1
        let payEnd = frame.count - 4
        let hasPayload = payEnd > payStart
        let pay: [UInt8] = hasPayload ? Array(frame[payStart..<payEnd]) : []

        // 5/MG replies carry an explicit result code @12 (0 FAILURE / 1 SUCCESS / 2 PENDING /
        // 3 UNSUPPORTED — 3 is the MG's hardware-confirmed rejection code, #48).
        let resultCode: Int? = (isWhoop5 && frame.count > 12) ? Int(frame[12]) : nil
        let resultLabel: String?
        switch resultCode {
        case 0: resultLabel = "FAILURE"
        case 1: resultLabel = "SUCCESS"
        case 2: resultLabel = "PENDING"
        case 3: resultLabel = "UNSUPPORTED"
        case nil: resultLabel = nil
        default: resultLabel = "result\(resultCode!)"
        }
        let verdict: String
        if resultCode == 3 {
            verdict = "opcode 98 REJECTED by firmware (UNSUPPORTED) — evidence for the decompile's 87"
        } else if hasPayload {
            verdict = "opcode 98 answered — \(pay.count)-byte payload (not a success verdict; see the bytes below)"
        } else {
            verdict = "opcode 98 answered with a bare stub — ambiguous"
        }

        var sb = ""
        sb += "#592 EXTENDED-BATTERY PROBE — \(fam)\n"
        sb += "Verdict: \(verdict)\n"
        if let resultLabel { sb += "Result code @12: \(resultLabel)(\(resultCode!))\n" }
        // Full raw hex on ONE line so it copies cleanly for sharing.
        sb += "\nRaw frame (\(frame.count) B):\n"
        sb += frame.map { String(format: "%02x", $0) }.joined() + "\n"

        var payloadHex: String?
        if hasPayload {
            payloadHex = pay.map { String(format: "%02x", $0) }.joined()
            sb += "\nPayload (\(pay.count) B, CRC excluded):\n"
            sb += hexGrid(pay)
            // NOOP's decoder reads the pack voltage at payload bytes 7..8 (LE) — confirmed only on WHOOP4.
            if !isWhoop5, pay.count >= 9 {
                let mv = Int(pay[7]) | (Int(pay[8]) << 8)
                sb += "\nVoltage: " + String(format: "%.2f V", Double(mv) / 1000.0)
                sb += "  (mV=\(mv) @07) — the field NOOP already reads\n"
            }
            // Per-byte diff vs the previous capture — the field-mapping signal.
            sb += "\n"
            if let prevPayloadHex, prevPayloadHex.count == payloadHex!.count {
                let prev = hexToBytes(prevPayloadHex)
                var deltas = ""
                for i in pay.indices where prev[i] != Int(pay[i]) {
                    deltas += String(format: " @%02d:%02x→%02x", i, prev[i], Int(pay[i]))
                }
                if deltas.isEmpty {
                    sb += "Δ vs previous capture: identical — re-probe at a different % / after wear to expose the fields"
                } else {
                    sb += "Δ vs previous capture:\(deltas)\n"
                    sb += "(a byte tracking battery % = SoC/capacity; drifting with wear = temperature; only ever climbing = cycle count)"
                }
            } else {
                sb += "Δ vs previous capture: first capture — probe again at another battery % to diff"
            }
        } else {
            sb += "\nNo payload beyond the command byte (bare stub) — no data over the battery event; "
            sb += "opcode 98 may be an unknown-command ack on this firmware"
        }
        return (sb, payloadHex)
    }

    /// Offset-labelled hex grid, 8 bytes per row ("  @00  0d 01 …"), for the #592 payload dump.
    private static func hexGrid(_ bytes: [UInt8]) -> String {
        var sb = ""
        var i = 0
        while i < bytes.count {
            sb += String(format: "  @%02d ", i)
            var j = i
            while j < min(i + 8, bytes.count) {
                sb += String(format: " %02x", bytes[j])
                j += 1
            }
            sb += "\n"
            i += 8
        }
        return sb
    }

    private static func hexToBytes(_ hex: String) -> [Int] {
        let chars = Array(hex)
        var out: [Int] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            out.append((Int(String(chars[i]), radix: 16) ?? 0) << 4 | (Int(String(chars[i + 1]), radix: 16) ?? 0))
            i += 2
        }
        return out
    }
}
