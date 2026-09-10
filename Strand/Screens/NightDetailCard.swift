import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Night detail (#today-hosted-cards)
//
// The Sleep tab's "Night detail" metric grid, extracted into a standalone view so it can ALSO be hosted
// in the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so
// the per-metric latest value / sparkline / typical caption can never diverge between the two surfaces
// (the parity contract). The card body + its `pctValue` / `rrValue` / `vsTypical` / `debtCaption` /
// `debtColor` / `spark` helpers are a verbatim lift of the former `SleepView.metricGrid` (and the helpers
// only it used); the seven series are computed once in `SleepModel.build` and read here.

/// The "Night detail" card. A grid of UNIFORM fixed-height StatTiles (Rest, Efficiency, Consistency,
/// Hours vs Needed, Restorative, Respiratory, Sleep Debt), each with its sparkline + typical caption,
/// rendered from the shared [SleepModel].
struct NightDetailCard: View {
    let model: SleepModel

    private let tileColumns = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    var body: some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean.
        // All seven series are computed ONCE in the model build (each is a full pass over
        // repo.days/repo.sleeps) — here we only read the memoized results.
        let perf  = model.performance
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics")

            #if os(iOS)
            // On iOS, Sleep Debt is the actionable summary for the section, so it leads at the
            // full two-column width. The remaining six peer metrics keep the established 2 × 3 grid.
            StatTile(
                label: "Sleep Debt",
                value: debt.latest.map { durationText($0) } ?? "—",
                caption: nightDetailDebtCaption(debt.latest),
                accent: nightDetailDebtColor(debt.latest),
                sparkline: spark(debt.series),
                sparkColor: StrandPalette.metricRose)
                .frame(maxWidth: .infinity)
            #endif

            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

                StatTile(
                    label: "Rest",
                    value: pctValue(perf.latest),
                    caption: tileCaption(latestDay: perf.latestDay, latest: perf.latest,
                                         typical: perf.typical, suffix: "%"),
                    accent: perf.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(perf.series),
                    sparkColor: StrandPalette.restColor)

                StatTile(
                    label: "Efficiency",
                    value: pctValue(eff.latest),
                    caption: tileCaption(latestDay: eff.latestDay, latest: eff.latest,
                                         typical: eff.typical, suffix: "%"),
                    accent: StrandPalette.statusPositive,
                    sparkline: spark(eff.series),
                    sparkColor: StrandPalette.statusPositive)

                StatTile(
                    label: "Consistency",
                    value: pctValue(cons.latest),
                    caption: tileCaption(latestDay: cons.latestDay, latest: cons.latest,
                                         typical: cons.typical, suffix: "%"),
                    accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(cons.series),
                    sparkColor: StrandPalette.metricCyan)

                StatTile(
                    label: "Hours vs Needed",
                    value: pctValue(need.latest),
                    caption: tileCaption(latestDay: need.latestDay, latest: need.latest,
                                         typical: need.typical, suffix: "%"),
                    accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                    sparkline: spark(need.series),
                    sparkColor: StrandPalette.restColor)

                StatTile(
                    label: "Restorative",
                    value: pctValue(rest.latest),
                    caption: tileCaption(latestDay: rest.latestDay, latest: rest.latest,
                                         typical: rest.typical, suffix: "%"),
                    accent: StrandPalette.sleepREM,
                    sparkline: spark(rest.series),
                    sparkColor: StrandPalette.sleepREM)

                StatTile(
                    label: "Respiratory",
                    value: rrValue(resp.latest),
                    caption: tileCaption(latestDay: resp.latestDay, latest: resp.latest,
                                         typical: resp.typical, suffix: " rpm", decimals: 1),
                    accent: StrandPalette.metricPurple,
                    sparkline: spark(resp.series),
                    sparkColor: StrandPalette.metricPurple)

                #if !os(iOS)
                // macOS keeps the original adaptive dashboard instead of stretching one
                // phone-width summary tile across an unbounded desktop detail pane.
                StatTile(
                    label: "Sleep Debt",
                    value: debt.latest.map { durationText($0) } ?? "—",
                    caption: nightDetailDebtCaption(debt.latest),
                    accent: nightDetailDebtColor(debt.latest),
                    sparkline: spark(debt.series),
                    sparkColor: StrandPalette.metricRose)
                #endif
            }
        }
    }

    // MARK: - Tile formatting (verbatim lift of the metricGrid-only SleepView helpers)

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// #1946: a carried prior-day value is stamped "Carried · <date>" instead of "vs typical", so it
    /// is never passed off as tonight's read. Falls through to `vsTypical` when the value is today's
    /// own (or there is no value).
    private func tileCaption(latestDay: String?, latest: Double?, typical: Double?,
                             suffix: String, decimals: Int = 0) -> String {
        if let carried = SleepModel.carriedMetricCaption(latestDay: latestDay, latest: latest) {
            return carried
        }
        return vsTypical(latest, typical, suffix: suffix, decimals: decimals)
    }

    /// "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries.
    private func vsTypical(_ latest: Double?, _ typical: Double?, suffix: String, decimals: Int = 0) -> String {
        guard let latest, let typical, typical != 0 else { return String(localized: "vs typical - ") }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return String(localized: "\(sign)\(num)\(suffix) vs typical")
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`). Kept local to the card so it
    /// renders identically whether hosted in Today or shown in the Sleep tab.
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

func nightDetailDebtCaption(_ debt: Double?) -> String {
    guard let debt else { return String(localized: "vs need") }
    return debt < SleepDebt.onTargetBandMin ? String(localized: "On target") : String(localized: "Below need")
}

func nightDetailDebtColor(_ debt: Double?) -> Color {
    guard let debt else { return StrandPalette.textPrimary }
    switch debt {
    case ..<SleepDebt.onTargetBandMin: return StrandPalette.statusPositive
    case ..<60: return StrandPalette.statusWarning
    default: return StrandPalette.statusCritical
    }
}
