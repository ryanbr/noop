import Foundation
import WhoopStore

// The one read behind every outcome the two Insights screens rank, correlate and run experiments on.
// Both screens carried a private copy of it, and both copies read Rest from the IMPORTED series only:
// when they were written a strap had no on-device Rest, so there was nothing else to read. There has been
// one since v2.6.0, so a strap-only wearer saw a Rest score on Today and Trends and no Rest outcome here.
extension Repository {

    /// day → value for one Insights outcome `key` ("recovery" / "hrv" / "sleep_performance" / "rhr").
    ///
    /// Charge, HRV and RHR are the imported metricSeries with the merged daily column filling the days it
    /// doesn't cover, so an account-free user still gets effects. `mergedDays` is the caller's snapshot of
    /// `days`, passed in so every outcome in one load is read against the same rows.
    ///
    /// Rest goes through `resolvedSeries`: the import wins, else the on-device composite, else the composite
    /// derived from the day's banked totals. A night with no Rest is absent. This is the read Android's
    /// Insights uses (`insightsRestByDay`), so both platforms rank the same Rest nights.
    func insightsOutcomeDays(key: String, mergedDays: [DailyMetric]) async -> [String: Double] {
        if key == "sleep_performance" {
            let rest = await resolvedSeries(key: key, source: Self.whoopSource).values
            return Dictionary(rest.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        var byDay: [String: Double] = [:]
        for row in await series(key: key, source: Self.whoopSource) { byDay[row.day] = row.value }
        for d in mergedDays where byDay[d.day] == nil {
            if let v = Self.insightsDailyColumn(key: key, day: d) { byDay[d.day] = v }
        }
        return byDay
    }

    /// The merged DailyMetric column backing an Insights outcome, for days the imported metricSeries
    /// doesn't cover. Rest is not a column; see `insightsOutcomeDays`.
    private static func insightsDailyColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }
}
