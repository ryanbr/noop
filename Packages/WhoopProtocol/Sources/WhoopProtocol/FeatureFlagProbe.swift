import Foundation

/// #761: READ-ONLY enumeration of the strap's own feature-flag key list.
///
/// NOOP already WRITES feature flags (`SET_FF_VALUE` / 0x78, the R22 deep-stream unlock in
/// `Whoop5Config`) but has never been able to ASK a strap which flags it knows. The protocol has a
/// symmetric read side that NOOP never implemented — `whoop_protocol.json` `CommandNumber` names all of
/// it: 117 `START_FF_KEY_EXCHANGE`, 118 `SEND_NEXT_FF`, 120 `SET_FF_VALUE`, 128 `GET_FF_VALUE` (and the
/// device-config quartet 115/116/119/121). This file decodes the **enumeration** pair only — 117 then
/// repeated 118 — which reads the key NAMES and nothing else.
///
/// `GET_FF_VALUE` (128) is deliberately NOT implemented: the only hands-on report of it
/// (`johnmiddleton12/wearable`, docs/specs/2026-05-24-whoop-protocol-complete.md §4, run against the
/// author's own WHOOP 4.0 on fw 41.16.6.0) states its reply's value field is contaminated by a stale
/// shared buffer, so a read of on/off is unreliable. The same session ran the 117→118 loop and got a
/// complete key dump, which is why the enumerate path is the one built here.
///
/// **Read-only.** The probe writes command frames in order to read — exactly like the Oura feature-status
/// probe NOOP already ships (`Packages/OuraProtocol/…/Commands.swift`, `spo2ReadStatus()` /
/// `realStepsReadStatus()`, `2f 02 20 <feature>`) — but sets no value, and 120/119 (the SET verbs) are
/// never sent from this path. Nothing about strap state changes.
///
/// ## Wire shape
///
/// Request: command 117 or 118 with body `[0x01]` — the same inner b3 convention CLIENT_HELLO and
/// `Whoop5Config`'s SET_CONFIG writes use. 118 carries a **cursor, not an index**: the same body is sent
/// repeatedly and the strap walks its own list.
///
/// Response: an ordinary COMMAND_RESPONSE echoing the command byte. The two-byte response header
/// (`pay[0..2]`, whose second byte is the 5/MG result code) precedes the record, exactly as every other
/// COMMAND_RESPONSE in this codebase decodes it — `GET_BATTERY_LEVEL` reads its value at `pay[2]` on both
/// families (`PostHooks.swift`, `Interpreter.decodeWhoop5CommandResponse`). So the record starts at
/// `pay[2]`:
///
/// ```
/// 117 START_FF_KEY_EXCHANGE   record = [revision u8][numberOfFeatureFlags u16 LE][padding…]
/// 118 SEND_NEXT_FF            record = [revision u8][index u8][validKey u8][key ASCII, NUL-terminated][padding…]
/// ```
///
/// Two independent sources agree on that ordering, which is why it is decoded rather than left raw:
/// the field ORDER and the opcode numbers are documented in a decompiled official client's response
/// types (`StartFeatureFlagKeyExchangeResponsePacket { revision, numberOfFeatureFlags, padding }`,
/// `SendNextFeatureFlagResponsePacket { revision, index, validKey, keyStringId, padding }`), and the
/// hands-on WHOOP 4.0 dump above shows literal replies of `0a 01 | 01 <count u16>` and
/// `0a 01 | 01 <index> 01 <key name…>`, with `0a 01 | 01 ff …` when the cursor is exhausted. Those are
/// facts about bytes on a wire, reimplemented here in NOOP's own code — no client code or naming is
/// copied (see ATTRIBUTION.md, and #822 on the fact/expression line).
///
/// **Unverified on 5/MG.** The hardware result behind this layout is a WHOOP 4.0 with an R19-era key
/// list; whether a 5/MG answers 117 at all is exactly what the probe exists to find out. Everything
/// here therefore fails closed: a frame whose CRCs don't pass, whose type isn't COMMAND_RESPONSE, or
/// whose record is short is REJECTED rather than guessed at, and an implausible flag count is reported
/// but never trusted as a loop bound.
public enum FeatureFlagProbe {

    // MARK: - Wire constants

    /// START_FF_KEY_EXCHANGE (117 / 0x75) — ask the strap how many feature flags it knows. Read-only.
    public static let startKeyExchangeCmd: UInt8 = 117
    /// SEND_NEXT_FF (118 / 0x76) — advance the strap's own cursor and report one key name. Read-only.
    public static let sendNextFlagCmd: UInt8 = 118

    /// Request body for both commands: the inner b3 byte `0x01`, the convention GET_HELLO and the
    /// SET_CONFIG family use. `BLEManager.send` carries it as the first payload byte.
    public static let requestBody: [UInt8] = [0x01]

    /// Hard ceiling on 118 round-trips in one probe, independent of the count the strap reports. A
    /// firmware that answers with a nonsense count (or never advances its cursor) must not be able to
    /// drive an unbounded write loop on the command characteristic. The published 4.0 dump enumerated
    /// 11 flags; 128 leaves generous headroom for a 5/MG's larger R22-era list.
    public static let maxFlags = 128

    /// Longest key name accepted from a reply. The SET side NUL-pads names to 32 bytes
    /// (`Whoop5Config.payloadBody`), so a longer run of printable bytes means we are reading padding or
    /// a mis-anchored record, not a key.
    public static let maxKeyLength = 32

    // MARK: - Decoded responses

    /// Why a frame was not decoded. Distinct cases so the probe can say *what* went wrong in the log
    /// instead of silently dropping a reply.
    public enum ParseFailure: String, Error, Equatable, Sendable {
        /// A CRC did not verify. Bad bytes never drive state (BLE safety contract §2).
        case crc
        /// Not a COMMAND_RESPONSE frame, or too short to hold the envelope.
        case envelope
        /// A COMMAND_RESPONSE for a different command.
        case wrongCommand
        /// The record is shorter than the fields it must carry.
        case truncated
    }

    /// Decoded `START_FF_KEY_EXCHANGE` reply.
    public struct StartResponse: Equatable, Sendable {
        /// Result code byte (`pay[1]`). Labelled only on 5/MG, where the codebase has already pinned its
        /// meaning (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED); nil on WHOOP 4.0, where the same
        /// byte's semantics are not established.
        public let resultCode: Int?
        /// Record `revision` — the layout version the firmware answers with.
        public let revision: Int
        /// `numberOfFeatureFlags` as reported by the strap. NOT trusted as a loop bound on its own.
        public let count: Int
        public init(resultCode: Int?, revision: Int, count: Int) {
            self.resultCode = resultCode
            self.revision = revision
            self.count = count
        }
        /// True when the count is inside the range a real key list could plausibly occupy.
        public var countIsPlausible: Bool { count > 0 && count <= FeatureFlagProbe.maxFlags }
    }

    /// Decoded `SEND_NEXT_FF` reply.
    public struct NextResponse: Equatable, Sendable {
        public let resultCode: Int?
        public let revision: Int
        /// The cursor position the strap reports for this entry. `0xFF` marks the walk finished.
        public let index: Int
        /// The firmware's own "this entry is a real key" flag.
        public let validKey: Bool
        /// The key name, when one decodes as printable ASCII; nil when the entry carries none.
        public let key: String?
        public init(resultCode: Int?, revision: Int, index: Int, validKey: Bool, key: String?) {
            self.resultCode = resultCode
            self.revision = revision
            self.index = index
            self.validKey = validKey
            self.key = key
        }
        /// The STRAP said stop: it returned the 0xFF end marker, or flagged the entry as not a real key.
        /// Both are the firmware's own signal, so both are trusted.
        ///
        /// Deliberately does NOT include `key == nil`. That is OUR parser declining a name — a byte outside
        /// printable ASCII, or one longer than `maxKeyLength` — and it says nothing about whether the strap
        /// has more entries. Treating it as a terminator meant one undecodable name threw away every entry
        /// after it: a list of forty with a bad byte at seven yielded six keys. See `isSkippable`.
        public var isExhausted: Bool { !validKey || index == 0xFF }

        /// The firmware calls this a real key but the name did not decode. Record it and KEEP WALKING.
        ///
        /// Safe because the walk was never bounded by this: `maxFlags` caps the replies and the announced
        /// count bounds it further, so skipping can only spend budget that already exists. And it matters
        /// most on the run that matters most — the first real capture is the expensive one to obtain, so
        /// truncating it on our own strictness is the worst possible time to lose entries.
        public var isSkippable: Bool { validKey && index != 0xFF && key == nil }
    }

    // MARK: - Parsing

    /// Decode a `START_FF_KEY_EXCHANGE` COMMAND_RESPONSE. CRC-gated: a frame whose checksums fail is
    /// rejected before any field is read.
    public static func parseStart(frame: [UInt8], family: DeviceFamily) -> Result<StartResponse, ParseFailure> {
        switch record(frame: frame, family: family, expecting: startKeyExchangeCmd) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            guard r.record.count >= 3 else { return .failure(.truncated) }
            let count = Int(r.record[1]) | (Int(r.record[2]) << 8)
            return .success(StartResponse(resultCode: r.resultCode, revision: Int(r.record[0]), count: count))
        }
    }

    /// Decode a `SEND_NEXT_FF` COMMAND_RESPONSE. CRC-gated like `parseStart`.
    public static func parseNext(frame: [UInt8], family: DeviceFamily) -> Result<NextResponse, ParseFailure> {
        switch record(frame: frame, family: family, expecting: sendNextFlagCmd) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            // revision + index are the minimum: the 0xFF end marker arrives with nothing after it.
            guard r.record.count >= 2 else { return .failure(.truncated) }
            let revision = Int(r.record[0])
            let index = Int(r.record[1])
            let validKey = r.record.count >= 3 ? r.record[2] != 0 : false
            let key = r.record.count >= 4 ? asciiKey(Array(r.record[3...])) : nil
            return .success(NextResponse(resultCode: r.resultCode, revision: revision, index: index,
                                         validKey: validKey, key: key))
        }
    }

    /// The record bytes (everything after the two-byte response header) plus the 5/MG result code.
    private struct Extracted {
        let record: [UInt8]
        let resultCode: Int?
    }

    /// Shared envelope work: verify both CRCs, confirm this is a COMMAND_RESPONSE for `expecting`, and
    /// slice out the record. `cmdOff` is 6 on WHOOP 4.0 (`[type][seq][cmd]` from frame[4]) and 10 on
    /// 5/MG (the puffin envelope inserts the format byte + CRC16 header first); the 4-byte CRC32 trailer
    /// is excluded from the payload on both.
    private static func record(frame: [UInt8], family: DeviceFamily,
                               expecting: UInt8) -> Result<Extracted, ParseFailure> {
        // BLE safety contract §2: CRC-gate everything. A frame that fails either checksum is not data.
        guard verifyFrame(frame, family: family).ok else { return .failure(.crc) }
        let typeOff = family == .whoop5 ? 8 : 4
        let cmdOff = typeOff + 2
        guard frame.count > cmdOff + 4 else { return .failure(.envelope) }
        guard frame[typeOff] == commandResponseType else { return .failure(.envelope) }
        guard frame[cmdOff] == expecting else { return .failure(.wrongCommand) }
        let payStart = cmdOff + 1
        let payEnd = frame.count - 4          // strip the CRC32 trailer
        guard payEnd > payStart else { return .failure(.truncated) }
        let pay = Array(frame[payStart..<payEnd])
        // The record sits behind the 2-byte response header, the same offset every other
        // COMMAND_RESPONSE decoder in this package uses (battery %, clock).
        guard pay.count > responseHeaderBytes else { return .failure(.truncated) }
        let resultCode: Int? = family == .whoop5 ? Int(pay[1]) : nil
        return .success(Extracted(record: Array(pay[responseHeaderBytes...]), resultCode: resultCode))
    }

    /// COMMAND_RESPONSE packet type (`PacketType.COMMAND_RESPONSE` = 36 / 0x24).
    static let commandResponseType: UInt8 = 36

    /// Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code.
    static let responseHeaderBytes = 2

    /// Read a NUL-terminated printable-ASCII key name. Returns nil when the first byte is already NUL or
    /// non-printable (no name in this entry) so a padding run can never be reported as a flag.
    static func asciiKey(_ bytes: [UInt8]) -> String? {
        var out: [UInt8] = []
        for b in bytes {
            if b == 0 { break }
            guard (32...126).contains(b) else { return nil }
            out.append(b)
            if out.count > maxKeyLength { return nil }
        }
        return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
    }

    /// 5/MG result-code label (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED), matching
    /// `BodyLocationProbe`. Unknown codes keep their number rather than being coerced.
    static func resultLabel(_ code: Int) -> String {
        switch code {
        case 0: return "FAILURE"
        case 1: return "SUCCESS"
        case 2: return "PENDING"
        case 3: return "UNSUPPORTED"
        default: return "result\(code)"
        }
    }
}

// MARK: - Report

/// The running result of one enumeration probe, rendered into the copyable text the Devices dialog and
/// the strap log both show. Pure and order-dependent (start → next… → finish), so `swift test` covers
/// the whole report without a strap. Kotlin twin: `FeatureFlagProbeReport` in
/// `android/…/protocol/FeatureFlagProbe.kt`; the rendered text is byte-identical across platforms so a
/// shared strap log reads the same either side.
public struct FeatureFlagProbeReport: Equatable, Sendable {

    /// Which family the probe ran against (labels only).
    public let family: DeviceFamily
    /// Key names collected, in the order the strap reported them.
    public private(set) var keys: [String] = []
    /// Trace lines: one per reply plus any failure notes.
    public private(set) var trace: [String] = []
    /// SEND_NEXT replies seen. Bounds the walk (see `noteNext`).
    public private(set) var steps = 0
    /// The count the strap reported for `START_FF_KEY_EXCHANGE`, when it answered.
    public private(set) var reportedCount: Int?
    /// Result code of the START reply on 5/MG (nil on 4.0, or before it lands).
    public private(set) var startResult: Int?
    /// Entries the strap flagged as real keys whose NAME did not decode, and which the walk stepped over
    /// rather than stopping at. Surfaced in the report so a dump with holes never reads as a complete list.
    public private(set) var skipped = 0
    /// Set once the walk stopped for a reason we can name.
    public private(set) var stopReason: String?

    public init(family: DeviceFamily) { self.family = family }

    /// Record the START reply.
    public mutating func noteStart(_ r: FeatureFlagProbe.StartResponse) {
        reportedCount = r.count
        startResult = r.resultCode
        var line = "START_FF_KEY_EXCHANGE(117) → revision=\(r.revision) count=\(r.count)"
        if let c = r.resultCode { line += " result=\(FeatureFlagProbe.resultLabel(c))(\(c))" }
        if !r.countIsPlausible {
            line += "  ⚠︎ count outside 1…\(FeatureFlagProbe.maxFlags) — treated as unknown, the walk still stops on the strap's own end marker"
        }
        trace.append(line)
    }

    /// Record one SEND_NEXT reply. Returns true when the walk should continue.
    @discardableResult
    public mutating func noteNext(_ r: FeatureFlagProbe.NextResponse) -> Bool {
        steps += 1
        var line = "SEND_NEXT_FF(118) → index=\(r.index) validKey=\(r.validKey)"
        if let k = r.key { line += " key=\"\(k)\"" }
        if let c = r.resultCode { line += " result=\(FeatureFlagProbe.resultLabel(c))(\(c))" }
        trace.append(line)
        if r.isExhausted {
            if r.index == 0xFF {
                stopReason = "cursor exhausted (index 0xFF)"
            } else {
                // `validKey = 0` is documented as an end marker alongside 0xFF, and it is the firmware's
                // own flag, so it is trusted here. But nothing observed so far rules out the other
                // reading — that it marks an EMPTY SLOT and the list continues past it. If so this stops
                // on the first hole, which is the same truncation `isSkippable` exists to prevent, one
                // condition over. It cannot be settled without a strap, so instead of guessing we make
                // the discrepancy loud: stopping here well short of the announced count is exactly the
                // evidence that would settle it.
                stopReason = "firmware reported validKey=false"
                if let count = reportedCount, count > steps {
                    stopReason = "firmware reported validKey=false at index \(r.index) after \(steps) of "
                        + "\(count) announced entries — if validKey=0 marks an empty slot rather than the "
                        + "end of the list, the remainder was NOT walked (see #872 review)"
                }
            }
            return false
        }
        if r.isSkippable {
            // Our decode declined the name; the strap still says the entry is real and may have more after
            // it. Count it so a partial dump describes itself instead of looking complete.
            skipped += 1
            trace[trace.count - 1] += "  (name did not decode — skipped, walk continues)"
        }
        if let k = r.key, !keys.contains(k) { keys.append(k) }
        // Bound the walk on REPLIES, not on distinct keys: a firmware whose cursor never advances would
        // repeat one name forever, and a key-count bound would never stop writing 118 to the strap.
        if steps >= FeatureFlagProbe.maxFlags {
            stopReason = "safety cap of \(FeatureFlagProbe.maxFlags) replies reached"
            return false
        }
        if let count = reportedCount, count > 0, count <= FeatureFlagProbe.maxFlags, steps >= count {
            stopReason = "walked the \(count) entries the strap announced"
            return false
        }
        return true
    }

    /// Record a reply that could not be decoded.
    public mutating func noteFailure(_ f: FeatureFlagProbe.ParseFailure, command: Int) {
        let why: String
        switch f {
        case .crc:          why = "CRC failed — frame rejected (never decoded)"
        case .envelope:     why = "not a COMMAND_RESPONSE envelope"
        case .wrongCommand: why = "COMMAND_RESPONSE for a different command"
        case .truncated:    why = "record too short for the documented layout"
        }
        trace.append("cmd \(command) reply not decoded: \(why)")
        stopReason = stopReason ?? why
    }

    /// Record the strap answering nothing at all within the probe's window.
    public mutating func noteTimeout(command: Int, seconds: Int) {
        trace.append("no COMMAND_RESPONSE for opcode \(command) within \(seconds)s")
        stopReason = stopReason ?? "strap served no reply to opcode \(command) within \(seconds)s"
    }

    /// The full copyable report.
    public func render() -> String {
        let fam = family == .whoop5 ? "WHOOP 5/MG" : "WHOOP 4.0"
        var sb = "#761 FEATURE-FLAG ENUMERATION PROBE — \(fam)\n"
        sb += "Read-only: START_FF_KEY_EXCHANGE(117) + SEND_NEXT_FF(118). No value is written; "
        sb += "SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.\n"
        sb += "\nVerdict: \(verdict)\n"
        if let stopReason { sb += "Stopped: \(stopReason)\n" }
        sb += "\nFlags reported by the strap (\(keys.count)"
        if let reportedCount { sb += " of \(reportedCount) announced" }
        if skipped > 0 { sb += ", \(skipped) name(s) did not decode and were skipped" }
        sb += "):\n"
        if keys.isEmpty {
            sb += "  (none)\n"
        } else {
            for (i, k) in keys.enumerated() { sb += String(format: "  %2d. ", i + 1) + k + "\n" }
        }
        sb += "\nExchange:\n"
        for line in trace { sb += "  " + line + "\n" }
        return sb
    }

    /// The announced count as a phrase for the verdict line, qualified when it falls outside the range a
    /// real key list could occupy. `noteStart` already marks an implausible count in the trace, but the
    /// verdict is the line that gets pasted into an issue, and restating a number the probe itself
    /// distrusts as bare fact is the same over-claim in a smaller place. A plausible count renders
    /// exactly as before, so the common report is unchanged.
    private var announcedFlags: String {
        let n = reportedCount ?? 0
        let plausible = n > 0 && n <= FeatureFlagProbe.maxFlags
        return plausible ? "\(n) flag(s)" : "an implausible \(n) flag(s)"
    }

    /// One-line summary of what the probe established.
    public var verdict: String {
        if let startResult, startResult == 3 {
            return "opcode 117 REJECTED by firmware (UNSUPPORTED) — this strap does not serve the enumerate verb"
        }
        if keys.isEmpty && reportedCount == nil {
            return "no usable reply — the enumerate path is unconfirmed on this firmware"
        }
        // "named none" would blame the strap for OUR decode. If entries were skipped the strap did name
        // them and this parser rejected the names, which is the opposite conclusion and the one a reader
        // would carry into #103. Same class as `isSkippable`: never report our limitation as the strap's
        // behaviour.
        if keys.isEmpty && skipped > 0 {
            return "strap named \(skipped) flag(s), none of which decoded as printable ASCII within "
                + "\(FeatureFlagProbe.maxKeyLength) chars — this is our parser rejecting them, NOT the "
                + "strap serving blanks; see the trace for the raw replies"
        }
        // Same discipline one condition over: with no 118 reply decoded, the walk never asked for a
        // single name, so "named none" would blame the strap for OUR timeout (or our parse failure).
        // `steps` counts decoded SEND_NEXT replies, so `steps == 0` is exactly "the key list was never
        // read" — the reachable case being `probeFeatureFlags()` getting its 117 answer and then the 8s
        // timer firing on the first 118. What the strap would have named is unknown, and the report has
        // to say unknown. `stopReason`, rendered directly under this line, names which of the two it was.
        if keys.isEmpty && steps == 0 {
            return "strap announced \(announcedFlags); no SEND_NEXT_FF(118) reply was decoded — "
                + "the key list was never read (inconclusive)"
        }
        if keys.isEmpty {
            return "strap announced \(announcedFlags) but named none"
        }
        if skipped > 0 {
            return "enumerated \(keys.count) feature-flag key name(s); \(skipped) further name(s) did not decode"
        }
        return "enumerated \(keys.count) feature-flag key name(s)"
    }
}
