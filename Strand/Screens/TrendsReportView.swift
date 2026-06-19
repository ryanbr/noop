import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends Report (#436)
//
// A shareable, offline one-page "trends report" over a chosen date range: per-metric
// mean / min / max / trend for Recovery, Sleep, HRV, Resting HR and Strain, a short set
// of plain-English headlines, and a simple sparkline for each metric. Everything is
// computed on-device by the pure, unit-tested `RangeReportEngine` (no network), then
// rendered to a PDF the user saves to Files / shares via the system share sheet.
//
// This file owns three things:
//   • `TrendsReportData` — pulls the five metric series out of the Repository's
//     DailyMetric history and calls RangeReportEngine.build for a range.
//   • `TrendsReportPage` — the laid-out SwiftUI page (the thing rendered to PDF),
//     built ENTIRELY from the locked StrandDesign component system (NoopCard,
//     SectionHeader, Sparkline, the colour worlds) so it matches every other surface.
//   • `TrendsReportSheet` — the in-app range picker + "Export" CTA presented from Trends.
//
// Honesty: an empty range (no metric carried a reading) renders a friendly
// "not enough data in this range yet" state, never a blank or fabricated page.

// MARK: - Range options

/// The export window choices offered in the picker. Mirrors the Trends range ethos
/// (trailing N days, or all history) but is its own type so the report's wording is
/// self-contained.
enum ReportRange: Int, CaseIterable, Identifiable {
    case days30 = 30, days90 = 90, days180 = 180, days365 = 365, all = 0
    var id: Int { rawValue }

    /// Short pill label.
    var label: String {
        switch self {
        case .days30:  return "30d"
        case .days90:  return "90d"
        case .days180: return "6M"
        case .days365: return "1Y"
        case .all:     return "All"
        }
    }

    /// Long human label for the report title / picker description.
    var longName: String {
        switch self {
        case .days30:  return "Last 30 days"
        case .days90:  return "Last 90 days"
        case .days180: return "Last 6 months"
        case .days365: return "Last year"
        case .all:     return "All history"
        }
    }

    /// Trailing-day window, or nil for "all history".
    var days: Int? { self == .all ? nil : rawValue }
}

// MARK: - Report data builder (pure glue over the engine)

/// Builds a `RangeReport` for a `ReportRange` from a DailyMetric history, plus the raw
/// per-metric sparkline series the page draws. Pure: no Repository, no I/O — give it the
/// `days` array and today's local day key.
enum TrendsReportData {

    /// The nine day→value maps the engine consumes, keyed by ReportMetric.
    ///
    /// `stressByDay` is the persisted daily stress series ("yyyy-MM-dd" → 0–3), the same
    /// stored series the Stress screen prioritises (#457). It isn't carried on `DailyMetric`,
    /// so the caller loads it and passes it in; absent days simply stay out of the report.
    static func metricMaps(from days: [DailyMetric],
                           stressByDay: [String: Double] = [:]) -> [ReportMetric: [String: Double]] {
        var workouts: [String: Double] = [:]
        var recovery: [String: Double] = [:]
        var sleepHours: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        var restingHr: [String: Double] = [:]
        var strain: [String: Double] = [:]
        var respRate: [String: Double] = [:]
        var skinTempDev: [String: Double] = [:]
        for d in days {
            // Workouts logged that day (#457). The count is always present on a recorded day
            // (0 on a rest day), so the row reflects the full window's activity cadence.
            if let c = d.exerciseCount { workouts[d.day] = Double(c) }
            if let v = d.recovery { recovery[d.day] = v }
            // Sleep is reported in HOURS to match the metric's unit; totalSleepMin is the
            // persisted minutes asleep. Days with no in-bed sleep stay absent.
            if let m = d.totalSleepMin, m > 0 { sleepHours[d.day] = m / 60.0 }
            if let v = d.avgHrv { hrv[d.day] = v }
            if let v = d.restingHr { restingHr[d.day] = Double(v) }
            if let v = d.strain { strain[d.day] = v }
            // In-sleep physiology (v7 columns). Absent on days the strap didn't measure them.
            if let v = d.respRateBpm { respRate[d.day] = v }
            if let v = d.skinTempDevC { skinTempDev[d.day] = v }
        }
        // Daily stress score (#457), clamped to its 0–3 scale. Stored-only — the report never
        // re-derives a stress value (unlike the live Stress screen), so a day with no banked
        // stress simply has no Stress row contribution.
        let stress = stressByDay.mapValues { Swift.min(Swift.max($0, 0), 3) }
        return [
            .workouts: workouts, .stress: stress,
            .recovery: recovery, .sleepHours: sleepHours, .hrv: hrv,
            .restingHr: restingHr, .strain: strain,
            .respRate: respRate, .skinTempDev: skinTempDev,
        ]
    }

    /// The inclusive [start, end] "yyyy-MM-dd" window for a range, anchored to today's
    /// LOCAL day (so a 30-day export is the last 30 calendar days, not the last 30 rows —
    /// matching TrendsView's window rule). For `.all`, start is the earliest day present.
    static func window(for range: ReportRange, days: [DailyMetric],
                       today: String) -> (start: String, end: String) {
        let end = today
        guard let n = range.days else {
            // All history: from the earliest recorded day (or today if the history is empty).
            let start = days.map(\.day).min() ?? today
            return (start, end)
        }
        // Trailing N calendar days ending today, computed via the local-day key so the
        // window matches TrendsView (Calendar-based, phone-local), then clamped to the
        // ISO string the engine compares on.
        let startDate = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        // Local-zone "yyyy-MM-dd" matching Repository.localDayKey, but self-contained so this stays a
        // nonisolated static (localDayKey is @MainActor-isolated and this runs off the main actor).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let start = f.string(from: startDate)
        return (start, end)
    }

    /// Build the full report for a range from a DailyMetric history (+ the stored daily
    /// stress series, for the Stress row — #457).
    static func report(for range: ReportRange, days: [DailyMetric],
                       today: String, stressByDay: [String: Double] = [:]) -> RangeReport {
        let (start, end) = window(for: range, days: days, today: today)
        return RangeReportEngine.build(metrics: metricMaps(from: days, stressByDay: stressByDay),
                                       start: start, end: end)
    }

    /// The in-range sparkline series (chronological values) for one metric — the same
    /// window the engine summarised, so the line and the stats agree.
    static func series(_ metric: ReportMetric, from days: [DailyMetric],
                       start: String, end: String, stressByDay: [String: Double] = [:]) -> [Double] {
        let map = metricMaps(from: days, stressByDay: stressByDay)[metric] ?? [:]
        return map.filter { $0.key >= start && $0.key <= end }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }
}

// MARK: - Metric → colour world

/// The line/accent hue for each report metric — drives the card tint + sparkline gradient
/// so each metric reads in its established colour world (Charge gold, Effort amber, Rest/HRV
/// blue, Resting-HR burnt-orange).
private extension ReportMetric {
    /// The line/accent colour for the metric, keeping each its long-standing hue.
    var accent: Color {
        switch self {
        case .workouts:    return StrandPalette.effortColor  // activity → the Effort world
        case .stress:      return StrandPalette.stressColor  // the Stress world hue
        case .recovery:    return StrandPalette.chargeColor
        case .strain:      return StrandPalette.effortColor
        case .sleepHours:  return StrandPalette.restColor
        case .hrv:         return StrandPalette.metricPurple
        case .restingHr:   return StrandPalette.metricRose
        case .respRate:    return StrandPalette.metricCyan   // breath / air — teal
        case .skinTempDev: return StrandPalette.metricRose   // temperature — warm (shares RHR's hue)
        }
    }

    /// The sparkline gradient (deep → bright in the metric's hue).
    var sparkGradient: Gradient {
        Gradient(colors: [accent.opacity(0.45), accent])
    }
}

// MARK: - The rendered page

/// The laid-out one-page report — the exact view handed to the renderer. A fixed-width
/// column (A4-ish portrait proportions) so the PDF reads as a clean printed sheet on
/// both platforms. Built only from StrandDesign primitives.
struct TrendsReportPage: View {
    let report: RangeReport
    let range: ReportRange
    /// Per-metric sparkline series, looked up by metric. Only present metrics are drawn.
    let series: [ReportMetric: [Double]]
    /// Generated-on label (e.g. "Jun 15, 2026").
    let generatedOn: String

    /// The fixed page width used for the PDF render. ~ A4 portrait at 72dpi-ish density.
    static let pageWidth: CGFloat = 612

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            header
            if report.isEmpty {
                emptyState
            } else {
                headlines
                metricCards
            }
            footer
        }
        .padding(28)
        .frame(width: Self.pageWidth, alignment: .leading)
        .background(StrandPalette.surfaceBase)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .leading) {
            ScenicHeroBackground(domain: .charge, starCount: 24)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    BrandMark(size: 22)
                    Text("NOOP").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.accent)
                    Spacer()
                    Text(range.longName).strandOverline()
                }
                Text("Trends report")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(rangeLabel)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(NoopMetrics.cardPadding)
        }
    }

    private var rangeLabel: String {
        let span = report.totalDays
        let dayWord = span == 1 ? "day" : "days"
        return "\(prettyDate(report.start)) – \(prettyDate(report.end))  ·  \(span) \(dayWord)"
    }

    // MARK: Headlines

    private var headlines: some View {
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("What changed", overline: "Summary")
                ForEach(Array(report.headlines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.accent)
                        Text(line)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Per-metric cards

    private var metricCards: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Metrics", overline: "By the numbers")
            ForEach(report.metrics, id: \.metric) { stat in
                metricCard(stat)
            }
        }
    }

    private func metricCard(_ stat: MetricRangeStat) -> some View {
        let metric = stat.metric
        let spark = series[metric] ?? []
        return NoopCard(tint: metric.accent) {
            VStack(alignment: .leading, spacing: 10) {
                // Title + mean read-out + trend chip.
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.label).strandOverline()
                    Spacer()
                    Text(meanText(stat))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    trendChip(stat)
                }

                // Sparkline over the window (decorative; the numbers below are the read).
                if spark.count >= 2 {
                    Sparkline(values: spark, gradient: metric.sparkGradient)
                        .frame(height: 34)
                        .accessibilityHidden(true)
                } else {
                    Text("Single reading in range")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                Divider().overlay(StrandPalette.hairline)

                // The numbers: min / max (with the day each fell on) + readings count.
                ChartFooter([
                    ("Avg", valueText(stat.mean, metric)),
                    ("Min", "\(valueText(stat.min.value, metric)) · \(prettyDate(stat.min.day))"),
                    ("Max", "\(valueText(stat.max.value, metric)) · \(prettyDate(stat.max.day))"),
                    ("Days", "\(stat.n)"),
                ])
            }
        }
    }

    /// A trend chip coloured good/bad for the metric (neutral when flat or valence-free).
    @ViewBuilder
    private func trendChip(_ stat: MetricRangeStat) -> some View {
        let d = stat.halfDelta
        if stat.trend == .flat || abs(d) < 0.05 {
            TrendChip(text: "steady", color: StrandPalette.textTertiary)
        } else {
            let up = d > 0
            // Signed-deviation metric (skin-temp Δ): show the move, no good/bad verdict.
            let color: Color = stat.metric.framesGoodBad
                ? (up == stat.metric.higherIsBetter ? StrandPalette.statusPositive : StrandPalette.metricRose)
                : StrandPalette.textTertiary
            let sign = up ? "+" : "−"
            TrendChip(text: "\(sign)\(round1Text(abs(d)))", color: color)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not enough data in this range yet")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("No workout, stress, recovery, sleep, HRV, resting-HR, strain, respiratory-rate or skin-temp readings fell inside \(range.longName.lowercased()). Wear your strap a few more days, or pick a wider range, then export again.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(StrandPalette.hairline)
            // Provenance legend (#457): a clinician (or anyone) reading this needs to know which numbers
            // are directly measured vs. NOOP's own derived scores. HRV / Resting HR come off the strap;
            // Recovery and Strain are computed on-device and are NOT clinical measures.
            Text("How to read this: HRV, Resting HR, Sleep duration, Respiratory rate and Skin temperature "
                + "are measured from the strap (skin temp is shown as the deviation from your own baseline). "
                + "Workouts is the count of activities you logged or that were detected. Recovery, Strain and "
                + "Stress are NOOP's own on-device scores, not clinical measures — Recovery is a daily readiness "
                + "composite (HRV, resting HR, sleep and skin-temp trend), Strain is cardiovascular load derived "
                + "from heart rate, and Stress is a 0–3 autonomic-load index from resting HR and HRV.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Generated by NOOP on \(generatedOn) · all on-device, no account, no cloud.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Informational only — not medical advice.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Formatting

    /// Whole-number for the 0–100 scores + bpm + ms + workout count; one decimal for sleep
    /// hours, respiratory rate, skin-temp Δ and the 0–3 stress score (`metric.usesOneDecimal`).
    /// Skin-temp is a signed deviation from baseline, so a positive reading gets an explicit
    /// "+" to keep it from reading as an absolute temp.
    private func valueText(_ v: Double, _ metric: ReportMetric) -> String {
        let unit = metric.unit
        // Workouts is a fractional rate in the AVG read-out but a whole count at min/max; one
        // decimal keeps the averaged cadence honest (e.g. "0.4 /day") without faking precision.
        var num = metric.usesOneDecimal ? round1Text(v) : "\(Int(v.rounded()))"
        if metric == .skinTempDev && v > 0 { num = "+\(num)" }
        return unit.isEmpty ? num : "\(num) \(unit)"
    }

    private func meanText(_ stat: MetricRangeStat) -> String {
        valueText(stat.mean, stat.metric)
    }

    private func round1Text(_ x: Double) -> String {
        String(format: "%.1f", (x * 10).rounded() / 10)
    }

    /// "Jun 15" from "2026-06-15", via a pure ISO parse (no Calendar/locale). Reuses the
    /// public WeeklyDigestEngine parser — both engines emit identical "yyyy-MM-dd" keys.
    private func prettyDate(_ ymd: String) -> String {
        guard let (_, m, d) = WeeklyDigestEngine.parseYMD(ymd) else { return ymd }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let name = (1...12).contains(m) ? months[m - 1] : "\(m)"
        return "\(name) \(d)"
    }
}

// MARK: - Export sheet (range picker + CTA)

/// The in-app sheet: pick a range, preview the page, export to PDF. Presented from the
/// Trends screen's "Export trends report" button.
struct TrendsReportSheet: View {
    let days: [DailyMetric]
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var range: ReportRange = .days90
    @State private var exporting = false
    /// Stored daily stress series ("yyyy-MM-dd" → 0–3), for the Stress row (#457). Loaded
    /// once from the same "my-whoop" series the Stress screen reads; empty until it arrives.
    @State private var stressByDay: [String: Double] = [:]

    private var today: String { Repository.localDayKey(Date()) }

    private var report: RangeReport {
        TrendsReportData.report(for: range, days: days, today: today, stressByDay: stressByDay)
    }

    private func seriesMap(start: String, end: String) -> [ReportMetric: [Double]] {
        var out: [ReportMetric: [Double]] = [:]
        for metric in ReportMetric.allCases {
            out[metric] = TrendsReportData.series(metric, from: days, start: start, end: end,
                                                  stressByDay: stressByDay)
        }
        return out
    }

    private var generatedOn: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date())
    }

    private func page(for report: RangeReport) -> TrendsReportPage {
        TrendsReportPage(report: report, range: range,
                         series: seriesMap(start: report.start, end: report.end),
                         generatedOn: generatedOn)
    }

    var body: some View {
        let rpt = report
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Export trends report")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A clean, shareable one-page PDF of your recovery, sleep, HRV, resting heart rate and strain over a date range. Saved on your \(Platform.deviceNoun) — nothing leaves the device.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Range").strandOverline()
                    SegmentedPillControl(ReportRange.allCases, selection: $range) { $0.label }
                    Text(range.longName)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                // A scaled-down live preview of the page so the user sees exactly what
                // they'll get before exporting.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview").strandOverline()
                    page(for: rpt)
                        .scaleEffect(0.46, anchor: .topLeading)
                        .frame(width: TrendsReportPage.pageWidth * 0.46,
                               height: 760 * 0.46, alignment: .topLeading)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                        )
                }

                Button {
                    export(rpt)
                } label: {
                    Label(exporting ? "Preparing…" : "Export PDF", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.noopPrimary)
                .disabled(exporting)

                Text("Tip: the share sheet can save the PDF to Files, AirDrop it, or send it on.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(24)
        }
        .background(StrandPalette.surfaceBase)
        .frame(width: 460, height: 640)
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
        // Load the stored daily stress series for the Stress row (#457). The same
        // "my-whoop" series the Stress screen prioritises; the report never re-derives it.
        .task {
            let pts = await repo.series(key: "stress", source: "my-whoop")
            stressByDay = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        }
    }

    @MainActor
    private func export(_ report: RangeReport) {
        guard !exporting else { return }
        exporting = true
        let name = "NOOP-trends-\(report.start)_to_\(report.end).pdf"
        TrendsReportRenderer.exportPDF(page: page(for: report), suggestedName: name)
        exporting = false
        #if os(macOS)
        // macOS NSSavePanel is modal and has already returned by now, so closing the report sheet is fine.
        dismiss()
        #endif
        // iOS (#455): do NOT dismiss here. The share sheet is presented ON TOP of this report sheet; calling
        // dismiss() would tear this sheet — and the share sheet with it — straight back down, so the user
        // saw nothing. Leave the report up; the share sheet sits over it and returns here when closed.
    }
}

#if DEBUG
@MainActor
private func previewDays() -> [DailyMetric] {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let cal = Calendar(identifier: .gregorian)
    var out: [DailyMetric] = []
    for i in stride(from: 119, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
        let p = Double(119 - i)
        out.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 380 + 60 * sin(p / 9), efficiency: 0.9,
            deepMin: 90, remMin: 110, lightMin: 200, disturbances: 6,
            restingHr: Int((52 + 4 * sin(p / 7)).rounded()),
            avgHrv: 55 + 14 * sin(p / 8) + p * 0.1,
            recovery: max(2, min(99, 58 + 26 * sin(p / 11) + p * 0.15)),
            strain: max(0, min(100, 50 + 18 * sin(p / 5))),
            exerciseCount: 1))
    }
    return out
}

#Preview("Trends report — page") {
    ScrollView {
        TrendsReportPage(
            report: TrendsReportData.report(for: .days90, days: previewDays(),
                                            today: Repository.localDayKey(Date())),
            range: .days90,
            series: {
                var m: [ReportMetric: [Double]] = [:]
                let r = TrendsReportData.report(for: .days90, days: previewDays(),
                                                today: Repository.localDayKey(Date()))
                for metric in ReportMetric.allCases {
                    m[metric] = TrendsReportData.series(metric, from: previewDays(),
                                                        start: r.start, end: r.end)
                }
                return m
            }(),
            generatedOn: "Jun 15, 2026")
    }
    .frame(width: 640, height: 900)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("Trends report — sheet") {
    TrendsReportSheet(days: previewDays())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 480, height: 640)
        .preferredColorScheme(.dark)
}
#endif
