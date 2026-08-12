import SwiftUI
import Foundation
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Compare
//
// The "overlay metrics & draw conclusions" screen. Pick 2–4 metrics from the
// catalog, choose a time window, and read them on a single normalized overlay
// chart (each metric min–max scaled to 0–1 within the window so different units
// share an axis). Below, every pair of selected metrics gets a live Pearson-r
// correlation readout with a plain-English conclusion. Pure read-side: each
// metric loads from repo.resolvedSeries (freshest-wins across imported / NOOP-computed /
// compatible Apple Health, PR#196); everything else is derived in-view.

// yyyy-MM-dd → Date, fixed UTC / en_US_POSIX (per task spec).
private let compareDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseCompareDay(_ day: String) -> Date? { compareDayParser.date(from: day) }

// MARK: - Range control (shared spec — W / M / 3M / 6M / 1Y / ALL)

/// The canonical Strand range window. `days == nil` means ALL of history.
enum CompareRange: String, CaseIterable, Identifiable {
    case week, month, quarter, half, year, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .week:    return String(localized: "W")
        case .month:   return String(localized: "M")
        case .quarter: return String(localized: "3M")
        case .half:    return String(localized: "6M")
        case .year:    return String(localized: "1Y")
        case .all:     return String(localized: "ALL")
        }
    }

    /// The trailing window length in days; nil = everything.
    var days: Int? {
        switch self {
        case .week:    return 7
        case .month:   return 30
        case .quarter: return 90
        case .half:    return 180
        case .year:    return 365
        case .all:     return nil
        }
    }

    /// A human phrase for sentences ("over 1Y").
    var phrase: String {
        switch self {
        case .week:    return String(localized: "the last 7 days")
        case .month:   return String(localized: "30 days")
        case .quarter: return String(localized: "3 months")
        case .half:    return String(localized: "6 months")
        case .year:    return String(localized: "1 year")
        case .all:     return String(localized: "all history")
        }
    }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when a selected window holds zero points for a series.
    var widening: [CompareRange] {
        let order: [CompareRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

// MARK: - Per-series model

/// One selected metric, resolved over the active window: its descriptor, the
/// windowed (day,value) rows, a stable display color, and its real min/max.
private struct CompareSeries: Identifiable {
    let metric: MetricDescriptor
    let color: Color
    let rows: [(day: String, value: Double)]

    /// Real min/max over the window, computed ONCE at construction. As computed vars
    /// these re-scanned every row per access, which put an O(rows) cost inside every
    /// `normalized()` call (so building the overlay's plot points was O(rows squared))
    /// and inside the per-frame hover read-outs.
    let realMin: Double
    let realMax: Double

    var id: String { metric.id }

    init(metric: MetricDescriptor, color: Color, rows: [(day: String, value: Double)]) {
        self.metric = metric
        self.color = color
        self.rows = rows
        let values = rows.map(\.value)
        self.realMin = values.min() ?? 0
        self.realMax = values.max() ?? 0
    }

    /// Min–max normalize a value into 0…1 within this series' window. Flat series
    /// (max == min) collapse to the mid-line so they still render.
    func normalized(_ v: Double) -> Double {
        let lo = realMin, hi = realMax
        guard hi > lo else { return 0.5 }
        return min(max((v - lo) / (hi - lo), 0), 1)
    }
}

// MARK: - Root

struct CompareView: View {
    @EnvironmentObject var repo: Repository

    // Effort display scale (#268) — routes the Effort metric's min/max + hover read-outs onto WHOOP's
    // 0–21 axis; display-only, the normalized overlay shape is untouched. Every other metric is
    // scale-agnostic (see MetricDescriptor.format).
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // Distinct, high-legibility series colors (avoid the recovery/strain ramps so
    // overlay lines read as categorical, not as a value gradient).
    private static let seriesPalette: [Color] = [
        StrandPalette.accent,        // mint-green
        StrandPalette.metricCyan,    // cyan
        StrandPalette.metricPurple,  // purple
        StrandPalette.metricAmber,   // amber
    ]

    /// Default starter selection (falls back gracefully if a key is missing).
    private static let defaultKeys = ["recovery", "sleep_performance", "weight"]

    // #358 parity (Android ComparePrefs): the time window + the ordered metric selection persist across
    // visits — a UI preference, not `.noopbak` data. Selection is stored as comma-joined descriptor ids
    // ("source:key"). Both are restored PRE-render (window straight off @AppStorage, selection via a
    // static initial value), so Compare opens directly on the saved state — matching Android, with no
    // default-then-restore flash.
    @AppStorage("compare.rangeRaw") private var savedRangeRaw = CompareRange.year.rawValue
    @AppStorage("compare.selectedIds") private var savedSelectedIds = ""

    /// The active window, backed directly by @AppStorage so it is the persisted value from the first
    /// frame. Read-only; writes go through `rangeBinding`.
    private var range: CompareRange { CompareRange(rawValue: savedRangeRaw) ?? .year }
    private var rangeBinding: Binding<CompareRange> {
        Binding(get: { CompareRange(rawValue: savedRangeRaw) ?? .year },
                set: { savedRangeRaw = $0.rawValue })
    }

    /// Ordered selection (max 4). Pre-populated from the persisted ids (else the defaults) at creation,
    /// so it renders the saved selection immediately. Drives both the legend order and color mapping.
    @State private var selected: [MetricDescriptor] = CompareView.initialSelection()
    /// Full-history series per selected metric id (ascending by day).
    @State private var fullSeries: [String: [(day: String, value: Double)]] = [:]
    @State private var loadedOnce = false

    /// Cache of the last pairwise-correlation scan + the inputs it was computed for.
    /// The scan (alignByDay + Pearson over full windows) is expensive and was re-run on
    /// every body evaluation — including hover/animation/HR ticks. We recompute it only
    /// when the windowed series content actually changes (see `correlationKey`).
    @State private var pairCache: [PairResult] = []
    @State private var pairCacheKey: String = ""

    private let maxSelection = 4
    private let minSelection = 2
    private var loadTaskID: String { "\(selectionKey)|\(repo.refreshSeq)" }

    var body: some View {
        ScreenScaffold(title: "Compare", subtitle: "Overlay signals, draw conclusions.",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack; no staggered
                       // reveals, and the only GeometryReaders are chart-local (.chartOverlay plot rects),
                       // so nothing depends on eager layout of the scroll column.
                       lazy: true,
                       // Liquid finish: the day-of-sky backdrop carries the liquid atmosphere across the
                       // analysis tabs, exactly like Today and the batch-1 screens.
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                metricSection

                if selected.count < minSelection {
                    ComingSoon(what: "Compare needs at least two metrics with history. Import your WHOOP export in Data Sources first.")
                } else {
                    let series = activeSeries
                    if series.allSatisfy({ $0.rows.isEmpty }) {
                        ComingSoon(what: loadedOnce
                            ? "No data for these metrics in \(range.phrase). Widen the range or pick metrics you've logged."
                            : "Reading your history…")
                    } else {
                        overlaySection(series)
                        correlationSection(series)
                    }
                }
            }
        }
        .task(id: loadTaskID) {
            await loadSelected()
            refreshPairCache(activeSeries)
        }
        // Recompute the pairwise scan only when the windowed series content changes,
        // never on hover/animation/HR-tick re-renders that don't touch these inputs.
        .onChangeCompat(of: correlationKey(activeSeries)) { _ in
            refreshPairCache(activeSeries)
        }
    }

    // MARK: - Selection key (re-loads when the set of metrics changes)

    private var selectionKey: String { selected.map(\.id).sorted().joined(separator: "|") }

    // MARK: - Active windowed series

    /// A full-history series' rows over a given range, taken RELATIVE TO THAT SERIES'
    /// LATEST data point (not "now"); `.all` returns everything.
    private func slice(_ full: [(day: String, value: Double)], _ r: CompareRange) -> [(day: String, value: Double)] {
        guard let n = r.days else { return full }
        guard let lastDay = full.last?.day, let last = parseCompareDay(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return full.filter { row in
            guard let d = parseCompareDay(row.day) else { return false }
            return d >= cutoff
        }
    }

    /// The range actually used for a series: the SELECTED range when its window holds
    /// ≥1 point, else the smallest LARGER range that does. So sparse metrics still
    /// overlay against dense ones, and switching ranges stays visibly distinct.
    private func effectiveRange(_ full: [(day: String, value: Double)]) -> CompareRange {
        guard !full.isEmpty else { return range }
        for r in range.widening where !slice(full, r).isEmpty { return r }
        return .all
    }

    /// Selected metrics resolved to windowed rows + stable colors, in pick order.
    private var activeSeries: [CompareSeries] {
        selected.enumerated().map { idx, metric in
            let full = fullSeries[metric.id] ?? []
            let rows = slice(full, effectiveRange(full))
            return CompareSeries(
                metric: metric,
                color: Self.seriesPalette[idx % Self.seriesPalette.count],
                rows: rows
            )
        }
    }

    /// True if any selected series had to auto-widen past the selected range.
    private var anyWidened: Bool {
        selected.contains { metric in
            let full = fullSeries[metric.id] ?? []
            return !full.isEmpty && effectiveRange(full) != range
        }
    }

    /// How the overlay subtitle tells the user to read real (un-normalized) values.
    /// The chart axis is normalized, so the only readout of real numbers is the
    /// crosshair tooltip — driven by pointer hover on macOS, by tap/drag on iOS.
    private var inspectHint: String {
        #if os(iOS)
        return String(localized: "tap or drag for real values")
        #else
        return String(localized: "hover for real values")
        #endif
    }

    /// "N readings · <range>" caption near the control, flagging any auto-widen.
    /// Whole-phrase variants per count so translators see complete sentences.
    private var rangeCaption: String {
        let series = activeSeries
        let total = series.reduce(0) { $0 + $1.rows.count }
        if anyWidened {
            return total == 1
                ? String(localized: "1 reading across \(series.count) · \(range.phrase) · sparse widened")
                : String(localized: "\(total) readings across \(series.count) · \(range.phrase) · sparse widened")
        }
        return total == 1
            ? String(localized: "1 reading across \(series.count) · \(range.phrase)")
            : String(localized: "\(total) readings across \(series.count) · \(range.phrase)")
    }

    // MARK: - Loading

    /// The persisted selection (comma-joined descriptor ids) resolved against the catalog, else the
    /// defaults. Evaluated at view creation (the `selected` initial value) so Compare renders the saved
    /// selection on the first frame. Twin of the Android `ComparePrefs.readSelection`. The literals
    /// mirror `minSelection` / `maxSelection` below (a static initial value can't read instance members).
    static func initialSelection() -> [MetricDescriptor] {
        let raw = UserDefaults.standard.string(forKey: "compare.selectedIds") ?? ""
        return restoreSelection(raw, minSelection: 2, maxSelection: 4) ?? defaultSelection()
    }

    /// The default starter selection from `defaultKeys` (graceful when a key is missing).
    static func defaultSelection() -> [MetricDescriptor] {
        var picks: [MetricDescriptor] = []
        for key in defaultKeys {
            if let m = MetricCatalog.all.first(where: { $0.key == key }) { picks.append(m) }
        }
        if picks.isEmpty { picks = Array(MetricCatalog.all.prefix(2)) }
        return Array(picks.prefix(4))   // maxSelection
    }

    /// Restore a persisted Compare selection (comma-joined descriptor ids), or nil to fall back to the
    /// defaults. Twin of the Android `parseCompareSelection` (#358): resolve each id against the catalog,
    /// dedupe, cap at `maxSelection`; restore when EVERY saved id still resolves (so a deliberate
    /// sub-minimum selection is honored) OR at least `minSelection` survive — nil only when a catalog
    /// change dropped the saved ids below the minimum (the stale-selection case). Pure for testability.
    static func restoreSelection(_ raw: String, minSelection: Int, maxSelection: Int) -> [MetricDescriptor]? {
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var seen = Set<String>()
        var parsed: [MetricDescriptor] = []
        for id in tokens {
            guard seen.insert(id).inserted else { continue }   // first occurrence only (dedupe)
            if let m = MetricCatalog.all.first(where: { $0.id == id }) {
                parsed.append(m)
                if parsed.count == maxSelection { break }
            }
        }
        let uniqueSaved = Set(tokens).count
        return (parsed.count == uniqueSaved || parsed.count >= minSelection) ? parsed : nil
    }

    /// Persist the current selection as comma-joined descriptor ids (#358).
    private func persistSelection() {
        savedSelectedIds = selected.map(\.id).joined(separator: ",")
    }

    /// Load the full history for the selected metrics. Selection is capped at four,
    /// so a repository refresh can safely replace cached rows instead of leaving
    /// Compare on a stale pre-sync snapshot.
    private func loadSelected() async {
        for metric in selected {
            let s = await repo.resolvedSeries(key: metric.key, source: metric.source).values
            fullSeries[metric.id] = s
        }
        loadedOnce = true
    }

    // MARK: - Metric picker section (chips + range control)

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Metrics", overline: "Overlay 2-4 signals")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    // Responsive: range pills + the Add menu side-by-side when there's room, else
                    // stacked so the pills don't overflow/clip on a narrow window (ported from the iOS port).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center) {
                            SegmentedPillControl(CompareRange.allCases, selection: rangeBinding) { $0.label }
                                .accessibilityLabel("Time range")
                            Spacer()
                            addMenu
                        }
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            SegmentedPillControl(CompareRange.allCases, selection: rangeBinding) { $0.label }
                                .accessibilityLabel("Time range")
                            addMenu
                        }
                    }

                    if selected.count >= minSelection {
                        Text(rangeCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(anyWidened ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                            .accessibilityLabel(rangeCaption)
                    }

                    if selected.isEmpty {
                        Text("Nothing selected yet.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        FlowChips(metrics: selected, colorFor: colorFor) { metric in
                            remove(metric)
                        }
                    }
                }
            }
        }
    }

    /// Grouped "add metric" menu, sectioned by catalog category. Disables already-
    /// picked metrics and the whole control once the cap is reached.
    private var addMenu: some View {
        Menu {
            ForEach(MetricCatalog.categories, id: \.self) { category in
                let metrics = MetricCatalog.inCategory(category)
                if !metrics.isEmpty {
                    // Section title localized at the render site only; `category` stays the
                    // raw English identifier that `inCategory` filters on.
                    Section(MetricCatalog.categoryDisplayName(category)) {
                        ForEach(metrics) { metric in
                            let isOn = selected.contains(metric)
                            Button {
                                toggle(metric)
                            } label: {
                                Label(metric.title, systemImage: isOn ? "checkmark" : metric.icon)
                            }
                            .disabled(!isOn && selected.count >= maxSelection)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text(selected.count >= maxSelection ? "Max 4" : "Add metric")
                    .font(StrandFont.subhead)
            }
            .foregroundStyle(selected.count >= maxSelection ? StrandPalette.textTertiary : StrandPalette.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(selected.count >= maxSelection)
        .accessibilityLabel("Add a metric to compare")
    }

    private func colorFor(_ metric: MetricDescriptor) -> Color {
        guard let idx = selected.firstIndex(of: metric) else { return StrandPalette.textSecondary }
        return Self.seriesPalette[idx % Self.seriesPalette.count]
    }

    private func toggle(_ metric: MetricDescriptor) {
        if selected.contains(metric) {
            remove(metric)
        } else if selected.count < maxSelection {
            withAnimation(StrandMotion.gentle) { selected.append(metric) }
            persistSelection()   // #358
        }
    }

    private func remove(_ metric: MetricDescriptor) {
        withAnimation(StrandMotion.gentle) { selected.removeAll { $0 == metric } }
        persistSelection()   // #358
    }

    // MARK: - Overlay chart section (locked ChartCard)

    @ViewBuilder
    private func overlaySection(_ series: [CompareSeries]) -> some View {
        let nonEmpty = series.filter { !$0.rows.isEmpty }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Overlay", overline: "\(range.phrase)")
            ChartCard(
                title: "Normalized overlay",
                subtitle: anyWidened
                    ? String(localized: "Min-max normalized · sparse series widened past \(range.phrase) · \(inspectHint)")
                    : String(localized: "Each line min-max normalized within \(range.phrase) · \(inspectHint)"),
                trailing: String(localized: "\(nonEmpty.count) series"),
                // Anchor the overlay card to the brand-green chrome world; each line keeps its own
                // categorical series colour so the lines stay distinguishable against the wash.
                tint: StrandPalette.accent
            ) {
                // The overlay is min–max NORMALIZED 0–1, so the Effort scale never touches the line shape;
                // only the per-series hover read-outs convert (passed through to the tooltip). (#268)
                OverlayChart(series: nonEmpty, effortScale: effortScale, height: NoopMetrics.chartHeight)
            } footer: {
                legend(nonEmpty)
            }
        }
    }

    private func legend(_ series: [CompareSeries]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(series.enumerated()), id: \.element.id) { idx, s in
                HStack(spacing: 10) {
                    // A small liquid vessel posed at this series' LATEST value within its own min–max
                    // window (the same 0–1 position the overlay's "now" end-cap sits at) — the liquid
                    // accent tying the legend to the real series. Static, decorative (the min/max text
                    // + colour swatch carry the meaning for VoiceOver).
                    LiquidVessel(value: s.rows.last.map { s.normalized($0.value) },
                                 tint: s.color, animated: false)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(s.color)
                        .frame(width: 14, height: 3)
                    Text(s.metric.title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    // Real min/max labels honour the Effort scale (#268); other metrics are unchanged.
                    Text("\(s.metric.format(s.realMin, effortScale: effortScale))-\(s.metric.format(s.realMax, effortScale: effortScale))")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(s.metric.title), range \(s.metric.format(s.realMin, effortScale: effortScale)) to \(s.metric.format(s.realMax, effortScale: effortScale))")
                if idx < series.count - 1 {
                    Divider().overlay(StrandPalette.hairline)
                }
            }
        }
    }

    // MARK: - Pairwise correlations card

    private struct PairResult: Identifiable {
        let id: String
        let a: CompareSeries
        let b: CompareSeries
        let r: Double
        let n: Int
    }

    /// A stable fingerprint of the inputs the correlation scan depends on: the
    /// non-empty series (in order) and their windowed content. Row content only
    /// changes when `selected`, `range`, or fetched `fullSeries` change, so this
    /// covers every case that alters the scan result. Used to invalidate `pairCache`.
    private func correlationKey(_ series: [CompareSeries]) -> String {
        series
            .filter { !$0.rows.isEmpty }
            .map { s in "\(s.id):\(s.rows.count):\(s.rows.first?.day ?? "")>\(s.rows.last?.day ?? "")" }
            .joined(separator: "|")
    }

    /// Cached accessor used by the body. Returns the memoized scan when the inputs
    /// match `pairCacheKey`; otherwise computes once for THIS render (without mutating
    /// state — that would be illegal mid-body) so the visible result is never stale by
    /// a frame. The matching `.onChange`/`.task` then persists the same result into
    /// `@State`, so subsequent renders (hover/animation/HR ticks) hit the cache.
    private func pairResults(_ series: [CompareSeries]) -> [PairResult] {
        correlationKey(series) == pairCacheKey ? pairCache : computePairResults(series)
    }

    /// The actual (expensive) pairwise scan. Pure — no view state read/written.
    private func computePairResults(_ series: [CompareSeries]) -> [PairResult] {
        var out: [PairResult] = []
        let s = series.filter { !$0.rows.isEmpty }
        guard s.count >= 2 else { return out }
        for i in 0..<(s.count - 1) {
            for j in (i + 1)..<s.count {
                let pairs = CorrelationEngine.alignByDay(s[i].rows, s[j].rows)
                guard pairs.count >= 3, let c = CorrelationEngine.pearson(pairs) else { continue }
                out.append(PairResult(
                    id: "\(s[i].id)~\(s[j].id)",
                    a: s[i], b: s[j], r: c.r, n: c.n
                ))
            }
        }
        // Strongest relationships first.
        out.sort { abs($0.r) > abs($1.r) }
        return out
    }

    /// Recompute the pair cache if (and only if) the correlation inputs changed.
    private func refreshPairCache(_ series: [CompareSeries]) {
        let key = correlationKey(series)
        guard key != pairCacheKey else { return }
        pairCacheKey = key
        pairCache = computePairResults(series)
    }

    @ViewBuilder
    private func correlationSection(_ series: [CompareSeries]) -> some View {
        let pairs = pairResults(series)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How They Move Together",
                          overline: "Pearson r · \(range.phrase)",
                          trailing: pairs.isEmpty ? nil
                                    : (pairs.count == 1 ? String(localized: "1 pair")
                                                        : String(localized: "\(pairs.count) pairs")))

            if pairs.isEmpty {
                NoopCard {
                    Text("Not enough overlapping days between these metrics in \(range.phrase). Widen the range.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(pairs) { p in
                    pairCard(p)
                }
            }
        }
    }

    /// One pairwise correlation as its own NoopCard.
    private func pairCard(_ p: PairResult) -> some View {
        let tint = correlationColor(p.r)
        // Frosted card washed by the relationship's own colour (green positive / rose negative), with a
        // TrendChip surfacing the signed direction at a glance — the Today delta idiom, applied to r.
        return NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // A small liquid vessel filled to the correlation STRENGTH (|r|, a neutral 0–1
                    // magnitude — not a health value), tinted by the relationship's own colour. Static
                    // (posed) so a page of pair cards costs one cached frame each, matching Today's small
                    // vessels. Decorative — the r read-out + sentence carry the meaning for VoiceOver.
                    LiquidVessel(value: min(abs(p.r), 1), tint: tint, animated: false)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    // Two color swatches for the pair.
                    HStack(spacing: 3) {
                        Circle().fill(p.a.color).frame(width: 8, height: 8)
                        Circle().fill(p.b.color).frame(width: 8, height: 8)
                    }
                    Text("\(p.a.metric.title) ↔ \(p.b.metric.title)")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    TrendChip(text: signedR(p.r), color: tint)
                    Text("r = \(signedR(p.r))")
                        .font(StrandFont.number(18))
                        .foregroundStyle(tint)
                }

                Text(insightSentence(p))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The strength magnitude drawn as a liquid tube — the horizontal progress idiom Today
                // uses for its key-metric fills, here reading |r| from none (0) to a perfect link (1).
                LiquidTube(frac: min(abs(p.r), 1), tint: tint, height: 8, animated: false)
                    .accessibilityHidden(true)

                Text("\(p.n) overlapping days · \(strengthWord(p.r)) \(directionWord(p.r)) correlation")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.a.metric.title) versus \(p.b.metric.title), r equals \(String(format: "%.2f", p.r)), \(p.n) days")
    }

    // MARK: - Insight language

    /// "Weight ↔ Recovery: r = −0.34 (moderate negative) over 1Y" + a plain-English
    /// conclusion when |r| is notable.
    private func insightSentence(_ p: PairResult) -> String {
        let head = String(localized: "\(p.a.metric.title) ↔ \(p.b.metric.title): r = \(signedR(p.r)) (\(strengthWord(p.r)) \(directionWord(p.r))) over \(p.n) shared days.")
        guard abs(p.r) >= 0.3 else {
            return String(localized: "\(head) No clear relationship. They move largely independently.")
        }
        let aT = p.a.metric.title.lowercased()
        let bT = p.b.metric.title.lowercased()
        // Whole-phrase variants per direction so translators never see a stitched verb fragment.
        return p.r < 0
            ? String(localized: "\(head) When \(aT) rises, \(bT) tends to fall, a \(strengthWord(p.r)) \(directionWord(p.r)) link.")
            : String(localized: "\(head) When \(aT) rises, \(bT) tends to rise, a \(strengthWord(p.r)) \(directionWord(p.r)) link.")
    }

    private func signedR(_ r: Double) -> String {
        (r >= 0 ? "+" : "−") + String(format: "%.2f", abs(r))
    }

    private func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return String(localized: "negligible")
        case ..<0.3:  return String(localized: "weak")
        case ..<0.5:  return String(localized: "moderate")
        case ..<0.7:  return String(localized: "strong")
        default:      return String(localized: "very strong")
        }
    }

    private func directionWord(_ r: Double) -> String {
        if abs(r) < 0.1 { return "" }
        return r >= 0 ? String(localized: "positive") : String(localized: "negative")
    }

    private func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - Selected-metric chips (wrapping flow layout)

/// Removable chips for the active selection, tinted to each series' color.
private struct FlowChips: View {
    let metrics: [MetricDescriptor]
    let colorFor: (MetricDescriptor) -> Color
    let onRemove: (MetricDescriptor) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(metrics) { metric in
                let color = colorFor(metric)
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(metric.title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        onRemove(metric)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(metric.title)")
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous).fill(StrandPalette.surfaceOverlay)
                )
                .overlay(
                    Capsule(style: .continuous).stroke(color.opacity(0.4), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Overlay chart (custom multi-line Swift Chart, normalized 0–1)

/// Draws each series as its own colored line on a shared 0…1 normalized y-axis.
/// Hovering reveals a crosshair plus a tooltip listing every series' REAL value on
/// the nearest day.
private struct OverlayChart: View {
    let series: [CompareSeries]
    /// Effort display scale (#268) — passed through to the hover tooltip's real-value read-outs. The
    /// plotted points stay min–max normalized 0–1, so the line shape is unaffected.
    var effortScale: EffortScale = .hundred
    var height: CGFloat = 260

    @State private var hoverX: CGFloat? = nil

    /// Cache of the derived chart model + the series fingerprint it was built for.
    /// `hoverX` is `@State` here, so every pointer move re-evaluates `body`; before
    /// this cache each hover frame re-ran the full flatten + normalize + date-parse
    /// + sort work over every row of every series. Mirrors the `pairCache` idiom
    /// CompareView already uses for its correlation scan.
    @State private var modelCache: Model = .empty
    @State private var modelCacheKey: String = ""

    // A flat, plottable point: the series title (drives the categorical color
    // scale), the date, and the min–max normalized y.
    private struct Plot: Identifiable {
        // Stable identity (one value per metric per day) so Chart can diff across renders instead
        // of treating every point as new on each hover tick — was `UUID()`, which forced full rebuilds.
        var id: String { title + "@" + String(date.timeIntervalSince1970) }
        let title: String
        let date: Date
        let norm: Double
    }

    /// Everything `body` derives from `series`, computed ONCE per data change instead
    /// of on every hover frame. Drawing (`plots`) is downsampled; every read-out path
    /// (hover index, tooltip values, end-caps) is built from the FULL-resolution rows.
    private struct Model {
        /// The plot points actually handed to the marks, per series: full resolution
        /// up to `markThreshold`, else min/max-bucketed toward `targetVertices`.
        /// DRAWING ONLY. The correlation cards never read this (they run on
        /// `CompareSeries.rows`), and neither do the hover read-outs below.
        let plots: [Plot]
        /// The latest normalized plot point of each series (the glowing "now" end-caps).
        let endCaps: [Plot]
        /// The union of all parseable days present, ascending, each pre-parsed to a
        /// `Date` once. The sorted index hover snapping binary-searches, replacing a
        /// linear min-scan that re-parsed every day string on every mouse move.
        let dayIndex: [(day: String, date: Date)]
        /// day -> (series id -> real value): O(1) crosshair-dot and tooltip lookups,
        /// replacing a per-frame linear `rows` scan per series.
        let valuesByDay: [String: [String: Double]]
        /// True when every series is sparse enough for its per-point marks to read as
        /// discrete readings. Dense series draw line-only.
        let showsPointMarks: Bool

        static let empty = Model(series: [])

        /// Same gate as TrendChart's dotted series: above 60 windowed points the dots
        /// are sub-pixel-dense and invisible but still cost the GPU a mark each.
        /// Because 60 < `markThreshold`, whenever marks ARE shown no series was
        /// downsampled, so every dot sits on a real full-resolution vertex.
        static let pointMarkGate = 60
        /// Above this many points per series the DRAWN line is downsampled; at or
        /// below it the series passes through untouched. Same constants as
        /// StrandDesign's `ChartDownsample` (TrendChart / OverviewHRChart), applied
        /// per overlaid series so bucketing never crosses a series boundary.
        static let markThreshold = 120
        static let targetVertices = 400

        init(series: [CompareSeries]) {
            var drawn: [Plot] = []
            var caps: [Plot] = []
            var byDay: [String: [String: Double]] = [:]
            var dateCache: [String: Date] = [:]
            var densest = 0

            for s in series {
                densest = max(densest, s.rows.count)
                var pts: [Plot] = []
                pts.reserveCapacity(s.rows.count)
                for row in s.rows {
                    byDay[row.day, default: [:]][s.id] = row.value
                    let d: Date
                    if let cached = dateCache[row.day] {
                        d = cached
                    } else if let parsed = parseCompareDay(row.day) {
                        dateCache[row.day] = parsed
                        d = parsed
                    } else {
                        continue // unparseable day: not plottable (as before)
                    }
                    pts.append(Plot(title: s.metric.title, date: d, norm: s.normalized(row.value)))
                }
                if let row = s.rows.last, let d = dateCache[row.day] ?? parseCompareDay(row.day) {
                    caps.append(Plot(title: s.metric.title, date: d, norm: s.normalized(row.value)))
                }
                drawn.append(contentsOf: Model.minMaxBucketed(pts))
            }

            plots = drawn
            endCaps = caps
            valuesByDay = byDay
            dayIndex = dateCache.map { (day: $0.key, date: $0.value) }.sorted { $0.date < $1.date }
            showsPointMarks = densest <= Model.pointMarkGate
        }

        /// Min/max-per-bucket downsample of ONE series' plot points, mirroring
        /// `ChartDownsample.minMaxBucketed` in StrandDesign: each interior bucket
        /// contributes its lowest and highest sample in time order, so every visible
        /// peak and trough survives and the line silhouette is unchanged at normal
        /// chart widths; first and last points are always kept. Pure + deterministic.
        static func minMaxBucketed(_ points: [Plot]) -> [Plot] {
            let n = points.count
            guard n > markThreshold, n > 2 else { return points }

            // Reserve the first and last; bucket the interior. Each bucket yields up
            // to 2 vertices (min+max), so aim for ~targetVertices/2 buckets.
            let first = points[0]
            let last = points[n - 1]
            let interior = n - 2
            let bucketCount = max(1, (targetVertices - 2) / 2)
            guard bucketCount < interior else { return points }

            var out: [Plot] = []
            out.reserveCapacity(targetVertices)
            out.append(first)

            var lastEmittedDate = first.date
            for b in 0..<bucketCount {
                // Interior indices [1 ... n-2] split into `bucketCount` contiguous ranges.
                let lo = 1 + (b * interior) / bucketCount
                let hi = 1 + ((b + 1) * interior) / bucketCount // exclusive
                guard lo < hi else { continue }

                var minIdx = lo, maxIdx = lo
                var i = lo + 1
                while i < hi {
                    if points[i].norm < points[minIdx].norm { minIdx = i }
                    if points[i].norm > points[maxIdx].norm { maxIdx = i }
                    i += 1
                }

                // Emit the two extremes in chronological order, skipping duplicates
                // (monotone bucket yields one point) and any whose date would not
                // advance (keeps the day-keyed `Plot.id` unique for Chart's diffing).
                let lowFirst = minIdx <= maxIdx
                let aIdx = lowFirst ? minIdx : maxIdx
                let bIdx = lowFirst ? maxIdx : minIdx
                for idx in [aIdx, bIdx] where points[idx].date > lastEmittedDate {
                    out.append(points[idx])
                    lastEmittedDate = points[idx].date
                }
            }

            if last.date > lastEmittedDate { out.append(last) }
            return out
        }
    }

    /// Fingerprint of the model's inputs, same idiom as `CompareView.correlationKey`:
    /// series id + windowed row count + endpoint days. Row content only changes when
    /// the selection, range, or fetched history changes, so this covers every input.
    private var modelKey: String {
        series
            .map { s in "\(s.id):\(s.rows.count):\(s.rows.first?.day ?? "")>\(s.rows.last?.day ?? "")" }
            .joined(separator: "|")
    }

    /// Cached accessor used by `body`. Mirrors `CompareView.pairResults`: returns the
    /// memoized model when the inputs match, else computes for THIS render (without
    /// mutating state mid-body); the matching onAppear/onChange then persist it so
    /// subsequent hover frames hit the cache.
    private var currentModel: Model {
        modelKey == modelCacheKey ? modelCache : Model(series: series)
    }

    /// Rebuild the model cache if (and only if) the series content changed.
    private func refreshModel() {
        let key = modelKey
        guard key != modelCacheKey else { return }
        modelCacheKey = key
        modelCache = Model(series: series)
    }

    /// The series colour for a metric title — drives the matching "now" end-cap glow.
    private func colorFor(_ title: String) -> Color? {
        series.first(where: { $0.metric.title == title })?.color
    }

    var body: some View {
        let model = currentModel
        Chart(model.plots) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Normalized", p.norm)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(by: .value("Metric", p.title))

            // Per-point dots are only legible on sparse series; on a dense window they
            // overlap into the line while still costing a mark each (same gate as
            // TrendChart). The line carries the data past the gate.
            if model.showsPointMarks {
                PointMark(
                    x: .value("Date", p.date),
                    y: .value("Normalized", p.norm)
                )
                .symbolSize(10)
                .foregroundStyle(by: .value("Metric", p.title))
            }
        }
        // Bevel "now" end-caps — a soft halo + bright core on each series' latest point, drawn on top.
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ForEach(model.endCaps) { cap in
                    if let px = proxy.position(forX: cap.date),
                       let py = proxy.position(forY: cap.norm),
                       let color = colorFor(cap.title) {
                        ZStack {
                            Circle().fill(color.opacity(0.30)).frame(width: 16, height: 16)
                            Circle().fill(color.opacity(0.65)).frame(width: 10, height: 10)
                            Circle().fill(Color.white).frame(width: 4, height: 4)
                        }
                        .position(x: px + plot.minX, y: py + plot.minY)
                        .allowsHitTesting(false)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .chartForegroundStyleScale(range: series.map(\.color))
        .chartYScale(domain: 0...1)
        .chartYAxis {
            // Normalized axis — label endpoints as low/high rather than raw numbers.
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(d == 0 ? "low" : d == 1 ? "high" : "mid")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartLegend(.hidden) // legend rendered separately with real min/max
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    if let hx = hoverX,
                       let snap = nearestEntry(toX: hx, proxy: proxy, plot: plot, index: model.dayIndex),
                       let px = proxy.position(forX: snap.date) {
                        let cx = px + plot.minX
                        let dayValues = model.valuesByDay[snap.day] ?? [:]
                        // Vertical crosshair at the hovered day.
                        Rectangle()
                            .fill(StrandPalette.hairlineStrong)
                            .frame(width: 1, height: geo.size.height)
                            .position(x: cx, y: geo.size.height / 2)

                        // Dot on each series at this day (where it has a value).
                        ForEach(series) { s in
                            if let v = dayValues[s.id],
                               let py = proxy.position(forY: s.normalized(v)) {
                                Circle()
                                    .fill(s.color)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(StrandPalette.surfaceBase, lineWidth: 2))
                                    .position(x: cx, y: py + plot.minY)
                            }
                        }

                        MultiTooltip(
                            date: snap.date,
                            series: series,
                            values: dayValues,
                            effortScale: effortScale,
                            anchorX: cx,
                            container: geo.size
                        )
                    }
                }
                .animation(StrandMotion.fade, value: hoverX)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
                #if os(iOS)
                // Touch input never fires onContinuousHover (pointer-only), so on iPhone /
                // iPad-without-pointer the crosshair + value tooltip would be unreachable.
                // Drive the same hoverX via tap (single touch-down) and drag-to-scrub across
                // days. minimumDistance:0 keeps the first touch responsive; a clearly vertical
                // pan is still claimed by the parent ScrollView.
                .gesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { hoverX = $0.location.x }
                        .exclusively(before:
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { hoverX = $0.location.x }
                                .onEnded { _ in hoverX = nil }
                        )
                )
                #endif
            }
        }
        // Persist the model into @State so hover-frame body evals hit the cache
        // (currentModel already served THIS render the fresh value when the key missed).
        .onAppear { refreshModel() }
        .onChangeCompat(of: modelKey) { _ in refreshModel() }
        .frame(height: height)
    }

    /// Map a cursor x back to the nearest day present in the data: binary search over
    /// the model's pre-parsed, date-sorted index, then pick the closer neighbour.
    /// O(log days) per mouse move; ties snap to the earlier day, as the old scan did.
    private func nearestEntry(toX x: CGFloat, proxy: ChartProxy, plot: CGRect,
                              index: [(day: String, date: Date)]) -> (day: String, date: Date)? {
        guard !index.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }

        // Lower bound: first entry whose date is >= the cursor date.
        var lo = 0, hi = index.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if index[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return index[0] }
        if lo == index.count { return index[index.count - 1] }
        let before = index[lo - 1], after = index[lo]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }
}

// MARK: - Multi-series tooltip

/// A floating tooltip listing each series' REAL value on the hovered day, kept
/// inside the chart bounds.
private struct MultiTooltip: View {
    /// The hovered day, pre-parsed once by the chart's model (no per-frame parse).
    let date: Date
    let series: [CompareSeries]
    /// Real values on the hovered day keyed by series id, precomputed in the chart's
    /// model. Replaces a per-frame linear `rows` scan per series.
    let values: [String: Double]
    /// Effort display scale (#268) — the per-series real value converts onto WHOOP's 0–21 axis when set.
    var effortScale: EffortScale = .hundred
    let anchorX: CGFloat
    let container: CGSize

    /// Shared formatter; was rebuilt from scratch on every hover frame.
    private static let dateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        // Device locale (not en_US_POSIX) so the DISPLAYED weekday/month names translate — the crosshair
        // parser above still uses en_US_POSIX for stable yyyy-MM-dd parsing. Same pattern + device locale
        // as the Android twin so both localize consistently.
        f.locale = Locale.autoupdatingCurrent
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private var dateLabel: String { Self.dateLabelFormatter.string(from: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dateLabel)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(series) { s in
                HStack(spacing: 7) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.metric.title)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 12)
                    Text(values[s.id].map { s.metric.format($0, effortScale: effortScale) } ?? "—")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
        .padding(10)
        .background(NoopPanelSurface(cornerRadius: 10, elevated: true))
        .frame(width: tooltipWidth, alignment: .leading)
        .position(x: clampedX, y: tooltipHeight / 2 + 8)
        .allowsHitTesting(false)
    }

    private var tooltipWidth: CGFloat { 220 }
    private var tooltipHeight: CGFloat { CGFloat(24 + series.count * 18) }

    /// Keep the tooltip on the side of the crosshair with more room, clamped.
    private var clampedX: CGFloat {
        let half = tooltipWidth / 2
        let preferRight = anchorX < container.width / 2
        let target = preferRight ? anchorX + half + 14 : anchorX - half - 14
        return min(max(target, half + 4), container.width - half - 4)
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func comparePreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Compare") {
    CompareView()
        .environmentObject(comparePreviewRepo())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}
#endif
