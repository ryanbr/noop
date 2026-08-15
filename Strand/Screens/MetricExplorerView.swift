import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Explore (Metric Explorer + Detail)
//
// The catalog-driven "Explore" surface. The root is a grouped list — one
// SectionHeader per MetricCatalog.category, then a row per metric — pushing a
// MetricDetailView. The detail is a uniform analytic dossier built ONLY from the
// locked StrandDesign components (NoopCard / ChartCard / StatTile / InsightCard /
// SegmentedPillControl). No custom card heights, paddings, or surfaces anywhere.
//
// Sparse-metric rule (owner saw "no data" on metrics that HAVE data): a series may
// be sampled weekly (weight / body fat). The window is taken RELATIVE TO THE LATEST
// data point — not "now" — so a stale-but-present series still resolves. If the
// selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay visibly
// distinct); only when it holds ZERO points do we auto-expand to the smallest larger
// range that does. The hero always shows the latest available point + "as of <date>".

// yyyy-MM-dd → Date, fixed UTC / en_US_POSIX (per task spec).
private let strandDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseDay(_ day: String) -> Date? { strandDayParser.date(from: day) }

/// "9 Jun 2026" — long, locale-stable date for the hero "as of" line.
private func longDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}

/// The category accent (colour communicates category only — never decoration).
private func metricAccent(_ m: MetricDescriptor) -> Color {
    switch m.key {
    case "recovery", "sleep_performance", "hours_vs_needed_pct", "sleep_consistency",
         "restorative_pct", "restorative_min", "sleep_efficiency", "sleep_total_min",
         "sleep_deep_min", "sleep_rem_min":
        return StrandPalette.accent
    case "strain", "hr_zones45_min", "hr_zones_all_min", "strength_min", "hr_zones13_min":
        return StrandPalette.strainColor(14)              // mid-strain hue
    case "hrv", "vo2max", "lean_mass":
        return StrandPalette.metricPurple
    case "rhr", "stress", "sleep_debt_min", "body_fat", "max_hr":
        return StrandPalette.metricRose
    case "spo2", "steps":
        return StrandPalette.metricCyan
    case "energy_kcal", "active_kcal":
        return StrandPalette.metricAmber
    default:
        switch m.source {
        case "apple-health": return StrandPalette.metricCyan
        case "xiaomi-band":  return StrandPalette.metricAmber
        default:             return StrandPalette.textPrimary
        }
    }
}

/// The gradient for a metric's trend line — strain/recovery ride their data scales;
/// everything else uses a flat tint of its category accent.
private func metricGradient(_ m: MetricDescriptor) -> Gradient {
    if m.category == "Effort" { return StrandPalette.strainGradient }
    if m.key == "recovery" { return StrandPalette.recoveryGradient }
    let c = metricAccent(m)
    return Gradient(colors: [c.opacity(0.55), c])
}

/// The Bevel colour world a metric's detail hero belongs to — the catalog's category
/// already names it (Charge / Rest / Effort), and Heart/Health/Nutrition/Mind metrics
/// fall back to the world that best fits their accent. Drives the ScenicHeroBackground
/// tint + the hero gauge/number glow.
private func metricDomain(_ m: MetricDescriptor) -> DomainTheme {
    switch m.category {
    case "Charge":            return .charge
    case "Effort":            return .effort
    case "Rest", "Mind":      return .rest
    default:
        // Heart / Health / Nutrition: lean on the metric's own world. RHR-style risk
        // metrics read as Stress (teal); everything else rides the Charge green chrome.
        switch m.key {
        case "rhr", "max_hr", "stress", "body_fat": return .stress
        default:                                    return .charge
        }
    }
}

/// A 0–100 score that reads naturally as a layered ring gauge in the hero (vs a bare
/// headline number). Recovery / Rest / Blood-oxygen sit on a clean 0–100 axis.
private func metricGaugeFraction(_ m: MetricDescriptor, value: Double) -> Double? {
    switch m.key {
    case "recovery", "sleep_performance", "spo2", "hours_vs_needed_pct",
         "sleep_consistency", "restorative_pct", "sleep_efficiency":
        return min(max(value / 100.0, 0), 1)
    default:
        return nil
    }
}

// MARK: - Range

/// The W/2W/3W/M/3M/6M/1Y/ALL window, driving the single SegmentedPillControl.
enum ExploreRange: Int, CaseIterable, Identifiable, Hashable {
    case week = 7, twoWeeks = 14, threeWeeks = 21, month = 30, quarter = 90, half = 180, year = 365, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .twoWeeks: return String(localized: "2W"); case .threeWeeks: return String(localized: "3W")
        case .week: return String(localized: "W"); case .month: return String(localized: "M"); case .quarter: return String(localized: "3M")
        case .half: return String(localized: "6M"); case .year: return String(localized: "1Y"); case .all: return String(localized: "ALL")
        }
    }
    var name: String {
        switch self {
        case .twoWeeks: return String(localized: "2 weeks"); case .threeWeeks: return String(localized: "3 weeks")
        case .week: return String(localized: "week"); case .month: return String(localized: "month"); case .quarter: return String(localized: "quarter")
        case .half: return String(localized: "6 months"); case .year: return String(localized: "year"); case .all: return String(localized: "all time")
        }
    }
    /// Trailing days the window spans (nil = everything).
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when the selected window holds zero points. ALW always terminates the chain.
    var widening: [ExploreRange] {
        let order: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

/// Pure #943 chip-coercion rule, extracted so it can be pinned by a test (the Swift twin of Android's
/// `coercedVitalRange` in HealthScreen.kt). Resolves a stored selection NON-DESTRUCTIVELY: an unlocked
/// selection is kept verbatim; a LOCKED one renders as the largest unlocked range with a real finite
/// window (`days != nil`, so never ALL) whose rawValue is <= the selection, else `.week`. Coercing a
/// locked default to ALL would jump a calibrating user to the everything view, so it is excluded.
enum ExploreRangeGating {
    static func coerced(selection: ExploreRange, isUnlocked: (ExploreRange) -> Bool) -> ExploreRange {
        if isUnlocked(selection) { return selection }
        return [ExploreRange.year, .half, .quarter, .month, .threeWeeks, .twoWeeks, .week]
            .first { $0.days != nil && $0.rawValue <= selection.rawValue && isUnlocked($0) } ?? .week
    }
}

// MARK: - Readings table projection (task #8)

/// One windowed reading behind a vital's detail chart: its day ("YYYY-MM-DD"), the value, and the RAW
/// source id it came from (a strap id, the "-noop" computed sibling, "apple-health", or "health-connect").
/// The readings TABLE and the "N readings" caption both derive from this ONE windowed list, so they can
/// never disagree; the raw source maps to a human label via `TodayView.provenanceDisplayLabel` — the SAME
/// resolver Today uses, so no source vocabulary is invented. Swift twin of Android's `VitalReading`.
struct VitalReading: Equatable {
    let day: String
    let value: Double
    let source: String
}

/// One row of a vital detail's readings table: the reading's day (localized), its formatted value with
/// unit, and a human source label. Plain strings so the view is a thin renderer and the projection stays
/// unit-testable. Swift twin of Android's `VitalReadingRow`.
struct VitalReadingRow: Equatable {
    let time: String
    let value: String
    let source: String
}

/// Project a vital's windowed `readings` into table rows, NEWEST FIRST — the same list (so the same count)
/// the "N readings" caption shows, guaranteeing the two never drift. Each row pairs the reading's DAY
/// (these vital series carry one aggregated reading per night, so a row's "time" is its localized calendar
/// date; the date always shows since a charted window spans 2+ days) with the model's own `format`ted
/// value + `unit` and the source label from `TodayView.provenanceDisplayLabel` (a strap id → "Whoop", its
/// "-noop" sibling → "On-device", "apple-health" → "Apple Health", "health-connect" → "Health Connect").
/// `strapDeviceId` is the active strap id the resolver needs. Byte-identical projection to Android's
/// `vitalReadingRows`.
func vitalReadingRows(readings: [VitalReading], unit: String, strapDeviceId: String,
                      now: Date = Date(), format: (Double) -> String) -> [VitalReadingRow] {
    readings.reversed().map { reading in
        let value = format(reading.value)
        return VitalReadingRow(
            time: vitalReadingDateLabel(reading.day, now: now),
            value: unit.isEmpty ? value : "\(value) \(unit)",
            source: TodayView.provenanceDisplayLabel(rawSource: reading.source, deviceId: strapDeviceId)
        )
    }
}

/// "9 Jun" for a "YYYY-MM-DD" reading day (today / yesterday read as words to match the hero "as of"
/// line); the verbatim string if it doesn't parse. UTC-fixed en_US_POSIX, matching this file's other date
/// labels. Swift twin of Android's `vitalReadingDateLabel`.
func vitalReadingDateLabel(_ day: String, now: Date = Date()) -> String {
    guard let date = parseDay(day) else { return day }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    if cal.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
       cal.isDate(date, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
    return readingShortDateFormatter.string(from: date)
}

/// "d MMM" (e.g. "9 Jun"), UTC / en_US_POSIX so the label is locale-stable, matching `longDate`.
private let readingShortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "d MMM"
    return f
}()

// MARK: - Root: categorized list

/// The "Explore" picker — categories as sections, metrics as rows, each pushing a
/// MetricDetailView. A faint trailing "•" marks metrics whose series is empty.
struct MetricExplorerView: View {
    @EnvironmentObject var repo: Repository
    /// metric.id → whether its series is empty. Filled INCREMENTALLY by `probeEmptiness()`; a metric
    /// absent from the map simply has no empty-dot yet (rows never wait on it — see `MetricRow`).
    @State private var emptyByID: [String: Bool] = [:]
    @State private var probedRefreshSeq: Int?
    /// True while the empty-dot probe is still running its first pass. Drives a small inline progress
    /// hint in the header, never gating the rows: the catalog is static, so every row's label/icon/unit
    /// must paint immediately even before any series read returns (#199).
    @State private var probing = true

    var body: some View {
        #if os(macOS)
        // macOS: Explore is a standalone detail pane, so it owns its NavigationStack.
        NavigationStack { exploreScaffold }
            .task(id: repo.refreshSeq) { await probeEmptiness(refreshSeq: repo.refreshSeq) }
        #else
        // iOS: Explore is pushed INSIDE the More tab's NavigationStack. A nested NavigationStack made
        // tapping a metric bounce straight back to the More list (#199) — so use the ambient stack; the
        // rows push their detail with a direct closure-based NavigationLink (#38).
        exploreScaffold
            .task(id: repo.refreshSeq) { await probeEmptiness(refreshSeq: repo.refreshSeq) }
        #endif
    }

    private var exploreScaffold: some View {
        // PERF (scroll): lazy column. Unlike most screens, Explore's content is a flat list of sibling
        // sections (the probe hint, the Deep Timeline row, then a long per-category ForEach of metric
        // cards), so LazyVStack genuinely builds the off-screen category cards on demand. No
        // `staggeredAppear` here and identical column alignment/spacing (20) + per-child bottom padding,
        // so the layout is byte-identical to the eager VStack.
        ScreenScaffold(title: "Explore", subtitle: "Every signal, one tap deep.",
                       onRefresh: { await repo.refresh() }, lazy: true,
                       topBackground: liquidScaffoldSky()) {
            // A quiet, non-blocking hint while the empty-dot probe runs its first pass. The rows below
            // render in full immediately regardless — this only reassures during the scan, and never
            // leaves the screen reading as a bare/empty list before the probe lands (#199).
            if probing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning your data…")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The headline tap-through (#575): a full-day, full-resolution, zoomable timeline. Sits above
            // the per-metric catalog because it's a different kind of view — every second of one day rather
            // than one number per day. Closure-based NavigationLink, matching the metric rows below (#38/#199).
            NavigationLink {
                FullDayChartView()
            } label: {
                deepTimelineRow
            }
            // Liquid press language: the settle-inward LiquidPressStyle (the same physical response the
            // Today / batch-1 cards use), replacing the classic StrandPressableButtonStyle.
            .buttonStyle(LiquidPressStyle())
            #if os(iOS)
            .simultaneousGesture(TapGesture().onEnded { StrandHaptic.selection.play() })
            #endif
            .padding(.bottom, NoopMetrics.sectionGap - 20)

            ForEach(MetricCatalog.categories, id: \.self) { category in
                let metrics = MetricCatalog.inCategory(category)
                if !metrics.isEmpty {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        // Localized at the render site only; `category` itself stays the raw
                        // English identifier that `inCategory` filters on.
                        SectionHeader("\(MetricCatalog.categoryDisplayName(category))", overline: "Category",
                                      trailing: "\(metrics.count)")
                        NoopCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(metrics.enumerated()), id: \.element.id) { idx, metric in
                                    // Push the detail directly (closure-based), like every other More-tab
                                    // screen. The old value + .navigationDestination(for:) pairing resolved
                                    // against TWO registered destinations and double-pushed — the detail
                                    // flashed then popped straight back (#38).
                                    NavigationLink {
                                        MetricDetailView(metric: metric)
                                    } label: {
                                        MetricRow(metric: metric,
                                                  isEmpty: emptyByID[metric.id] ?? false)
                                    }
                                    // Full-row press-down feedback in the liquid language — the settle-inward
                                    // LiquidPressStyle (a transform, so it works edge-to-edge with dividers
                                    // between, no corner radius to match). Matches Today's tappable rows.
                                    .buttonStyle(LiquidPressStyle())
                                    #if os(iOS)
                                    // Light selection tick on tap; the simultaneousGesture leaves the
                                    // NavigationLink push intact.
                                    .simultaneousGesture(TapGesture().onEnded {
                                        StrandHaptic.selection.play()
                                    })
                                    #endif
                                    if idx < metrics.count - 1 {
                                        Divider().overlay(StrandPalette.hairline)
                                            .padding(.leading, 56)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, NoopMetrics.sectionGap - 20)
                }
            }
        }
        // Rows push MetricDetailView directly (closure-based NavigationLink above) — no value/destination
        // pairing, which is what double-pushed (#38). Nothing else registers a MetricDescriptor destination.
    }

    /// The hero entry that opens the Deep Timeline (#575). A full-bleed card, not a list row, so it reads
    /// as the headline above the per-metric catalog.
    private var deepTimelineRow: some View {
        NoopCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(StrandPalette.metricRose.opacity(0.16))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricRose)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Deep Timeline")
                        .font(StrandFont.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Every second of your day, zoomable.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deep Timeline, every second of your day, zoomable")
        .accessibilityAddTraits(.isButton)
    }

    /// One lightweight pass to learn which metrics have no series, so rows can flag them with the
    /// faint trailing dot. Failures default to "has data" (no dot).
    ///
    /// #199 originally fixed this by publishing PER METRIC rather than in one final batch, because the
    /// sweep ran ~60 sequential `exploreSeries` reads — each hopping back to the @MainActor Repository —
    /// and the freshly-pushed list painted blank until it finished. That made the symptom bearable
    /// without addressing the cost: the sweep still read sixty full histories, built sixty dictionaries
    /// and sorted them, only to keep sixty booleans.
    ///
    /// `Repository.nonEmptyMetricIDs` asks the cheap question instead — one DISTINCT-key query per
    /// source plus one in-memory pass — so the whole probe is now a single await. The per-metric
    /// publishing and the `Task.yield()` are gone with it: there is no longer a long sweep to interleave
    /// with layout, and one assignment publishes the lot. Rows still render their label / icon / unit
    /// without waiting on this — the map only ever ADDS a trailing dot.
    private func probeEmptiness(refreshSeq: Int) async {
        guard probedRefreshSeq != refreshSeq || emptyByID.isEmpty else { probing = false; return }
        probedRefreshSeq = refreshSeq
        probing = true
        let nonEmpty = await repo.nonEmptyMetricIDs(MetricCatalog.all)
        guard !Task.isCancelled else { return }
        emptyByID = Dictionary(uniqueKeysWithValues: MetricCatalog.all.map { ($0.id, !nonEmpty.contains($0.id)) })
        probing = false
    }
}

// MARK: - One catalog row

private struct MetricRow: View {
    let metric: MetricDescriptor
    let isEmpty: Bool

    // Trailing unit chip follows the Imperial/Metric preference (kg→lb, °C→°F) and the Effort scale
    // (/100→/21, #268).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var unitLabel: String {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        let temp = UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
        let effort = UnitPrefs.resolveEffortScale(effortScaleRaw)
        return metric.displayUnit(system: system, temperature: temp, effortScale: effort)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(StrandPalette.surfaceInset)
                Image(systemName: metric.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(metricAccent(metric))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(metric.sourceLabel)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            Spacer(minLength: 8)

            if !unitLabel.isEmpty {
                Text(unitLabel)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            // Faint trailing dot ONLY when this metric has no series at all.
            if isEmpty {
                Text("•")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                    .accessibilityLabel("No data")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // Whole-string key per variant (never a concatenated localized tail on an a11y label).
        .accessibilityLabel(isEmpty
            ? "\(metric.title), \(unitLabel.isEmpty ? MetricCatalog.categoryDisplayName(metric.category) : unitLabel), no data"
            : "\(metric.title), \(unitLabel.isEmpty ? MetricCatalog.categoryDisplayName(metric.category) : unitLabel)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Detail / drill-down

/// The full analytic dossier for one metric, built ONLY from locked components:
/// a SegmentedPillControl range, a hero ChartCard (line + latest "as of"), a uniform
/// StatTile row (Average / Min / Max / Latest / Δ), and a "What correlates" NoopCard.
struct MetricDetailView: View {
    let metric: MetricDescriptor
    @EnvironmentObject var repo: Repository
    /// #430 parity: the detail carries the SAME backdrop as the screen that pushed it — the day-cycle sky
    /// when the setting is on, the plain canvas when off — so a Key-Metrics tile tap doesn't jar from the
    /// liquid Today's sky to a flat page. Same keys TodayView/LiquidTodayView gate on; "Sky behind cards"
    /// extends the sky to the full viewport (softer settle) so the transparent cards reveal it throughout.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    /// Custom background image (#custom-background): when active it overrides the sky in the backdrop.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
    // Profile basics for the Fitness Age not-ready countdown (age/sex gate its readiness lead). Injected
    // app-wide at the root; previews supply their own. Only read on the fitness_age empty-state path.
    @EnvironmentObject var profile: ProfileStore
    // Drives the fitness_age not-ready "refresh" button (force an immediate recompute). App-wide injected.
    @EnvironmentObject var intelligence: IntelligenceEngine
    /// True while a manual Fitness Age refresh runs (spinner on the not-ready empty state).
    @State private var refreshing = false

    // Imperial/Metric display preference (D#103). Display-only: weight (kg) and skin temp (°C) re-label
    // here; everything else is unit-agnostic and renders unchanged.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    // Effort display scale (#268) — routes the Effort metric's numbers + unit; display-only, the plotted
    // series stays 0–100. Every other metric is scale-agnostic (see MetricDescriptor.format).
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private func fmt(_ v: Double) -> String {
        metric.format(v, system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    @State private var range: ExploreRange = .month
    /// Draw-in fraction for the hero ring gauge (0–100 scores). Set to the real fraction
    /// in `.onAppear` with a soft ease, exactly as TodayView animates its rings.
    @State private var heroAnimatedFraction: Double = 0
    /// Full ascending series for this metric — ALL history.
    @State private var series: [(day: String, value: Double)] = []
    /// day → the RAW source id that supplied that day's value (task #8). Loaded from `resolvedSeries`
    /// alongside `series` and used ONLY for the readings-table provenance column, so the plotted line
    /// (which rides `series`/`exploreSeries`) is never changed by adding source labels.
    @State private var sourceByDay: [String: String] = [:]
    /// Every OTHER catalog series, loaded once for the correlation scan.
    ///
    /// Filled by a SECOND load phase, after the screen is already on screen — see `load()`. Nothing above
    /// the correlation card reads it, so nothing above the correlation card waits for it.
    @State private var others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
    /// True once THIS metric's own series is in — the gate for the whole screen (hero, chart, stats,
    /// readings). Deliberately not "everything is in": see `load()`.
    @State private var loaded = false
    /// True once the cross-catalog scan behind the correlation card has finished. Only that one card
    /// reads it, so it can lag the rest of the screen by a second without anyone noticing.
    @State private var correlationsLoaded = false

    /// Cached correlation scan, keyed by its inputs (selected range + the metric id),
    /// so the full cross-catalog Pearson sweep runs ONLY when those change — not on
    /// every body re-eval (hover / 1 Hz HR ticks / animation). Recomputed from
    /// `recomputeCorrelations(...)` after load and on range change.
    @State private var correlationCache: [CorrRow] = []
    /// The (metricID, range) the cache was built for; nil means "not yet computed".
    @State private var correlationKey: String? = nil
    private var loadTaskID: String { "\(metric.id)|\(repo.refreshSeq)" }

    // MARK: Derived

    /// The trailing-N-days slice for a given range, taken RELATIVE TO THE LATEST data
    /// point (not "now") — `.all` returns everything.
    private func slice(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard let days = r.days else { return series }
        guard let lastDay = series.last?.day, let last = parseDay(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        return series.filter { row in
            guard let d = parseDay(row.day) else { return false }
            return d >= cutoff
        }
    }

    /// The range actually shown: the SELECTED range whenever its window holds ≥1
    /// point, otherwise the smallest LARGER range that does. So switching ranges is
    /// always visibly distinct when data allows, and only sparse windows widen.
    /// The range the chips + caption ACTUALLY describe, resolved NON-DESTRUCTIVELY from the stored
    /// `range` (#943, true cross-platform lockstep with Android's effectiveVitalRange). We never
    /// overwrite the @State selection - a locked default (`range == .month` with under a week of
    /// history) simply RENDERS as the largest unlocked range with a real finite window that is <= the
    /// selection, else `.week`. NOT `.all`: coercing a locked default to ALL would jump a calibrating
    /// user to the everything view. When the stored range is itself unlocked it is used verbatim, so
    /// once history grows the selection un-coerces on its own with no snap-back.
    private var coercedSelection: ExploreRange {
        ExploreRangeGating.coerced(selection: range, isUnlocked: isUnlocked)
    }

    /// The pill's selection binding: it HIGHLIGHTS the coerced selection (so a locked default shows the
    /// unlocked chip that is actually rendering) but a user tap writes straight to the stored @State
    /// `range`. Reads never mutate state, so this stays non-destructive.
    private var selectionBinding: Binding<ExploreRange> {
        Binding(get: { coercedSelection }, set: { range = $0 })
    }

    private var effectiveRange: ExploreRange {
        guard !series.isEmpty else { return coercedSelection }
        for r in coercedSelection.widening where !slice(for: r).isEmpty { return r }
        return .all
    }

    /// Whole days between the first and last reading (0 for a single point). The
    /// UTC-fixed day parser makes the Int truncation exact.
    private var historySpanDays: Int {
        guard let firstDay = series.first?.day, let lastDay = series.last?.day,
              let first = parseDay(firstDay), let last = parseDay(lastDay) else { return 0 }
        return Int(last.timeIntervalSince(first) / 86_400)
    }

    /// Whether a range chip is selectable (#943, reimplemented from ryanbr's PR): a longer
    /// range only unlocks once the history span EXCEEDS the previous window, i.e. once it
    /// would actually show more than the range below it. Before that, every window is taken
    /// relative to the latest point, so thin history sat inside all of them and the six chips
    /// drew byte-identical charts (a week of data stretched full-width under a 1Y label).
    /// W (the shortest) and ALL (the honest everything view) are never gated, so a calibrating
    /// user always has a selectable range; until the series loads (or with no history at all)
    /// nothing is gated, since the empty state deliberately keeps the full range bar for context.
    private func isUnlocked(_ r: ExploreRange) -> Bool {
        guard loaded, !series.isEmpty else { return true }
        switch r {
        case .week, .all: return true
        case .twoWeeks:   return historySpanDays > ExploreRange.week.rawValue
        case .threeWeeks: return historySpanDays > ExploreRange.twoWeeks.rawValue
        case .month:      return historySpanDays > ExploreRange.threeWeeks.rawValue
        case .quarter:    return historySpanDays > ExploreRange.month.rawValue
        case .half:       return historySpanDays > ExploreRange.quarter.rawValue
        case .year:       return historySpanDays > ExploreRange.half.rawValue
        }
    }

    /// True when at least one range chip is locked; drives the one-line unlock hint under
    /// the caption, so the dimmed chips read as "not yet" rather than broken.
    private var hasLockedRanges: Bool { !ExploreRange.allCases.allSatisfy(isUnlocked) }

    /// The window immediately preceding the active one (equal length, by day count).
    private func previousWindow(effectiveRange: ExploreRange,
                                windowed: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        guard effectiveRange != .all else { return [] }
        let size = windowed.count
        guard size > 0 else { return [] }
        // Index of the active window's first row, then step back `size` rows.
        guard let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - size)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    private func trendPoints(_ windowed: [(day: String, value: Double)]) -> [TrendPoint] {
        windowed.compactMap { row in
            guard let d = parseDay(row.day) else { return nil }
            return TrendPoint(date: d, value: row.value)
        }
    }

    /// Padded value range so the line never sits flush against an axis.
    private func valueRange(_ windowValues: [Double]) -> ClosedRange<Double> {
        let v = windowValues
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    private var latest: (day: String, value: Double)? { series.last }

    // MARK: Body

    var body: some View {
        // Compute the heavy window derivations ONCE per body eval, then hand them to
        // the subviews — instead of every subview re-deriving `effectiveRange` /
        // `windowed` (each of which re-parses + re-filters the full history).
        let effRange = effectiveRange
        let win = slice(for: effRange)
        let fellBack = effRange != range
        return ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if loaded && series.isEmpty {
                    // No data in the entire history — keep the range bar for context, then the
                    // honest empty state (no scenic hero floating over nothing). Deliberately
                    // NOT gated by the #943 chip locking: with zero data there is no chart for
                    // the ranges to misrepresent, and hiding the bar here would regress this
                    // "for context" intent.
                    rangeBar(effectiveRange: effRange, windowed: win, windowFellBack: fellBack)
                    if metric.key == "fitness_age" {
                        // Fitness Age is COMPUTED on-device from resting HR + activity — not imported — so
                        // the generic "import your history" copy was wrong (and a dead end) here. Lead with
                        // the same "N more nights of wear" countdown the Health hub shows, from the shared
                        // engine + `fitnessReadyLeadCopy` (parity with Android's VitalDetailScreen fix).
                        // `what` is a LocalizedStringKey; the lead is an already-resolved String, so wrap
                        // it in an interpolation (renders verbatim) rather than passing it as a lookup key.
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            ComingSoon(what: "\(fitnessReadyLeadCopy(rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count, hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))", symbol: "figure.run")
                            // Force the weekly recompute NOW from stored data (works offline), then re-read.
                            if refreshing {
                                ProgressView().controlSize(.small).tint(StrandPalette.accent)
                            } else {
                                Button {
                                    guard !refreshing else { return }
                                    refreshing = true
                                    Task {
                                        _ = await intelligence.recomputeFitnessAgeOnly()
                                        await load()
                                        refreshing = false
                                    }
                                } label: {
                                    Label("Refresh Fitness Age", systemImage: "arrow.clockwise")
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ComingSoon(what: "Import your history first. A WHOOP export in Data Sources fills every metric you can explore here in about a minute.")
                    }
                } else if !loaded {
                    rangeBar(effectiveRange: effRange, windowed: win, windowFellBack: fellBack)
                    ComingSoon(what: "Reading your \(metric.title.lowercased())…")
                } else {
                    // Scenic hero: the metric's current value as a layered ring gauge (0–100
                    // scores) or a big SF-Rounded headline, floated over the domain's starfield,
                    // with the range pill. Then the frosted chart / stat tiles / correlations.
                    heroHeader(effectiveRange: effRange, windowed: win, windowFellBack: fellBack)
                    heroChart(effectiveRange: effRange, windowed: win, windowFellBack: fellBack)
                    statRow(effectiveRange: effRange, windowed: win)
                    readingsTable(windowed: win)
                    correlationCard
                }
            }
            .padding(NoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Day-cycle-aware backdrop (#430 parity): the top sky band every liquid screen uses when the
        // setting is on — or the FULL-viewport sky with the softer settle when "Sky behind cards" is also
        // on (the LiquidTodayView treatment, so the transparent cards reveal it the whole way down); the
        // plain canvas when off.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                // Custom background image (#custom-background) OVERRIDES the sky, full-bleed.
                if backgroundStore.isActive {
                    BackgroundImageBackdrop()
                } else if showDayCycleBackground {
                    LiquidSkyStatic(hour: nil, settleStrength: skyBehindCards ? 0.78 : 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: skyBehindCards ? nil : 240, alignment: .top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea()
        }
        .navigationTitle(metric.title)
        .task(id: loadTaskID) { await load() }
        // Range changes the window, hence the correlation inputs — recompute the
        // cached scan rather than letting `correlationCard` run it inside body.
        .onChangeCompat(of: range) { _ in recomputeCorrelations() }
    }

    /// Two phases, because the screen used to wait for data it does not draw.
    ///
    /// PERF: `loaded` gates the ENTIRE screen — hero, chart, stat tiles, readings table — and it used to be
    /// set only after the cross-catalog scan had read all 59 OTHER metrics in the catalog, one sequential
    /// `exploreSeries` each. Every one of those walks `repo.days` and sorts on the main actor
    /// (`Repository` is `@MainActor`), and none of them feeds anything above the correlation card at the
    /// very bottom. So opening any metric detail paid ~60 full-history reads before drawing its first
    /// pixel, to satisfy one card most readers never scroll to.
    ///
    /// Phase 1 is this metric's own series + provenance — everything the visible screen needs. `loaded`
    /// flips there. Phase 2 is the catalog scan, awaited afterwards, and only the correlation card waits
    /// on it. Same reads, same results, same order; only the gate moved.
    private func load() async {
        // Phase 1 — what the screen actually draws.
        series = await repo.exploreSeries(key: metric.key, source: metric.source)
        // Per-day provenance for the readings table (task #8). resolvedSeries names the source that
        // actually supplied each day (imported strap / on-device / Apple Health / Health Connect); the
        // chart still rides `series` above, so this only ADDS the source column, never moves the line.
        let resolution = await repo.resolvedSeries(key: metric.key, source: metric.source)
        sourceByDay = Dictionary(resolution.points.map { ($0.day, $0.source) },
                                 uniquingKeysWith: { first, _ in first })
        // #943 selection seam: a locked default (.month with under a week of history) no longer
        // OVERWRITES @State range - it renders through `coercedSelection` instead (non-destructive,
        // recomputed every body eval), so a shrinking history re-coerces and a growing one un-coerces
        // with no snap-back. See `coercedSelection`.
        loaded = true

        // Phase 2 — the cross-catalog scan behind the correlation card, now that the screen is up.
        // `Task.isCancelled` is checked per metric so navigating away mid-scan stops it: the task is
        // bound to `loadTaskID`, and without the check a quick in-and-out would keep 59 main-actor
        // merges running for a screen nobody is looking at.
        var loadedOthers: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
        for other in MetricCatalog.all where other.id != metric.id {
            guard !Task.isCancelled else { return }
            let s = await repo.exploreSeries(key: other.key, source: other.source)
            if !s.isEmpty { loadedOthers.append((other, s)) }
        }
        guard !Task.isCancelled else { return }
        others = loadedOthers
        correlationsLoaded = true
        // First correlation build, now that `series`/`others` exist.
        recomputeCorrelations()
    }

    // MARK: Scenic hero

    /// The detail's opening hero: the metric's latest value as either the signature liquid
    /// LiquidVessel gauge (for 0–100 scores, filled to the score with the number counting up over
    /// it) or a big count-up headline number, floated over a domain-tinted ScenicHeroBackground,
    /// with the category overline, the "as of" line, and the range pill. Mirrors TodayView's
    /// liquid score-hero idiom (and Health's Fitness-Age / Vitality vessels).
    @ViewBuilder
    private func heroHeader(effectiveRange: ExploreRange,
                            windowed: [(day: String, value: Double)],
                            windowFellBack: Bool) -> some View {
        let domain = metricDomain(metric)
        let value = latest?.value
        let heroValue = latest.map { fmt($0.value) } ?? "—"
        let asOf: String = {
            guard let day = latest?.day, let d = parseDay(day) else { return "—" }
            return String(localized: "as of \(longDate(d))")
        }()
        let fraction = value.flatMap { metricGaugeFraction(metric, value: $0) }

        // Gap fix (2026-07-02): draw the starfield as the content's BACKGROUND, not as a
        // stretching ZStack sibling — an unconstrained ScenicHeroBackground inside a ScrollView filled
        // the whole viewport and left a huge blank band above the chart. As a .background it sizes to
        // the hero content, so the number/ring sits directly under the range pill.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // Category + title on their OWN full-width row so a long title ("Heart Rate Variability")
                // is never crushed into a letter-per-line column by the range pill (2026-07-02).
                VStack(alignment: .leading, spacing: 2) {
                    Text(MetricCatalog.categoryDisplayName(metric.category).uppercased()).strandOverline()
                    Text(metric.title)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Range control on its own row beneath the title.
                SegmentedPillControl(ExploreRange.allCases, selection: selectionBinding,
                                     adaptsToAvailableWidth: true,
                                     isEnabled: isUnlocked) { $0.label }

                // The headline read-out in the liquid language: for a 0–100 score, the signature
                // LiquidVessel gauge filled to the score (the same hero idiom as Today's rings / Health's
                // Fitness-Age + Vitality heroes), with the integer counting up over it and the unit + "as
                // of" line beneath. For a non-score metric, a big count-up number. The vessel fills from 0
                // to its fraction on appear (`heroAnimatedFraction`), so it settles once like TodayView's
                // rings; the number ticks itself. A liquid accent on the ONE headline value, where it reads
                // well — never over the chart below.
                HStack {
                    Spacer(minLength: 0)
                    if let fraction, let v = value {
                        VStack(spacing: 10) {
                            ZStack {
                                // The big hero vessel stays live (animated) — the one sloshing gauge on the
                                // screen, exactly like the hero gauges on Today.
                                LiquidVessel(value: heroAnimatedFraction, tint: domain.bright, animated: true)
                                    .frame(width: 188, height: 188)
                                    .accessibilityHidden(true)
                                VStack(spacing: 2) {
                                    CountUpNumber(value: v, font: StrandFont.rounded(48))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                                    if !metric.unit.isEmpty {
                                        Text(metric.unit)
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(.white.opacity(0.85))
                                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                            Text(asOf)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        // One VoiceOver stop for the hero read-out (the vessel is decorative above).
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(heroValue), \(asOf)")
                    } else if let v = value {
                        VStack(spacing: 6) {
                            CountUpText(value: v, format: { fmt($0) },
                                        font: StrandFont.number(54),
                                        color: StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(asOf)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.vertical, 18)
                    } else {
                        VStack(spacing: 6) {
                            Text(heroValue)
                                .font(StrandFont.number(54))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(asOf)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.vertical, 18)
                    }
                    Spacer(minLength: 0)
                }

                // The "N readings · range" caption (auto-widen flagged when it happens).
                Text(rangeCaption(effectiveRange: effectiveRange,
                                  windowed: windowed,
                                  windowFellBack: windowFellBack))
                    .font(StrandFont.footnote)
                    .foregroundStyle(windowFellBack ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                    .accessibilityLabel(rangeCaption(effectiveRange: effectiveRange,
                                                     windowed: windowed,
                                                     windowFellBack: windowFellBack))
                // The subtle reason the dimmed chips exist (#943); shown only while some are locked.
                // Byte-identical wording to the Android HealthScreen's unlock hint.
                if hasLockedRanges {
                    Text("Longer ranges unlock as more history builds.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        .padding(NoopMetrics.cardPadding)
        .background {
            NoopPanelSurface(tint: domain.color,
                             cornerRadius: NoopMetrics.cardRadius,
                             elevated: true)
        }
        // The hero shows the LATEST available point (range-independent), so the vessel fills once on
        // appear (0 → its fraction) and settles — like TodayView's rings.
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                heroAnimatedFraction = fraction ?? 0
            }
        }
    }

    // MARK: Range bar

    private func rangeBar(effectiveRange: ExploreRange,
                          windowed: [(day: String, value: Double)],
                          windowFellBack: Bool) -> some View {
        let caption = rangeCaption(effectiveRange: effectiveRange,
                                   windowed: windowed,
                                   windowFellBack: windowFellBack)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MetricCatalog.categoryDisplayName(metric.category).uppercased()).strandOverline()
                Text(metric.title)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            SegmentedPillControl(ExploreRange.allCases, selection: selectionBinding,
                                 adaptsToAvailableWidth: true,
                                 isEnabled: isUnlocked) { $0.label }
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(caption)
                .font(StrandFont.footnote)
                .foregroundStyle(windowFellBack ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .accessibilityLabel(caption)
        }
    }

    /// "N readings · <range>" near the control, flagging an auto-widen when one happened.
    /// Whole-phrase variants per count so translators never see a stitched plural.
    private func rangeCaption(effectiveRange: ExploreRange,
                              windowed: [(day: String, value: Double)],
                              windowFellBack: Bool) -> String {
        guard loaded, !series.isEmpty else { return "—" }
        let n = windowed.count
        if windowFellBack {
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(effectiveRange.name)")
                : String(localized: "\(n) readings · sparse, widened to \(effectiveRange.name)")
        }
        return n == 1
            ? String(localized: "1 reading · \(range.name)")
            : String(localized: "\(n) readings · \(range.name)")
    }

    // MARK: Hero chart

    private func heroChart(effectiveRange: ExploreRange,
                           windowed: [(day: String, value: Double)],
                           windowFellBack: Bool) -> some View {
        let asOf: String = {
            guard let day = latest?.day, let d = parseDay(day) else { return "—" }
            return String(localized: "as of \(longDate(d))")
        }()
        let heroValue = latest.map { fmt($0.value) } ?? "—"
        let subtitle = windowFellBack
            ? String(localized: "Sparse, widened to \(effectiveRange.name) · \(windowed.count) readings")
            : String(localized: "\(windowed.count) readings · \(range.name)")
        return ChartCard(
            title: "\(metric.title)",
            subtitle: subtitle,
            trailing: "\(heroValue) · \(asOf)",
            tint: metricDomain(metric).color
        ) {
            TrendChart(
                points: trendPoints(windowed),
                gradient: metricGradient(metric),
                valueRange: valueRange(windowed.map(\.value)),
                showsArea: true,
                height: NoopMetrics.chartHeight,
                valueFormat: { fmt($0) }
            )
        } footer: {
            ChartFooter([
                ("Window", effectiveRange.label),
                ("Points", "\(windowed.count)"),
                ("Latest", heroValue),
            ])
        }
    }

    // MARK: Stat tile row (uniform 104pt tiles)

    private func statRow(effectiveRange: ExploreRange,
                         windowed: [(day: String, value: Double)]) -> some View {
        let windowValues = windowed.map(\.value)
        let s = ComparisonEngine.stat(windowValues)
        let cmp = ComparisonEngine.compare(current: windowValues,
                                           previous: previousWindow(effectiveRange: effectiveRange,
                                                                    windowed: windowed).map(\.value))
        let accent = metricAccent(metric)

        // Δ vs previous equal-length window. Tinted by higherIsBetter.
        let hasDelta = cmp.current.n > 0 && cmp.previous.n > 0
        let deltaText: String? = hasDelta ? signed(cmp.delta) : nil
        let deltaColor: Color = {
            guard hasDelta, cmp.direction != 0, let better = metric.higherIsBetter else {
                return StrandPalette.textTertiary
            }
            return ((cmp.direction > 0) == better)
                ? StrandPalette.statusPositive : StrandPalette.statusCritical
        }()
        let deltaCaption = hasDelta ? String(localized: "vs prev \(effectiveRange.name)")
            : (effectiveRange == .all ? String(localized: "all history") : String(localized: "no prior \(effectiveRange.name)"))

        #if os(iOS)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // On iOS, Average summarizes the selected range, so it leads at the full
            // two-column width.
            StatTile(label: "Average", value: fmt(s.mean),
                     caption: s.n == 1 ? String(localized: "1 day") : String(localized: "\(s.n) days"),
                     accent: accent,
                     sparkline: windowValues.count > 1 ? windowValues : nil,
                     sparkColor: accent)
                .frame(maxWidth: .infinity)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                alignment: .leading,
                spacing: NoopMetrics.gap
            ) {
                StatTile(label: "Min", value: fmt(s.min),
                         accent: StrandPalette.textPrimary)
                StatTile(label: "Max", value: fmt(s.max),
                         accent: StrandPalette.textPrimary)
                StatTile(label: "Δ vs prev", value: deltaText ?? "—",
                         caption: deltaCaption, accent: StrandPalette.textPrimary,
                         delta: cmp.pctChange.map { "\($0 >= 0 ? "+" : "")\(String(format: "%.1f", $0))%" },
                         deltaColor: deltaColor)
                StatTile(label: "Latest", value: latest.map { fmt($0.value) } ?? "—",
                         caption: latestCaption, accent: accent)
            }
        }
        #else
        // macOS keeps its adaptive multi-column dashboard. Promoting one tile to the
        // unbounded screen width would turn a phone-specific hierarchy into an oversized
        // desktop card and could leave the remaining adaptive row uneven.
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            StatTile(label: "Average", value: fmt(s.mean),
                     caption: s.n == 1 ? String(localized: "1 day") : String(localized: "\(s.n) days"),
                     accent: accent,
                     sparkline: windowValues.count > 1 ? windowValues : nil,
                     sparkColor: accent)
            StatTile(label: "Min", value: fmt(s.min),
                     accent: StrandPalette.textPrimary)
            StatTile(label: "Max", value: fmt(s.max),
                     accent: StrandPalette.textPrimary)
            StatTile(label: "Latest", value: latest.map { fmt($0.value) } ?? "—",
                     caption: latestCaption, accent: accent)
            StatTile(label: "Δ vs prev", value: deltaText ?? "—",
                     caption: deltaCaption, accent: StrandPalette.textPrimary,
                     delta: cmp.pctChange.map { "\($0 >= 0 ? "+" : "")\(String(format: "%.1f", $0))%" },
                     deltaColor: deltaColor)
        }
        #endif
    }

    private var latestCaption: String? {
        guard let day = latest?.day, let d = parseDay(day) else { return nil }
        return longDate(d)
    }

    // MARK: Readings table (task #8)

    /// The per-reading breakdown below the stats, so the provenance behind the trend is visible — whether
    /// each reading came from the WHOOP strap, a Health Connect / Apple Health import, or the on-device
    /// pipeline — not just the "N readings" caption. Rows derive from the SAME `windowed` slice the caption
    /// counts (so the two never disagree), NEWEST FIRST, and reuse `TodayView.provenanceDisplayLabel` for
    /// the source words. Swift twin of Android's `VitalReadingsTable`.
    @ViewBuilder
    private func readingsTable(windowed: [(day: String, value: Double)]) -> some View {
        let readings = windowed.map {
            VitalReading(day: $0.day, value: $0.value, source: sourceByDay[$0.day] ?? metric.source)
        }
        let rows = vitalReadingRows(readings: readings, unit: metric.unit,
                                    strapDeviceId: repo.deviceId, format: fmt)
        if !rows.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    Text("Readings").strandOverline()
                    // Slim column header naming the three columns — SAME frames as the data rows below so
                    // each label sits over its column. Android twin (VitalReadingsTable) mirrors this.
                    HStack(spacing: 12) {
                        Text("Date")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Value")
                        Text("Source")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                            HStack(spacing: 12) {
                                Text(row.time)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.value)
                                    .font(StrandFont.number(15))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(row.source)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(readingSourceTint(row.source))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .padding(.vertical, 8)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(row.time), \(row.value), \(row.source)")
                            if idx < rows.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The tint for a resolved provenance label — gold for Whoop, cyan for Apple Health, purple for Health
    /// Connect, the positive status hue for on-device (and anything else). Mirrors Android's
    /// `provenanceLabelTint` so the same source reads the same colour across the twins.
    private func readingSourceTint(_ label: String) -> Color {
        switch label {
        case "Whoop":         return StrandPalette.accent
        case "Apple Health":  return StrandPalette.metricCyan
        case "Health Connect": return StrandPalette.metricPurple
        default:              return StrandPalette.statusPositive
        }
    }

    // MARK: Correlations

    private struct CorrRow: Identifiable {
        let id: String
        let metric: MetricDescriptor
        let r: Double
        let n: Int
    }

    /// Top |r| catalog metrics over a given window (|r| ≥ 0.30, n ≥ 10). Pure — takes
    /// the window so the heavy scan can be driven from `recomputeCorrelations()` into
    /// the `@State` cache instead of running inside `body`.
    private func computeCorrelationRows(windowed: [(day: String, value: Double)]) -> [CorrRow] {
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { return [] }
        var rows: [CorrRow] = []
        for entry in others {
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs) else { continue }
            if abs(c.r) >= 0.3 {
                rows.append(CorrRow(id: entry.metric.id, metric: entry.metric, r: c.r, n: c.n))
            }
        }
        rows.sort { abs($0.r) > abs($1.r) }
        return Array(rows.prefix(6))
    }

    /// Rebuild the cached correlation scan for the CURRENT effective window, but only
    /// when its key (metric id + selected range) actually changed — so re-evals that
    /// don't alter the inputs (hover / HR ticks) are no-ops.
    private func recomputeCorrelations() {
        // `others.count` belongs in the key, not just the metric and range. The catalog scan now lands
        // AFTER the screen (see `load()`), so a range change during the scan would otherwise compute
        // against a still-empty `others`, cache that empty result under this key, and then skip the
        // recompute the scan itself triggers — leaving the card permanently blank.
        let key = "\(metric.id)|\(range.rawValue)|\(others.count)"
        guard correlationKey != key else { return }
        correlationKey = key
        correlationCache = computeCorrelationRows(windowed: slice(for: effectiveRange))
    }

    private var correlationCard: some View {
        let rows = correlationCache
        return NoopCard(tint: metricDomain(metric).color) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What correlates").strandOverline()
                    Text("Pearson r over the visible window · |r| ≥ 0.30, n ≥ 10")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if !correlationsLoaded {
                    // The scan now lands after the rest of the screen, so this card has a real "still
                    // working" state. Without it the card would assert "nothing correlates" for the
                    // second or two before the catalog is in — a confident, wrong answer.
                    StatePill("Scanning the catalog…", tone: .accent, pulsing: true)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                } else if rows.isEmpty {
                    Text("Nothing in the catalog moves clearly with \(metric.title.lowercased()) over this window. Widen the range to surface relationships.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            correlationRowView(row)
                            if idx < rows.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func correlationRowView(_ row: CorrRow) -> some View {
        let color = correlationColor(row.r)
        HStack(spacing: 12) {
            Image(systemName: row.metric.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.metric.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(MetricCatalog.categoryDisplayName(row.metric.category)) · n = \(row.n)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                // The strength bar as the signature liquid tube — filled to |r|, tinted by the
                // correlation's sign (positive green / negative red), posed (static) so a list of them
                // costs one cached frame each. Replaces the flat capsule with the liquid range-bar idiom.
                LiquidTube(frac: min(abs(row.r), 1.0), tint: color, height: 8, animated: false)
                    .frame(width: 64)
                    .accessibilityHidden(true)
                Text("\(row.r >= 0 ? "+" : "−")\(String(format: "%.2f", abs(row.r)))")
                    .font(StrandFont.number(15))
                    .foregroundStyle(color)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.metric.title), correlation \(String(format: "%.2f", row.r)), \(row.n) days")
    }

    // MARK: Helpers

    private func signed(_ delta: Double) -> String {
        // A difference between two readings: route through the delta formatter so a temperature Δ
        // scales without the +32 offset.
        (delta >= 0 ? "+" : "−") + metric.formatDelta(abs(delta), system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    private func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func explorerPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Explore") {
    MetricExplorerView()
        .environmentObject(explorerPreviewRepo())
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Metric Detail") {
    let repo = explorerPreviewRepo()
    return NavigationStack {
        MetricDetailView(metric: MetricCatalog.all.first { $0.key == "recovery" }!)
    }
    .environmentObject(repo)
    .environmentObject(ProfileStore())
    .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}
#endif
