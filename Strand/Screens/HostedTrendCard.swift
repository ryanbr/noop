import StrandDesign
import SwiftUI
import WhoopStore

/// Resolving a metric's trend points from banked days.
///
/// Extracted from `TrendsView` so the Today host cards resolve EXACTLY as the Trends tab does. It is
/// shared rather than copied on purpose: the widening fallback is the part a wearer with two weeks of
/// history actually depends on, and a second implementation of it would drift the moment either side
/// was tuned. `TrendsView.resolve` calls this too.
enum HostedTrendData {

    /// Day strings are banked as `yyyy-MM-dd` in UTC; parsing them any other way shifts every point.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The metric's points for the smallest window at or wider than `selected` that holds any data,
    /// and the window it settled on.
    ///
    /// Walks the widening order ONCE, keeping the window's points rather than re-filtering to read them
    /// back. Falls back to all history when no window held anything, which matches what the tab shows
    /// rather than leaving a new wearer with an empty card.
    static func resolve(days: [DailyMetric],
                        selected: TrendsView.Range,
                        value: (DailyMetric) -> Double?) -> (points: [TrendPoint], effective: TrendsView.Range) {
        for r in selected.widening {
            let pts = points(window(days, r), value)
            if !pts.isEmpty { return (pts, r) }
        }
        return (points(window(days, .all), value), .all)
    }

    /// The trailing window of `days`, anchored on today's local day exactly as the tab anchors it.
    private static func window(_ days: [DailyMetric], _ r: TrendsView.Range) -> [DailyMetric] {
        guard let n = r.days, n > 0 else { return days }
        let cutoff = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// The plotted y-range: the data's own span with a little air, the fixed fallback when there is no
    /// data at all, and a unit either side of a single repeated value so one flat line does not map onto
    /// a zero-width range.
    ///
    /// Shared with the tab for the same reason the windowing is. A card that padded by a different
    /// fraction would plot the SAME points at a visibly different height from the chart it mirrors,
    /// which is exactly the drift hosting is meant to avoid.
    static func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>,
                           pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private static func points(_ days: [DailyMetric], _ value: (DailyMetric) -> Double?) -> [TrendPoint] {
        days.compactMap { d in
            guard let v = value(d), let dt = dayParser.date(from: d.day) else { return nil }
            return TrendPoint(date: dt, value: v)
        }
    }
}

/// One Trends metric trend, rendered as a Today host card (#today-hosted-cards).
///
/// Draws the same `ChartCard` + `TrendChart` pair the Trends tab draws, from the same resolved points,
/// so the hosted copy cannot become a second chart of the same numbers.
///
/// What it does NOT carry is the range selector. A home-screen card has nowhere to put one and no place
/// to persist a per-card choice, so each takes a fixed trailing month and keeps the tab's widening
/// fallback for a wearer whose history is shorter than that. The Trends tab stays where the window is
/// chosen. Twin of the Kotlin `TrendHostCard`.
struct HostedTrendCard: View {
    let card: HostedCard
    let days: [DailyMetric]
    /// The wearer's Effort scale, resolved by the host rather than read here: only one of the three
    /// cards needs it, and Today already has it for its own tiles.
    let effortScale: EffortScale

    var body: some View {
        switch card {
        case .trendHRV:
            chart(title: "Heart rate variability", unit: "ms",
                  colour: StrandPalette.metricPurple, fallback: 20...120, value: { $0.avgHrv },
                  fmt: { "\(Int($0.rounded()))" })
        case .trendRestingHR:
            chart(title: "Resting heart rate", unit: "bpm",
                  colour: StrandPalette.metricRose, fallback: 40...90, value: { $0.restingHr.map(Double.init) },
                  fmt: { "\(Int($0.rounded()))" })
        case .trendEffort:
            // Plotted on the stored 0-100 axis so the line's shape is scale-independent; only the
            // printed numbers follow the Effort-scale toggle, converted inside `fmt`, exactly as the
            // Trends tab does it (#268).
            chart(title: "Effort", unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                  colour: StrandPalette.effortColor, fallback: 0...100, value: { $0.strain },
                  fmt: { UnitFormatter.effortDisplay($0, scale: effortScale) })
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func chart(title: LocalizedStringKey, unit: String, colour: Color,
                       fallback: ClosedRange<Double>,
                       value: @escaping (DailyMetric) -> Double?,
                       fmt: @escaping (Double) -> String) -> some View {
        let resolved = HostedTrendData.resolve(days: days, selected: .month, value: value)
        let pts = resolved.points
        let avg = pts.isEmpty ? nil : pts.map(\.value).reduce(0, +) / Double(pts.count)
        // The unit rides with the average. The Trends tab carries it in a footer of min/mean/max, which
        // a home-screen card has no room for, so without this the number would appear bare.
        let trailing = avg.map { "\(fmt($0)) \(unit)" }
        ChartCard(title: title, subtitle: nil, trailing: trailing,
                  height: NoopMetrics.chartHeight, tint: colour) {
            TrendChart(points: pts,
                       gradient: Gradient(colors: [colour.opacity(0.35), colour]),
                       valueRange: HostedTrendData.valueRange(pts, fallback: fallback),
                       showsArea: true,
                       // Hover OFF. The card sits inside a NavigationLink, so a scrubbing gesture here
                       // would compete with the tap that opens the metric — the same conflict that
                       // keeps the tap-to-log card out of the navigation map. The Trends tab keeps the
                       // scrub; the Today host mirrors only the display, as the hosted Stages card does.
                       showsHover: false)
        }
        .accessibilityElement(children: .combine)
        // The average goes into the spoken label, not just the visible corner. `children: .combine`
        // merges what the card renders, and overriding that with the bare title, as this first did,
        // silently drops the one number on the card: VoiceOver announced "Heart rate variability" and
        // nothing else. Composed rather than interpolated into a localized string, so it needs no new
        // catalog entry for what is a title the app already has plus a formatted value.
        .accessibilityLabel(trailing.map { Text(title) + Text(verbatim: ", \($0)") } ?? Text(title))
    }

}
