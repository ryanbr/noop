import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Xiaomi Smart Band (Mi Band) — per-source page
//
// Mirrors AppleHealthView: ONE range control (SegmentedPillControl), a LazyVGrid of
// uniform StatTiles, then ChartCard sections. Everything reads from the "xiaomi-band"
// source — the data imported from the Mi Fitness app in Data Sources. ALL history is
// loaded once and the range control windows it client-side, RELATIVE TO THE LATEST data
// point (not "now"); a sparse series auto-widens to the smallest range that holds data.

/// Carries the measured chart-column width up to the view so decimation can target pixels.
private struct ChartWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct XiaomiBandView: View {
    @EnvironmentObject var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    /// Per-source partition key — matches `XiaomiImporter.deviceId`.
    private static let source = "xiaomi-band"

    @State private var loaded = false
    @State private var series: [String: [(day: String, value: Double)]] = [:]
    @State private var range: RangeWindow = .quarter
    @State private var windowCache: [String: ResolvedSeries] = [:]

    /// Measured chart-column width (points). Chart point counts are capped to the chart's pixel
    /// width — there's nothing to see in more line vertices than horizontal pixels.
    @State private var chartWidthPts: CGFloat = 320
    @Environment(\.displayScale) private var displayScale
    /// Imported Mi sleep sessions (carry the per-epoch hypnogram in `stagesJSON`).
    @State private var sleeps: [CachedSleepSession] = []

    private struct ResolvedSeries {
        var effective: RangeWindow
        var rows: [(day: String, value: Double)]
    }

    /// The metricSeries keys written by `XiaomiImporter`.
    private static let seriesKeys = [
        "steps", "distance_m", "energy_kcal", "intensity_min",
        "rhr", "avg_hr", "max_hr", "spo2",
        "sleep_total_min", "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "sleep_score",
        "stress", "vitality",
    ]

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let spanFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy"; return f
    }()
    private static let asOfFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM"; return f
    }()
    private static let groupedIntFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()

    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: - Range control (W / M / 3M / 6M / 1Y / ALL)

    enum RangeWindow: String, CaseIterable, Identifiable {
        case week, month, quarter, half, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week: return String(localized: "W"); case .month: return String(localized: "M"); case .quarter: return String(localized: "3M")
            case .half: return String(localized: "6M"); case .year: return String(localized: "1Y"); case .all: return String(localized: "ALL")
            }
        }
        var days: Int? {
            switch self {
            case .week: return 7; case .month: return 30; case .quarter: return 90
            case .half: return 180; case .year: return 365; case .all: return nil
            }
        }
        var caption: String {
            switch self {
            case .week: return String(localized: "7 DAYS"); case .month: return String(localized: "30 DAYS"); case .quarter: return String(localized: "90 DAYS")
            case .half: return String(localized: "180 DAYS"); case .year: return String(localized: "365 DAYS"); case .all: return String(localized: "ALL TIME")
            }
        }
        var name: String {
            switch self {
            case .week: return String(localized: "week"); case .month: return String(localized: "month"); case .quarter: return String(localized: "3 months")
            case .half: return String(localized: "6 months"); case .year: return String(localized: "year"); case .all: return String(localized: "all history")
            }
        }
        var widening: [RangeWindow] {
            let order: [RangeWindow] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    var body: some View {
        ScreenScaffold(title: "Mi Band", subtitle: spanSubtitle.map { "\($0)" },
                       onRefresh: { await repo.refresh() }, lazy: loaded && hasAnyData) {
            if loaded && !hasAnyData {
                ComingSoon(what: "Nothing imported yet. In Data Sources, choose your Mi Fitness export (a .zip of the Mi Fitness app folder from the Files app) to bring in your steps, heart rate, sleep stages, SpO₂ and stress.")
            } else if !loaded {
                loadingState
            } else {
                // Flat children (no wrapping VStack) so the scaffold's LazyVStack can defer each
                // off-screen chart card instead of building all ~15 at once.
                rangeControl
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ChartWidthKey.self, value: g.size.width)
                    })
                tileGrid
                ForEach(pageItems) { item in
                    switch item {
                    case .header(let title, let overline):
                        SectionHeader(title, overline: "\(overline)", trailing: range.caption)
                    case .chart(let title, let key, let gradient, let fallback, let fmt):
                        chartCard(title: title, key: key, gradient: gradient, fallback: fallback, fmt: fmt)
                    case .hypnogram:
                        sleepDetailSection   // lazily-built, positioned just before the Sleep charts
                    }
                }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .onChangeCompat(of: range) { _ in rebuildWindowCache() }
        .onPreferenceChange(ChartWidthKey.self) { w in if w > 1 { chartWidthPts = w } }
    }

    /// The page's chart cards as a flat, lazily-rendered list (headers interleaved). Modelled as
    /// data so the scaffold's `LazyVStack` + `ForEach` only build the cards actually on screen.
    private enum PageItem: Identifiable {
        case header(LocalizedStringKey, String)
        case chart(LocalizedStringKey, String, Gradient, ClosedRange<Double>, (Double) -> String)
        case hypnogram
        var id: String {
            switch self {
            case .header(_, let overline): return "h-\(overline)"
            case .chart(_, let key, _, _, _): return "c-\(key)"
            case .hypnogram: return "hypnogram"
            }
        }
    }

    private var pageItems: [PageItem] {
        [
            .header("Heart & Vitals", "Cardiac"),
            .chart("Resting heart rate", "rhr", roseGradient, 40...90, { "\(Int($0.rounded())) bpm" }),
            .chart("Average heart rate", "avg_hr", roseGradient, 50...110, { "\(Int($0.rounded())) bpm" }),
            .chart("Peak heart rate", "max_hr", roseGradient, 80...170, { "\(Int($0.rounded())) bpm" }),
            .chart("Blood oxygen", "spo2", cyanGradient, 90...100, { String(format: "%.0f%%", $0) }),
            .hypnogram,
            .header("Sleep", "Rest"),
            .chart("Time asleep", "sleep_total_min", purpleGradient, 240...600, { durationString($0) }),
            .chart("Deep sleep", "sleep_deep_min", purpleGradient, 0...180, { durationString($0) }),
            .chart("REM sleep", "sleep_rem_min", purpleGradient, 0...180, { durationString($0) }),
            .chart("Sleep score", "sleep_score", accentGradient, 0...100, { "\(Int($0.rounded()))" }),
            .header("Activity & Energy", "Movement"),
            .chart("Steps", "steps", cyanGradient, 0...12000, { intString($0) }),
            .chart("Distance", "distance_m", cyanGradient, 0...10000, {
                UnitFormatter.distanceFromMeters($0, system: distanceUnitSystem)
            }),
            .chart("Active energy", "energy_kcal", amberGradient, 0...1000, { "\(intString($0)) kcal" }),
            .chart("Intensity minutes", "intensity_min", amberGradient, 0...120, { "\(Int($0.rounded())) min" }),
            .header("Wellbeing", "Body energy"),
            .chart("Stress", "stress", amberGradient, 0...100, { "\(Int($0.rounded()))" }),
            .chart("Vitality", "vitality", accentGradient, 0...100, { "\(Int($0.rounded()))" }),
        ]
    }

    private func rebuildWindowCache() {
        var cache: [String: ResolvedSeries] = [:]
        cache.reserveCapacity(Self.seriesKeys.count)
        for key in Self.seriesKeys {
            let eff = computeEffectiveRange(key)
            cache[key] = ResolvedSeries(effective: eff, rows: slice(key, eff))
        }
        windowCache = cache
    }

    private var hasAnyData: Bool { series.values.contains { !$0.isEmpty } }

    // MARK: - Load

    private func load() async {
        var fetched: [String: [(day: String, value: Double)]] = [:]
        for key in Self.seriesKeys {
            fetched[key] = await repo.series(key: key, source: Self.source)
        }
        var loadedSleeps: [CachedSleepSession] = []
        if let store = await repo.storeHandle() {
            let far = Int(Date.distantFuture.timeIntervalSince1970)
            loadedSleeps = (try? await store.sleepSessions(deviceId: Self.source, from: 0, to: far, limit: 4000)) ?? []
        }
        await MainActor.run {
            series = fetched
            sleeps = loadedSleeps
            rebuildWindowCache()
            loaded = true
        }
    }

    // MARK: - Range control + header

    private var rangeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SegmentedPillControl(RangeWindow.allCases, selection: $range) { $0.label }
                Spacer()
                Text(range.caption).strandOverline()
            }
            Text(rangeSummaryCaption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var rangeSummaryCaption: String {
        let anyWidened = Self.seriesKeys.contains { !raw($0).isEmpty && effectiveRange($0) != range }
        let base = range.name
        return anyWidened ? String(localized: "\(base) · some sparse series widened") : base
    }

    private var spanSubtitle: String? {
        // The widest span across all loaded series — for the header.
        let allDays = series.values.flatMap { $0 }.map(\.day)
        guard let first = allDays.min(), let last = allDays.max(),
              let lo = date(first), let hi = date(last) else {
            return String(localized: "Steps, heart rate, sleep, SpO₂ and stress, imported from Mi Fitness, read locally on \(Platform.deviceNounPhrase).")
        }
        let loS = Self.spanFormatter.string(from: lo)
        let hiS = Self.spanFormatter.string(from: hi)
        return loS == hiS ? loS : "\(loS) → \(hiS)"
    }

    private var loadingState: some View {
        NoopCard(tint: StrandPalette.metricAmber) {
            HStack(spacing: 10) {
                ConnectionDot(tone: .accent, pulsing: true)
                Text("Reading your Mi Band history…")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Last sleep (hypnogram)

    /// The most recent imported night that carries a per-epoch hypnogram, drawn with the same
    /// `Hypnogram` component the WHOOP Sleep screen uses. Empty when no Mi sleep has stages.
    @ViewBuilder
    private var sleepDetailSection: some View {
        if let night = sleeps.last(where: { ($0.stagesJSON?.count ?? 0) > 2 }),
           let decoded = decodeStages(night.stagesJSON, sessionStart: night.startTs),
           decoded.intervals.count >= 2 {
            let s = decoded.stages
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last sleep", overline: "Hypnogram",
                              trailing: Self.nightFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(night.startTs))))
                ChartCard(
                    title: "Stage breakdown",
                    subtitle: night.efficiency.map { eff in
                        String(localized: "\(durationString(Double(night.endTs - night.startTs) / 60)) in bed · \(Int(eff.rounded()))% efficiency")
                    } ?? String(localized: "\(durationString(Double(night.endTs - night.startTs) / 60)) in bed"),
                    trailing: durationString(s.asleepMin),
                    height: NoopMetrics.chartHeight,
                    tint: StrandPalette.restColor,
                    chart: {
                        Hypnogram(intervals: decoded.intervals,
                                  height: NoopMetrics.chartHeight,
                                  showsStageAxis: true,
                                  nightStart: Date(timeIntervalSince1970: TimeInterval(night.startTs)),
                                  showsTimeAxis: true)
                    },
                    footer: {
                        ChartFooter([
                            ("REM", durationString(s.rem)),
                            ("Deep", durationString(s.deep)),
                            ("Light", durationString(s.light)),
                            ("Awake", durationString(s.awake)),
                        ])
                    })
            }
        }
    }

    private struct MiStages { var awake = 0.0; var light = 0.0; var deep = 0.0; var rem = 0.0
        var asleepMin: Double { light + deep + rem } }

    /// Reconstruct `[SleepInterval]` (seconds from onset) + stage totals from the verbatim
    /// `[{start,end,stage}]` hypnogram JSON the importer stores. Mirrors `SleepView.decodeSegments`.
    private func decodeStages(_ json: String?, sessionStart: Int) -> (stages: MiStages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !arr.isEmpty
        else { return nil }
        var stages = MiStages()
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let mins = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += mins
            case "light": stage = .light; stages.light += mins
            case "deep": stage = .deep; stages.deep += mins
            case "rem": stage = .rem; stages.rem += mins
            default: continue
            }
            intervals.append(SleepInterval(stage: stage,
                                           start: TimeInterval(start - sessionStart),
                                           end: TimeInterval(end - sessionStart)))
        }
        return stages.asleepMin > 0 ? (stages, intervals) : nil
    }

    private static let nightFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM"; return f
    }()

    // MARK: - Tiles

    private var tileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            statTile(key: "steps", label: "Steps", accent: StrandPalette.metricCyan, fmt: { intString($0) })
            statTile(key: "rhr", label: "Resting HR", accent: StrandPalette.metricRose, unit: "bpm",
                     fmt: { "\(Int($0.rounded()))" })
            statTile(key: "sleep_total_min", label: "Sleep avg", accent: StrandPalette.metricPurple,
                     aggregate: .mean, fmt: { durationString($0) })
            statTile(key: "sleep_score", label: "Sleep score", accent: StrandPalette.accent,
                     fmt: { "\(Int($0.rounded()))" })
            statTile(key: "spo2", label: "Blood oxygen", accent: StrandPalette.metricCyan, unit: "%",
                     fmt: { String(format: "%.0f", $0) })
            statTile(key: "stress", label: "Stress avg", accent: StrandPalette.metricAmber,
                     aggregate: .mean, fmt: { "\(Int($0.rounded()))" })
            statTile(key: "avg_hr", label: "Avg HR", accent: StrandPalette.metricRose, unit: "bpm",
                     aggregate: .mean, fmt: { "\(Int($0.rounded()))" })
            statTile(key: "vitality", label: "Vitality", accent: StrandPalette.accent,
                     fmt: { "\(Int($0.rounded()))" })
        }
    }

    private enum Aggregate { case latest, mean }

    private func statTile(key: String, label: LocalizedStringKey,
                          accent: Color, unit: String = "",
                          aggregate: Aggregate = .latest,
                          fmt: @escaping (Double) -> String) -> some View {
        let rows = resolvedWindow(key)
        let values = rows.map(\.value)
        let value: String
        let caption: String?
        if values.isEmpty {
            value = "—"; caption = nil
        } else {
            switch aggregate {
            case .latest:
                let v = values.last ?? 0
                value = unit.isEmpty ? fmt(v) : "\(fmt(v)) \(unit)"
                caption = rows.last.flatMap { date($0.day) }.map { String(localized: "as of \(Self.asOfFormatter.string(from: $0))") }
            case .mean:
                let m = mean(values) ?? 0
                value = unit.isEmpty ? fmt(m) : "\(fmt(m)) \(unit)"
                caption = String(localized: "avg · \(values.count)d")
            }
        }
        return StatTile(
            label: label, value: value, caption: caption,
            accent: values.isEmpty ? StrandPalette.textTertiary : accent,
            sparkline: values.count > 1 ? sparkValues(values) : nil,
            sparkColor: accent)
    }

    // MARK: - Chart card

    @ViewBuilder
    private func chartCard(title: LocalizedStringKey, key: String, gradient: Gradient,
                           fallback: ClosedRange<Double>,
                           fmt: @escaping (Double) -> String) -> some View {
        let rows = resolvedWindow(key)
        // Cap to the chart's pixel width — no value in more line vertices than horizontal pixels.
        let pixelTarget = max(64, Int(chartWidthPts * displayScale))
        let pts = decimate(trendPoints(rows), max: pixelTarget)
        let vals = rows.map(\.value)
        let trailing = mean(vals).map { fmt($0) }
        let footerItems: [(LocalizedStringKey, String)] = {
            guard let avg = mean(vals), let lo = vals.min(), let hi = vals.max() else {
                return [("Avg", "—"), ("Min", "—"), ("Max", "—"), ("Points", "0")]
            }
            return [("Avg", fmt(avg)), ("Min", fmt(lo)), ("Max", fmt(hi)), ("Points", "\(vals.count)")]
        }()
        ChartCard(
            title: title,
            subtitle: rangeNote(forKey: key),
            trailing: trailing,
            chart: {
                if pts.count >= 2 {
                    TrendChart(points: pts, gradient: gradient,
                               valueRange: valueRange(pts, fallback: fallback),
                               showsArea: true, height: NoopMetrics.chartHeight, valueFormat: fmt)
                } else if let only = vals.last {
                    singlePoint(only, fmt: fmt, accent: StrandPalette.sample(stops: gradient.stops, at: 0.85))
                } else {
                    emptyChart
                }
            },
            footer: { ChartFooter(footerItems) })
    }

    private func singlePoint(_ value: Double, fmt: (Double) -> String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latest reading").strandOverline()
            Text(fmt(value)).font(StrandFont.number(34)).foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emptyChart: some View {
        Text("No readings recorded.")
            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Gradients

    private var accentGradient: Gradient {
        Gradient(colors: [StrandPalette.accentMuted, StrandPalette.accent, StrandPalette.accentHover])
    }
    private var roseGradient: Gradient {
        Gradient(colors: [StrandPalette.statusWarning, StrandPalette.statusCritical])
    }
    private var cyanGradient: Gradient {
        Gradient(colors: [StrandPalette.metricCyan.opacity(0.55), StrandPalette.metricCyan])
    }
    private var amberGradient: Gradient {
        Gradient(colors: [StrandPalette.metricAmber.opacity(0.55), StrandPalette.metricAmber])
    }
    private var purpleGradient: Gradient {
        Gradient(colors: [StrandPalette.metricPurple.opacity(0.55), StrandPalette.metricPurple])
    }

    // MARK: - Series helpers (sparse-data fallback to ALL)

    private func raw(_ key: String) -> [(day: String, value: Double)] { series[key] ?? [] }

    private func latestDate(_ key: String) -> Date? {
        guard let d = raw(key).last?.day else { return nil }
        return date(d)
    }

    private func slice(_ key: String, _ r: RangeWindow) -> [(day: String, value: Double)] {
        let all = raw(key)
        guard let n = r.days else { return all }
        guard let last = latestDate(key) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return all.filter { row in
            guard let d = date(row.day) else { return false }
            return d >= cutoff
        }
    }

    private func effectiveRange(_ key: String) -> RangeWindow {
        windowCache[key]?.effective ?? computeEffectiveRange(key)
    }

    private func computeEffectiveRange(_ key: String) -> RangeWindow {
        guard !raw(key).isEmpty else { return range }
        for r in range.widening where !slice(key, r).isEmpty { return r }
        return .all
    }

    private func resolvedWindow(_ key: String) -> [(day: String, value: Double)] {
        if let cached = windowCache[key]?.rows { return cached }
        return slice(key, computeEffectiveRange(key))
    }

    private func rangeNote(forKey key: String) -> String {
        let rows = resolvedWindow(key)
        let eff = effectiveRange(key)
        let n = rows.count
        if eff != range {
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(eff.name)")
                : String(localized: "\(n) readings · sparse, widened to \(eff.name)")
        }
        return n == 1
            ? String(localized: "1 reading · \(range.name)")
            : String(localized: "\(n) readings · \(range.name)")
    }

    /// Cap a dense daily series to ~`max` points for charting. A year/all-time window holds
    /// hundreds of daily points per card; rendering every one across a dozen cards is what makes
    /// "1Y"/"ALL" feel slow. Min/max bucketing keeps the visual envelope (peaks + troughs) while
    /// cutting the point count, and always keeps the first/last sample. Stats (avg/min/max in the
    /// footer) are computed from the FULL series, so decimation is purely a render optimization.
    private func decimate(_ pts: [TrendPoint], max: Int) -> [TrendPoint] {
        guard pts.count > max, max >= 4 else { return pts }
        let bucketCount = max / 2                         // each bucket emits up to 2 points (min,max)
        let size = Double(pts.count) / Double(bucketCount)
        var out: [TrendPoint] = []
        out.reserveCapacity(max + 2)
        out.append(pts.first!)
        for b in 0..<bucketCount {
            let lo = Int(Double(b) * size)
            let hi = min(pts.count, Int(Double(b + 1) * size))
            guard lo < hi else { continue }
            let slice = pts[lo..<hi]
            guard let mn = slice.min(by: { $0.value < $1.value }),
                  let mx = slice.max(by: { $0.value < $1.value }) else { continue }
            // Emit in time order so the line doesn't zig-zag backwards.
            if mn.date <= mx.date { out.append(mn); if mx.date != mn.date { out.append(mx) } }
            else { out.append(mx); out.append(mn) }
        }
        out.append(pts.last!)
        return out
    }

    private func trendPoints(_ rows: [(day: String, value: Double)]) -> [TrendPoint] {
        rows.compactMap { row in
            guard let dt = date(row.day) else { return nil }
            return TrendPoint(date: dt, value: row.value)
        }
    }

    private func sparkValues(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return [values.first ?? 0, values.first ?? 0] }
        return Array(values.suffix(40))
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        let v = pts.map(\.value)
        guard let lo = v.min(), let hi = v.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private func intString(_ v: Double) -> String {
        let n = Int(v.rounded())
        if abs(n) >= 1000 { return Self.groupedIntFmt.string(from: NSNumber(value: n)) ?? "\(n)" }
        return "\(n)"
    }

    private func durationString(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        return h > 0 ? String(localized: "\(h)h \(m)m") : String(localized: "\(m)m")
    }
}
