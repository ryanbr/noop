import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Trends
//
// The longitudinal view, rebuilt on the locked Noop component system so every
// surface, height and gap is identical: one SegmentedPillControl for the range,
// a hero recovery ChartCard, a uniform grid of HRV / Resting HR / Day Strain
// ChartCards (all NoopMetrics.chartHeight tall), and the whole history as a
// recovery YearHeatStrip in a NoopCard. No hand-sized cards anywhere.

struct TrendsView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    // The shared range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week:    return "W"
            case .month:   return "M"
            case .quarter: return "3M"
            case .half:    return "6M"
            case .year:    return "1Y"
            case .all:     return "ALL"
            }
        }
        /// Trailing-day window, or nil for "all history".
        var days: Int? { self == .all ? nil : rawValue }

        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    @State private var range: Range = .quarter

    // #436 — shareable offline trends report (PDF over a date range). The sheet owns its
    // own range picker; this just presents it with the loaded history.
    @State private var showingReport = false

    /// Rest's per-day series, keyed by YYYY-MM-DD. Rest is the sleep_performance COMPOSITE (matching the
    /// Today Rest score + the Sleep Rest-detail, #614 follow-up) — NOT raw efficiency, which read different
    /// under the same "Rest" label and made the Trends Rest graph disagree with the Today Rest score (#732).
    /// sleep_performance is a metricSeries, not a DailyMetric field, so load it once (mirroring TodayView's
    /// restScore source) and key by day for `resolve` below.
    @State private var sleepPerfByDay: [String: Double] = [:]

    // Effort display scale (#268) — routes the Effort small-multiple's numbers + unit. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: Window selection (relative to the LATEST day, with auto-expand)

    /// The latest recorded day across all history (anchors every window).
    private var latestDay: Date? {
        guard let d = repo.days.last?.day else { return nil }
        return date(d)
    }

    /// Days for a given range, taken RELATIVE TO TODAY (the phone's local date) — not the latest
    /// recorded day, which on a stale import anchored W/M/3M to months-old data so it looked current
    /// (issue #23). Empty short windows auto-widen (see `resolve`), so old imports surface under a
    /// wider range / All history instead of masquerading as recent. `.all` returns everything.
    /// ISO yyyy-MM-dd compares chronologically.
    private func days(for r: Range) -> [DailyMetric] {
        guard let n = r.days else { return repo.days }
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date())
        return repo.days.filter { $0.day >= cutoffKey }
    }

    /// Build trend points from a metric accessor over a day slice.
    private func points(_ days: ArraySlice<DailyMetric>, _ value: (DailyMetric) -> Double?) -> [TrendPoint] {
        days.compactMap { d in
            guard let v = value(d), let dt = date(d.day) else { return nil }
            return TrendPoint(date: dt, value: v)
        }
    }
    private func points(_ days: [DailyMetric], _ value: (DailyMetric) -> Double?) -> [TrendPoint] {
        points(days[...], value)
    }

    // MARK: Resolved metric (memoized per body)
    //
    // days(for:) / points each re-filter the full multi-year `repo.days` array,
    // and the subviews used to fan out to them many times per render (caption +
    // widened + windowPoints, ×4 metrics). `resolve(_:)` walks the widening order
    // ONCE per metric (the smallest range ≥ selected whose window holds ≥1 point,
    // else ALL), captures that window's points and its effective range, then
    // derives the caption / widened flag from those — so a single body evaluation
    // filters each metric's window once instead of dozens of times. Identical
    // results to the old per-helper (effectiveRange / windowPoints / caption /
    // widened) computation.
    private struct ResolvedMetric {
        var points: [TrendPoint]
        var effective: Range
        var widened: Bool
        var caption: String
    }

    private func resolve(_ value: (DailyMetric) -> Double?) -> ResolvedMetric {
        // Find the smallest range ≥ selected whose window has ≥1 point, keeping
        // that window's points so we don't re-filter to read them back.
        for r in range.widening {
            let pts = points(days(for: r), value)
            if !pts.isEmpty {
                return ResolvedMetric(points: pts, effective: r,
                                      widened: r != range, caption: caption(count: pts.count, eff: r))
            }
        }
        // No range held data: fall back to ALL (matches effectiveRange()).
        let pts = points(days(for: .all), value)
        return ResolvedMetric(points: pts, effective: .all,
                              widened: .all != range, caption: caption(count: pts.count, eff: .all))
    }

    /// Caption text from an already-resolved count + effective range. Mirrors
    /// `caption(_:)` exactly but takes precomputed inputs to avoid re-filtering.
    private func caption(count n: Int, eff: Range) -> String {
        let unit = n == 1 ? "reading" : "readings"
        if eff != range {
            return "\(n) \(unit) · sparse — widened to \(name(for: eff))"
        }
        return "\(n) \(unit) · \(name(for: range))"
    }

    /// A padded value range for a series so the line isn't flat against the axis.
    private func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private func mean(_ pts: [TrendPoint]) -> Double? {
        guard !pts.isEmpty else { return nil }
        return pts.map(\.value).reduce(0, +) / Double(pts.count)
    }

    /// The window's trend as a signed mean-of-recent-half minus mean-of-earlier-half. Drives a
    /// TrendChip so the card reads its direction at a glance, like Today's deltas. nil for a window
    /// too short to split. `higherIsBetter == nil` (e.g. Effort) keeps the chip neutral.
    private func periodChange(_ pts: [TrendPoint]) -> Double? {
        guard pts.count >= 4 else { return nil }
        let mid = pts.count / 2
        let earlier = pts.prefix(mid).map(\.value)
        let recent = pts.suffix(pts.count - mid).map(\.value)
        guard !earlier.isEmpty, !recent.isEmpty else { return nil }
        let e = earlier.reduce(0, +) / Double(earlier.count)
        let r = recent.reduce(0, +) / Double(recent.count)
        return r - e
    }

    /// A TrendChip for a window's period change, coloured green/rose by whether the move is good for
    /// THIS metric (`higherIsBetter`); neutral when direction has no valence or the change is flat.
    @ViewBuilder
    private func changeChip(_ pts: [TrendPoint], higherIsBetter: Bool?, fmt: @escaping (Double) -> String) -> some View {
        if let d = periodChange(pts), abs(d) > 0.0001 {
            let sign = d >= 0 ? "+" : "−"
            let color: Color = {
                guard let better = higherIsBetter else { return StrandPalette.textTertiary }
                return (d > 0) == better ? StrandPalette.statusPositive : StrandPalette.metricRose
            }()
            TrendChip(text: "\(sign)\(fmt(abs(d)))", color: color)
        }
    }

    /// "Trailing 90 days" / "All history" — used as a card subtitle.
    private var rangeSubtitle: String {
        guard let n = range.days else { return "All history" }
        return "Trailing \(n) days"
    }

    private func name(for r: Range) -> String {
        switch r {
        case .week:    return "week"
        case .month:   return "month"
        case .quarter: return "3 months"
        case .half:    return "6 months"
        case .year:    return "year"
        case .all:     return "all history"
        }
    }

    var body: some View {
        ScreenScaffold(title: "Trends", subtitle: "The thread of you over time.",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       onRefresh: { await repo.refresh() },
                       lazy: true) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                // Resolve each metric's window ONCE per body and pass the results
                // down — rangeBar/heroRecovery/smallMultiples all reuse these
                // instead of re-filtering repo.days through caption/widened/
                // windowPoints on every render (hover, animation, 1 Hz HR tick).
                let recovery = resolve { $0.recovery }
                let hrv = resolve { $0.avgHrv }
                let rhr = resolve { $0.restingHr.map(Double.init) }
                let strain = resolve { $0.strain }
                // Rest = the sleep_performance composite — the same number the Today Rest score shows
                // (#732); see sleepPerfByDay. resolve() still does the windowing/widening.
                let rest = resolve { sleepPerfByDay[$0.day] }
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    // The main card list ripples in once on appear (Reduce-Motion safe).
                    Group {
                        // Week-in-review digest (#208) — self-hides when this week has no data.
                        WeeklyDigestCard()
                            .staggeredAppear(index: 0)
                        // The Charge / Effort / Rest trio, presented in NOOP's pip language.
                        weekInReview(charge: recovery, effort: strain, rest: rest)
                            .staggeredAppear(index: 1)
                        rangeBar(recovery: recovery)
                            .staggeredAppear(index: 2)
                        heroRecovery(recovery: recovery)
                            .staggeredAppear(index: 3)
                        smallMultiples(hrv: hrv, rhr: rhr, strain: strain)
                            .staggeredAppear(index: 4)
                        yearStrip
                            .staggeredAppear(index: 5)
                        exportReportRow
                            .staggeredAppear(index: 6)
                    }
                }
            }
        }
        // #436 — present the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.days)
        }
        // #732 — load the resolved sleep_performance series so Rest plots the SAME composite the Today
        // Rest score uses (not raw efficiency). Mirrors TodayView's restScore read. Keyed on the day
        // count so a newly-banked/-scored night refreshes Rest reactively, like the other metrics that
        // read `repo.days` directly (and like the Android LaunchedEffect(days) twin).
        .task(id: repo.days.count) {
            let s = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    // MARK: Week in Review — the Charge / Effort / Rest trio in pip language

    /// The three daily scores as NOOP pip rows over the resolved window: Charge (recovery, 0–100),
    /// Effort (strain, shown on the WHOOP 0–21 scale per the unit toggle) and Rest (sleep_performance
    /// composite, 0–100 — the same metric the Today Rest score shows, #732). Each value ticks up via
    /// `CountUpText`; the segmented `PipBar` cascades on appear. Self-
    /// hides when none of the three carry a window mean, so an empty history shows nothing here.
    @ViewBuilder
    private func weekInReview(charge: ResolvedMetric, effort: ResolvedMetric, rest: ResolvedMetric) -> some View {
        let chargeAvg = mean(charge.points)
        let effortAvg = mean(effort.points)   // stored 0–100 internal Effort scale
        let restAvg = mean(rest.points)
        if chargeAvg != nil || effortAvg != nil || restAvg != nil {
            NoopCard(tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Week in review", overline: "Charge · Effort · Rest")
                    if let v = chargeAvg {
                        pipScoreRow(label: "Charge", value: v, range: 0...100,
                                    tint: StrandPalette.chargeColor,
                                    format: { "\(Int($0.rounded()))" })
                    }
                    if let v = effortAvg {
                        // Effort is stored 0–100 but reads on the WHOOP 0–21 scale per the unit toggle:
                        // convert the displayed number + bar position to the user's chosen Effort scale so
                        // the pip fill and the count-up value agree (both on the same scale).
                        let display = UnitFormatter.effortValue(v, scale: effortScale)
                        let maxV = UnitFormatter.effortValue(100, scale: effortScale)
                        // On the 0–21 WHOOP scale Effort reads to one decimal (e.g. "9.0"); on the 0–100
                        // scale it's a whole number — match `effortScaleMax` so the count-up format agrees.
                        let oneDecimal = effortScale == .whoop
                        pipScoreRow(label: "Effort", value: display, range: 0...maxV,
                                    tint: StrandPalette.effortColor,
                                    format: { oneDecimal ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" })
                    }
                    if let v = restAvg {
                        pipScoreRow(label: "Rest", value: v, range: 0...100,
                                    tint: StrandPalette.restColor,
                                    format: { "\(Int($0.rounded()))" })
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// One pip row matching `PipBarRow`'s layout, but with the value driven by `CountUpText` so the big
    /// number ticks up. UPPERCASE label + big white count-up value over the segmented count-up bar.
    private func pipScoreRow(label: LocalizedStringKey, value: Double, range: ClosedRange<Double>,
                             tint: Color, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)
            CountUpText(value: value, format: format,
                        font: StrandFont.number(30, weight: .bold),
                        color: StrandPalette.textPrimary)
            PipBar(value: value, range: range, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(format(value)))
    }

    // MARK: Export trends report (#436)

    /// A footer entry that opens the shareable-report sheet. Flat WHOOP card with a blue accent
    /// action — the icon, label and "Export" CTA all read in the accent (blue) world, no gold.
    private var exportReportRow: some View {
        NoopCard(tint: StrandPalette.accent) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "doc.richtext")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Export trends report").strandOverline()
                    Text("A shareable one-page PDF of recovery, sleep, HRV, resting HR and strain over a range — saved on your \(Platform.deviceNoun).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                // The card's call-to-action — routed through the unified button system (secondary kind:
                // a quiet raised capsule that reads as the card action, not the one primary on the page).
                NoopButton("Export", systemImage: "square.and.arrow.up", kind: .secondary) {
                    showingReport = true
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Range control

    private func rangeBar(recovery: ResolvedMetric) -> some View {
        let cap = recovery.caption
        let isWide = recovery.widened
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                SegmentedPillControl(Range.allCases, selection: $range) { $0.label }
                Spacer()
                Text(rangeSubtitle).strandOverline()
            }
            Text(cap)
                .font(StrandFont.footnote)
                .foregroundStyle(isWide ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .accessibilityLabel(cap)
        }
    }

    // MARK: Hero — recovery over time

    private func heroRecovery(recovery: ResolvedMetric) -> some View {
        let pts = recovery.points
        let avg = mean(pts)
        // Charge world — the WHOOP recovery value scale (red→yellow→green) drawn as a crisp flat line
        // with a bright "now" cap. No glow.
        return ChartCard(
            title: "Charge",
            // The range bar above already prints the authoritative reading-count caption;
            // the hero only names its window so the count isn't doubled in one card height.
            subtitle: rangeSubtitle,
            trailing: avg.map { "\(Int($0.rounded()))" },
            height: NoopMetrics.chartHeight,
            tint: StrandPalette.chargeColor,
            chart: {
                if pts.count >= 2 {
                    glowChart(points: pts,
                              gradient: StrandPalette.recoveryGradient,
                              // Lift the ceiling ~6% so a near-100 peak and the now-cap halo
                              // clear the top gridline, matching the padded small multiples.
                              valueRange: 0...106,
                              tip: StrandPalette.chargeBright,
                              valueFormat: { "\(Int($0.rounded()))" },
                              accessibilityLabel: "Charge trend")
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack {
                        ChartFooter([
                            ("Avg", avg.map { "\(Int($0.rounded()))" } ?? "—"),
                            ("Peak", pts.map(\.value).max().map { "\(Int($0.rounded()))" } ?? "—"),
                            ("Low", pts.map(\.value).min().map { "\(Int($0.rounded()))" } ?? "—"),
                            ("Days", "\(pts.count)"),
                        ])
                        changeChip(pts, higherIsBetter: true, fmt: { "\(Int($0.rounded()))" })
                    }
                }
            }
        )
    }

    // MARK: Small multiples — HRV / Resting HR / Day Strain

    private func smallMultiples(hrv: ResolvedMetric, rhr: ResolvedMetric, strain: ResolvedMetric) -> some View {
        let cols = [GridItem(.adaptive(minimum: 320), spacing: NoopMetrics.gap)]
        let hrvPts = hrv.points
        let rhrPts = rhr.points
        let strainPts = strain.points

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // No trailing window label — the range bar's overline already states it.
            SectionHeader("Daily signals", overline: "Trends")
            LazyVGrid(columns: cols, alignment: .leading, spacing: NoopMetrics.gap) {
                // HRV / Resting HR are Charge sub-signals → the Charge (green) card world, each line
                // keeping its established metric hue for legibility. Effort is the WHOOP blue strain world.
                metricChart(
                    title: "Heart rate variability", unit: "ms",
                    accessibilityTitle: "Heart rate variability",
                    points: hrvPts,
                    gradient: gradient(StrandPalette.metricPurple),
                    tip: StrandPalette.metricPurple,
                    tint: StrandPalette.chargeColor,
                    higherIsBetter: true,
                    range: valueRange(hrvPts, fallback: 20...120),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    title: "Resting heart rate", unit: "bpm",
                    accessibilityTitle: "Resting heart rate",
                    points: rhrPts,
                    gradient: gradient(StrandPalette.metricRose),
                    tip: StrandPalette.metricRose,
                    tint: StrandPalette.chargeColor,
                    higherIsBetter: false,
                    range: valueRange(rhrPts, fallback: 40...80),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    // Plotted points + range stay on the stored 0–100 scale (line shape unchanged); only the
                    // displayed numbers + unit follow the Effort-scale toggle, converted inside `fmt`. (#268)
                    title: "Effort", unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                    accessibilityTitle: "Effort",
                    points: strainPts,
                    // WHOOP: Effort/Strain is always BLUE — a deep→bright blue line, not the amber ramp.
                    gradient: gradient(StrandPalette.effortColor),
                    tip: StrandPalette.effortColor,
                    tint: StrandPalette.effortColor,
                    higherIsBetter: nil,
                    range: valueRange(strainPts, fallback: 0...100),
                    fmt: { UnitFormatter.effortDisplay($0, scale: effortScale) }
                )
            }
        }
    }

    @ViewBuilder
    private func metricChart(
        title: LocalizedStringKey, unit: String,
        // Plain-string series name for VoiceOver (the `title` is a LocalizedStringKey and can't be
        // re-read as a String); supplied by callers so the line announces e.g. "HRV trend".
        accessibilityTitle: String,
        points pts: [TrendPoint],
        subtitle: String? = nil,
        gradient: Gradient,
        tip: Color,
        tint: Color,
        higherIsBetter: Bool?,
        range: ClosedRange<Double>,
        fmt: @escaping (Double) -> String
    ) -> some View {
        let avg = mean(pts)
        ChartCard(
            title: title,
            subtitle: subtitle,
            trailing: avg.map(fmt),
            height: NoopMetrics.chartHeight,
            tint: tint,
            chart: {
                if pts.count >= 2 {
                    glowChart(points: pts, gradient: gradient, valueRange: range,
                              tip: tip, valueFormat: { "\(fmt($0)) \(unit)" },
                              accessibilityLabel: "\(accessibilityTitle) trend")
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                HStack {
                    ChartFooter([
                        // Plain "MEAN" to match the bare MIN/MAX columns; the unit moves into
                        // the value (e.g. "58 ms") so uppercasing can't render a shouty "MEAN MS".
                        ("Mean", avg.map { "\(fmt($0)) \(unit)" } ?? "—"),
                        ("Min", pts.map(\.value).min().map(fmt) ?? "—"),
                        ("Max", pts.map(\.value).max().map(fmt) ?? "—"),
                    ])
                    changeChip(pts, higherIsBetter: higherIsBetter, fmt: fmt)
                }
            }
        )
    }

    // MARK: Year heat-strip

    private var yearStrip: some View {
        // Always show at least a full year for context; expand to all history on ALL.
        let stripDays = max(range.days ?? repo.days.count, 365)
        let recent = repo.days.suffix(stripDays)
        let recoveryDays: [RecoveryDay] = recent.compactMap { d in
            guard let dt = date(d.day) else { return nil }
            return RecoveryDay(date: dt, score: d.recovery)
        }
        let title = (range == .all && repo.days.count > 365) ? "Charge — all history" : "Charge — past year"
        return NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("\(title)", overline: "Calendar", trailing: "\(recoveryDays.filter { $0.score != nil }.count) days")
                if recoveryDays.isEmpty {
                    sparsePlaceholder.frame(height: 120)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        YearHeatStrip(days: recoveryDays).padding(.vertical, NoopMetrics.space1 / 2)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    legend
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space2) {
            Text("Depleted").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                .frame(width: 120, height: 8)
                .clipShape(Capsule())
            Text("Peaked").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
        }
    }

    // MARK: Shared bits

    /// Single-color gradient (for metric lines that aren't a value ramp).
    private func gradient(_ color: Color) -> Gradient {
        Gradient(stops: [
            .init(color: color.opacity(0.55), location: 0.0),
            .init(color: color, location: 1.0),
        ])
    }

    /// A domain-tinted `TrendChart` with a crisp flat line and a bright end-cap dot at the latest
    /// point. WHOOP-flat: no underglow blur layer — the single crisp line carries the data and the
    /// fill contrast does the rest. The "now" end-cap is a small dot pinned to the final sample.
    /// Pure presentation: it forwards every value to the locked `TrendChart` unchanged.
    @ViewBuilder
    private func glowChart(points pts: [TrendPoint], gradient: Gradient, valueRange: ClosedRange<Double>,
                           tip: Color, valueFormat: @escaping (Double) -> String,
                           accessibilityLabel: String) -> some View {
        // One crisp, interactive line + area — flat, no blurred glow copy underneath (WHOOP language).
        // The "now" end-cap is drawn INSIDE this chart (nowCapColor) so it's mapped by the chart's own
        // scales and lands on the line — the previous sibling overlay guessed the plot insets and
        // floated the dot left/below the curve (#458).
        TrendChart(points: pts, gradient: gradient, valueRange: valueRange,
                   showsArea: true, height: NoopMetrics.chartHeight, valueFormat: valueFormat,
                   accessibilityLabel: accessibilityLabel, nowCapColor: tip)
    }

    private var sparsePlaceholder: some View {
        Text("Not enough data for this window.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
