import Foundation

/// One line summarising every day a scoring pass skipped for want of HR samples, replacing one line per
/// skipped day.
///
/// A pass walks a fixed recent window, so a day whose raw HR never arrived is re-read, re-skipped and
/// re-logged on every pass, forever. The strap banks days rather than weeks of raw HR while an import can
/// supply a much longer spine of daily rows, so the steady state for an importing user is a permanent
/// block of un-scoreable days. In one field capture that was 1262 lines - 21 days re-skipped across 63
/// passes in two hours, about a fifth of everything the log had to say.
///
/// That matters because the strap log is a fixed-size rolling buffer: noise does not merely annoy, it
/// evicts the older lines an investigation needs. Collapsing per pass keeps every fact - which days, and
/// each day's own HR count - while removing the repetition, so days are grouped by their sample count
/// and listed rather than summarised into a range that could hide a gap.
///
/// Returns `nil` when nothing was skipped, so a healthy pass stays silent. Kotlin twin:
/// `com.noop.analytics.skippedSleepDaysLine`.
public func skippedSleepDaysLine(_ skipped: [(day: String, hrSamples: Int)], minHrSamples: Int) -> String? {
    if skipped.isEmpty { return nil }
    var byCount: [Int: [String]] = [:]
    for entry in skipped { byCount[entry.hrSamples, default: []].append(entry.day) }
    let groups = byCount.keys.sorted().map { count -> String in
        let days = byCount[count]!.sorted()
        return "hrSamples=\(count) on \(days.count) day(s): \(days.joined(separator: ", "))"
    }
    return "sleep SKIPPED \(skipped.count) day(s) — need ≥\(minHrSamples) hrSamples: "
        + groups.joined(separator: "; ")
}
