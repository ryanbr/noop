import Foundation

/// Classification of a METADATA frame (packet type 49) for the historical-offload state machine.
public enum HistoricalMeta: Equatable {
    case start
    case end(unix: UInt32, trim: UInt32)
    case complete
    case other
}

/// Classify a parsed METADATA frame into the four cases the Backfiller needs.
///
/// Field mapping (verified against whoop_protocol.json + Schema.swift + PostHooks.swift):
/// - `p.parsed["meta_type"]` → `.string("HISTORY_START(1)"|"HISTORY_END(2)"|"HISTORY_COMPLETE(3)")`
///   Schema.enumName() appends "(rawValue)" to every enum lookup, so the strings have the form
///   "NAME(N)". We match by checking `hasPrefix` to be robust against raw-value changes.
///   (byte offset 6, u8, MetadataType enum, cat="meta" → stored in parsed dict by FieldBuilder)
/// - For HISTORY_END the metadata post-hook additionally stores in p.parsed:
///   `"unix"` → `.int(unix_seconds)` and `"trim_cursor"` → `.int(trim_value)`
public func classifyHistoricalMeta(_ p: ParsedFrame) -> HistoricalMeta {
    // Integrity gate: only act on an INTACT frame. `ok` is now the verifier's FULL verdict — header
    // checksum, payload CRC32 and the structural length together — which is the part that matters
    // here: a forged HISTORY_END/HISTORY_COMPLETE whose payload CRC32 is right but whose header
    // checksum or declared length is not used to reach this classifier, and acting on one advances the
    // trim cursor, which acks the strap to discard data we never durably stored.
    //
    // The `crcOK` half of the old two-step check is now redundant for every freshly parsed frame and is
    // kept only for parse results handed in from elsewhere — a `ParsedFrame` decoded from a capture
    // written before the verdict widened carries the old constant `ok: true` beside a false `crcOK`.
    guard p.ok, p.crcOK != false else { return .other }
    guard p.typeName == "METADATA" else { return .other }
    guard case .string(let metaName)? = p.parsed["meta_type"] else { return .other }
    // Schema.enumName() produces "NAME(rawValue)" — match by prefix so the classifier is
    // insulated from raw-value changes.
    if metaName.hasPrefix("HISTORY_START") {
        return .start
    } else if metaName.hasPrefix("HISTORY_COMPLETE") {
        return .complete
    } else if metaName.hasPrefix("HISTORY_END") {
        guard case .int(let unix)? = p.parsed["unix"],
              case .int(let trim)? = p.parsed["trim_cursor"]
        else { return .other }
        return .end(unix: UInt32(truncatingIfNeeded: unix), trim: UInt32(truncatingIfNeeded: trim))
    } else {
        return .other
    }
}
