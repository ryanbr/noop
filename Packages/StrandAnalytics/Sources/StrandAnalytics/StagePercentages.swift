/// Largest-remainder ("Hamilton") apportionment of parts into whole percentages.
///
/// Rounding each part's share of the whole on its own — `round(part / total * 100)` — does NOT preserve
/// the sum: four stages of one night land on 99 or 101 as often as 100, and two views that each round
/// independently can disagree on the same part. This apportions ONCE: floor every share, then hand the
/// leftover whole-percent units to the parts with the largest fractional remainders, so the results sum
/// to exactly 100. Every call site reads the one result, so they agree with each other and add up.
///
/// Kotlin twin: `com.noop.analytics.StagePercentages.wholePercentages` — byte-identical, including the
/// leftover tie-break (larger remainder first, then lower index), so both platforms return the same ints.
public enum StagePercentages {

    /// `parts` are raw non-negative magnitudes (e.g. stage minutes) in a FIXED order; the returned whole
    /// percentages line up with them and sum to exactly 100. Returns nil when the total is <= 0 — there is
    /// nothing to apportion, and the caller should show no share rather than a `0%` it never measured.
    public static func wholePercentages(_ parts: [Double]) -> [Int]? {
        let clamped = parts.map { Swift.max(0, $0) }
        let total = clamped.reduce(0, +)
        guard total > 0 else { return nil }

        let raw = clamped.map { $0 / total * 100 }
        var whole = raw.map { Int($0.rounded(.down)) }
        var remaining = 100 - whole.reduce(0, +)   // the fractional units the floors dropped; in 0..<count
        guard remaining > 0 else { return whole }

        // Largest fractional remainder first; ties broken by lower index so the twin can match exactly.
        let order = raw.indices.sorted { i, j in
            let fi = raw[i] - Double(whole[i])
            let fj = raw[j] - Double(whole[j])
            if fi != fj { return fi > fj }
            return i < j
        }
        var k = 0
        while remaining > 0 && k < order.count {
            whole[order[k]] += 1
            remaining -= 1
            k += 1
        }
        return whole
    }
}
