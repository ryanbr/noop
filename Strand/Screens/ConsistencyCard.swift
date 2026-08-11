import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Consistency (#today-hosted-cards)
//
// The Sleep tab surfaces "Consistency" only as a StatTile inside the Night-detail metric grid — there is
// no standalone renderer for it. This card gives that single metric its own hostable view so it can be
// surfaced in the Today tab on its own. Both the Sleep tab tile and this hosted card read the SAME
// `SleepModel.consistency` metric (latest / typical / series) — the bedtime-onset-spread score that also
// honours the imported-consistency preference and is byte-identical to Android's `consistencySeries` — so
// the number, the vs-typical caption and the sparkline can never diverge between the two surfaces (the
// parity contract). The tile presentation (value / caption / accent / sparkline) is a verbatim lift of the
// `NightDetailCard` "Consistency" tile, so the hosted card reads byte-identically to the Sleep-tab tile.

/// The "Consistency" card. Renders the wearer's latest sleep-consistency percentage against their personal
/// typical from the shared [SleepModel], as a single full-width StatTile with its sparkline and vs-typical
/// caption — the same presentation the Night-detail grid uses for this metric.
struct ConsistencyCard: View {
    let model: SleepModel

    var body: some View {
        // The metric (latest %, typical mean, history series) is computed ONCE in the model build and
        // read here — the same memoized result the Night-detail grid reads for its tile.
        let cons = model.consistency

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Consistency", overline: "Sleep")
            // Verbatim of the NightDetailCard "Consistency" tile so the hosted value matches the Sleep-tab
            // tile exactly; stretched to the card's full width as a single-metric summary.
            StatTile(
                label: "Consistency",
                value: pctValue(cons.latest),
                caption: vsTypical(cons.latest, cons.typical, suffix: "%"),
                accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                sparkline: spark(cons.series),
                sparkColor: StrandPalette.metricCyan)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Tile formatting (verbatim lift of the NightDetailCard "Consistency" tile helpers)

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// "+12% vs typical" — the latest-vs-mean caption the metric tile carries.
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
}
