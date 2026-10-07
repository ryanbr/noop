import Foundation

// ActivityRecordTiming: place a 0x50 activity_info record's MET samples on the clock.
//
// A 0x50 record carries N MET samples and ONE ring timestamp, and that timestamp is the END of the
// record's LAST sample — not the start of its first. Fitted against Oura's own per-minute export,
// every record length N matched best at exactly −N epochs: reading forward from the timestamp gives
// 23 % exact minute matches (r 0.57), reading back from it gives 85 % (r 0.90). So sample i starts at
// `endUtc − (N − i) × epoch`, and the record's samples span `endUtc − N × epoch ..< endUtc`.
//
// This lived inline in both BLE callbacks, which no test can reach: the arithmetic is one expression,
// but it is the expression that decides which DAY a minute lands on, so a record straddling local
// midnight splits correctly only if both platforms agree to the second. Hoisted here so the rule is
// stated once per platform and pinned by a shared fixture.
//
// Platform-pure, database-free, value types only (builds on Linux). Facts per OURA_PROTOCOL.md s6.13.

/// Where a 0x50 activity record's samples sit on the UTC clock.
///
/// The ring reports one timestamp per record and it marks the END of the last sample, so the whole
/// series is addressed backwards from it. Callers hand in the anchored UTC seconds for the record (the
/// `0x13`/`0x42` session anchor has already been applied) and get back one start time per sample, in
/// record order.
public enum OuraActivityRecordTiming {
    /// Start time (UTC seconds) of sample `index` in a record of `sampleCount` samples whose timestamp
    /// is `endUtc`. `index` is zero-based in record order, so the LAST sample (`sampleCount - 1`)
    /// starts one epoch before `endUtc` and the first starts `sampleCount` epochs before it.
    ///
    /// No clamping and no validation: a caller passing a non-positive `epochSeconds` or an out-of-range
    /// `index` gets the arithmetic it asked for. The guard belongs at the call site, which knows whether
    /// the record was anchored at all — see `sampleStarts`, which rejects the degenerate shapes.
    ///
    /// Byte-parity twin of Kotlin `OuraActivityRecordTiming.sampleStart`.
    public static func sampleStart(endUtc: Int, sampleCount: Int, index: Int, epochSeconds: Int) -> Int {
        endUtc - (sampleCount - index) * epochSeconds
    }

    /// Start times for every sample in the record, in record order (ascending, one `epochSeconds` apart).
    ///
    /// Empty when the record carries no samples or `epochSeconds` is not positive — both mean "there is
    /// nothing to place on the clock", and returning empty keeps the decision here instead of leaving
    /// each call site to remember it. The first element is `endUtc - sampleCount * epochSeconds`; the
    /// last is `endUtc - epochSeconds`. `endUtc` itself is never a sample start: it is the exclusive end
    /// of the record's span.
    ///
    /// Byte-parity twin of Kotlin `OuraActivityRecordTiming.sampleStarts`.
    public static func sampleStarts(endUtc: Int, sampleCount: Int, epochSeconds: Int) -> [Int] {
        guard sampleCount > 0, epochSeconds > 0 else { return [] }
        return (0..<sampleCount).map {
            sampleStart(endUtc: endUtc, sampleCount: sampleCount, index: $0, epochSeconds: epochSeconds)
        }
    }

}
