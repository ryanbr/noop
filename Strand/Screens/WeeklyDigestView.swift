import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Weekly Digest (#208)
//
// A deterministic, offline "week in review". Reads the local DailyMetric history
// from the Repository, pulls each tracked metric into a day→value map, and feeds
// WeeklyDigestEngine (pure, in StrandAnalytics) to produce a Monday-anchored
// summary: per-metric this-week mean + week-over-week delta + vs-baseline, the
// biggest movers, a strain-vs-recovery balance read, and 1–2 plain-English focal
// points. No AI, no network — the engine is fully deterministic and unit-tested.
//
// Two surfaces are exposed so the orchestrator can wire whichever it wants:
//   • `WeeklyDigestCard` — an embeddable card (drop into Today / Trends).
//   • `WeeklyDigestView` — a full ScreenScaffold screen (for a sidebar `.digest`
//      case). Both share `WeeklyDigestContent`, so they never drift.
//
// Framing is informational and non-clinical, consistent with the app DISCLAIMER.

// MARK: - Shared digest builder (pure glue over the engine)

enum WeeklyDigestSource {

    /// Build the digest for the week containing today's local day from a DailyMetric
    /// history. Extracts each tracked metric into a "yyyy-MM-dd"→value map and hands
    /// it to the pure engine.
    static func digest(from days: [DailyMetric],
                       anchorDay: String,
                       effortDisplayFactor: Double = UnitPrefs.currentEffortDisplayFactor()) -> WeeklyDigest {
        var charge: [String: Double] = [:]
        var effort: [String: Double] = [:]
        var rest: [String: Double] = [:]
        var rhr: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        for d in days {
            if let v = d.recovery { charge[d.day] = v }
            if let v = d.strain   { effort[d.day] = v }
            // Rest = the sleep-performance composite, recomputed on the persisted day.
            if let r = restScore(for: d) { rest[d.day] = r }
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.avgHrv    { hrv[d.day] = v }
        }
        return WeeklyDigestEngine.build(
            byMetric: [.charge: charge, .effort: effort, .rest: rest, .rhr: rhr, .hrv: hrv],
            anchorDay: anchorDay,
            effortDisplayFactor: effortDisplayFactor)
    }

    /// The 0–100 Rest composite for a persisted day, via AnalyticsEngine's display-path
    /// helper (duration-vs-need / efficiency / restorative / consistency). Returns nil
    /// for a day with no in-bed sleep / missing efficiency, so non-sleep days are simply
    /// absent from the Rest series.
    private static func restScore(for d: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: d)
    }
}

// MARK: - Embeddable card

/// The weekly digest as a single card (for Today / Trends). Renders nothing
/// (an empty view) when there's no data this week, so it's safe to always place.
struct WeeklyDigestCard: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
        if digest.isEmpty {
            EmptyView()
        } else {
            // Content owns its own frosted cards (the domain score row + the signals
            // card), so it's no longer wrapped in an outer NoopCard — that would double
            // the frost. The compact flag trims it to the three headline scores.
            WeeklyDigestContent(digest: digest, compact: true)
        }
    }
}

// MARK: - Full screen

/// The weekly digest as a full screen (for a sidebar `.digest` case).
struct WeeklyDigestView: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Week in review",
                       subtitle: "Your Monday-to-Sunday, read in one glance.",
                       // PERF: chart-heavy column (per-score summary cards with gauges, the metric grid
                       // and the focal-points list, all inside WeeklyDigestContent). The LazyVStack path
                       // is byte-identical layout. The content is kept in its inner VStack(sectionGap=22)
                       // for pixel-identical spacing (the scaffold stack is 20pt), so the win is partial
                       // until those rows are promoted to direct children.
                       lazy: true) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "A weekly digest needs a few days of history. Wear your strap or import your WHOOP export in Data Sources."
                    : "Loading your history…")
            } else {
                let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
                if digest.isEmpty {
                    DataPendingNote(
                        title: "No readings this week yet",
                        message: "Once this week has a day or two of data, your week-in-review appears here.")
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        WeeklyDigestContent(digest: digest, compact: false)
                    }
                }
            }
        }
    }
}

// MARK: - Shared content

/// Compact, localized range shared by the standalone digest card and the Trends week navigator.
func weeklyDigestRangeLabel(_ digest: WeeklyDigest) -> String {
    "\(weeklyDigestShortDate(digest.weekStart))–\(weeklyDigestShortDate(digest.weekEnd))"
}

/// "Jun 8" from "2026-06-08", via the engine's own pure parse (no Calendar).
private func weeklyDigestShortDate(_ ymd: String) -> String {
    guard let (_, month, day) = WeeklyDigestEngine.parseYMD(ymd) else { return ymd }
    let months = [String(localized: "Jan"), String(localized: "Feb"), String(localized: "Mar"),
                  String(localized: "Apr"), String(localized: "May"), String(localized: "Jun"),
                  String(localized: "Jul"), String(localized: "Aug"), String(localized: "Sep"),
                  String(localized: "Oct"), String(localized: "Nov"), String(localized: "Dec")]
    let name = (1...12).contains(month) ? months[month - 1] : "\(month)"
    return "\(name) \(day)"
}

/// The inner content shared by the card and the full screen. `compact` trims the
/// metric grid to the headline rows for the card; the full screen shows everything.
struct WeeklyDigestContent: View {
    let digest: WeeklyDigest
    var compact: Bool = false
    var showsHeader: Bool = true

    /// The Effort display scale (#268), so the Week-in-review Effort gauge matches the Today tile
    /// and the Trends small-multiple instead of being stuck on "of 100". Charge/Rest stay 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    /// Display order: the two daily scores first, then the nightly signals.
    private static let order: [WeeklyMetric] = [.charge, .effort, .rest, .hrv, .rhr]
    /// The three headline 0–100 scores shown as domain summaries.
    private static let scoreOrder: [WeeklyMetric] = [.charge, .effort, .rest]

    /// The shared colour world for each weekly metric — drives the summary card tint,
    /// the gauge stroke and the secondary-signal accents.
    private func domain(for m: WeeklyMetric) -> DomainTheme {
        switch m {
        case .charge: return .charge
        case .effort: return .effort
        case .rest:   return .rest
        case .hrv:    return .rest    // HRV shares the Rest / periwinkle world
        case .rhr:    return .stress
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Headline over a subtle scenic backdrop (Charge-tinted starfield).
            if showsHeader {
                header
            }

            // The three headline scores, each with a domain-tinted gauge and week-over-week context.
            scoreRow

            // Focal points + secondary signals + balance footer in one frosted card.
            detailCard
        }
    }

    // MARK: Header (scenic hero)

    private var header: some View {
        ZStack(alignment: .leading) {
            NoopPanelSurface(cornerRadius: NoopMetrics.cardRadius,
                             elevated: true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Week in review").strandOverline()
                    Text(weekRangeLabel)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Text("\(digest.daysWithData)/7 days")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityLabel("\(digest.daysWithData) of 7 days had data this week")
            }
            .padding(NoopMetrics.cardPadding)
        }
    }

    // MARK: Score row — three domain summaries

    @ViewBuilder
    private var scoreRow: some View {
        #if os(iOS)
        if compact {
            compactScoreRow
        } else {
            scoreGrid
        }
        #else
        // `compact` describes the embedded digest, not a compact desktop width.
        // Keep macOS on its original adaptive, individually surfaced score cards.
        scoreGrid
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var compactScoreRow: some View {
        let summaries = Self.scoreOrder.compactMap { digest.summary($0) }
        if !summaries.isEmpty {
            NoopCard(padding: NoopMetrics.space2) {
                if dynamicTypeSize.isAccessibilitySize {
                    // At accessibility text sizes, three narrow columns would either truncate
                    // localized labels/chips or force gauge text below a readable size.
                    VStack(spacing: 0) {
                        ForEach(Array(summaries.enumerated()), id: \.element.metric.rawValue) { index, summary in
                            scoreCard(summary: summary, presentation: .embedded)
                            if index < summaries.count - 1 {
                                Divider()
                                    .overlay(StrandPalette.hairline)
                                    .padding(.horizontal, NoopMetrics.space3)
                                    .padding(.vertical, NoopMetrics.space3)
                            }
                        }
                    }
                } else {
                    // Align from the shared label/gauge rows. Optional content below one gauge must
                    // never shift that gauge relative to its neighbours.
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(summaries.enumerated()), id: \.element.metric.rawValue) { index, summary in
                            scoreCard(summary: summary, presentation: .embedded)
                            if index < summaries.count - 1 {
                                Divider()
                                    .overlay(StrandPalette.hairline)
                                    .padding(.vertical, NoopMetrics.space3)
                            }
                        }
                    }
                }
            }
        }
    }
    #endif

    private var scoreGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: compact ? 140 : 168), spacing: NoopMetrics.gap)],
            spacing: NoopMetrics.gap
        ) {
            ForEach(Self.scoreOrder, id: \.rawValue) { metric in
                if let summary = digest.summary(metric) {
                    scoreCard(summary: summary, presentation: .standalone)
                }
            }
        }
    }

    private func scoreCard(summary: WeeklyMetricSummary,
                           presentation: DigestScoreCard.Presentation) -> some View {
        DigestScoreCard(summary: summary,
                        domain: domain(for: summary.metric),
                        deltaText: deltaText(summary),
                        deltaTone: chipTone(summary),
                        accessibility: rowAccessibility(summary, effortScale: effortScale),
                        effortScale: effortScale,
                        presentation: presentation)
    }

    // MARK: Detail card (focal points · secondary signals · footer)

    @ViewBuilder
    private var detailCard: some View {
        let signals = secondarySignals
        let hasFocal = !digest.focalPoints.isEmpty
        if hasFocal || !signals.isEmpty || !compact {
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    if hasFocal {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(digest.focalPoints.enumerated()), id: \.offset) { _, line in
                                focalRow(line)
                            }
                        }
                    }

                    // Secondary nightly signals (HRV / RHR) as compact rows — full screen only.
                    if !signals.isEmpty {
                        if hasFocal { Divider().overlay(StrandPalette.hairline) }
                        VStack(spacing: 10) {
                            ForEach(signals, id: \.metric.rawValue) { row in
                                metricRow(row)
                            }
                        }
                    }

                    if !compact { footer }
                }
            }
        }
    }

    /// The nightly signals shown as rows beneath the score cards (HRV / RHR) — only on
    /// the full screen; the compact card shows the three score cards alone.
    private var secondarySignals: [WeeklyMetricSummary] {
        guard !compact else { return [] }
        return [WeeklyMetric.hrv, .rhr].compactMap { digest.summary($0) }
    }

    // MARK: Focal row

    private func focalRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(line)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
    }

    // MARK: Metric row (secondary signals)

    private func metricRow(_ s: WeeklyMetricSummary) -> some View {
        HStack(spacing: 12) {
            // Domain dot + label so each signal reads as part of its colour world.
            Circle().fill(domain(for: s.metric).color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(s.metric.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 84, alignment: .leading)

            // This-week mean.
            Text(meanText(s, effortScale: effortScale))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 56, alignment: .leading)

            Spacer(minLength: 8)

            // Week-over-week delta chip (color-coded by good/bad, not just up/down).
            deltaChip(s)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibility(s, effortScale: effortScale))
    }

    private func deltaChip(_ s: WeeklyMetricSummary) -> some View {
        let tone = chipTone(s)
        let arrow = s.wowDelta > 0 ? "arrow.up" : (s.wowDelta < 0 ? "arrow.down" : "minus")
        return HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(deltaText(s))
                .font(StrandFont.captionNumber)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.opacity(0.12), in: Capsule())
    }

    // MARK: Footer (full screen only)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(StrandPalette.hairline)
            if let sd = digest.sleepConsistencySD {
                Text("Sleep steadiness: Rest varied ±\(fmt1(sd)) pts night to night.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(digest.balance.sentence)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Informational only, not medical advice.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Formatting

    private var weekRangeLabel: String {
        weeklyDigestRangeLabel(digest)
    }

    private func meanText(_ s: WeeklyMetricSummary, effortScale: EffortScale) -> String {
        guard s.thisWeek.n > 0 else { return "—" }
        // #463/#268: Effort is STORED 0-100; render it on the user's chosen display scale WITH the
        // denominator ("4.6 / 21", "21.6 / 100") so VoiceOver never speaks a different number than the
        // visible gauge. Mirrors Android meanText(s, effortScale) byte-for-byte.
        if s.metric == .effort {
            return "\(UnitFormatter.effortDisplay(s.thisWeek.mean, scale: effortScale)) / \(UnitFormatter.effortScaleMax(effortScale))"
        }
        let v = Int(s.thisWeek.mean.rounded())
        return s.metric.unit.isEmpty ? "\(v)" : "\(v) \(s.metric.unit)"
    }

    private func deltaText(_ s: WeeklyMetricSummary) -> String {
        guard s.weekOverWeek.current.n > 0, s.weekOverWeek.previous.n > 0 else { return String(localized: "new") }
        // Always speak in percent so the chip's ↑/↓ + sign reads as a delta. A sub-1% mover
        // used to fall back to a bare "0.1" which, once the card prepended "−", looked like a
        // truncated number rather than a change.
        if let pct = s.weekOverWeek.pctChange {
            return abs(pct) >= 1 ? "\(Int(abs(pct).rounded()))%" : "<1%"
        }
        return "<1%"
    }

    /// Tone: good moves green, bad moves rose, flat/uncomparable grey — folding in
    /// each metric's `higherIsBetter` so a Resting-HR rise reads as a warning. A ROUGH comparison
    /// (either side thin, engine's `isRoughComparison`, the #463 fix) keeps its arrow + % but stays
    /// grey regardless of direction, so the chip can't frame a verdict off 1-2 days. Mirrors the
    /// Android WeeklyDigestCard.chipTone gate byte-for-byte.
    private func chipTone(_ s: WeeklyMetricSummary) -> Color {
        if WeeklyDigestChipStyle.neutralizesTone(s) { return StrandPalette.textTertiary }
        switch s.wowGoodness {
        case 1:  return StrandPalette.statusPositive
        case -1: return StrandPalette.statusCritical
        default: return StrandPalette.textTertiary
        }
    }

    private func rowAccessibility(_ s: WeeklyMetricSummary, effortScale: EffortScale) -> String {
        let mean = meanText(s, effortScale: effortScale)
        guard s.weekOverWeek.current.n > 0, s.weekOverWeek.previous.n > 0 else {
            return String(localized: "\(s.metric.label): \(mean) this week, no comparison.")
        }
        // Whole-phrase variants per direction, then a whole-key wrapper per goodness frame, so
        // VoiceOver never hears a stitched half-English fragment.
        let delta = deltaText(s)
        let base: String
        if s.wowDelta > 0 {
            base = String(localized: "\(s.metric.label): \(mean) this week, up \(delta) week over week")
        } else if s.wowDelta < 0 {
            base = String(localized: "\(s.metric.label): \(mean) this week, down \(delta) week over week")
        } else {
            base = String(localized: "\(s.metric.label): \(mean) this week, unchanged \(delta) week over week")
        }
        // A rough comparison drops the verdict framing too, so VoiceOver matches the neutral chip.
        if WeeklyDigestChipStyle.dropsVerdictFrame(s) { return String(localized: "\(base).") }
        switch s.wowGoodness {
        case 1:  return String(localized: "\(base), a good sign.")
        case -1: return String(localized: "\(base), worth a look.")
        default: return String(localized: "\(base).")
        }
    }

    private func fmt1(_ x: Double) -> String { String(format: "%.1f", x) }
}

// MARK: - Rough-comparison chip contract (#463, testable mirror of Android)

/// The display-side gate for a ROUGH week-over-week comparison (either side thin, engine's
/// `WeeklyMetricSummary.isRoughComparison`). Pulled out of the View's private helpers so it can be
/// pinned by a test without exposing the whole View: `chipTone`/`rowAccessibility` above delegate to
/// these, exactly as the Android WeeklyDigestCard chipTone/rowAccessibility gate on the same flag.
enum WeeklyDigestChipStyle {
    /// A rough comparison keeps its arrow + % but the chip stays grey regardless of direction, so it
    /// can't frame a green/rose verdict off 1-2 days (the #463 complaint).
    static func neutralizesTone(_ s: WeeklyMetricSummary) -> Bool { s.isRoughComparison }
    /// A rough comparison also drops the ", a good sign."/", worth a look." VoiceOver frame so the
    /// spoken row matches the neutral chip.
    static func dropsVerdictFrame(_ s: WeeklyMetricSummary) -> Bool { s.isRoughComparison }
}

// MARK: - Digest score summary (one headline domain: gauge + week-over-week chip)

/// A summary for one 0–100 weekly score (Charge / Effort / Rest): a compact layered ring gauge for
/// the week's mean, the domain label, and a TrendChip for the week-over-week move. It can own its
/// domain-tinted card surface or sit inside the compact digest's shared surface. Owns its gauge
/// draw-in @State, like Today.
private struct DigestScoreCard: View {
    enum Presentation: Equatable {
        case embedded
        case standalone
    }

    let summary: WeeklyMetricSummary
    let domain: DomainTheme
    let deltaText: String
    let deltaTone: Color
    let accessibility: String
    /// The Effort display scale (#268). Only consulted for the Effort card; Charge/Rest are genuine
    /// 0–100 scores and ignore it, keeping their "of 100" caption and integer mean.
    var effortScale: EffortScale = .hundred
    let presentation: Presentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var animatedFraction: Double = 0
    @State private var showScaleGuide = false

    /// The Effort card is the only one that follows the 0–100/0–21 toggle; the rest are fixed 0–100.
    private var isEffort: Bool { summary.metric == .effort }
    private var isEmbedded: Bool { presentation == .embedded }
    private var gaugeDiameter: CGFloat {
        isEmbedded && !dynamicTypeSize.isAccessibilitySize ? 82 : 118
    }

    private var fraction: Double {
        guard summary.thisWeek.n > 0 else { return 0 }
        return min(max(summary.thisWeek.mean / 100.0, 0), 1)
    }
    private var numberText: String {
        guard summary.thisWeek.n > 0 else { return "—" }
        return isEffort
            ? UnitFormatter.effortDisplay(summary.thisWeek.mean, scale: effortScale)
            : "\(Int(summary.thisWeek.mean.rounded()))"
    }
    /// "of 100" for the genuine 0–100 scores; the Effort card follows the scale toggle ("of 100"/"of 21").
    private var captionText: String {
        isEffort ? String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))") : String(localized: "of 100")
    }

    @ViewBuilder
    var body: some View {
        Group {
            if isEmbedded {
                content
                    .padding(.horizontal, NoopMetrics.space1)
            } else {
                NoopCard(padding: 14, tint: domain.color) {
                    content
                }
            }
        }
        .onAppear {
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showScaleGuide = true }
    }

    private var content: some View {
        VStack(spacing: NoopMetrics.space2) {
            if isEmbedded {
                Text(summary.metric.label)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(domain.color)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack {
                    metricLabel
                    Spacer(minLength: 0)
                    if hasComparison {
                        TrendChip(text: deltaSigned, color: deltaTone)
                    }
                }
            }
            BevelGauge(
                fraction: fraction,
                stops: domain.gradient.stops,
                tipColor: domain.bright,
                numberText: numberText,
                // The 82pt embedded gauge would reduce its proportional caption to
                // roughly 7pt. Render that caption below with the scalable footnote role.
                captionText: isEmbedded ? nil : captionText,
                stateText: nil,
                supporting: nil,
                diameter: gaugeDiameter,
                lineWidth: isEmbedded && !dynamicTypeSize.isAccessibilitySize ? NoopMetrics.space2 : 11,
                showsLabel: summary.thisWeek.n > 0,
                animatedFraction: animatedFraction
            )
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .onTapGesture { showScaleGuide = true }
            .popover(isPresented: $showScaleGuide, arrowEdge: .bottom) {
                VStack(spacing: NoopMetrics.space1) {
                    Text(summary.metric.label)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(domain.color)
                    Text(captionText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(NoopMetrics.cardInnerPadding)
                .frame(minWidth: 120)
                .background(NoopPanelSurface(cornerRadius: NoopVisualStyle.compactRadius, elevated: true))
                .accessibilityElement(children: .combine)
                .digestScalePopoverAdaptation()
            }
            if isEmbedded && hasComparison {
                TrendChip(text: deltaSigned, color: deltaTone)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var metricLabel: some View {
        Text(summary.metric.label)
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(domain.color)
    }

    private var hasComparison: Bool {
        summary.weekOverWeek.current.n > 0 && summary.weekOverWeek.previous.n > 0
    }

    /// The week-over-week delta carrying a +/− so the TrendChip infers its arrow.
    private var deltaSigned: String {
        guard summary.weekOverWeek.current.n > 0, summary.weekOverWeek.previous.n > 0 else { return deltaText }
        let sign = summary.wowDelta > 0 ? "+" : (summary.wowDelta < 0 ? "−" : "")
        return "\(sign)\(deltaText)"
    }
}

private extension View {
    @ViewBuilder
    func digestScalePopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
private func previewDigest() -> WeeklyDigest {
    var charge: [String: Double] = [:], effort: [String: Double] = [:]
    var rest: [String: Double] = [:], hrv: [String: Double] = [:], rhr: [String: Double] = [:]
    // This week (Mon 2026-06-08 .. Sun 2026-06-14) trending up; last week lower.
    for (i, day) in (8...14).enumerated() {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 62 + Double(i) * 3
        effort[k] = 70 - Double(i)
        rest[k] = 82 + Double(i % 3)
        hrv[k] = 58 + Double(i)
        rhr[k] = 53 - Double(i % 2)
    }
    for day in 1...7 {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 55; effort[k] = 64; rest[k] = 80; hrv[k] = 52; rhr[k] = 55
    }
    return WeeklyDigestEngine.build(
        byMetric: [.charge: charge, .effort: effort, .rest: rest, .hrv: hrv, .rhr: rhr],
        anchorDay: "2026-06-13")
}

#Preview("Weekly digest – card") {
    WeeklyDigestContent(digest: previewDigest(), compact: true)
        .padding(24)
        .frame(width: 420)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}

#if os(iOS)
#Preview("Weekly digest – card · accessibility text") {
    WeeklyDigestContent(digest: previewDigest(), compact: true)
        .padding(24)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility1)
}
#endif

#Preview("Weekly digest – full") {
    ScrollView {
        WeeklyDigestContent(digest: previewDigest(), compact: false)
            .padding(24)
    }
    .frame(width: 520, height: 680)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
