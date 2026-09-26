import WhoopProtocol

/// Reconcile a missing WRIST_ON event without declaring an unobserved tail worn.
/// Only the unpaired OFF tail uses this evidence; explicit OFF/ON intervals stay authoritative.
/// The 30...220 bpm range matches AnalyticsEngine's existing worn-HR gate. Five minutes with
/// no gap over five seconds rejects isolated pulses and sparse streams. The returned boundary is
/// the first observed sample of that confirmed run, never the OFF timestamp or a fabricated event.
/// This is event reconciliation, not a sleep classifier; all sleep and HR-gap gates still run.
public enum WristWearRecovery {
    public static let confirmationSeconds = 5 * 60
    public static let maximumGapSeconds = 5

    public static func firstSustainedHR(_ hr: [HRSample], after: Int, before: Int) -> Int? {
        // Collapse duplicate timestamps conservatively: an invalid observation wins a conflict.
        var validByTimestamp: [Int: Bool] = [:]
        for sample in hr where sample.ts > after && sample.ts < before {
            validByTimestamp[sample.ts] = (validByTimestamp[sample.ts] ?? true)
                && (30...220).contains(sample.bpm)
        }
        var start: Int?
        var previous: Int?
        for ts in validByTimestamp.keys.sorted() {
            guard validByTimestamp[ts] == true else {
                start = nil; previous = nil
                continue
            }
            if previous == nil || ts - previous! > maximumGapSeconds { start = ts }
            previous = ts
            if let start, ts - start >= confirmationSeconds { return start }
        }
        return nil
    }
}
