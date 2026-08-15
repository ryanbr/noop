import Foundation

/// Pure, deterministic encoder for ONE line of the Oura real_steps_features (0x7E/0x7F) research corpus
/// — a diagnostic JSONL sidecar, NOT a datastore row.
///
/// WHY a sidecar and not a stream/table: the decode is Tier-B (a cited third-party unpack formula,
/// [oura-rs], not ground-truth-validated against a known step count — OURA_PROTOCOL.md s6.13). The
/// honest-data invariant forbids Tier-B ever minting a durable scoring row, so it must never touch
/// `Streams`/SQLite. This corpus is a separate, clearly-labeled file the app appends to as a
/// **movement-feature** record — the step-count question is CLOSED (ground truth: no field is a count,
/// they are the inputs to Oura's step model), so nothing here may ever be turned into steps. It never
/// feeds scoring and is safe to delete. Parallels `OuraActivityDumpLine` / `OuraCvaPpgDumpLine`.
public enum OuraRealStepsDumpLine {
    /// Bump when the record shape changes so a downstream reader can branch on `schema`.
    public static let schema = 1

    /// One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
    /// (e.g. `oura-<serial>`) and `iso`/`tag` are app-generated, so none need JSON string-escaping here.
    ///   - tag:    "0x7e" or "0x7f" (which half of the paired record this is).
    ///   - ringTs: the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
    ///   - utc:    the anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:    human-readable UTC of `utc` (convenience for eyeballing).
    ///   - fields: the 14 decoded fields this ONE record contributed, verbatim, in the source's own order.
    public static func encode(deviceId: String, tag: String, ringTs: UInt32, utc: Int, iso: String,
                              fields: [Int]) -> String {
        let fieldsStr = fields.map { String($0) }.joined(separator: ",")
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"tag\":\"\(tag)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"fields\":[\(fieldsStr)]}"
    }
}
