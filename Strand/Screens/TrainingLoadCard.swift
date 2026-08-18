import Foundation
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Training Load card (CTL / ATL / TSB)
//
// The first UI surface for the long-horizon training-load model (TrainingLoadEngine, added with the
// paired `ReadinessEngine.evaluateWithTrainingLoad`). It overlays chronic load (CTL, the 42-day
// fitness proxy) and acute load (ATL, the 7-day fatigue proxy); the gap between the two lines IS the
// TSB / "form" (CTL − ATL), surfaced as the headline number and a footer stat.
//
// Descriptive only: CTL/ATL/TSB never feed the Readiness level or any score, and the loads are NOOP's
// daily Effort/strain — NOT TRIMP. Long-horizon by nature, so the card models the full history rather
// than the Trends range window (14+ contiguous days are needed before anything is drawn).
//
// Isolated in its own file on purpose: TrendsView already sits near the iOS type-check budget, so this
// keeps its own inference cost out of that body.
struct TrainingLoadCard: View {
    let days: [DailyMetric]

    // yyyy-MM-dd → Date (en_US_POSIX, UTC) — same keying TrendsView uses so the x-axis matches.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private struct Row: Identifiable {
        let date: Date
        let ctl: Double
        let atl: Double
        var id: Date { date }
    }

    /// One modelled point per day of the contiguous suffix the engine returned.
    private var rows: [Row] {
        result.points.compactMap { p in
            guard let d = Self.dayParser.date(from: p.day) else { return nil }
            return Row(date: d, ctl: p.chronicLoad, atl: p.acuteLoad)
        }
    }

    /// Model straight from the training-load engine — NOT the paired `evaluateWithTrainingLoad`, which
    /// would also run the full Readiness synthesis this card never uses. `DailyMetric.strain` is the load.
    private var result: TrainingLoadEngine.Result {
        let loads = days.map { TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain) }
        return TrainingLoadEngine.evaluate(days: loads)
    }

    private static let established = TrainingLoadEngine.Configuration.standard.establishedDays
    private static let minimum = TrainingLoadEngine.Configuration.standard.minimumDays

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
    private func signed(_ v: Double) -> String { String(format: "%+.1f", v) }

    var body: some View {
        let tl = result
        if !tl.isAvailable {
            unavailableCard(contiguousDays: tl.contiguousDays)
        } else {
            let latest = tl.points.last
            ChartCard(
                title: "Training Load",
                subtitle: subtitle(for: tl),
                trailing: latest.map { signed($0.balance) },
                height: NoopMetrics.chartHeight,
                chart: {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        legend
                        chart
                    }
                },
                footer: {
                    ChartFooter([
                        ("CTL", latest.map { fmt($0.chronicLoad) } ?? "—"),
                        ("ATL", latest.map { fmt($0.acuteLoad) } ?? "—"),
                        ("Form", latest.map { signed($0.balance) } ?? "—"),
                        ("Days", "\(tl.contiguousDays)"),
                    ])
                }
            )
        }
    }

    // Two overlaid lines: CTL (fitness) and ATL (fatigue). The vertical gap between them is the form.
    private var chart: some View {
        // Floor at 1 (matching the Android `fold(1.0)` twin): an all-rest window of zero loads would
        // otherwise make the y-domain `0...0`, which Swift Charts renders as a degenerate/empty scale.
        let maxY = max(rows.map { max($0.ctl, $0.atl) }.max() ?? 1, 1)
        return Chart {
            ForEach(rows) { r in
                LineMark(x: .value("Day", r.date), y: .value("CTL", r.ctl),
                         series: .value("Series", "CTL"))
                    .foregroundStyle(StrandPalette.gold)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(rows) { r in
                LineMark(x: .value("Day", r.date), y: .value("ATL", r.atl),
                         series: .value("Series", "ATL"))
                    .foregroundStyle(StrandPalette.strain100)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: 0...(maxY * 1.08))
        .chartYAxis { AxisMarks(position: .leading) }
        .accessibilityLabel(Text("Training load: chronic vs acute"))
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space2 * 2) {
            legendDot(color: StrandPalette.gold, label: "CTL · Fitness")
            legendDot(color: StrandPalette.strain100, label: "ATL · Fatigue")
            Spacer()
        }
    }

    private func legendDot(color: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func subtitle(for tl: TrainingLoadEngine.Result) -> String {
        switch tl.state {
        case .established:
            return String(localized: "42-day fitness vs 7-day fatigue")
        case .building:
            return String(localized: "Building — \(tl.contiguousDays) of \(Self.established) days")
        case .unavailable:
            return ""
        }
    }

    // Honest empty state: name exactly how many consecutive Effort days are still needed.
    private func unavailableCard(contiguousDays: Int) -> some View {
        ChartCard(
            title: "Training Load",
            subtitle: String(localized: "Chronic vs acute load"),
            chart: {
                VStack(spacing: NoopMetrics.space2) {
                    Text("Needs \(Self.minimum)+ consecutive days of Effort to begin. \(contiguousDays) so far.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            },
            footer: { EmptyView() }
        )
    }
}
