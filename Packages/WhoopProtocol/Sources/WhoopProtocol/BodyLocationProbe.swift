import Foundation

/// #690: format a `GET_BODY_LOCATION_AND_STATUS` (84 / 0x54) COMMAND_RESPONSE into a clean, readable,
/// copyable report — a verdict, the full raw hex on one line, an offset-labelled payload hex grid, and the
/// four decoded fields (revision / location + enum label / confidence / status). Pure + deterministic, so
/// it's unit-tested without a strap.
///
/// READ-ONLY diagnostic: it never changes wear detection, sleep gating, or scoring. Unknown `location`
/// values (including the gap at 6) fall through to a raw label, and `confidence`/`status` are always kept
/// raw — their semantics aren't established, so labelling them would be a guess presented as fact.
///
/// Swift twin of the Android `WhoopBleClient.formatBodyLocationProbe`; lives in the pure `WhoopProtocol`
/// package (like `ExtendedBatteryProbe`) so `swift test` covers it on every CI run, and the output text is
/// byte-identical to the Kotlin formatter.
///
/// Protocol facts — the 0x54 command number, the 4-byte `revision/location/confidence/status` response
/// layout, and the location enum — are reverse-engineered from the WHOOP app (via the goose reference set)
/// and reimplemented here in NOOP's own code: facts, not copied expression (see ATTRIBUTION.md).
public enum BodyLocationProbe {

    /// Returns the display text and the payload hex to persist for the next capture's diff (nil when there
    /// is no decodable payload). `cmdOff` is the response-command byte offset (6 on WHOOP4, 10 on 5/MG);
    /// the 4-byte CRC32 trailer both families carry is excluded from the payload.
    public static func format(frame: [UInt8], cmdOff: Int, isWhoop5: Bool, prevPayloadHex: String?) -> (text: String, payloadHex: String?) {
        let fam = isWhoop5 ? "WHOOP 5/MG" : "WHOOP 4.0"
        let payStart = cmdOff + 1
        let payEnd = frame.count - 4
        let hasPayload = payEnd > payStart
        let pay: [UInt8] = hasPayload ? Array(frame[payStart..<payEnd]) : []

        // 5/MG replies carry an explicit result code @12 (0 FAILURE / 1 SUCCESS / 2 PENDING /
        // 3 UNSUPPORTED — the firmware's rejection code for an opcode it doesn't implement).
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
            verdict = "opcode 84 REJECTED by firmware (UNSUPPORTED)"
        } else if hasPayload {
            verdict = "opcode 84 ACCEPTED — \(pay.count)-byte payload"
        } else {
            verdict = "opcode 84 answered with a bare stub — ambiguous"
        }

        var sb = ""
        sb += "#690 BODY-LOCATION PROBE — \(fam)\n"
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
            // GetBodyLocationResponsePacket layout: revision, location, confidence, status (4 bytes) — but
            // only at cmdOff+1 on WHOOP4, where the inner payload starts right after the command byte. On
            // 5/MG the puffin envelope inserts a result code @12 (= pay[1] here), so decoding these offsets
            // would mislabel the RESULT CODE as the location. Until a real 5/MG capture maps the record's
            // true offset, only WHOOP4 is decoded; 5/MG shows the raw grid, never a guessed field.
            if !isWhoop5, pay.count >= 4 {
                let revision = Int(pay[0])
                let location = Int(pay[1])
                let confidence = Int(pay[2])
                let status = Int(pay[3])
                sb += "\nDecoded:\n"
                sb += "  revision:   \(revision)\n"
                sb += "  location:   \(location)  (\(locationLabel(location)))\n"
                sb += "  confidence: \(confidence)  (raw)\n"
                sb += "  status:     \(status)  (raw)\n"
            } else if !isWhoop5 {
                sb += "\nPayload shorter than the 4-byte body-location record — fields kept raw only\n"
            } else {
                sb += "\n5/MG: the record's offset inside the puffin envelope is unconfirmed — NOT decoded (the raw grid above stands); a real capture is needed to map the fields\n"
            }
            // Per-byte diff vs the previous capture — helps map confidence/status as they move with wear.
            sb += "\n"
            if let prevPayloadHex, prevPayloadHex.count == payloadHex!.count {
                let prev = hexToBytes(prevPayloadHex)
                var deltas = ""
                for i in pay.indices where prev[i] != Int(pay[i]) {
                    deltas += String(format: " @%02d:%02x→%02x", i, prev[i], Int(pay[i]))
                }
                if deltas.isEmpty {
                    sb += "Δ vs previous capture: identical — re-probe after moving/re-seating the strap to expose the fields"
                } else {
                    sb += "Δ vs previous capture:\(deltas)"
                }
            } else {
                sb += "Δ vs previous capture: first capture — probe again in another position to diff"
            }
        } else {
            sb += "\nNo payload beyond the command byte (bare stub) — this reply carried no body-location data, which is not the same as the firmware having none (see the Verdict above)"
        }
        return (sb, payloadHex)
    }

    /// 0x54 location enum. Unknown/gap values (e.g. 6) fall through to a raw label so an unfamiliar reading
    /// is preserved, never crashes, and is never silently coerced to a known position.
    private static func locationLabel(_ v: Int) -> String {
        switch v {
        case 0: return "UNKNOWN"
        case 1: return "WRIST"
        case 2: return "BICEP"
        case 3: return "CALF"
        case 4: return "SIDE_TORSO"
        case 5: return "GLUTE"
        case 7: return "ANKLE"
        case 128: return "NOT_CONCLUSIVE"
        case 160: return "UNKNOWN_GARMENT"
        default: return "raw\(v)"
        }
    }

    /// Offset-labelled hex grid, 8 bytes per row ("  @00  01 01 5a 00"), for the payload dump.
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
