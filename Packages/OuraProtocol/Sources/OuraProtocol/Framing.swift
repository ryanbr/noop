import Foundation

// Framing: the two framing layers that ride on the same characteristics (OURA_PROTOCOL.md s2).
//   - Outer command / command-response frame:  op(1) len(1) body(len)        (s2.1)
//   - Extended / secure-session frame (0x2F):   2F len subop subop-body       (s2.2)
//   - Inner event record (TLV):                 type(1) len(1) rt:u32LE payload (s2.3)
// All multi-byte integers are little-endian unless a decoder states otherwise (OURA_PROTOCOL.md s2.1).
//
// The first byte disambiguates layers: a value present in the opcode table (s4) is an outer frame;
// otherwise it is an inner event record. The OuraDriver routes on this; Framing exposes pure parsers
// plus a defensive Reassembler that buffers partial trailing bytes across notifications (s2.4).
//
// Platform-pure, value types only. Facts cited per OURA_PROTOCOL.md s2.

// MARK: - Outer command / response frame

/// A parsed outer frame: `op len body` (OURA_PROTOCOL.md s2.1). `body` is the `len` bytes after the
/// header. Multiple outer frames may be packed into one notification; the consumer loops 2+len.
public struct OuraOuterFrame: Equatable, Sendable {
    public let op: UInt8
    public let body: [UInt8]
    public init(op: UInt8, body: [UInt8]) { self.op = op; self.body = body }

    /// Total wire length of this frame (header + body).
    public var totalLength: Int { 2 + body.count }
}

/// A parsed secure-session sub-frame: the first body byte of a 0x2F frame is the sub-op
/// (OURA_PROTOCOL.md s2.2 / s4.2). `subBody` is the remaining body bytes after the sub-op.
public struct OuraSecureFrame: Equatable, Sendable {
    public let subop: UInt8
    public let subBody: [UInt8]
    public init(subop: UInt8, subBody: [UInt8]) { self.subop = subop; self.subBody = subBody }
}

public enum OuraFraming {
    /// The secure-session / extended opcode. Per OURA_PROTOCOL.md s2.2 / s4.1.
    public static let secureSessionOp: UInt8 = 0x2F

    /// The GetEvents response / summary outer opcode (OURA_PROTOCOL.md s5.2). Below the event-tag range
    /// (tags are >= 0x41), so a caller that fails to special-case it and lets it fall through to the TLV
    /// decoder gets a safe no-op ("unknown tag") with correct byte accounting, never a misdecode.
    public static let getEventsResponseOp: UInt8 = 0x11

    /// The GetBattery response outer opcode (OURA_PROTOCOL.md s4.1/s6.10). Below the event-tag range
    /// (tags are >= 0x41), so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
    /// caller fails to special-case it.
    public static let batteryResponseOp: UInt8 = 0x0D

    /// The SyncTime response outer opcode (OURA_PROTOCOL.md s5.4, [ringverse BLE.md]). Below the
    /// event-tag range, so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
    /// caller fails to special-case it.
    public static let syncTimeResponseOp: UInt8 = 0x13

    /// Parse a 0x13 SyncTime response body per ringverse BLE.md:
    /// `current_device_timestamp:4 LE  status:1`. The device timestamp is the ring's own clock counter
    /// AT THE MOMENT it processed our SyncTime — paired with the host wall-clock at receipt it forms a
    /// deterministic ring-time→UTC anchor available at EVERY connect (the 0x42 time-sync record is only
    /// logged when the ring actually adjusts its clock, so a session on an already-synced ring may never
    /// see one — observed 2026-07-13: a whole night's drain with no anchor). ringverse labels the field
    /// "seconds" but the tick unit is unconfirmed; the caller disambiguates against the persisted resume
    /// cursor (OuraDriver.syncTimeAnchorCandidate). Returns nil on a short body.
    public static func parseSyncTimeResponse(_ body: [UInt8]) -> (deviceTimestamp: UInt32, status: UInt8)? {
        guard body.count >= 5 else { return nil }
        let ts = UInt32(body[0]) | (UInt32(body[1]) << 8) | (UInt32(body[2]) << 16) | (UInt32(body[3]) << 24)
        return (ts, body[4])
    }

    /// Parse a 0x11 GetEvents response body per open_oura's `EventBatchSummary`:
    /// `events_received:1  sleep_analysis_progress:1  bytes_left:4LE  [pad:2]`. The drain loop runs
    /// until `bytes_left == 0`; there is NO resume cursor in this packet — the resume position is a
    /// CLIENT-managed event-envelope ring-time, never read back from here. Returns nil on a short body.
    ///
    /// #91 (was re-broken on main; observed on-device 2026-07-11): bytes[2..5] were decoded as a
    /// `last_ring_timestamp` cursor and body[0] as a "more data" status. Both are wrong: body[0] is
    /// `events_received` (a batch COUNT — treating 0 as "done" stopped a drain with 400,873 bytes still
    /// left, losing the newest data), and bytes[2..5] is `bytes_left` (a remaining-BYTE count — persisting
    /// it and comparing across sessions as clocks minted a phantom "ring-time regression" → reset-to-0 →
    /// full history re-dump on every connect).
    public static func parseGetEventsResponse(_ body: [UInt8]) -> (eventsReceived: UInt8, bytesLeft: UInt32, moreData: Bool)? {
        guard body.count >= 6 else { return nil }
        let eventsReceived = body[0]
        let bytesLeft = UInt32(body[2]) | (UInt32(body[3]) << 8) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 24)
        return (eventsReceived, bytesLeft, bytesLeft > 0)
    }

    /// Parse one outer frame from the front of `bytes`. Returns nil on a short buffer (header or body
    /// not fully present), so a caller can wait for more bytes. Per OURA_PROTOCOL.md s2.1.
    public static func parseOuterFrame(_ bytes: [UInt8]) -> OuraOuterFrame? {
        guard bytes.count >= 2 else { return nil }
        let op = bytes[0]
        let len = Int(bytes[1])
        guard bytes.count >= 2 + len else { return nil }
        return OuraOuterFrame(op: op, body: Array(bytes[2..<(2 + len)]))
    }

    /// Split a notification value that may pack several outer frames back to back. Stops and returns
    /// what it parsed when a trailing partial frame is found (the Reassembler handles re-buffering for
    /// the stream case). Per OURA_PROTOCOL.md s2.1 (loop consume(2+len)).
    public static func parseOuterFrames(_ bytes: [UInt8]) -> [OuraOuterFrame] {
        var out: [OuraOuterFrame] = []
        var i = 0
        while i + 2 <= bytes.count {
            let len = Int(bytes[i + 1])
            let total = 2 + len
            guard i + total <= bytes.count else { break }
            out.append(OuraOuterFrame(op: bytes[i], body: Array(bytes[(i + 2)..<(i + total)])))
            i += total
        }
        return out
    }

    /// Interpret an outer frame whose op is 0x2F as a secure-session sub-frame (OURA_PROTOCOL.md s2.2).
    /// Returns nil when the op is not 0x2F or the body is empty.
    public static func parseSecureFrame(_ frame: OuraOuterFrame) -> OuraSecureFrame? {
        guard frame.op == secureSessionOp, let subop = frame.body.first else { return nil }
        return OuraSecureFrame(subop: subop, subBody: Array(frame.body.dropFirst()))
    }
}

// MARK: - Inner event record (TLV)

/// A parsed TLV inner event record (OURA_PROTOCOL.md s2.3):
///   type(1) len(1) ctr:u16LE ses:u16LE payload(len-4)
/// `ringTimestamp` is stored as a single u32 LE = (session << 16) | counter (the two views are
/// equivalent per the s2.3 note). `payload` is the `len-4` bytes after the 4 timestamp bytes.
public struct OuraRecord: Equatable, Sendable {
    public let type: UInt8
    public let ringTimestamp: UInt32
    public let payload: [UInt8]
    public init(type: UInt8, ringTimestamp: UInt32, payload: [UInt8]) {
        self.type = type
        self.ringTimestamp = ringTimestamp
        self.payload = payload
    }

    /// Low 16 bits = the per-record counter. Per OURA_PROTOCOL.md s2.3.
    public var counter: UInt16 { UInt16(ringTimestamp & 0xFFFF) }
    /// High 16 bits = the session id. Per OURA_PROTOCOL.md s2.3.
    public var session: UInt16 { UInt16((ringTimestamp >> 16) & 0xFFFF) }

    /// Total wire length of this record = len + 2 (header byte + len byte). Per OURA_PROTOCOL.md s2.3.
    public var totalLength: Int { payload.count + 4 + 2 }
}

public extension OuraFraming {
    /// The minimum legal TLV `len` field: it must cover the 4 timestamp bytes. Per OURA_PROTOCOL.md s2.3.
    static let minRecordLen = 4

    /// Parse ONE TLV inner record from a single BLE notification, the open_oura way (protocol.rs
    /// `Packet::parse`): read `type`/`len` from the first two bytes, then take the payload LENIENTLY —
    /// exactly `len - 4` payload bytes when the notification carries them, otherwise whatever payload
    /// bytes are present (`frame.get(2..2+len).unwrap_or(frame[2..])`). The `len` field is NOT required
    /// to equal the notification length; open_oura tolerates that disagreement, and honoring it is what
    /// keeps NOOP from (a) minting phantom records out of a "too-small" len's leftover bytes or (b)
    /// swallowing the next notification on a "too-big" len. Returns nil only when the 4 timestamp bytes
    /// are not even present (`count < 6`) or `len < 4` (a record must cover its timestamp) — a genuinely
    /// unusable frame, never a guess (honest-data invariant). Per OURA_PROTOCOL.md s2.3.
    static func parseRecord(_ bytes: [UInt8]) -> OuraRecord? {
        guard bytes.count >= 6 else { return nil }   // 2 header + 4 timestamp bytes, the record floor
        let type = bytes[0]
        let len = Int(bytes[1])
        guard len >= minRecordLen else { return nil }
        // ringTimestamp is the 4 bytes at offset 2 as a u32 LE (counter low, session high).
        let rt = UInt32(bytes[2])
            | (UInt32(bytes[3]) << 8)
            | (UInt32(bytes[4]) << 16)
            | (UInt32(bytes[5]) << 24)
        // Lenient payload: min(declared end, notification end). Trailing bytes beyond `len` (BLE padding
        // / a following packet the ring did not pack for us) are ignored; a truncated payload uses what
        // arrived. Never reaches past the notification, never waits for a next one.
        let end = min(2 + len, bytes.count)
        let payload = end > 6 ? Array(bytes[6..<end]) : []
        return OuraRecord(type: type, ringTimestamp: rt, payload: payload)
    }

    /// The records of a notification that tiles EXACTLY into consecutive `tag | len | payload` packets —
    /// every packet with `len >= minRecordLen`, every declared end inside the value, and the last one
    /// ending on the value's last byte — or nil when it does not. This is the strict counterpart of the
    /// lenient single-packet `parseRecord` above: it never clamps, never guesses, and a value that fails
    /// the tiling at any packet is rejected whole (the caller then falls back to the one lenient packet).
    /// Byte-identical twin of Kotlin `OuraFraming.tiledRecords`.
    static func tiledRecords(_ bytes: [UInt8]) -> [OuraRecord]? {
        var out: [OuraRecord] = []
        var i = 0
        while i < bytes.count {
            guard i + 2 <= bytes.count else { return nil }
            let len = Int(bytes[i + 1])
            let end = i + 2 + len
            guard len >= minRecordLen, end <= bytes.count,
                  let rec = parseRecord(Array(bytes[i..<end])) else { return nil }
            out.append(rec)
            i = end
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Notification → record (open_oura one-packet-per-notification model)

/// Turn each BLE notification into its TLV inner record(s): ONE lenient packet per notification, matching
/// open_oura's `Packet::parse` (protocol.rs), with NO cross-notification buffering and NO byte-drop
/// "resync" — plus the one case the ring has been seen to send that the one-packet model loses: a
/// notification that tiles EXACTLY into several complete packets. `get_events` streams events as
/// separate ≤ 20-byte notifications on every NOOP session captured, then a `0x11` summary reporting
/// `events_received` (OURA_PROTOCOL.md s5.2); records are never split across notifications. But the same
/// ring, serving the official app on the same link with the same MTU and the same get_events bytes,
/// packs ~10 packets per 196–200-byte notification (2026-09-15: 38,136 packets in 3,613 notifications,
/// every value tiling exactly). What flips the ring between the two modes is not yet known; what is
/// known is that reading one packet from a packed value drops nine.
///
/// HISTORY (why this replaced a buffering reassembler): the old design accumulated bytes across feeds
/// and looped extracting `2+len` records. Whenever a packet's `len` disagreed with the notification
/// length — which open_oura explicitly tolerates — a too-small `len` made the loop mint phantom records
/// from the leftover bytes (aliased `0x42`/`0x85`/`0x57`/`0x70` tags → the reject/drop storm), and a
/// too-big `len` made it wait and swallow the following notification. Parsing exactly one lenient packet
/// per notification removes both failure modes at the source — and the packed walk keeps them removed:
/// it runs only when every packet's declared length lands exactly on the next tag and the last one on the
/// value's final byte, so a lone packet with a disagreeing `len` is still read as that one packet.
///
/// The type name and `feed`/`reset` API are kept so the driver call sites are unchanged; there is simply
/// no longer any state to carry. Platform-pure, value types only.
public final class OuraReassembler {
    public init() {}

    /// Parse one notification value into at most one record (open_oura `Packet::parse`, lenient). Returns
    /// `[]` when the notification is not a usable TLV record (too short, or `len < 4`). Never buffers,
    /// never spans, never resyncs — a garbled notification is dropped whole, not walked byte-by-byte.
    public func feed(_ fragment: [UInt8]) -> [OuraRecord] {
        guard let rec = OuraFraming.parseRecord(fragment) else { return [] }
        // A PACKED notification carries several complete packets back to back. The ring does this on
        // some sessions and not others: every NOOP drain captured to date arrives one packet per
        // ≤ 20-byte notification, but the same ring serving the official app on the same link (same
        // MTU 203, same get_events bytes) packs ~10 packets into each 196–200-byte notification —
        // 38,136 packets in 3,613 notifications on 2026-09-15, every one tiling the value exactly, and
        // the one-packet read above kept 3,613 of them. Walk the packets ONLY when the whole value tiles
        // into two or more well-formed ones; anything else is the single lenient packet, byte-identical
        // to before. That keeps the phantom-storm guarantee: a lone packet whose `len` disagrees with
        // the notification length still yields exactly that packet unless its tail happens to tile
        // into whole packets ending on the last byte — which no value in 40,696 captured notifications
        // does.
        if let packed = OuraFraming.tiledRecords(fragment), packed.count >= 2 { return packed }
        return [rec]
    }

    /// No-op retained for call-site compatibility (disconnect teardown). There is no buffered state to
    /// clear in the one-packet-per-notification model, so a half-record can never bleed across sessions.
    public func reset() {}

    /// Always 0: no bytes are ever buffered between notifications (observability only).
    public var bufferedByteCount: Int { 0 }
}
