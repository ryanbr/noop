import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH),
// and a single plain-English line on *why*. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 LOW · 1–2 MEDIUM · 2–3 HIGH.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the "How this is computed" card at the bottom.

struct StressView: View {
    @EnvironmentObject var repo: Repository

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loaded = false
    /// Trend window for the chart (W/M/3M/6M/1Y/ALL).
    @State private var range: ExploreRange = .month

    /// Today's intraday stress read (hourly timeline + sustained-high flag), computed
    /// from the day's banked HR + R-R via the SAME 0–3 proxy the daily score uses. Nil
    /// until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// Drives the Breathe sheet presented from the sustained-stress suggestion.
    @State private var showBreathe = false

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: "Stress", subtitle: "Autonomic load from HRV and resting heart rate") {
            if let model {
                content(model)
            } else if !loaded {
                ComingSoon(what: "Reading your heart-rate variability and resting heart rate…")
            } else {
                emptyState
            }
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        storedSeries = await repo.series(key: "stress", source: "my-whoop")
        loaded = true
        rebuildModelIfNeeded()
        await loadDaytime()
    }

    /// Read TODAY's banked HR + R-R and build the intraday stress timeline. Local-day
    /// window [midnight, now]; the helper buckets it into waking hours and reuses the
    /// daily score's math, so this is the same proxy at a finer grain — never a new score.
    private func loadDaytime() async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else { daytime = .empty; return }
        let rr = (try? await repo.storeHandle()?.rrIntervals(
            deviceId: repo.deviceId, from: from, to: to, limit: 200_000)) ?? []

        daytime = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: tz)
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    // MARK: Loaded content

    @ViewBuilder
    private func content(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {

            // 1. HERO — the gauge + band + one plain-English line, all in one card.
            heroCard(model)

            // 2. Today's numbers — uniform 104pt tiles in one grid.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today", overline: "Markers", trailing: "vs 30-day baseline")
                tileGrid(model)
            }

            // 3. Today's intraday timeline — when in the day stress ran high, + a
            //    passive Breathe suggestion when the recent hours stay elevated.
            if let daytime, !daytime.scored.isEmpty {
                daytimeSection(daytime)
            }

            // 4. Trend over the chosen window.
            trendSection(model)

            // 5. Transparency — how the number is built.
            methodologyCard(model)
        }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet —
        // in-app and passive (no alert / notification), inheriting the app environment.
        .sheet(isPresented: $showBreathe) {
            NavigationStack { BreathingView() }
                #if os(macOS)
                .frame(width: 520, height: 760)
                #endif
        }
    }

    // MARK: 3 · Daytime timeline (intraday, same 0–3 proxy)

    @ViewBuilder
    private func daytimeSection(_ day: DaytimeStress.Result) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Today's Timeline", overline: "Intraday",
                          trailing: timelineTrailing(day))

            NoopCard(tint: StrandPalette.stressColor) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Autonomic load through the day").strandOverline()
                        Spacer()
                        if let peak = day.peak, let lvl = peak.level {
                            Text("peak \(String(format: "%.1f", lvl)) · \(hourLabel(peak.hour))")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StressRamp.color(lvl))
                        }
                    }

                    // README screen-9: the day autonomic-load LINE, drawn with the same
                    // 3-stop blue→gold→orange gradient as the gauge.
                    DaytimeLoadLine(hours: day.hours)

                    // Hour ruler under the line (first / midday / last covered hour).
                    if let lo = day.hours.first?.hour, let hi = day.hours.last?.hour {
                        HStack {
                            Text(hourLabel(lo)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Text(hourLabel((lo + hi) / 2)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Text(hourLabel(hi)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }

                    Divider().overlay(StrandPalette.hairline)

                    // README screen-9: the Calm / Moderate / High totals bar — one stacked
                    // bar split by how many waking hours sat in each band, with durations.
                    StressTotalsBar(totals: StressTotals(hours: day.hours))

                    Text("The line is each waking hour's 0–3 proxy, scored against your own calm hours today. The bar below splits your day into calm, moderate and high stress time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Sustained-high suggestion — only when the recent run stays in the HIGH band.
            if day.sustainedHigh { sustainedBreatheCard(day) }
        }
    }

    /// "avg 1.4 · 9h" summary for the timeline header, from the scored hours.
    private func timelineTrailing(_ day: DaytimeStress.Result) -> String {
        let n = day.scored.count
        guard let mean = day.dayMean else { return "\(n)h" }
        return "avg " + String(format: "%.1f", mean) + " · \(n)h"
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a card with a CTA that opens the existing trainer.
    private func sustainedBreatheCard(_ day: DaytimeStress.Result) -> some View {
        NoopCard(tint: StrandPalette.stressColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "lungs.fill")
                        .foregroundStyle(StrandPalette.stressColor)
                    Text("Sustained high stress").strandOverline()
                    Spacer()
                    StatePill("\(day.sustainedRun)h elevated", tone: .warning, showsDot: true)
                }
                Text("Your last \(day.sustainedRun) hours have stayed in the high band. A few minutes of paced breathing can help downshift your nervous system.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showBreathe = true
                } label: {
                    Label("Start a Breathe session", systemImage: "wind")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
            }
        }
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: 1 · Hero — the README screen-9 SEMICIRCLE gauge on a clean frosted card.
    //
    // A flat 180° Material gauge (surfaceInset track + the 3-stop blue→gold→orange
    // stressGradient value arc, round caps) with a needle/marker at the value and a
    // centred big number + state word in gold. No scenic starfield / bloom — the maintainer
    // asked for less glow, so the hero reads clean and flat over the frosted card.

    private func heroCard(_ model: StressModel) -> some View {
        NoopCard(tint: StrandPalette.stressColor) {
            VStack(spacing: 14) {
                HStack {
                    Text("Stress monitor").strandOverline()
                    Spacer()
                    StatePill("\(model.band.title)", tone: model.band.tone, showsDot: true)
                }
                StressHeroGauge(score: model.score, band: model.band)
                    .frame(maxWidth: .infinity)
                // One plain-English line, full width under the gauge.
                Text(model.explanation)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2 · Today's tiles (uniform grid)

    private func tileGrid(_ model: StressModel) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            // Today's stress value, with its band as the caption.
            StatTile(
                label: "Stress",
                value: String(format: "%.1f", model.score),
                caption: "of 3 · \(model.band.title)",
                accent: StressRamp.color(model.score),
                sparkline: model.sparkValues.count > 1 ? model.sparkValues : nil,
                sparkColor: StressRamp.color(model.score)
            )
            // Resting HR — an INCREASE is the stressful direction.
            markerTile(
                label: "Resting HR",
                value: model.rhrToday.map { "\($0) bpm" } ?? "—",
                delta: model.rhrDelta,
                accent: StrandPalette.metricRose,
                higherIsStress: true
            )
            // HRV — a DECREASE is the stressful direction.
            markerTile(
                label: "HRV",
                value: model.hrvToday.map { "\(Int($0.rounded())) ms" } ?? "—",
                delta: model.hrvDelta,
                accent: StrandPalette.metricPurple,
                higherIsStress: false
            )
            // Estimated calm time — share of recent days spent in the LOW band.
            StatTile(
                label: "Calm time",
                value: model.calmTimeValue,
                caption: model.calmTimeCaption,
                accent: StressRamp.calm
            )
        }
    }

    /// A vs-baseline marker as a fixed-height StatTile. The delta is tinted by
    /// whether the move is toward stress (warning) or recovery (positive).
    private func markerTile(label: LocalizedStringKey, value: String, delta: Double?, accent: Color, higherIsStress: Bool) -> some View {
        let deltaText: String?
        let deltaColor: Color
        if let delta, abs(delta) >= 0.5 {
            let up = delta > 0
            let isStressful = (up == higherIsStress)
            deltaText = "\(up ? "+" : "−")\(Int(abs(delta).rounded())) vs base"
            deltaColor = isStressful ? StrandPalette.statusWarning : StrandPalette.statusPositive
        } else {
            deltaText = "at baseline"
            deltaColor = StrandPalette.textTertiary
        }
        return StatTile(
            label: label,
            value: value,
            caption: nil,
            accent: accent,
            delta: deltaText,
            deltaColor: deltaColor
        )
    }

    // MARK: 3 · Trend (range-controlled)

    @ViewBuilder
    private func trendSection(_ model: StressModel) -> some View {
        let points = windowedTrend(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stress Trend", overline: "History", trailing: range.name)
            if points.count >= 2 {
                let avg = points.map(\.value).reduce(0, +) / Double(points.count)
                ChartCard(
                    title: "Stress · \(range.label)",
                    subtitle: "Daily 0–3 proxy",
                    trailing: "avg " + String(format: "%.1f", avg),
                    tint: StrandPalette.stressColor
                ) {
                    TrendChart(
                        points: points,
                        gradient: StressRamp.gradient,
                        valueRange: 0...3,
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { String(format: "%.1f", $0) },
                        accessibilityLabel: "Stress trend"
                    )
                } footer: {
                    ChartFooter([
                        ("Today", String(format: "%.1f", model.score)),
                        ("Average", String(format: "%.1f", avg)),
                        ("Days", "\(points.count)"),
                    ])
                }
                // The one segmented control — full width, right-aligned.
                HStack {
                    Spacer()
                    SegmentedPillControl(ExploreRange.allCases, selection: $range) { $0.label }
                }
            } else {
                NoopCard(tint: StrandPalette.stressColor) {
                    Text("Not enough recent days to chart a trend yet. Import a history or keep wearing your strap.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// The full daily proxy trend, sliced to the selected trailing window. Falls
    /// back to ALL when the trailing slice holds < 2 points.
    private func windowedTrend(_ model: StressModel) -> [TrendPoint] {
        let all = model.fullTrend
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }

    // MARK: 4 · Methodology (transparency)

    private func methodologyCard(_ model: StressModel) -> some View {
        NoopCard(tint: StrandPalette.stressColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How this is computed").strandOverline()
                Text(model.usingStored
                     ? "Today's value is your recorded daily stress score (0–3)."
                     : "Stress is derived from two autonomic signals.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up — classic signs the body is activated. The combined shift is mapped onto a 0–3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 0) {
                    bandLegend("0–1", "LOW", StressRamp.calm)
                    bandLegend("1–2", "MEDIUM", StressRamp.steady)
                    bandLegend("2–3", "HIGH", StressRamp.tense)
                }
            }
        }
    }

    private func bandLegend(_ range: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                Text(range).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ComingSoon(what: "No stress history yet. Import your WHOOP export in Data Sources to see it.")
    }
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return "LOW"
        case .medium: return "MEDIUM"
        case .high:   return "HIGH"
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Stress ramp (the canonical Titanium & Gold Stress world: blue → gold → orange)
//
// The Stress screen's one ramp, read straight off the design token `stressGradient`
// (calm blue `#4A90E2` → balanced gold `#E8B84B` → high burnt-orange `#E0662F`). The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen and matches the per-domain Stress world. Never the red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / gold / orange the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.sleepLight     // #4A90E2 — calm blue
    static let steady  = StrandPalette.gold           // #E8B84B — balanced gold
    static let tense   = StrandPalette.statusCritical // #E0662F — high burnt-orange

    /// The 3-stop gauge ramp, evenly spaced (blue → gold → orange).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The shared design token (same colours) — used directly for arc / line fills.
    static let gradient = StrandPalette.stressGradient

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        guard let today = days.last else { return nil }

        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Baseline window: up to 30 days ending the day BEFORE today, so "today"
        // is measured against its own recent past rather than itself.
        let history = Array(days.dropLast())
        let baseline = Array(history.suffix(30))

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = "needs history"
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = "low-stress days · \(recent.count)d"
        }
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return "Resting HR is elevated and HRV is below your baseline — both classic signs of high activation. Prioritise rest, hydration and an easy day."
            } else if hrvDn {
                return "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover."
            } else if rhrUp {
                return "Resting heart rate is running high versus your norm — your body is under load today. Keep effort light."
            }
            return "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day."
        case .medium:
            if rhrUp || hrvDn {
                return "Slightly off baseline — \(rhrUp ? "resting HR is a touch high" : "HRV is a little low") — so you're moderately activated. Nothing alarming; just don't overreach."
            }
            return "You're sitting around your typical autonomic baseline — moderate stress, a normal, balanced day."
        case .low:
            if rhrDn && hrvUp {
                return "Resting heart rate is low and HRV is up — your nervous system looks well-recovered and calm. A great day to push if you want to."
            } else if hrvUp {
                return "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low."
            }
            return "Resting heart rate and HRV are sitting at or below baseline — low physiological stress. You're in a calm, recovered state."
        }
    }
}

// MARK: - Stress hero gauge — the README screen-9 SEMICIRCLE gauge
//
// A flat 180° Material gauge: a `surfaceInset` track sweeps left→right across the top
// half, the value arc is filled with the 3-stop `stressGradient` (calm blue → balanced
// gold → high burnt-orange) with round caps, and a slim needle/marker points to the
// value. The centre carries the big 0–3 number, an "of 3" caption and the band state
// word (LOW/MEDIUM/HIGH) in gold. Clean and flat — no bloom/glow.

struct StressHeroGauge: View {
    let score: Double          // 0–3
    let band: StressBand
    var diameter: CGFloat = 230

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFraction: Double = 0

    private var fraction: Double { min(max(score / 3.0, 0), 1) }
    private var lineWidth: CGFloat { diameter * 0.085 }

    var body: some View {
        // A `diameter`-wide gauge whose radius is bound by the WIDTH (so the round caps
        // never clip horizontally). The semicircle's hub sits at the bottom of the drawing
        // area; the read-out is centred inside the bowl, just above the hub. The frame is
        // `width/2 + lineWidth` tall — the full top-half plus a hair for the round caps.
        let gaugeHeight = diameter / 2 + lineWidth
        ZStack {
            Semicircle(track: true, lineWidth: lineWidth)
                .stroke(StrandPalette.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Value arc — the 3-stop stress ramp, swept along the 180° span so the colour
            // under the tip matches the value's band (blue calm → gold → orange high).
            Semicircle(track: false, fraction: animatedFraction, lineWidth: lineWidth)
                .stroke(
                    AngularGradient(
                        gradient: StressRamp.gradient,
                        center: .init(x: 0.5, y: 1.0),   // arc centre = bottom-middle
                        startAngle: .degrees(180), endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // Needle / marker at the value — a slim gold pointer from the hub to the arc.
            StressNeedle(fraction: animatedFraction, lineWidth: lineWidth)

            // Centred read-out: big number + "of 3" + state word in gold. Sits inside the
            // bowl, biased toward the hub so it never collides with the top of the arc.
            VStack(spacing: 1) {
                Text(String(format: "%.1f", score))
                    .font(StrandFont.rounded(diameter * 0.22, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text("of 3")
                    .font(StrandFont.rounded(diameter * 0.062, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(band.title)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.gold)
                    .padding(.top, 1)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, lineWidth * 0.6)
        }
        .frame(width: diameter, height: gaugeHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress \(String(format: "%.1f", score)) of 3, \(band.title)")
        .onAppear {
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
        }
    }
}

// MARK: - Semicircle arc shape (180°, left→right across the top)
//
// A half-ring whose hub is the bottom-middle of its rect. `track == true` draws the full
// 180° span; otherwise it draws `fraction` of it (animatable), so the same shape backs
// both the inset track and the gradient value arc with round caps.

struct Semicircle: Shape {
    var track: Bool = false
    var fraction: Double = 1
    var lineWidth: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Hub at bottom-middle; radius leaves room for the stroke width.
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width / 2, rect.height) - lineWidth / 2
        let span = track ? 1.0 : min(max(fraction, 0), 1)
        let start = Angle.degrees(180)                       // 9 o'clock (left)
        let end = Angle.degrees(180 + 180 * span)            // sweeps over the top to 3 o'clock
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}

// MARK: - Stress needle — a slim gold marker at the value
//
// A thin gold pointer from the gauge hub out to (just short of) the value arc, capped
// with a small hub dot. Honours the gauge's animated fill so it sweeps in with the arc.

struct StressNeedle: View {
    var fraction: Double
    var lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height)
            let radius = min(geo.size.width / 2, geo.size.height) - lineWidth / 2
            // Angle along the 180° span (π … 2π), measured from the hub.
            // Explicitly-typed sub-expressions: the CGFloat↔Double mix in the tip arithmetic
            // makes the SwiftUI type-checker thrash (it times out the body on a Debug build),
            // so cast cos/sin to CGFloat and break the point out step by step. Behaviour-identical.
            let theta: Double = .pi + .pi * min(max(fraction, 0), 1)
            let reach: CGFloat = radius - lineWidth * 0.55
            let tipX: CGFloat = center.x + reach * CGFloat(cos(theta))
            let tipY: CGFloat = center.y + reach * CGFloat(sin(theta))
            let tip = CGPoint(x: tipX, y: tipY)
            ZStack {
                Path { p in
                    p.move(to: center)
                    p.addLine(to: tip)
                }
                .stroke(StrandPalette.gold,
                        style: StrokeStyle(lineWidth: max(2, lineWidth * 0.16), lineCap: .round))

                // Hub knob.
                Circle()
                    .fill(StrandPalette.gold)
                    .frame(width: lineWidth * 0.5, height: lineWidth * 0.5)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 2))
                    .position(center)

                // Marker dot riding the arc at the value.
                Circle()
                    .fill(StrandPalette.tipCore)
                    .frame(width: lineWidth * 0.42, height: lineWidth * 0.42)
                    .overlay(Circle().fill(StressRamp.color(fraction * 3.0)).opacity(0.4))
                    .position(tip)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→gold→orange `stressGradient` as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = max(hours.count, 1)
            // x for an hour index; y maps a 0–3 level into the chart (0 at bottom).
            // (closures, not `func` — a `@ViewBuilder` closure can't contain declarations)
            let x: (Int) -> CGFloat = { i in n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1) }
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            let pts: [(CGFloat, CGFloat)] = hours.enumerated().compactMap { i, p in
                p.level.map { (x(i), y($0)) }
            }

            ZStack {
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if pts.count >= 2 {
                    // Soft area fill under the curve.
                    areaPath(pts, width: w, height: h)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    StrandPalette.stressColor.opacity(0.22),
                                    StrandPalette.stressColor.opacity(0.02),
                                ]),
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    // The gradient line itself (blue→gold→orange, left→right).
                    linePath(pts)
                        .stroke(
                            LinearGradient(gradient: StressRamp.gradient,
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                } else if let only = pts.first {
                    // A single scored hour: a lone dot rather than a line.
                    Circle()
                        .fill(StressRamp.color(1.5))
                        .frame(width: 6, height: 6)
                        .position(x: only.0, y: only.1)
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return "No intraday stress data yet today." }
        let parts = scored.map { "\($0.0):00 \(String(format: "%.1f", $0.1))" }
        return "Autonomic load today: " + parts.joined(separator: ", ")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}

// MARK: - Stress totals bar (README screen-9)
//
// One stacked horizontal bar split Calm (blue) / Moderate (gold) / High (burnt-orange)
// by how much of the scored day sat in each band, with a legend of durations below. Empty
// segments collapse; an all-empty day shows a faint placeholder track.

struct StressTotalsBar: View {
    let totals: StressTotals

    private let barHeight: CGFloat = 12

    private struct Band: Identifiable {
        let id = UUID()
        let band: StressBand
        let label: String
        let color: Color
    }

    private var bands: [Band] {
        [
            Band(band: .low,    label: "Calm",     color: StressRamp.calm),
            Band(band: .medium, label: "Moderate", color: StressRamp.steady),
            Band(band: .high,   label: "High",     color: StressRamp.tense),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The split bar.
            GeometryReader { geo in
                let w = geo.size.width
                // Visible segments share the gaps between them, so subtract those from the
                // width pool before splitting proportionally — the segments always sum to ≤ w.
                let visible = bands.filter { totals.fraction($0.band) > 0 }
                let gaps = CGFloat(max(visible.count - 1, 0)) * 2
                let usable = max(0, w - gaps)
                HStack(spacing: totals.total > 0 ? 2 : 0) {
                    if totals.total > 0 {
                        ForEach(visible) { b in
                            Capsule(style: .continuous)
                                .fill(b.color)
                                .frame(width: max(barHeight, usable * CGFloat(totals.fraction(b.band))))
                        }
                    } else {
                        Capsule(style: .continuous)
                            .fill(StrandPalette.surfaceInset)
                            .frame(width: w)
                    }
                }
                .frame(width: w, alignment: .leading)
            }
            .frame(height: barHeight)

            // Legend: a dot, the band name, and its duration.
            HStack(spacing: 0) {
                ForEach(bands) { b in
                    HStack(spacing: 7) {
                        Circle().fill(b.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.label)
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(durationLabel(totals.hours(b.band)))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Today's stress split: "
            + "calm \(durationLabel(totals.calmHours)), "
            + "moderate \(durationLabel(totals.moderateHours)), "
            + "high \(durationLabel(totals.highHours))."
        )
    }

    /// "—" when a band had no scored hours, else "Nh" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "—" : "\(hours)h"
    }
}

// MARK: - Preview

#if DEBUG
private func sampleStressTrend(_ n: Int) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<n).map { i in
        let date = cal.date(byAdding: .day, value: -(n - 1 - i), to: today)!
        let v = 1.4 + 0.9 * sin(Double(i) / 2.4) + Double((i * 13) % 5) * 0.12
        return TrendPoint(date: date, value: min(max(v, 0), 3))
    }
}

/// A sample waking-hour timeline (06:00→22:00) for the preview, with a couple of
/// no-signal gaps so the line break reads honestly.
private func sampleDaytimeHours() -> [DaytimeStress.HourPoint] {
    let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    return (DaytimeStress.wakingStartHour...DaytimeStress.wakingEndHour).map { h in
        let curve = 1.3 + 1.1 * sin(Double(h - 6) / 3.2)
        // Drop two hours to show the gap behaviour.
        let level: Double? = (h == 11 || h == 17) ? nil : min(max(curve, 0), 3)
        return DaytimeStress.HourPoint(hour: h, startTs: base + h * 3600,
                                       level: level, meanHR: 64, rmssd: 38)
    }
}

private struct StressPreviewHarness: View {
    let score: Double
    @State private var range: ExploreRange = .month
    var body: some View {
        let band = StressBand(score: score)
        let hours = sampleDaytimeHours()
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Stress").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)

                // Clean hero — the semicircle gauge on a frosted card (no scenic glow).
                NoopCard(tint: StrandPalette.stressColor) {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Stress monitor").strandOverline()
                            Spacer()
                            StatePill("\(band.title)", tone: band.tone)
                        }
                        StressHeroGauge(score: score, band: band)
                            .frame(maxWidth: .infinity)
                        Text(StressMath.explanation(band: band, rhrDelta: 3, hrvDelta: -8, usingStored: false))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Screen-9 day autonomic-load line + Calm/Moderate/High totals bar.
                NoopCard(tint: StrandPalette.stressColor) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Autonomic load through the day").strandOverline()
                        DaytimeLoadLine(hours: hours)
                        Divider().overlay(StrandPalette.hairline)
                        StressTotalsBar(totals: StressTotals(hours: hours))
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                          alignment: .leading, spacing: NoopMetrics.gap) {
                    StatTile(label: "Stress", value: String(format: "%.1f", score),
                             caption: "of 3 · \(band.title)", accent: StressRamp.color(score))
                    StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose,
                             delta: "+3 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "HRV", value: "48 ms", accent: StrandPalette.metricPurple,
                             delta: "−8 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "Calm time", value: "58%", caption: "low-stress days · 30d",
                             accent: StressRamp.calm)
                }

                ChartCard(title: "Stress · M", subtitle: "Daily 0–3 proxy", trailing: "avg 1.5") {
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { String(format: "%.1f", $0) })
                } footer: {
                    ChartFooter([("Today", String(format: "%.1f", score)), ("Average", "1.5"), ("Days", "30")])
                }
                HStack { Spacer(); SegmentedPillControl(ExploreRange.allCases, selection: $range) { $0.label } }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Stress — HIGH") {
    StressPreviewHarness(score: 2.4)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}

#Preview("Stress — LOW") {
    StressPreviewHarness(score: 0.6)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}
#endif
