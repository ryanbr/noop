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

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own card. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: "Stress", subtitle: "Autonomic load from HRV and resting heart rate",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching Today / Health / Live / Sleep / Trends: a
                       // fixed, full-bleed time-of-day sky behind the scroll content (does not scroll), so the
                       // Stress screen sits in the same liquid atmosphere as every other tab.
                       topBackground: liquidScaffoldSky()) {
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
        // Too few HR samples: empty the timeline AND clear the advanced readouts in lockstep. Without this
        // reset a later refresh that hits this path would leave the Advanced HRV card showing stale values
        // next to an empty timeline (the readouts are only recomputed past this guard).
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytime = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        let rr = (try? await repo.storeHandle()?.rrIntervals(
            deviceId: repo.deviceId, from: from, to: to, limit: 200_000)) ?? []
        // Wrist accelerometer for the motion gate: an ambulatory hour is EXERTION, not stress, so it
        // is masked rather than scored (DaytimeStress). Same store read as R-R; empty on hardware or
        // imports with no gravity, which is exactly the "no masking, prior behaviour" degradation.
        let gravity = (try? await repo.storeHandle()?.gravitySamples(
            deviceId: repo.deviceId, from: from, to: to, limit: 200_000)) ?? []

        daytime = DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz)

        // ADDITIVE advanced readouts, computed on-demand from the SAME `rr` (no extra fetch, no
        // DB / schema change, and no effect on the 0..3 score above). Each engine returns nil when
        // its own gate is not met (Baevsky needs >= 20 clean beats; freq-HRV needs >= 60 s span),
        // in which case its row is simply hidden.
        stressIndex = StressIndex.components(rr: rr)
        freqHRV = HRVFreqDomain.freqDomain(rr: rr)
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
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {

            // 1. HERO — the liquid stress-level vessel + band + one plain-English line, all in one card.
            heroCard(model)
                .staggeredAppear(index: 0)

            // 1b. ADVANCED HRV readouts (additive, on-demand). A separate, clearly-labelled card
            //     that appears only when at least one engine returned a value. It sits BELOW the
            //     hero and never alters the hero, the markers or the timeline.
            if hasAdvancedReadouts {
                advancedReadoutsCard()
                    .staggeredAppear(index: 1)
            }

            // 2. Today's numbers — uniform tiles in one grid.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today", overline: "Markers", trailing: String(localized: "vs 30-day baseline"))
                tileGrid(model)
            }
            .staggeredAppear(index: 1)

            // 3. Today's intraday timeline — when in the day stress ran high, + a
            //    passive Breathe suggestion when the recent hours stay elevated.
            if let daytime, !daytime.scored.isEmpty {
                daytimeSection(daytime)
                    .staggeredAppear(index: 2)
            }

            // 4. Trend over the chosen window.
            trendSection(model)
                .staggeredAppear(index: 3)

            // 5. Transparency — how the number is built.
            methodologyCard(model)
                .staggeredAppear(index: 4)
        }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet —
        // in-app and passive (no alert / notification), inheriting the app environment.
        .sheet(isPresented: $showBreathe) {
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem {
                            Button("Done") { showBreathe = false }
                        }
                    }
            }
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

            NoopCard(tint: StressRamp.calm) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
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
                    // 3-stop blue→green→amber WHOOP gradient as the gauge.
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

                    Text("The line is each waking hour's 0-3 proxy, scored against your own calm hours today. The bar below splits your day into calm, moderate and high stress time.")
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
        guard let mean = day.dayMean else { return String(localized: "\(n)h") }
        return String(localized: "avg \(String(format: "%.1f", mean)) · \(n)h")
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a card with a CTA that opens the existing trainer.
    private func sustainedBreatheCard(_ day: DaytimeStress.Result) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.rowSpacing) {
                    Image(systemName: "lungs.fill")
                        .foregroundStyle(StressRamp.calm)
                    Text("Sustained high stress").strandOverline()
                    Spacer()
                    StatePill("\(day.sustainedRun)h elevated", tone: .warning, showsDot: true)
                }
                Text("Your last \(day.sustainedRun) hours have stayed in the high band. A few minutes of paced breathing can help downshift your nervous system.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Start a Breathe session", systemImage: "wind",
                           kind: .primary, fullWidth: true) {
                    showBreathe = true
                }
            }
        }
        .softCardTransition()
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: 1 · Hero — the liquid stress-level vessel.
    //
    // The 0–3 stress score reads as the signature liquid gauge: a LiquidVessel that fills to score/3
    // and is tinted by the live band (calm blue → steady green → tense amber), with the count-up value +
    // "of 3" over it (the Today HeroScoreCell / Live BPM-gauge idiom). The band pill sits top-trailing and
    // one plain-English line explains the number below. Frosted card, liquid finish.

    private func heroCard(_ model: StressModel) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Stress monitor").strandOverline()
                    Spacer()
                    StatePill("\(model.band.title)", tone: model.band.tone, showsDot: true)
                }

                HStack(alignment: .center, spacing: NoopMetrics.space5) {
                    // The stress-level vessel: fills to score/3, tinted to the live band, the value
                    // counting up over it. Taps splash the gauge (the numeral is hit-transparent).
                    StressHeroGauge(score: model.score, tint: StressRamp.color(model.score))

                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text(model.band.title)
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StressRamp.color(model.score))
                        // One plain-English line beside the gauge.
                        Text(model.explanation)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 1b · Advanced HRV readouts (additive, on-demand)
    //
    // Two extra, clearly-labelled lenses on the SAME day's R-R the timeline already reads, surfaced
    // in their own card so they are visibly separate from the 0..3 monitor. Each row is shown only
    // when its engine produced a value (the engines self-gate on clean-beat count / record span),
    // and the whole card is gated by `hasAdvancedReadouts`. Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power). Drives whether the advanced card is shown at all.
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    @ViewBuilder
    private func advancedReadoutsCard() -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Advanced HRV").strandOverline()
                    Spacer()
                    Text("on demand · today's R-R")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
                    if let si = stressIndex {
                        StatTile(
                            label: "Baevsky Stress Index",
                            value: "\(Int(si.si.rounded()))",
                            caption: String(localized: "Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm."),
                            accent: StressRamp.tense
                        )
                    }

                    // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for
                    // LF (lfhf nil) fall back to the HF (rest) band power so the lens still reads.
                    if let f = freqHRV {
                        if let ratio = f.lfhf {
                            StatTile(
                                label: "Autonomic balance (LF/HF)",
                                value: String(format: "%.1f", ratio),
                                caption: String(localized: "Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward)."),
                                accent: StressRamp.steady
                            )
                        } else if f.hf > 0 {
                            StatTile(
                                label: "HF power",
                                value: "\(Int(f.hf.rounded()))",
                                caption: String(localized: "Parasympathetic (rest) band of your HRV."),
                                accent: StressRamp.steady
                            )
                        }
                    }
                }

                Text("These are extra, on-demand HRV lenses computed from today's R-R intervals. They are informational and do not change the stress score above.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
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
                caption: String(localized: "of 3 · \(model.band.title)"),
                accent: StressRamp.color(model.score),
                sparkline: model.sparkValues.count > 1 ? model.sparkValues : nil,
                sparkColor: StressRamp.color(model.score)
            )
            // Resting HR — an INCREASE is the stressful direction.
            markerTile(
                label: "Resting HR",
                value: model.rhrToday.map { String(localized: "\($0) bpm") } ?? "—",
                delta: model.rhrDelta,
                accent: StrandPalette.metricRose,
                higherIsStress: true
            )
            // HRV — a DECREASE is the stressful direction.
            markerTile(
                label: "HRV",
                value: model.hrvToday.map { String(localized: "\(Int($0.rounded())) ms") } ?? "—",
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
            deltaText = String(localized: "\(up ? "+" : "−")\(Int(abs(delta).rounded())) vs base")
            deltaColor = isStressful ? StrandPalette.statusWarning : StrandPalette.statusPositive
        } else {
            deltaText = String(localized: "at baseline")
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
                // Axis top = highest reading rounded up, plus a little headroom, so a peak curve and
                // the top axis label clear the plot clip (#974). Floor of 1 keeps a flat calm history
                // from collapsing to a zero-height axis. The gradient stays on the full 0–3 scale
                // because TrendChart keys its colors off `valueRange`, not this domain.
                let peak = (points.map(\.value).max() ?? 3).rounded(.up)
                let yTop = max(1, peak + 0.3)
                ChartCard(
                    title: "Stress · \(range.label)",
                    subtitle: String(localized: "Daily 0-3 proxy"),
                    trailing: String(localized: "avg \(String(format: "%.1f", avg))"),
                    tint: StressRamp.calm
                ) {
                    TrendChart(
                        points: points,
                        gradient: StressRamp.gradient,
                        valueRange: 0...3,
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { String(format: "%.1f", $0) },
                        accessibilityLabel: String(localized: "Stress trend"),
                        yDomain: 0...yTop
                    )
                } footer: {
                    ChartFooter([
                        ("Today", String(format: "%.1f", model.score)),
                        ("Average", String(format: "%.1f", avg)),
                        ("Days", "\(points.count)"),
                    ])
                }
                // The one segmented control. Its eight options use the shared adaptive-width mode so
                // the control stays inside the same page gutter as the chart on compact iPhones.
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                NoopCard(tint: StressRamp.calm) {
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
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("How this is computed").strandOverline()
                Text(model.usingStored
                     ? "Today's value is your recorded daily stress score (0-3)."
                     : "Stress is derived from two autonomic signals.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up, classic signs the body is activated. The combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 0) {
                    bandLegend("0-1", String(localized: "LOW"), StressRamp.calm)
                    bandLegend("1-2", String(localized: "MEDIUM"), StressRamp.steady)
                    bandLegend("2-3", String(localized: "HIGH"), StressRamp.tense)
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

// MARK: - Stress hero gauge (liquid vessel + count-up score)

/// The stress-level vessel: a LiquidVessel filled to `score`/3 and tinted to the live band, with the
/// 0–3 value counting up over it and "of 3" beneath (the Today HeroScoreCell / Live BPM-gauge idiom).
/// CountUpText self-animates the number roll; the numeral is hit-transparent so a tap reaches the
/// vessel and splashes it.
private struct StressHeroGauge: View {
    let score: Double        // 0–3
    let tint: Color

    private var frac: Double { max(0, min(1, score / 3.0)) }

    var body: some View {
        ZStack {
            LiquidVessel(value: frac, tint: tint, animated: true)
                .frame(width: 104, height: 104)
            VStack(spacing: 0) {
                // CountUpText self-animates (counts up from 0 on appear, re-rolls on value change),
                // so the score is passed straight through — no external roll state needed.
                CountUpText(
                    value: score,
                    format: { String(format: "%.1f", $0) },
                    font: StrandFont.rounded(34, weight: .bold),
                    color: .white
                )
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                Text("of 3")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .allowsHitTesting(false)   // taps fall through to the vessel → splash
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress \(String(format: "%.1f", score)) of 3")
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
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
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

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp. WHOOP has NO gold: calm reads as the link blue, a
// balanced day as positive green, and a high-stress day as warning amber. The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.accent         // #60A0E0 — calm WHOOP blue
    static let steady  = StrandPalette.statusPositive // #03E095 — balanced WHOOP green
    static let tense   = StrandPalette.statusWarning  // #F0A020 — high WHOOP amber

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

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
        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Carry (#543): today's own row is often vitals-less until the overnight is analyzed —
        // especially right after an app update relaunches and re-runs the pass — so score the NEWEST
        // day that actually carries usable signal (RHR/HRV, or a stored/imported stress value) instead of
        // calibrating, the same last-night carry every other Today vital uses. The predicate mirrors the
        // storedToday||derived gate below, so an imported stress-only latest day is still honored (not
        // skipped). Falls back to the last row when no day has any signal (cold start).
        guard let idx = days.lastIndex(where: {
            $0.restingHr != nil || $0.avgHrv != nil || storedByDay[$0.day] != nil
        }) ?? days.indices.last
        else { return nil }   // no days at all
        let today = days[idx]

        // Baseline window: up to 30 days ending the day BEFORE the scored day, so it's measured
        // against its own recent past rather than itself.
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []

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
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-stress days · \(recent.count)d")
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
                return String(localized: "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day.")
            } else if hrvDn {
                return String(localized: "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light.")
            }
            return String(localized: "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Slightly off baseline (resting HR is a touch high), so you're moderately activated. Nothing alarming; just don't overreach.")
                    : String(localized: "Slightly off baseline (HRV is a little low), so you're moderately activated. Nothing alarming; just don't overreach.")
            }
            return String(localized: "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to.")
            } else if hrvUp {
                return String(localized: "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low.")
            }
            return String(localized: "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state.")
        }
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber WHOOP ramp as
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
                    // Soft area fill under the curve — a calm WHOOP-blue wash (no gold).
                    areaPath(pts, width: w, height: h)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    StressRamp.calm.opacity(0.22),
                                    StressRamp.calm.opacity(0.02),
                                ]),
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    // The gradient line itself (blue→green→amber, left→right).
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
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(String(format: "%.1f", $0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
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

// MARK: - Stress totals bar (README screen-9, liquid finish)
//
// The Calm / Moderate / High split of the scored day, rendered as three labelled liquid tubes (the
// signature LiquidTube, matching Health's recovery contributors and Today's Key-Metrics tubes). Each
// tube fills to that band's SHARE of the scored day and is tinted to the band's WHOOP colour (calm blue /
// steady green / tense amber), with the band name + its duration above it. A day with no scored hours
// leaves all three tubes empty (no fabricated fill).

struct StressTotalsBar: View {
    let totals: StressTotals

    private struct Band: Identifiable {
        let id = UUID()
        let band: StressBand
        let label: String
        let color: Color
    }

    private var bands: [Band] {
        [
            Band(band: .low,    label: String(localized: "Calm"),     color: StressRamp.calm),
            Band(band: .medium, label: String(localized: "Moderate"), color: StressRamp.steady),
            Band(band: .high,   label: String(localized: "High"),     color: StressRamp.tense),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(bands) { b in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.label)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(durationLabel(totals.hours(b.band)))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    // The signature liquid tube: fills to the band's share of the scored day, tinted to the
                    // band colour. Static (posed) — a row of small bars shouldn't each run a live Canvas.
                    LiquidTube(frac: totals.fraction(b.band), tint: b.color, height: 10, animated: false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Today's stress split: calm \(durationLabel(totals.calmHours)), moderate \(durationLabel(totals.moderateHours)), high \(durationLabel(totals.highHours)).")
        )
    }

    /// "—" when a band had no scored hours, else "Nh" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "—" : String(localized: "\(hours)h")
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

                // Liquid hero — the stress-level vessel + band + one plain-English line.
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack {
                            Text("Stress monitor").strandOverline()
                            Spacer()
                            StatePill("\(band.title)", tone: band.tone)
                        }
                        HStack(alignment: .center, spacing: NoopMetrics.space5) {
                            StressHeroGauge(score: score, tint: StressRamp.color(score))
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text(band.title).font(StrandFont.overline)
                                    .tracking(StrandFont.overlineTracking)
                                    .foregroundStyle(StressRamp.color(score))
                                Text(StressMath.explanation(band: band, rhrDelta: 3, hrvDelta: -8, usingStored: false))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                // Screen-9 day autonomic-load line + Calm/Moderate/High totals bar.
                NoopCard(tint: StressRamp.calm) {
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

                ChartCard(title: "Stress · M", subtitle: "Daily 0-3 proxy", trailing: "avg 1.5") {
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { String(format: "%.1f", $0) })
                } footer: {
                    ChartFooter([("Today", String(format: "%.1f", score)), ("Average", "1.5"), ("Days", "30")])
                }
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
