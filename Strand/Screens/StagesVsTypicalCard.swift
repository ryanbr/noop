import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Stages vs typical (#today-hosted-cards)
//
// The Sleep tab's "Stages vs typical" card, extracted into a standalone view so it can ALSO be hosted in
// the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so the
// per-stage last-night-vs-typical bars can never diverge between the two surfaces (the parity contract).
// The card body + its `stageRow` / `stageRowAccessibilityLabel` helpers are a verbatim lift of the former
// `SleepView.stagesVsTypical` (and its helpers); the per-stage typical means are computed once in
// `SleepModel.build` and read here.

/// The "Stages vs typical" card. Renders last night's Deep/REM/Light against the wearer's personal
/// per-stage means from the shared [SleepModel].
struct StagesVsTypicalCard: View {
    let model: SleepModel

    var body: some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    stageRow(stage: String(localized: "Deep"),  last: s.deep,  typical: model.typicalDeepMin,  nightTotal: s.total, color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: String(localized: "REM"),   last: s.rem,   typical: model.typicalRemMin,   nightTotal: s.total, color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: String(localized: "Light"), last: s.light, typical: model.typicalLightMin, nightTotal: s.total, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage row, WHOOP sleep-detail style: a colour swatch + UPPERCASE stage + the share-of-night %
    /// (in the stage colour), then a bar that reads "solid = you, hatch = the context" — a diagonal-hatch
    /// track spanning the TYPICAL (the personal mean for this stage) with the user's last-night value as a
    /// solid coloured fill on top, plus a thin marker at the typical mean and the right-aligned duration.
    /// Same data as before (`last` minutes, `typical` personal mean) — the hatch just renders the typical
    /// context the prior vertical-only marker implied.
    @ViewBuilder
    private func stageRow(stage label: String, last: Double, typical: Double?, nightTotal: Double, color: Color) -> some View {
        // Scale both values against a shared per-row max so the typical hatch + marker are meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        // Share of the night this stage took (drives the WHOOP coloured %); over time-in-bed, matching the
        // stage-breakdown rows above.
        let sharePct = nightTotal > 0 ? Int((last / nightTotal * 100).rounded()) : 0
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return String(localized: "\(sign)\(durationText(abs(diff))) vs typ")
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(sharePct)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(color)
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Last-night value as the signature liquid tube — "solid = you", now a filling liquid
                    // capsule tinted in the stage colour (static/posed, like Today's grid tubes). It renders
                    // its own dark capsule track, so it replaces the flat solid fill + track. The fraction
                    // is unchanged (last / shared per-row max).
                    LiquidTube(frac: min(1, last / max), tint: color, height: 12, animated: false)
                    // Typical-range CONTEXT overlaid on top: a diagonal-hatch track spanning the personal
                    // mean for this stage. "Hatch = the context" — the liquid value sits under it.
                    if let typical, typical > 0 {
                        DiagonalHatch(spacing: 5, lineWidth: 1)
                            .stroke(color.opacity(0.6), lineWidth: 1)
                            .frame(width: w * CGFloat(min(1, typical / max)))
                            .clipShape(Capsule(style: .continuous))
                    }
                    // Crisp typical-mean marker so the exact mean still reads at a glance.
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 18)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 6)
                    }
                }
            }
            .frame(height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stageRowAccessibilityLabel(label: label, last: last, sharePct: sharePct, typical: typical))
        }
    }

    /// Whole-string VoiceOver label for a stage row: one key per variant, never a stitched tail fragment.
    private func stageRowAccessibilityLabel(label: String, last: Double, sharePct: Int, typical: Double?) -> String {
        if let typical, typical > 0 {
            return String(localized: "\(label): \(durationText(last)) last night, \(sharePct) percent of the night, typical \(durationText(typical))")
        }
        return String(localized: "\(label): \(durationText(last)) last night, \(sharePct) percent of the night")
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`). Kept local to the card so it renders
    /// identically whether hosted in Today or shown in the Sleep tab.
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

/// 45° diagonal-hatch fill used by the stage rows' "typical" context track (verbatim of the former
/// file-private `SleepView.DiagonalHatch` — moved here with its only caller). The public
/// `StrandDesign.DiagonalHatch` has no `lineWidth`, so this local shape is kept to preserve byte-identical
/// rendering.
private struct DiagonalHatch: Shape {
    var spacing: CGFloat = 5
    var lineWidth: CGFloat = 1
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start well before the left edge so the 45° lines fully cover the rect after the diagonal shear.
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return p
    }
}
