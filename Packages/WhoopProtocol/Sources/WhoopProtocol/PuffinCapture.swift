import Foundation

/// One captured WHOOP 5.0 / MG ("puffin") frame plus the provenance a protocol mapper needs to
/// correlate raw bytes against ground truth.
///
/// The `hex` key is intentionally the same shape the test fixtures use (`frames.json` is an array of
/// `{"hex": …}`), so a capture file is *directly* usable as a parity fixture — the extra fields are a
/// superset the decoder ignores. Keys are snake_case to match the existing `golden.json` style.
public struct PuffinCaptureRecord: Codable, Equatable, Sendable {
    /// Full on-wire frame as lowercase hex — the canonical `ParsedFrame.rawHex`.
    public let hex: String
    /// Source notify characteristic UUID (e.g. `fd4b0005-…`) — tells you which channel the frame
    /// arrived on, which is itself a clue to its meaning.
    public let char: String
    /// Capture wall-clock as unix milliseconds. Lets you line a frame up against a known event time.
    public let tsMs: Int
    /// Live heart rate from the *standard* `2A37` profile at capture time, when known. This is the
    /// ground-truth cross-check: find the byte that tracks this value to locate the puffin HR field.
    public let hr: Int?
    /// Best-effort decoded packet type (`parseFrame(_:family:.whoop5)`), or nil only when the bytes
    /// could not be read as a frame at all.
    ///
    /// A frame that FAILED its integrity check still carries its type here. That is the point of a
    /// capture: an unmapped or corrupted frame is precisely what a mapper wants to see, and blanking
    /// its type would throw away the one thing the decoder did learn. The verdict lives in `ok`, the
    /// cause in `rejectReason` — the record says what happened rather than going quiet.
    public let typeName: String?
    /// Sequence byte — for historical records this doubles as the record *version*, so it matters.
    public let seq: Int?
    /// Did the payload CRC32 verify? nil when it could not be computed at all.
    public let crcOK: Bool?
    /// The FULL integrity verdict: header checksum, payload CRC32 and structural length together.
    public let ok: Bool
    /// Why `ok` is false; `none` on an intact frame. Additive — older capture files that predate this
    /// key decode with `none`, so nothing that was readable before stops being readable.
    public let rejectReason: FrameRejectReason

    enum CodingKeys: String, CodingKey {
        case hex, char
        case tsMs = "ts_ms"
        case hr
        case typeName = "type_name"
        case seq
        case crcOK = "crc_ok"
        case ok
        case rejectReason = "reject_reason"
    }

    public init(hex: String, char: String, tsMs: Int, hr: Int?, typeName: String?, seq: Int?,
                crcOK: Bool?, ok: Bool, rejectReason: FrameRejectReason = .none) {
        self.hex = hex
        self.char = char
        self.tsMs = tsMs
        self.hr = hr
        self.typeName = typeName
        self.seq = seq
        self.crcOK = crcOK
        self.ok = ok
        self.rejectReason = rejectReason
    }

    /// Decoding tolerates a MISSING `reject_reason` and defaults it to `none`, so a capture file
    /// written before this key existed still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hex = try c.decode(String.self, forKey: .hex)
        char = try c.decode(String.self, forKey: .char)
        tsMs = try c.decode(Int.self, forKey: .tsMs)
        hr = try c.decodeIfPresent(Int.self, forKey: .hr)
        typeName = try c.decodeIfPresent(String.self, forKey: .typeName)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        crcOK = try c.decodeIfPresent(Bool.self, forKey: .crcOK)
        ok = try c.decode(Bool.self, forKey: .ok)
        rejectReason = try c.decodeIfPresent(FrameRejectReason.self, forKey: .rejectReason) ?? .none
    }
}

/// Accumulates captured puffin frames and serialises them in a fixture-compatible JSON shape.
///
/// Pure (no CoreBluetooth, no file IO) so it unit-tests in the `WhoopProtocol` package. The app's
/// `PuffinFrameRecorder` owns one of these, feeds it frames off `fd4b0003/0004/0005/0007`, and
/// persists `encodedJSON()` to disk.
public final class PuffinCapture {
    public private(set) var records: [PuffinCaptureRecord] = []

    public init() {}

    public var count: Int { records.count }

    public func reset() { records.removeAll() }

    /// Decode `frame` as a puffin envelope and append a record with the given provenance.
    /// The stored `hex` is the decoder's canonical `rawHex`, so it always round-trips through parsing.
    @discardableResult
    public func record(frame: [UInt8], char: String, tsMs: Int, hr: Int?) -> PuffinCaptureRecord {
        // D#969: rawHex is only built when collectFields is true; PuffinCapture is the one production
        // consumer that stores it, so opt in here (this diagnostic path is off by default anyway).
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        let rec = PuffinCaptureRecord(
            hex: parsed.rawHex,
            char: char,
            tsMs: tsMs,
            hr: hr,
            // PARSEABILITY, not integrity: a frame the verifier rejected keeps the packet type the
            // decoder read out of it. Only a byte run that produced no type at all records nil.
            typeName: parsed.isParsable ? parsed.typeName : nil,
            seq: parsed.seq,
            crcOK: parsed.crcOK,
            ok: parsed.ok,
            rejectReason: parsed.rejectReason
        )
        records.append(rec)
        return rec
    }

    /// The full capture (provenance + decode hints), pretty-printed with stable key order.
    public func encodedJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(records)
    }

    /// The `[{"hex": …}]` subset — byte-for-byte the shape `Tests/.../Resources/frames.json` expects,
    /// so a capture can be dropped straight into the parity suite.
    public func framesFixtureJSON() throws -> Data {
        struct HexOnly: Encodable { let hex: String }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(records.map { HexOnly(hex: $0.hex) })
    }
}
