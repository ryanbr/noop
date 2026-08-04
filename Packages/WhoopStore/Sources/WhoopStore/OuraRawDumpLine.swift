import Foundation

/// Pure, deterministic encoder for ONE line of the Oura RAW capture — a diagnostic JSONL sidecar holding
/// the UNDECODED TLV-record bytes exactly as received, NOT a datastore row. Complement to the decoded
/// sidecars (`OuraActivityDumpLine` = MET values, `OuraIbiHrDumpLine` = HR from IBIs): those are what NOOP
/// *interpreted*; this is what the ring actually *sent*.
///
/// WHY a raw file too: the decoded sidecars can only show what we successfully decoded, so a hole in them is
/// ambiguous — did the ring not send those records, or did we drop/fail to decode them? This capture removes
/// the ambiguity: reframe it OFFLINE (walk `2+len` TLV records, read the tag + ring-time) and a window that is
/// empty in the decoded file but present here is a DECODE drop; absent in both is RING-SIDE. It also preserves
/// tags NOOP does not decode yet (superset of the `0x71` fixture log). Never scored, safe to delete.
///
/// SCOPE: the HISTORY-drain record path only (the tap sits where TLV notifications are fed to the driver,
/// NOT the high-frequency live-HR push), so a night stays bounded. Auth/secure frames are handled+consumed
/// before the tap, so no challenge/response crypto lands here — only DATA records.
///
/// FORMAT: newline-delimited JSON, one received TLV notification per line, hand-built in FIXED key order so
/// it is byte-stable + testable. `hex` is the notification's raw bytes as contiguous lowercase hex.
public enum OuraRawDumpLine {
    /// Bump when the record shape changes so a downstream reader can branch on `schema`.
    public static let schema = 1

    /// One JSONL record (NO trailing newline — the writer adds it). `deviceId`/`iso` are app-generated, so
    /// neither needs JSON string-escaping here.
    ///   - utc:   the wall-clock arrival time (unix seconds) of the notification.
    ///   - iso:   human-readable UTC of `utc`.
    ///   - bytes: the raw TLV notification bytes, hex-encoded verbatim (one or more packed `2+len` records).
    public static func encode(deviceId: String, utc: Int, iso: String, bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"utc\":\(utc),"
             + "\"iso\":\"\(iso)\",\"hex\":\"\(hex)\"}"
    }
}
