import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Apple Health (per-source page) — locked component system
//
// Vitaltrends-style, instrument-grade, uniform. ONE range control at the top
// (SegmentedPillControl), a LazyVGrid of fixed-height StatTiles (every metric the
// same 104pt tall), then ChartCard sections — Heart & Vitals, Activity & Energy,
// Body Composition, Sleep — each chart the same height with an avg/min/max footer.
//
// Everything reads from the "apple-health" source. ALL history is loaded once; the
// range control simply windows it client-side, RELATIVE TO THE LATEST data point
// (not "now"). Per the data contract a series may be SPARSE (weight/body-fat are
// weekly): if the selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay
// visibly distinct); only when it holds ZERO points do we auto-expand to the smallest
// larger range that does. Tile heroes show the LATEST point with "as of <date>".

/// #833/v7.7.2 (Apple Health per-source freeze): the snapshot AppleHealthView.load() builds, parked on the
/// long-lived Repository so a re-mount (macOS keys the NavigationSplitView detail with `.id`, so every sidebar
/// switch cold-mounts the screen) can RESTORE it in-memory instead of re-running the whole apple-health history
/// read on the @MainActor. The exact twin of `InsightsLoadCache` for #833; holds load()'s three `@State`
/// outputs. Consumed only when the seq AND the dayKey still match (see `Repository.appleHealthLoadedSeq` /
/// `appleHealthLoadedDayKey`).
struct AppleHealthLoadCache {
    let appleRows: [AppleDaily]
    let workoutCount: Int
    let series: [String: [(day: String, value: Double)]]
}

/// #833/v7.7.2: `.task(id:)` key for the Apple Health load, the data-refresh seq PLUS today's local day-key, so
/// the load re-runs both on a data change AND on a calendar-day rollover while the screen stays mounted across
/// midnight (keying on `refreshSeq` alone left the inside-load dayKey guard unreachable). The exact twin of
/// InsightsView's `InsightsLoadKey`.
struct AppleHealthLoadKey: Equatable {
    let seq: Int
    let dayKey: String
}

struct AppleHealthView: View {
    @EnvironmentObject var repo: Repository

    // iOS-only: the live two-way HealthKit bridge, injected at StrandiOSApp. macOS has no HealthKit
    // (HealthKitBridge is `#if os(iOS)` in its own file and isn't in the macOS environment), so this
    // property and every `health.*` use below MUST stay inside `#if os(iOS)`.
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var model: AppModel
    #endif

    // Imperial/Metric display preference (D#103). Weight and lean mass (stored kg) re-label to lb here;
    // every other Apple Health metric is unit-agnostic. Display-only.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    /// kg value → the active mass unit, full string with label (e.g. "74.5 kg" / "164.2 lb").
    private func massLabel(_ kg: Double) -> String { UnitFormatter.massFromKilograms(kg, system: unitSystem) }

    /// Optional pre-seeded data for previews; when set, the async store load is
    /// skipped (store-backed reads can't be seeded in a preview). Production leaves
    /// this nil and loads from the repository in `.task`.
    private let previewData: PreviewData?

    init() { self.previewData = nil }
    fileprivate init(previewData: PreviewData) { self.previewData = previewData }

    // Loaded state.
    @State private var loaded = false
    @State private var appleRows: [AppleDaily] = []
    @State private var workoutCount = 0

    // Raw series (day, value) keyed by metric — ALL history, ascending by day.
    @State private var series: [String: [(day: String, value: Double)]] = [:]

    // The active range window. The data goes back years — never hard-cap.
    @State private var range: RangeWindow = .quarter

    /// Memoized per-metric resolved window. Resolving a key (effective range +
    /// trimmed rows) re-slices the full multi-year series and, on auto-widen, slices
    /// it once per candidate range. The view body asks for the same key many times
    /// per render (every StatTile, every ChartCard, plus rangeNote/rangeSummary), and
    /// SwiftUI re-evaluates the body on hover / animation / 1Hz HR ticks. The inputs
    /// (`series`, `range`) only change on load or pill tap, so we compute once and
    /// cache, recomputing via .onChangeCompat(of:) when an input actually changes.
    @State private var windowCache: [String: ResolvedSeries] = [:]

    /// Memoized per-day rows trimmed to the active window. Read by both
    /// `rangeSummaryCaption` and `spanSubtitle` every render; depends only on
    /// `appleRows` + `range`, so it's cached alongside `windowCache`.
    @State private var windowedRowsCache: [AppleDaily] = []

    /// A key's resolved (possibly auto-widened) window: the effective range plus the
    /// rows trimmed to it.
    private struct ResolvedSeries {
        var effective: RangeWindow
        var rows: [(day: String, value: Double)]
    }

    // The series keys this page pulls from the apple-health source.
    private static let seriesKeys = [
        "steps", "active_kcal", "vo2max",
        "resting_hr", "hrv", "spo2", "resp_rate", "asleep_min",
        "weight", "body_fat", "lean_mass", "bmi"
    ]

    // yyyy-MM-dd → Date (en_US_POSIX / UTC), per the project's date contract.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let spanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let asOfFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()

    /// Thousands-grouped integer formatter (steps / calories). Static so it isn't reallocated
    /// per tile on every render. (perf plan Q3)
    private static let groupedIntFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: - Range control (W / M / 3M / 6M / 1Y / ALL) — the ONE pill control.

    enum RangeWindow: String, CaseIterable, Identifiable {
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
        /// Number of trailing days; nil = everything.
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
        var caption: String {
            switch self {
            case .week:    return String(localized: "7 DAYS")
            case .month:   return String(localized: "30 DAYS")
            case .quarter: return String(localized: "90 DAYS")
            case .half:    return String(localized: "180 DAYS")
            case .year:    return String(localized: "365 DAYS")
            case .all:     return String(localized: "ALL TIME")
            }
        }
        var name: String {
            switch self {
            case .week:    return String(localized: "week")
            case .month:   return String(localized: "month")
            case .quarter: return String(localized: "3 months")
            case .half:    return String(localized: "6 months")
            case .year:    return String(localized: "year")
            case .all:     return String(localized: "all history")
            }
        }
        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [RangeWindow] {
            let order: [RangeWindow] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    var body: some View {
        ScreenScaffold(title: "Apple Health", subtitle: spanSubtitle.map { "\($0)" },
                       onRefresh: { await repo.refresh() },
                       // PERF: chart-heavy column (the tile grid plus the heart / activity / body / sleep
                       // sections, each carrying its own sparklines + metric charts). The LazyVStack path
                       // is byte-identical layout. NOTE: the populated branch wraps its sections in an
                       // inner VStack(spacing: sectionGap=22) to preserve the 22pt inter-section spacing
                       // (the scaffold stack is 20pt), so the lazy win is partial until those sections are
                       // promoted to direct children — kept as one node here to stay pixel-identical.
                       lazy: true) {
            if loaded && !hasAnyData {
                #if os(iOS)
                // No data yet, but iOS can grant live access right here — keep the Enable card above
                // the (now live-aware) empty-state copy so the richer path isn't hidden behind a
                // manual .zip export.
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    liveSyncCard
                    // #348 — when the build can't carry the HealthKit entitlement there's no "Enable"
                    // button to tap, so the empty-state copy must point at the file/Shortcuts path
                    // instead of telling the user to tap a control that isn't shown.
                    ComingSoon(what: health.auth == .entitlementMissing
                               ? "Nothing here yet. This sideloaded install can't read Apple Health directly. Import a Health export .zip in Data Sources, or turn on Shortcuts Export to bring your strap data into Health."
                               : "Nothing here yet. Tap Enable Apple Health above to read your data live, or import a Health export .zip in Data Sources.")
                }
                #else
                ComingSoon(what: "Nothing imported yet. On an iPhone: Health app, tap your photo, Export All Health Data, then import the .zip here in Data Sources.")
                #endif
            } else if !loaded {
                loadingState
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    #if os(iOS)
                    liveSyncCard
                    #endif
                    rangeControl
                    tileGrid
                    heartSection
                    activitySection
                    bodySection
                    sleepSection
                }
            }
        }
        .task(id: AppleHealthLoadKey(seq: repo.refreshSeq, dayKey: Repository.localDayKey(Date()))) { await load(allowCache: true) }
        .onChangeCompat(of: range) { _ in rebuildWindowCache() }
    }

    /// Rebuild the per-metric resolved-window cache from scratch. Called once after
    /// load and again whenever `range` changes — never inside the render path.
    private func rebuildWindowCache() {
        var cache: [String: ResolvedSeries] = [:]
        cache.reserveCapacity(Self.seriesKeys.count)
        for key in Self.seriesKeys {
            let eff = computeEffectiveRange(key)
            cache[key] = ResolvedSeries(effective: eff, rows: slice(key, eff))
        }
        windowCache = cache
        windowedRowsCache = computeWindowedRows()
    }

    /// True if ANY series or per-day row holds data (drives the empty state).
    private var hasAnyData: Bool {
        if !appleRows.isEmpty { return true }
        return series.values.contains { !$0.isEmpty }
    }

    // MARK: - Load

    private func load(allowCache: Bool = false) async {
        // Previews inject data directly (store-backed reads can't be seeded). Stays ABOVE the cache path so a
        // preview never touches the repo.
        if let pd = previewData {
            appleRows = pd.rows.sorted { $0.day < $1.day }
            workoutCount = pd.workoutCount
            series = pd.series
            rebuildWindowCache()
            loaded = true
            return
        }

        // #833/v7.7.2: the whole heavy load, cache short-circuit, DEBUG fire tally, and write-back live on the
        // long-lived repo (`performAppleHealthLoad`, a headless-testable seam) so a re-mount RESTORES the prior
        // snapshot in-memory instead of re-running the whole apple-health history read on the @MainActor, which
        // is the freeze fix. `allowCache` is true ONLY on the `.task(id:)`-driven path (a re-mount / data refresh
        // / day rollover); the direct load() sites (Enable / Sync now) leave it false so a live sync always
        // re-reads. The seam owns the cache; this view just copies the snapshot into its `@State`.
        let snapshot = await repo.performAppleHealthLoad(seriesKeys: Self.seriesKeys, allowCache: allowCache)
        appleRows = snapshot.appleRows
        workoutCount = snapshot.workoutCount
        series = snapshot.series
        rebuildWindowCache()
        loaded = true
    }

    // MARK: - Range control + header span

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
                .accessibilityLabel(rangeSummaryCaption)
        }
    }

    /// Window-level caption near the control: how many days the per-day rows span in
    /// the selected range, plus a flag if any tracked series had to auto-widen.
    private var rangeSummaryCaption: String {
        let n = windowedRows.count
        let anyWidened = Self.seriesKeys.contains { !raw($0).isEmpty && effectiveRange($0) != range }
        // Whole-phrase variants per count so translators see complete sentences (never a stitched plural).
        if anyWidened {
            return n == 1
                ? String(localized: "1 day · \(range.name) · some sparse series widened")
                : String(localized: "\(n) days · \(range.name) · some sparse series widened")
        }
        return n == 1
            ? String(localized: "1 day · \(range.name)")
            : String(localized: "\(n) days · \(range.name)")
    }

    /// Header subtitle reflects the windowed (visible) per-day span.
    private var spanSubtitle: String? {
        let rows = loaded ? windowedRows : appleRows
        guard let first = rows.first?.day, let last = rows.last?.day,
              let lo = date(first), let hi = date(last) else {
            return String(localized: "Steps, heart, sleep, body composition and VO₂ max, read locally on \(Platform.deviceNounPhrase).")
        }
        let loS = Self.spanFormatter.string(from: lo)
        let hiS = Self.spanFormatter.string(from: hi)
        let span = loS == hiS ? loS : "\(loS) → \(hiS)"
        return String(localized: "\(rows.count) days · \(span)")
    }

    /// AppleDaily rows trimmed to the active window (for the span readout), taken
    /// RELATIVE TO THE LATEST recorded day rather than "now". Served from the
    /// per-render cache; recomputed only when `appleRows`/`range` change.
    private var windowedRows: [AppleDaily] {
        loaded ? windowedRowsCache : computeWindowedRows()
    }

    /// The actual windowing of the per-day rows. Called only from
    /// rebuildWindowCache and the not-yet-loaded fallback — never per render.
    private func computeWindowedRows() -> [AppleDaily] {
        guard let n = range.days else { return appleRows }
        guard let lastDay = appleRows.last?.day, let last = date(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return appleRows.filter { row in
            guard let d = date(row.day) else { return false }
            return d >= cutoff
        }
    }

    private var loadingState: some View {
        NoopCard(tint: StrandPalette.metricCyan) {
            HStack(spacing: 10) {
                ConnectionDot(tone: .accent, pulsing: true)
                Text("Reading your Apple Health history…")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Live Apple Health (iOS only)
    //
    // The opt-in entry point for the two-way HealthKitBridge. macOS has no HealthKit, so this whole
    // card — and every `health.*` reference — is `#if os(iOS)`-gated. Tapping "Enable Apple Health"
    // shows the system permission sheet (rationale strings ship in the iOS target's Info.plist), then
    // runs the first read + write-back and refreshes this screen. Once authorized, a "Sync now"
    // control and last-synced/status line take its place.
    #if os(iOS)
    @ViewBuilder
    private var liveSyncCard: some View {
        StrandCard(padding: 20, tint: StrandPalette.metricCyan) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricCyan)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.metricCyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Apple Health (Live)")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if health.auth == .authorized {
                        StatePill(health.syncing ? "Syncing" : "Connected",
                                  tone: .positive, pulsing: health.syncing)
                    }
                }

                switch health.auth {
                case .unavailable:
                    Text("Apple Health isn't available on \(Platform.deviceNounPhrase).")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .entitlementMissing:
                    // #348 / #930: the sideload was re-signed WITHOUT the HealthKit entitlement (free
                    // Apple IDs always lack it; some paid reseller certs do too), so "Enable Apple Health"
                    // can never work and the app can never appear under Settings › Health › Data Access
                    // & Devices. Give the honest path instead of impossible Settings instructions: bring
                    // data in via a file import or the HealthKit-free Shortcuts export.
                    Text("This install can't connect to Apple Health directly. It was signed with a profile that doesn't include Apple's Health permission, so there's nothing to enable, and NOOP won't appear under Settings › Health.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("To get your Apple Health data in anyway: import a Health export .zip in Data Sources, or turn on Shortcuts Export to feed your strap data into Health without the entitlement. (A build installed from the App Store or signed with a paid Apple Developer account connects directly.)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                case .unknown, .denied:
                    Text("Read your heart rate, HRV, blood oxygen, respiratory rate, sleep, steps and energy straight from Apple Health, and write NOOP's strap data back: sleep with full stages, continuous heart rate, workouts, and nightly vitals. Everything stays on \(Platform.deviceNounPhrase).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task {
                            await health.requestAuthorization()
                            await HealthSyncRefreshCoordinator.run(
                                sync: { await health.sync() },
                                refresh: {
                                    await model.refreshAfterAppleHealthSync(
                                        authorized: health.auth == .authorized)
                                }
                            )
                            await load()
                        }
                    } label: {
                        Label("Enable Apple Health", systemImage: "heart.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.metricCyan)
                    if health.auth == .denied {
                        Text("If you don't see the prompt, enable NOOP under Settings › Health › Data Access & Devices.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .authorized:
                    if let last = health.lastSync {
                        Text("Last synced \(relativeAgo(last.timeIntervalSince1970)).")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Connected. Reading on launch and when you return to NOOP.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Button {
                        Task {
                            await HealthSyncRefreshCoordinator.run(
                                sync: { await health.sync() },
                                refresh: {
                                    await model.refreshAfterAppleHealthSync(
                                        authorized: health.auth == .authorized)
                                }
                            )
                            await load()
                        }
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.metricCyan)
                    .disabled(health.syncing)
                }

                if let err = health.lastError {
                    Text(err)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusCritical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    #endif

    // MARK: - Metric tiles (uniform 104pt StatTiles in an adaptive grid)

    private var tileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            statTile(key: "steps", label: "Steps",
                     accent: StrandPalette.metricCyan, fmt: { intString($0) })
            statTile(key: "resting_hr", label: "Resting HR",
                     accent: StrandPalette.metricRose, unit: "bpm",
                     fmt: { "\(Int($0.rounded()))" })
            statTile(key: "hrv", label: "HRV",
                     accent: StrandPalette.metricPurple, unit: "ms",
                     fmt: { "\(Int($0.rounded()))" })
            statTile(key: "vo2max", label: "VO₂ Max",
                     accent: StrandPalette.accent, unit: "ml/kg",
                     fmt: { String(format: "%.1f", $0) })
            statTile(key: "weight", label: "Weight",
                     accent: StrandPalette.accent,
                     fmt: { massLabel($0) })
            statTile(key: "body_fat", label: "Body Fat",
                     accent: StrandPalette.metricAmber, unit: "%",
                     fmt: { String(format: "%.1f", $0) })
            statTile(key: "lean_mass", label: "Lean Mass",
                     accent: StrandPalette.accent,
                     fmt: { massLabel($0) })
            statTile(key: "asleep_min", label: "Asleep avg",
                     accent: StrandPalette.metricPurple,
                     aggregate: .mean, fmt: { durationString($0) })
            workoutsTile
        }
    }

    /// How a tile's hero value is derived from its window.
    private enum Aggregate { case latest, mean }

    /// A StatTile for one metric. Sparse-safe: the window auto-falls-back to ALL,
    /// the hero is the LATEST point ("as of <date>") unless a mean is requested,
    /// and the sparkline + caption track the same resolved window.
    private func statTile(key: String, label: LocalizedStringKey,
                          accent: Color, unit: String = "",
                          aggregate: Aggregate = .latest,
                          fmt: @escaping (Double) -> String) -> some View {
        let rows = resolvedWindow(key)
        let values = rows.map(\.value)
        let value: String
        let caption: String?
        if values.isEmpty {
            value = "—"
            caption = nil
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
            label: label,
            value: value,
            caption: caption,
            accent: values.isEmpty ? StrandPalette.textTertiary : accent,
            sparkline: values.count > 1 ? sparkValues(values) : nil,
            sparkColor: accent
        )
    }

    /// Workouts is a count, not a series — its own fixed-height StatTile.
    private var workoutsTile: some View {
        StatTile(
            label: "Workouts",
            value: "\(workoutCount)",
            caption: workoutCount > 0 ? String(localized: "Apple-logged") : nil,
            accent: workoutCount > 0 ? StrandPalette.strainColor(57) : StrandPalette.textTertiary
        )
    }

    // MARK: - Chart sections (uniform ChartCard, same height per page)

    private var heartSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Heart & Vitals", overline: "Cardiac",
                          trailing: range.caption)
            chartCard(title: "Resting heart rate", key: "resting_hr",
                      gradient: roseGradient, fallback: 40...80,
                      fmt: { "\(Int($0.rounded())) bpm" })
            chartCard(title: "Heart rate variability", key: "hrv",
                      gradient: purpleGradient, fallback: 20...120,
                      fmt: { "\(Int($0.rounded())) ms" })
            chartCard(title: "Blood oxygen", key: "spo2",
                      gradient: cyanGradient, fallback: 90...100,
                      fmt: { String(format: "%.1f%%", $0) })
            chartCard(title: "Respiratory rate", key: "resp_rate",
                      gradient: accentGradient, fallback: 10...22,
                      fmt: { String(format: "%.1f rpm", $0) })
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Activity & Energy", overline: "Movement",
                          trailing: range.caption)
            chartCard(title: "Steps", key: "steps",
                      gradient: cyanGradient, fallback: 0...12000,
                      fmt: { intString($0) })
            chartCard(title: "Active energy", key: "active_kcal",
                      gradient: amberGradient, fallback: 0...1000,
                      fmt: { "\(intString($0)) kcal" })
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Body Composition", overline: "Slow threads",
                          trailing: range.caption)
            chartCard(title: "Weight", key: "weight",
                      gradient: accentGradient, fallback: 50...100,
                      fmt: { massLabel($0) })
            chartCard(title: "Body fat", key: "body_fat",
                      gradient: amberGradient, fallback: 8...35,
                      fmt: { String(format: "%.1f%%", $0) })
            chartCard(title: "Lean body mass", key: "lean_mass",
                      gradient: accentGradient, fallback: 40...80,
                      fmt: { massLabel($0) })
            chartCard(title: "BMI", key: "bmi",
                      gradient: purpleGradient, fallback: 16...35,
                      fmt: { String(format: "%.1f", $0) })
        }
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep", overline: "Rest",
                          trailing: range.caption)
            chartCard(title: "Asleep", key: "asleep_min",
                      gradient: purpleGradient, fallback: 240...600,
                      fmt: { durationString($0) })
        }
    }

    /// One uniform ChartCard for a metric series: header + TrendChart body (same
    /// height) + avg/min/max ChartFooter. Sparse-safe via resolvedWindow.
    @ViewBuilder
    private func chartCard(title: LocalizedStringKey, key: String, gradient: Gradient,
                           fallback: ClosedRange<Double>,
                           fmt: @escaping (Double) -> String) -> some View {
        let rows = resolvedWindow(key)
        let pts = trendPoints(rows)
        let vals = rows.map(\.value)
        let trailing = mean(vals).map { fmt($0) }
        // One concrete footer type (ChartFooter) keeps every card uniform — avg /
        // min / max / point-count, with dashes only in the defensive no-data case.
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
                    TrendChart(
                        points: pts,
                        gradient: gradient,
                        valueRange: valueRange(pts, fallback: fallback),
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: fmt
                    )
                } else if let only = vals.last {
                    // A single point is not a line — present the lone reading,
                    // never an "empty" state when the series has data.
                    singlePoint(only, fmt: fmt, accent: StrandPalette.sample(stops: gradient.stops, at: 0.85))
                } else {
                    emptyChart
                }
            },
            footer: { ChartFooter(footerItems) }
        )
    }

    /// Lone-reading body for series with exactly one point in range.
    private func singlePoint(_ value: Double, fmt: (Double) -> String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latest reading").strandOverline()
            Text(fmt(value)).font(StrandFont.number(34)).foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emptyChart: some View {
        Text("No readings recorded.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Per-metric gradients (colour communicates category only)

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

    /// All-history rows for a key (ascending by day).
    private func raw(_ key: String) -> [(day: String, value: Double)] { series[key] ?? [] }

    /// The latest recorded day for a key (anchors its windows).
    private func latestDate(_ key: String) -> Date? {
        guard let d = raw(key).last?.day else { return nil }
        return date(d)
    }

    /// Rows for a key over a given range, taken RELATIVE TO THE LATEST data point
    /// (not "now"); `.all` returns everything.
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

    /// The range actually shown for a key: the SELECTED range whenever its window
    /// holds ≥1 point, otherwise the smallest LARGER range that does — so switching
    /// ranges stays visibly distinct and only sparse windows widen. Served from the
    /// per-render cache; falls back to a fresh compute on a cache miss.
    private func effectiveRange(_ key: String) -> RangeWindow {
        windowCache[key]?.effective ?? computeEffectiveRange(key)
    }

    /// The actual effective-range computation (re-slices the series, once per widening
    /// candidate). Called only from rebuildWindowCache and the cache-miss fallback —
    /// never repeatedly within a single render.
    private func computeEffectiveRange(_ key: String) -> RangeWindow {
        guard !raw(key).isEmpty else { return range }
        for r in range.widening where !slice(key, r).isEmpty { return r }
        return .all
    }

    /// Rows for a key trimmed to its resolved (possibly widened) window. Served from
    /// the per-render cache; falls back to a fresh compute on a cache miss.
    private func resolvedWindow(_ key: String) -> [(day: String, value: Double)] {
        if let cached = windowCache[key]?.rows { return cached }
        return slice(key, computeEffectiveRange(key))
    }

    /// Card subtitle: "N readings · <range>", flagging an auto-widen when it happened.
    private func rangeNote(forKey key: String) -> String {
        let rows = resolvedWindow(key)
        let eff = effectiveRange(key)
        let n = rows.count
        // Whole-phrase variants per count so translators see complete sentences (never a stitched plural).
        if eff != range {
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(eff.name)")
                : String(localized: "\(n) readings · sparse, widened to \(eff.name)")
        }
        return n == 1
            ? String(localized: "1 reading · \(range.name)")
            : String(localized: "\(n) readings · \(range.name)")
    }

    private func trendPoints(_ rows: [(day: String, value: Double)]) -> [TrendPoint] {
        rows.compactMap { row in
            guard let dt = date(row.day) else { return nil }
            return TrendPoint(date: dt, value: row.value)
        }
    }

    /// Sparklines need a non-degenerate series; cap to the last ~40 samples.
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
        if abs(n) >= 1000 {
            return Self.groupedIntFmt.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        return "\(n)"
    }

    private func durationString(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Preview seam

extension AppleHealthView {
    /// In-memory bundle that bypasses the store-backed async load for previews.
    fileprivate struct PreviewData {
        var rows: [AppleDaily]
        var workoutCount: Int
        var series: [String: [(day: String, value: Double)]]
    }
}

#if DEBUG
@MainActor
private func appleHealthPreviewData() -> AppleHealthView.PreviewData {
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()

    var rows: [AppleDaily] = []
    var series: [String: [(day: String, value: Double)]] = [
        "steps": [], "active_kcal": [], "vo2max": [],
        "resting_hr": [], "hrv": [], "spo2": [], "resp_rate": [], "asleep_min": [],
        "weight": [], "body_fat": [], "lean_mass": [], "bmi": []
    ]

    // Seed ~2 years so the range control has real depth to window into.
    for i in stride(from: 729, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let day = fmt.string(from: d)
        let phase = Double(729 - i)
        let steps  = 8000 + 3200 * sin(phase / 6.0) + Double((Int(phase) * 53) % 1800)
        let active = 420 + 180 * sin(phase / 5.0 + 0.6) + Double((Int(phase) * 17) % 90)
        let rhr    = 53 + 4 * sin(phase / 8.0) + Double((Int(phase) * 7) % 4) - 2
        let hrv    = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let spo2   = 96 + 1.4 * sin(phase / 4.0) + Double((Int(phase) * 3) % 2)
        let resp   = 14.5 + 1.2 * sin(phase / 7.0)
        let vo2    = 47 + 2.2 * sin(phase / 21.0)
        let asleep = 410 + 55 * sin(phase / 5.0 + 1.1) + Double((Int(phase) * 11) % 30) - 15
        // Slow body-composition drift over the two years (measured WEEKLY → sparse).
        let weight = 78.0 - 5.0 * sin(phase / 220.0) + 0.6 * sin(phase / 13.0)
        let bodyFat = 18.0 - 3.0 * sin(phase / 240.0) + 0.4 * sin(phase / 11.0)
        let lean   = weight * (1.0 - bodyFat / 100.0)
        let bmi    = weight / (1.78 * 1.78)

        rows.append(AppleDaily(
            day: day,
            steps: Int(steps.rounded()),
            activeKcal: max(120, active),
            basalKcal: 1600,
            vo2max: vo2,
            avgHr: 72,
            maxHr: 148,
            walkingHr: 96,
            weightKg: weight))

        series["steps"]?.append((day, max(0, steps)))
        series["active_kcal"]?.append((day, max(80, active)))
        series["vo2max"]?.append((day, vo2))
        series["resting_hr"]?.append((day, max(40, rhr)))
        series["hrv"]?.append((day, max(15, hrv)))
        series["spo2"]?.append((day, min(100, spo2)))
        series["resp_rate"]?.append((day, resp))
        series["asleep_min"]?.append((day, max(180, asleep)))
        // Body composition is logged once a week → deliberately sparse, to exercise
        // the trailing-window → ALL fallback (a W/M view would otherwise be empty).
        if Int(phase) % 7 == 0 {
            series["weight"]?.append((day, weight))
            series["body_fat"]?.append((day, bodyFat))
            series["lean_mass"]?.append((day, lean))
            series["bmi"]?.append((day, bmi))
        }
    }

    return .init(rows: rows, workoutCount: 124, series: series)
}

#Preview("Apple Health — seeded") {
    AppleHealthView(previewData: appleHealthPreviewData())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}

#Preview("Apple Health — empty") {
    AppleHealthView(previewData: .init(rows: [], workoutCount: 0, series: [:]))
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 920, height: 600)
        .preferredColorScheme(.dark)
}
#endif
