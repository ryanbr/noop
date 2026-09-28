import Foundation

/// Pure, deterministic encoder for ONE line of the Oura activity (0x50 MET) research corpus — a
/// diagnostic JSONL sidecar, NOT a datastore row.
///
/// WHY a sidecar and not a stream/table: the 0x50 activity/MET decode is Tier-B (a plausible third-party
/// formula, day-scale validated but not per-minute exact — OURA_PROTOCOL.md s6.13). The honest-data invariant + the #960
/// pin forbid Tier-B ever minting a durable scoring row, so it must never touch `Streams`/SQLite. This
/// corpus is a separate, clearly-labeled file the app appends to purely so the raw MET series can be
/// accumulated for offline investigation (cadence, state-byte semantics, WHOOP cross-checks). It never
/// feeds scoring and is safe to delete.
///
/// FORMAT: newline-delimited JSON (JSONL) — one record per line, append-only. Chosen over a single JSON
/// array because appends never rewrite the file, a torn write loses only the last line, and every line
/// loads directly into pandas/`jq`/DuckDB. The line is hand-built in a FIXED key order so it is stable and
/// testable byte-for-byte; `met` uses Swift's shortest round-trip `Double` description (lossless, compact).
public enum OuraActivityDumpLine {
    /// Bump when the record shape changes so a downstream reader can branch on `schema`.
    public static let schema = 1

    /// One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
    /// (e.g. `oura-<uuid>`) and `iso` is app-generated, so neither needs JSON string-escaping here.
    ///   - ringTs:       the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
    ///   - utc:          the anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:          human-readable UTC of `utc` (convenience for eyeballing).
    ///   - state:        the raw 0x50 state byte (semantics unconfirmed — captured verbatim for study).
    ///   - secPerSample: the ASSUMED per-sample cadence (60 s); downstream can recompute real spacing from
    ///                   consecutive `utc` deltas.
    ///   - met:          the decoded per-sample MET series (Tier-B formula output, verbatim).
    public static func encode(deviceId: String, ringTs: UInt32, utc: Int, iso: String,
                              state: Int, secPerSample: Int, met: [Double]) -> String {
        let metStr = met.map { String($0) }.joined(separator: ",")
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"state\":\(state),"
             + "\"secPerSample\":\(secPerSample),\"met\":[\(metStr)]}"
    }
}
