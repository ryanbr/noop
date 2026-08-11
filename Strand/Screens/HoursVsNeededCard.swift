import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Hours vs Needed (#today-hosted-cards)
//
// The Sleep tab surfaces "Hours vs Needed" only as a StatTile inside the Night-detail metric grid — there
// is no standalone renderer for it. This card gives that single metric its own hostable view so it can be
// surfaced in the Today tab on its own. Both the Sleep tab tile and this hosted card read the SAME
// `SleepModel.hoursVsNeeded` metric (latest / typical / series), so the number, the vs-typical caption and
// the sparkline can never diverge between the two surfaces (the parity contract). The tile presentation
// (value / caption / accent / sparkline) is a verbatim lift of the `NightDetailCard` "Hours vs Needed"
// tile, so the hosted card reads byte-identically to the Sleep-tab tile.

/// The "Hours vs Needed" card. Renders the wearer's latest hours-vs-needed percentage against their
/// personal typical from the shared [SleepModel], as a single full-width StatTile with its sparkline and
/// vs-typical caption — the same presentation the Night-detail grid uses for this metric.
struct HoursVsNeededCard: View {
    let model: SleepModel

    var body: some View {
        // The metric (latest %, typical mean, history series) is computed ONCE in the model build and
        // read here — the same memoized result the Night-detail grid reads for its tile.
        let need = model.hoursVsNeeded

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Hours vs Needed", overline: "Sleep")
            // Verbatim of the NightDetailCard "Hours vs Needed" tile so the hosted value matches the
            // Sleep-tab tile exactly; stretched to the card's full width as a single-metric summary.
            StatTile(
                label: "Hours vs Needed",
                value: pctValue(need.latest),
                caption: vsTypical(need.latest, need.typical, suffix: "%"),
                accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                sparkline: spark(need.series),
                sparkColor: StrandPalette.restColor)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Tile formatting (verbatim lift of the NightDetailCard "Hours vs Needed" tile helpers)

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
