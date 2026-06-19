import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - FusedRecordView — "Your Data, Fused" (v5 — Local Multi-Device Fusion)
//
// The read-only headline screen for the fusion pillar
// (docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §UX). For each core
// metric it shows the BEST-sourced value, a provenance pill naming the source, the plain published
// reason from MetricArbitrationPolicy ("counts directly" / "best stager"), and the inline agreement
// state from FusionResolver (agree / minor delta / conflict). When two sources disagree it offers a
// conflict-compare sheet that lists EVERY source's value side by side and which one NOOP is using and
// why — it NEVER silently merges or averages.
//
// SELF-CONTAINED: the view takes a fully-resolved `FusedRecord` via init (the Repository adapter that
// pulls today's per-source metrics and runs `FusionResolver.resolve` lives in Wave 3 — see
// `wiringNeeded`). It does no I/O and never touches AppModel/Repository directly, so it compiles and
// previews from a fixture. This file owns only PRESENTATION: a metric label, a value formatter, and
// the row/sheet chrome — all built from the locked component set (NoopCard / StatePill / SourceBadge /
// ScoreStatePill / SectionHeader) and tokens (StrandPalette / StrandFont / NoopMetrics).
//
// Wellness framing only: a source is "higher-trust for this metric" with a plain reason; we never say
// a number is accurate / correct / clinical, never flag a value as concerning. "Everything stays on
// this device."

// MARK: - Presentation model (the read-model this screen consumes)

/// One resolved metric row for the fused record — the engine's `FusedMetricPoint` plus the display
/// label + unit this screen needs to render it. The Wave 3 Repository adapter builds these from the
/// rows it already loads (it owns the metric→label/unit mapping there, or reuses this one).
public struct FusedRow: Identifiable, Equatable {
    public let point: FusedMetricPoint
    /// Human label for the metric ("Resting HR", "Steps", "Sleep").
    public let label: String
    /// Optional accent colour world for the row's value (per-metric tint), defaulted to primary text.
    public let accentHex: String?

    public var id: String { point.metric }

    public init(point: FusedMetricPoint, label: String, accentHex: String? = nil) {
        self.point = point
        self.label = label
        self.accentHex = accentHex
    }
}

/// The whole fused day-record this screen renders. Built by the Wave 3 Repository adapter; passed in
/// via init so the view stays pure and previewable.
public struct FusedRecord: Equatable {
    /// The resolved rows, in display order (importance-first, per the hub rule).
    public let rows: [FusedRow]
    /// The device that OWNS the day's scores (from `DayOwnerResolver`) — shown as the day badge so the
    /// scores' single-owner invariant stays honest. Nil when no scored owner exists yet.
    public let dayOwner: FusionSource?
    /// How many distinct sources contributed across the whole record. Drives the single-source
    /// degradation: when ≤ 1 the screen shows a plain record with no provenance noise.
    public let contributingSourceCount: Int

    public init(rows: [FusedRow], dayOwner: FusionSource?, contributingSourceCount: Int) {
        self.rows = rows
        self.dayOwner = dayOwner
        self.contributingSourceCount = contributingSourceCount
    }
}

// MARK: - Screen

struct FusedRecordView: View {
    let record: FusedRecord
    /// The day label shown in the header subtitle ("Today", or a formatted date). Defaulted so the
    /// preview/caller can omit it.
    var dayLabel: String = "Today"

    /// The metric currently open in the conflict-compare sheet (nil = closed).
    @State private var comparing: FusedRow?

    /// True only when more than one source contributed anywhere — gates all provenance chrome so a
    /// single-WHOOP user sees a plain record, not a manufactured multi-source experience.
    private var isMultiSource: Bool { record.contributingSourceCount > 1 }

    var body: some View {
        ScreenScaffold(
            title: "Your Data, Fused",
            subtitle: subtitle
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                if isMultiSource { dayBadgeRow }

                if record.rows.isEmpty {
                    DataPendingNote(
                        title: "Nothing to fuse yet",
                        message: "Import a WHOOP export, Apple Health or a second band and your best-sourced record builds here — on this device.",
                        symbol: "square.stack.3d.up"
                    )
                } else {
                    NoopCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(record.rows.enumerated()), id: \.element.id) { index, row in
                                FusedMetricRowView(
                                    row: row,
                                    showProvenance: isMultiSource,
                                    onCompare: { comparing = row }
                                )
                                if index < record.rows.count - 1 {
                                    Divider().overlay(StrandPalette.hairline)
                                        .padding(.leading, NoopMetrics.cardPadding)
                                }
                            }
                        }
                    }
                }

                privacyNote
                disclaimerNote
            }
        }
        // The conflict-compare detail: every source's value side by side, the winner labelled with its
        // reason. Opening it never changes the resolved value — it only explains it.
        .sheet(item: $comparing) { row in
            ConflictCompareSheet(row: row)
                #if os(iOS)
                .noopSheetPresentation(largeFirst: false)
                #else
                .frame(width: 480, height: 600)
                #endif
        }
    }

    private var subtitle: LocalizedStringKey {
        if isMultiSource {
            return "\(dayLabel) · best signal per metric, from \(record.contributingSourceCount) sources. Everything stays on \(deviceNoun)."
        }
        return "\(dayLabel) · your record, on \(deviceNoun)."
    }

    /// "this Mac" / "this device" without pulling in the app's Platform helper (keeps the view's deps
    /// minimal — the helper lives in the main target, not the design package).
    private var deviceNoun: String {
        #if os(macOS)
        return "this Mac"
        #else
        return "this device"
        #endif
    }

    /// "Today's record owned by WHOOP" — the scores' single-owner, made honest. Only shown when the
    /// fused record actually spans multiple sources (else there's no ambiguity to caption).
    private var dayBadgeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            if let owner = record.dayOwner {
                Text("Today's scores owned by \(owner.displayName)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Scores still calibrating — no single day-owner yet")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var privacyNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("Fused on \(deviceNoun). Nothing leaves it — no account, no cloud.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// The pillar's standing non-clinical line (umbrella §4.1). Kept inline + plain — wellness only.
    private var disclaimerNote: some View {
        Text("NOOP picks the best-sourced number and shows you where each came from. It's for wellness and curiosity — it doesn't diagnose or replace medical advice.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }
}

// MARK: - One fused metric row

private struct FusedMetricRowView: View {
    let row: FusedRow
    /// When false (single-source record) the provenance pill + reason + agreement are all hidden — a
    /// plain "label … value" row, no manufactured multi-source noise.
    let showProvenance: Bool
    let onCompare: () -> Void

    private var point: FusedMetricPoint { row.point }

    private var accent: Color {
        if let hex = row.accentHex { return Color(hex: hex) }
        return StrandPalette.textPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: metric label + the winning value (best-sourced), right-aligned.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.label)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Text(FusionFormat.value(point.value, metricKey: point.metric))
                    .font(StrandFont.number(20))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if showProvenance {
                // Provenance line: a source badge + the published one-line reason.
                HStack(spacing: 8) {
                    SourceBadge(LocalizedStringKey("from \(point.winningSource.displayName)"),
                                tint: StrandPalette.accent)
                    if let reason = winnerReason {
                        Text(reason)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                // Agreement line: quiet for agree, neutral both-values for minorDelta, a ⚠ + compare
                // affordance for conflict. Single → nothing (no second source to cross-check).
                agreementLine
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The whole conflict row is the compare affordance, so VoiceOver and a tap both reach it.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(point.agreement == .conflict ? .isButton : [])
        .accessibilityHint(point.agreement == .conflict ? "Compare sources" : "")
        .onTapGesture { if point.agreement == .conflict { onCompare() } }
    }

    /// The winner's published reason — only worth showing when it adds justification ("counts
    /// directly" / "best stager" / a tier word). A bare "direct sensor" on a lone vital is noise, so we
    /// keep it but it reads quietly in tertiary text.
    private var winnerReason: String? {
        point.contributors.first?.reason
    }

    @ViewBuilder private var agreementLine: some View {
        switch point.agreement {
        case .single:
            EmptyView()

        case .agree:
            if let other = point.contributors.dropFirst().first {
                Text("\(other.source.displayName) agrees: \(FusionFormat.value(other.value, metricKey: point.metric))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

        case .minorDelta:
            if let other = point.contributors.dropFirst().first {
                HStack(spacing: 6) {
                    StatePill("Differs slightly", tone: .neutral, showsDot: false)
                    Text("\(other.source.displayName): \(FusionFormat.value(other.value, metricKey: point.metric))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                }
            }

        case .conflict:
            Button(action: onCompare) {
                HStack(spacing: 6) {
                    StatePill("Sources differ", tone: .warning)
                    Text(conflictSummary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            // Don't double-announce: the row already carries the compare hint+trait above.
            .accessibilityHidden(true)
        }
    }

    /// "Apple Health says 6h 40m — tap to compare" style line for a conflict.
    private var conflictSummary: String {
        guard let other = point.contributors.dropFirst().first else { return "Tap to compare" }
        return "\(other.source.displayName) says \(FusionFormat.value(other.value, metricKey: point.metric)) — tap to compare"
    }
}

// MARK: - Conflict-compare sheet

/// A small read-only sheet: every source's value for the metric, side by side, with the one NOOP is
/// using marked and its trust reason named. NOOP never adjudicates which is "correct" — it shows the
/// spread and explains its best-signal pick. Transparency, not diagnosis.
private struct ConflictCompareSheet: View {
    let row: FusedRow
    @Environment(\.dismiss) private var dismiss

    private var point: FusedMetricPoint { row.point }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(row.label), subtitle: "Your bands report different numbers. Here's every source, and the one NOOP is using.") {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                NoopCard {
                    VStack(spacing: 0) {
                        ForEach(Array(point.contributors.enumerated()), id: \.offset) { index, contrib in
                            ContributorRow(
                                contrib: contrib,
                                metricKey: point.metric,
                                isWinner: index == 0
                            )
                            if index < point.contributors.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }

                // Why this one — the honest explanation of the pick, never a "correct" claim.
                if let winner = point.contributors.first {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("NOOP shows the \(winner.source.displayName) reading because it \(winner.reason) for this metric — a higher-trust source here, not a verdict that the others are wrong.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.noopSecondary)
                    .padding(.top, 4)
            }
        }
    }
}

/// One source's value inside the compare sheet — a source badge, its value, a "trust" caption (the
/// reason), and a "● Using" marker on the winner.
private struct ContributorRow: View {
    let contrib: ContributingSource
    let metricKey: String
    let isWinner: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SourceBadge(LocalizedStringKey(contrib.source.displayName),
                                tint: isWinner ? StrandPalette.accent : StrandPalette.textTertiary)
                    if isWinner {
                        StatePill("Using", tone: .accent, showsDot: true)
                    }
                }
                Text(contrib.reason)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Text(FusionFormat.value(contrib.value, metricKey: metricKey))
                .font(StrandFont.number(18))
                .foregroundStyle(isWinner ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(contrib.source.displayName), \(FusionFormat.value(contrib.value, metricKey: metricKey))\(isWinner ? ", in use" : "")")
    }
}

// MARK: - Display formatting (presentation only — the engine returns raw Doubles + raw keys)

/// Formats a fused metric's `Double` value for display by its resolver key. Pure + local to this
/// screen: the engine deals in numbers, the UI owns units. Sleep/duration keys read as "7h 12m";
/// temp as "34.1°C"; HR/HRV/steps as plain integers with the right unit.
enum FusionFormat {
    static func value(_ v: Double, metricKey: String) -> String {
        switch MetricArbitrationPolicy.kind(forKey: metricKey) {
        case .restingHR, .heartRate:
            return "\(Int(v.rounded())) bpm"
        case .hrv:
            return "\(Int(v.rounded())) ms"
        case .spo2:
            return "\(Int(v.rounded()))%"
        case .skinTemp:
            return String(format: "%.1f°C", v)
        case .steps:
            return integerGrouped(v)
        case .sleep:
            return duration(minutes: v)
        case .calories:
            return "\(integerGrouped(v)) kcal"
        case .other:
            // Unknown unit: a trimmed number, no fake unit.
            return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
        }
    }

    /// "8,420" — grouped integer.
    private static func integerGrouped(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))"
    }

    /// "7h 12m" from a minutes value; "52m" under an hour; "0m" for nothing.
    private static func duration(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let h = total / 60
        let m = total % 60
        if h == 0 { return "\(m)m" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Preview

#if DEBUG
private extension FusedMetricPoint {
    /// Build a fixture point straight through the real resolver so the preview exercises the engine.
    static func fixture(_ key: String, _ inputs: [(FusionSource, Double)]) -> FusedMetricPoint {
        FusionResolver.resolve(metricKey: key,
                               inputs: inputs.map { FusionInput(source: $0.0, value: $0.1) })!
    }
}

#Preview("Your Data, Fused — multi-source") {
    let record = FusedRecord(
        rows: [
            FusedRow(point: .fixture("rhr", [(.whoopImport, 52), (.appleHealth, 53)]),
                     label: "Resting HR", accentHex: nil),
            FusedRow(point: .fixture("steps", [(.xiaomiBand, 8420), (.whoopImport, 6100)]),
                     label: "Steps"),
            FusedRow(point: .fixture("sleep_total_min", [(.whoopImport, 432), (.appleHealth, 400)]),
                     label: "Sleep"),
            FusedRow(point: .fixture("skin_temp", [(.whoopImport, 34.1)]),
                     label: "Skin temp"),
            FusedRow(point: .fixture("hrv", [(.whoopImport, 68)]),
                     label: "HRV"),
        ],
        dayOwner: .whoopImport,
        contributingSourceCount: 3
    )
    return FusedRecordView(record: record)
        .frame(width: 480, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Single WHOOP — plain record") {
    let record = FusedRecord(
        rows: [
            FusedRow(point: .fixture("rhr", [(.whoopImport, 52)]), label: "Resting HR"),
            FusedRow(point: .fixture("sleep_total_min", [(.whoopImport, 432)]), label: "Sleep"),
            FusedRow(point: .fixture("hrv", [(.whoopImport, 68)]), label: "HRV"),
        ],
        dayOwner: .whoopImport,
        contributingSourceCount: 1
    )
    return FusedRecordView(record: record)
        .frame(width: 480, height: 600)
        .preferredColorScheme(.dark)
}
#endif
