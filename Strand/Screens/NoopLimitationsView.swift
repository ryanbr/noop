import SwiftUI
import StrandDesign

// MARK: - NoopLimitationsView — "what NOOP can (and can't) read off each strap"
//
// The iOS/macOS twin of Android's NoopLimitationsScreen: a plain tri-state capability grid reached from
// Settings, note-free, listing every metric NOOP surfaces and whether it comes live off a WHOOP 4.0 vs a
// 5.0/MG. Marks mirror the decoder/analytics truth (Interpreter / AnalyticsEngine / HistoricalStreams):
// full = read live; partial = an on-device estimate or an experimental / firmware-gated read; none = not
// off the strap (SpO₂ % is import-only on both; blood pressure has no path at all). A legend carries the
// meaning in place of per-row prose. Presented as a sheet, mirroring HowNoopWorksView / ScoringGuideView.

struct NoopLimitationsView: View {
    let onClose: () -> Void

    /// Tri-state support for a metric on a given strap — honest, never overstated.
    private enum LimitState {
        case full, partial, none

        /// SF Symbol glyph shown in the strap column.
        var glyph: String {
            switch self {
            case .full:    return "checkmark"
            case .partial: return "minus"
            case .none:    return "xmark"
            }
        }

        var tint: Color {
            switch self {
            case .full:    return StrandPalette.statusPositive
            case .partial: return StrandPalette.statusWarning
            case .none:    return StrandPalette.textTertiary
            }
        }

        /// Spoken label for the row's accessibility description.
        var spoken: String {
            switch self {
            case .full:    return String(localized: "yes")
            case .partial: return String(localized: "partly")
            case .none:    return String(localized: "no")
            }
        }
    }

    /// One row: a metric, and how it reads on a 4.0 vs a 5.0/MG. No note — the legend carries the meaning.
    private struct LimitRow: Identifiable {
        let feature: LocalizedStringKey
        let spokenFeature: String
        let whoop4: LimitState
        let whoop5: LimitState
        var id: String { spokenFeature }
    }

    private let rows: [LimitRow] = [
        LimitRow(feature: "Live heart rate", spokenFeature: "Live heart rate", whoop4: .full, whoop5: .full),
        LimitRow(feature: "HRV (rMSSD)", spokenFeature: "HRV", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Sleep staging", spokenFeature: "Sleep staging", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Recovery & strain", spokenFeature: "Recovery and strain", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Respiratory rate", spokenFeature: "Respiratory rate", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Stress (on-device)", spokenFeature: "Stress", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Workout detection", spokenFeature: "Workout detection", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Skin temperature", spokenFeature: "Skin temperature", whoop4: .partial, whoop5: .full),
        LimitRow(feature: "Steps", spokenFeature: "Steps", whoop4: .partial, whoop5: .full),
        LimitRow(feature: "Blood oxygen (SpO₂ %)", spokenFeature: "Blood oxygen", whoop4: .none, whoop5: .none),
        LimitRow(feature: "ECG", spokenFeature: "ECG", whoop4: .none, whoop5: .partial),
        LimitRow(feature: "Blood pressure", spokenFeature: "Blood pressure", whoop4: .none, whoop5: .none),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    tableCard
                    legendCard
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PER STRAP").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("NOOP Limitations").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("What each WHOOP can read")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Cards

    private var tableCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("WHAT NOOP READS").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                // Column header.
                HStack {
                    Text("Feature").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("4.0").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 52)
                    Text("5.0/MG").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 52)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 { Divider().overlay(StrandPalette.hairline) }
                    HStack {
                        Text(row.feature).font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        supportCell(row.whoop4)
                        supportCell(row.whoop5)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(a11yLabel(row))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legendCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("LEGEND").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                legendRow(.full, "Read live off the strap")
                legendRow(.partial, "On-device estimate, or experimental / firmware-gated")
                legendRow(.none, "Not from the strap. SpO₂ can be filled by importing a WHOOP or Health export.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendRow(_ state: LimitState, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            supportCell(state)
            Text(label).font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// VoiceOver line for one row, assembled at runtime from already-localized parts. A plain String (not a
    /// LocalizedStringKey), so it carries no catalog key of its own.
    private func a11yLabel(_ row: LimitRow) -> String {
        "\(row.spokenFeature): WHOOP 4.0 \(row.whoop4.spoken), 5.0/MG \(row.whoop5.spoken)"
    }

    private func supportCell(_ state: LimitState) -> some View {
        Image(systemName: state.glyph)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(state.tint)
            .frame(width: 52)
            .accessibilityHidden(true)
    }
}
