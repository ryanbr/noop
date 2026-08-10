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
    /// Best-effort decoded packet type (`parseFrame(_:family:.whoop5)`), or nil if it didn't frame.
    public let typeName: String?
    /// Sequence byte — for historical records this doubles as the record *version*, so it matters.
    public let seq: Int?
    /// Did the family-aware (CRC16-Modbus header + CRC32 payload) check pass?
    public let crcOK: Bool?
    /// Did the frame parse as a well-formed puffin envelope at all?
    public let ok: Bool

    enum CodingKeys: String, CodingKey {
        case hex, char
        case tsMs = "ts_ms"
        case hr
        case typeName = "type_name"
        case seq
        case crcOK = "crc_ok"
        case ok
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
            typeName: parsed.ok ? parsed.typeName : nil,
            seq: parsed.seq,
            crcOK: parsed.crcOK,
            ok: parsed.ok
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
