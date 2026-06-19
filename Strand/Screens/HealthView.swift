import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// NOOP — Health Monitor.
/// Live heart rate hero (ChartCard with a streaming sparkline + HR-zone footer),
/// then a uniform LazyVGrid of the body's vital signs (respiratory rate, blood
/// oxygen, resting HR, HRV, skin temp) as fixed-height StatTiles, each tinted and
/// captioned with its in-range state. Re-skinned to the locked NOOP component
/// system: every surface is a NoopCard, every metric is a StatTile, every chart is
/// a ChartCard — no ad-hoc card heights or paddings.
struct HealthView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var model: AppModel

    // MARK: - Derived live HR

    /// HR to display: the spike-filtered median (model.bpm, #39) when available, else the reported
    /// value, else R-R-derived (the strap streams R-R even when its HR field reads 0).
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hasLiveHR: Bool { displayHR != nil }

    // MARK: - Body

    var body: some View {
        ScreenScaffold(title: "Health Monitor",
                       subtitle: "Live vitals, streamed from the strap.",
                       onRefresh: { await repo.refresh() }) {
            if repo.days.isEmpty && !hasLiveHR {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // Even with no history yet, a freshly-connected strap can be told to sync now (#364) —
                    // so the control is reachable before the screen has any data to show.
                    SyncStatusSection()
                    emptyState
                }
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // Manual "Sync now" + honest sync status (#364). Its own view so the ~1Hz HR stream
                    // doesn't re-render it; depends on `live` (connection/backfill state) + `model`.
                    SyncStatusSection()
                    // The live HR section is its own view: it owns `live`/`profile`,
                    // so the ~1Hz HR stream re-renders only this subtree — the static
                    // vitals grid below does not re-render on each HR tick.
                    HeartRateSection()
                    // Fitness Age (weekly, computed by IntelligenceEngine and read back from the
                    // "fitness_age" metricSeries). Its own view depending only on `repo`/`profile`,
                    // so the live HR stream never re-renders it.
                    FitnessAgeSection()
                    // Vitality / Body Age (weekly, computed by IntelligenceEngine from the mortality-
                    // hazard model). Its own view depending only on repo/profile.
                    VitalitySection()
                    // Screen-5 recovery detail: the CONTRIBUTORS to today's recovery as
                    // labelled progress bars (HRV / Resting HR / Sleep / Respiratory), each
                    // scored against the on-device baseline. Depends only on `repo`.
                    RecoveryContributorsSection()
                    // The static vitals grid is its own view depending only on `repo`,
                    // so it is unaffected by live HR ticks.
                    VitalsSection()
                    // v5 skin-temperature suite: the illness "heads-up", body clock, and (opt-in) cycle
                    // awareness, each driven by a pure StrandAnalytics engine result the analytics pass
                    // computed and AppModel publishes. Its own view depending on `model` + `repo`.
                    SkinTempSection()
                    // v5 deep-links: the records logbook + the multi-device fused record, reachable
                    // from their honest Health home as drill-in rows (not their own destinations).
                    HealthHubLinksSection()
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ComingSoon(what: "No biometrics yet. Import your WHOOP export (and Apple Health if you have it) in Data Sources to fill this in.")
    }
}

// MARK: - Sync status + "Sync now" (#364)

/// Manual "Sync now" control + honest sync status, mirroring the Android Sync-now button. Its own view
/// depending only on `live` (connection + backfill state) and `model` (the BLE pass-through), so the
/// ~1Hz live HR stream never re-renders it. Honesty rules (CLAUDE.md): the button is disabled and the
/// copy explains itself when no strap is connected; while a sync runs it shows the in-progress pill +
/// the live chunk count (never a fabricated percent — total pending is unknowable from the protocol);
/// otherwise it shows when history last synced.
private struct SyncStatusSection: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    /// The strap link is usable for a manual offload kick (matches BLEManager.syncNow's own gate).
    private var canSync: Bool { live.connected && live.bonded && !live.backfilling }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sync", overline: "Strap history",
                          trailing: live.connected ? (live.bonded ? "Connected" : "Pairing…") : "Offline")

            NoopCard(tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 14) {
                    statusRow

                    Button {
                        // Reach the BLE engine's gated entry point directly (same idiom as
                        // SettingsView's `model.ble.enableWhoop5DeepData()`). BLEManager.syncNow() is the
                        // honest gate — a no-op when no strap is connected or a sync is already running.
                        model.ble.syncNow()
                    } label: {
                        Label(live.backfilling ? "Syncing…" : "Sync now",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.noopSecondary)
                    .disabled(!canSync)
                    .accessibilityLabel("Sync now")
                    .accessibilityHint(canSync
                        ? "Pulls your strap's stored history immediately, without waiting for the next automatic sync."
                        : (live.backfilling ? "A sync is already in progress." : "Connect your strap first."))

                    Text(helperText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The status line above the button: an in-progress pill while syncing (with the live chunk count),
    /// else a last-synced read-out, else an honest "not connected".
    @ViewBuilder private var statusRow: some View {
        if live.backfilling {
            // Reuse the shared in-progress affordance so this matches every other "syncing history" surface.
            SyncingHistoryNote(chunks: live.syncChunksThisSession)
        } else if !live.connected {
            StatePill("No strap connected", tone: .neutral, showsDot: false)
        } else if let last = live.lastSyncedAt {
            HStack(spacing: 8) {
                StatePill("History synced", tone: .positive)
                Text(relativeAgo(last))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        } else {
            StatePill(live.bonded ? "Ready to sync" : "Pairing…",
                      tone: .accent, showsDot: true, pulsing: !live.bonded)
        }
    }

    private var helperText: String {
        if live.backfilling {
            return "Pulling your strap's stored history. This drains oldest-first; a deep backlog now continues automatically across passes instead of waiting between syncs."
        }
        if !live.connected {
            return "Connect your strap to sync its stored history. Until then, only imported data shows here."
        }
        if !live.bonded {
            return "Finishing the pairing handshake — Sync now becomes available once the strap is paired."
        }
        return "Syncs your strap's stored history right away, instead of waiting for the next automatic sync."
    }
}

// MARK: - Heart rate hero (live)

/// Live HR hero, split into its own view so the ~1Hz HR stream only re-renders this
/// subtree — the static vitals grid does not. Depends on `live` and `profile` only.
private struct HeartRateSection: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var model: AppModel

    /// Rolling buffer of recently-streamed live HR (newest last), so the hero graph builds a real
    /// continuous time-series instead of collapsing to a 2-point flat line when the strap streams HR
    /// but little/no R-R (the #105 case — Live HR works, but the Health graph showed only 2 samples).
    /// Each sample now carries the wall-clock time it arrived so the hero renders a real time x-axis
    /// (#198 — the chart had no time axis, so an iPhone user with no hover had no time context).
    /// Capped to ~3 min @ ~1 Hz; resets when the view is recreated, which is fine for a live trace.
    @State private var hrHistory: [LiveHRSample] = []

    /// HR to display: the spike-filtered median (model.bpm, #39) when available — raw live.heartRate
    /// carries PPG harmonic spikes (real ~92 read as 170+); AppModel.bpm's doc mandates "every screen
    /// should show THIS". Falls back to the reported value, then R-R-derived, only until the median has a sample.
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hrIsDerived: Bool { (live.heartRate ?? 0) <= 0 && !live.rr.isEmpty }

    /// HR as a fraction of HR-max (0…1).
    private func hrFraction(_ hr: Int?) -> Double {
        guard let hr = hr, profile.hrMax > 0 else { return 0 }
        return min(max(Double(hr) / Double(profile.hrMax), 0), 1)
    }

    /// Current zone 1…5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90).
    private func hrZone(_ fraction: Double) -> Int {
        switch fraction {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    /// A short, time-stamped HR series for the hero chart (newest last).
    /// Prefers the accumulated live-HR time-series — that's what a "live" graph should show, and it
    /// keeps growing even when the strap streams HR but sparse R-R (#105). Falls back to R-R-derived
    /// beats, then a flat line at the current HR. The R-R / flat fallbacks have no real per-sample
    /// timestamps, so we synthesise a 1 Hz trailing window ending "now" — the x-axis still reads as
    /// clock time and scrolls, matching the live buffer's behaviour (#198).
    private func hrSeries(_ hr: Int?) -> [LiveHRSample] {
        if hrHistory.count > 1 { return hrHistory }
        let beats = live.rr.suffix(60).compactMap { rr -> Double? in
            rr > 0 ? 60_000.0 / Double(rr) : nil
        }
        if beats.count > 1 { return Self.synthesiseSeries(beats) }
        if let hr = hr { return Self.synthesiseSeries([Double(hr), Double(hr)]) }
        return []
    }

    /// Wrap a bare value series in trailing 1 Hz timestamps ending at `Date()`, so the
    /// fallbacks (R-R-derived beats, flat line) chart on the same time x-axis as the live buffer.
    private static func synthesiseSeries(_ values: [Double]) -> [LiveHRSample] {
        let now = Date()
        let n = values.count
        return values.enumerated().map { i, v in
            LiveHRSample(date: now.addingTimeInterval(Double(i - (n - 1))), bpm: v)
        }
    }

    var body: some View {
        // Compute the derived live values ONCE per body pass and thread them into the
        // subviews, instead of re-evaluating heavy computed properties multiple times.
        let displayHR = self.displayHR
        let hasLiveHR = displayHR != nil
        let fraction = hrFraction(displayHR)
        let zone = hrZone(fraction)
        let series = hrSeries(displayHR)

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Heart Rate", overline: "Live", trailing: hrIsDerived ? "from R-R" : nil)

            // The live HR hero floats over a Charge-world scenic backdrop (the Health screen's
            // colour world), with the card itself tinted rose — heart-rate's metric accent.
            ChartCard(
                title: "Heart Rate",
                subtitle: hrIsDerived ? "Estimated from R-R interval"
                    : (hasLiveHR ? "Streaming live" : "Awaiting strap"),
                trailing: hasLiveHR ? "\(displayHR!) bpm" : "—",
                tint: StrandPalette.metricRose
            ) {
                heroChart(displayHR: displayHR, hasLiveHR: hasLiveHR,
                          fraction: fraction, zone: zone, series: series)
            } footer: {
                ChartFooter([
                    ("Zone", hasLiveHR ? "Z\(zone)" : "—"),
                    ("% Max", hasLiveHR ? "\(Int((fraction * 100).rounded()))%" : "—"),
                    ("Max HR", "\(profile.hrMax)"),
                    ("State", hasLiveHR ? "STREAMING" : "IDLE"),
                ])
            }
            .background {
                ScenicHeroBackground(domain: .charge)
                    .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            }
        }
        .onChangeCompat(of: displayHR) { newHR in
            // Append each new live HR reading (with its arrival time) so the hero graph grows a
            // continuous, time-stamped series — feeding the time x-axis (#198) and the #105 trace.
            guard let v = newHR else { return }
            hrHistory.append(LiveHRSample(date: Date(), bpm: Double(v)))
            if hrHistory.count > 180 { hrHistory.removeFirst(hrHistory.count - 180) }
        }
    }

    /// The hero chart body: a tall, time-aware HR line tinted to the current zone, with a
    /// status pill floated top-trailing. Fixed to NoopMetrics.chartHeight via ChartCard.
    private func heroChart(displayHR: Int?, hasLiveHR: Bool,
                           fraction: Double, zone: Int, series: [LiveHRSample]) -> some View {
        ZStack(alignment: .topTrailing) {
            if series.count > 1 {
                LiveTimeChart(
                    samples: series,
                    gradient: Gradient(colors: [
                        StrandPalette.hrZoneColor(max(1, zone - 1)),
                        StrandPalette.hrZoneColor(zone),
                    ])
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Live heart rate over time")
                .accessibilityValue(hasLiveHR ? "\(displayHR ?? 0) beats per minute, zone \(zone)" : "no data")
            } else {
                VStack(spacing: 8) {
                    Text(displayHR.map(String.init) ?? "—")
                        .font(StrandFont.display(72))
                        .foregroundStyle(hasLiveHR ? StrandPalette.hrZoneColor(zone) : StrandPalette.textTertiary)
                        .contentTransition(.numericText())
                        .animation(StrandMotion.interactive, value: displayHR)
                    Text("bpm").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            StatePill("\(zoneLabel(hasLiveHR: hasLiveHR, zone: zone, fraction: fraction))",
                      tone: hasLiveHR ? .accent : .neutral,
                      showsDot: hasLiveHR,
                      pulsing: hasLiveHR)
        }
    }

    private func zoneLabel(hasLiveHR: Bool, zone: Int, fraction: Double) -> String {
        guard hasLiveHR else { return "Idle" }
        return "Zone \(zone) · \(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Live HR sample + time chart

/// One streamed live-HR reading with the wall-clock time it arrived. Carrying the time
/// (rather than a bare bpm) is what lets the hero render a real time x-axis (#198).
struct LiveHRSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

/// The live HR hero chart: a zone-gradient line + soft area over a real **time** x-axis
/// (hour:minute:second), so the trace visibly scrolls as new samples arrive. Replaces the
/// axis-less Sparkline on this hero (#198) — an iPhone user has no hover, so the visible
/// clock axis is the fix. Built on Swift Charts; the rolling ~90–180 s window comes from the
/// caller's capped buffer (HeartRateSection.hrHistory).
private struct LiveTimeChart: View {
    var samples: [LiveHRSample]
    /// The gradient the line/area is stroked with (the current HR-zone band).
    var gradient: Gradient

    /// Auto-fitted y bounds with a little headroom so the trace never kisses the edges.
    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.bpm)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 5)...(hi + 5) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// A vertical gradient keyed bottom→top so the stroke colour tracks the zone band.
    private var lineGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    /// The lightest stop of the zone gradient, used to tint the area wash.
    private var areaTint: Color {
        StrandPalette.sample(stops: gradient.stops, at: 0.85)
    }

    var body: some View {
        Chart(samples) { s in
            AreaMark(
                x: .value("Time", s.date),
                y: .value("BPM", s.bpm)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                LinearGradient(
                    colors: [areaTint.opacity(0.24), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Time", s.date),
                y: .value("BPM", s.bpm)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .foregroundStyle(lineGradient)
        }
        .chartYScale(domain: yDomain)
        // catmullRom overshoots on sharp HR turns and the area fill draws unclipped — clip the
        // plot so nothing bleeds below the card (mirrors TrendChart's fix for #104).
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .clipped()
    }
}

// MARK: - Recovery contributors (screen-5: labelled progress bars)

/// The README "Recovery detail · CONTRIBUTORS" section: the inputs to today's recovery
/// (HRV, Resting HR, Sleep, Respiratory) as labelled zone/stage progress bars, each scored
/// 0–100 against the user's on-device baseline. Depends only on `repo`, so the ~1Hz live HR
/// stream never re-renders it. Presentation-only — every value reads off the latest
/// `DailyMetric` and the baseline mean of prior nights; nothing here changes data or scoring.
private struct RecoveryContributorsSection: View {
    @EnvironmentObject var repo: Repository

    /// One contributor row's resolved read-out: its 0–100 strength, the qualitative word,
    /// the metric hue, and the right-aligned raw value.
    private struct Contributor {
        let label: LocalizedStringKey
        let strength: Double?      // 0…100, nil while calibrating / no value
        let word: String
        let detail: String         // right-aligned raw reading ("64 ms")
        let tint: Color
    }

    var body: some View {
        let latest = repo.days.last
        // A contributor needs at least the recovery seed depth of prior nights to score against
        // a baseline; below that we show CALIBRATING and leave the bars unfilled but honest.
        let priorCount = repo.days.dropLast().compactMap(\.avgHrv).filter { $0 > 0 }.count
        let ready = priorCount >= Baselines.minNightsSeed
        let contributors = buildContributors(latest)

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader("Contributors", overline: "Recovery", trailing: nil)
                if ready {
                    ScoreStatePill(.solid)
                } else {
                    ScoreStatePill(.calibrating, text: "Calibrating — \(priorCount) of \(Baselines.minNightsSeed)")
                }
            }
            NoopCard(tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(contributors.enumerated()), id: \.offset) { _, c in
                        ContributorBar(label: c.label, strength: ready ? c.strength : nil,
                                       word: ready ? c.word : "Calibrating",
                                       detail: c.detail, tint: c.tint)
                    }
                }
            }
            Text("Baselines are learned on-device over your first 14 days — until then, typical ranges apply.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Resolve each contributor from the latest day against the baseline mean of prior nights.
    /// HRV and Sleep score higher when above baseline; Resting HR and Respiratory score higher
    /// when at/below baseline (lower is better). Strength is a centred 0–100 (baseline ≈ 70).
    private func buildContributors(_ latest: DailyMetric?) -> [Contributor] {
        let hrvBase  = baseline { $0.avgHrv }
        let rhrBase  = baseline { $0.restingHr.map(Double.init) }
        let sleepBase = baseline { $0.totalSleepMin }
        let respBase = baseline { $0.respRateBpm }

        return [
            Contributor(
                label: "HRV",
                strength: higherIsBetter(latest?.avgHrv, base: hrvBase),
                word: word(higherIsBetter(latest?.avgHrv, base: hrvBase)),
                detail: latest?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "—",
                tint: StrandPalette.metricCyan),       // HRV = teal
            Contributor(
                label: "Resting HR",
                strength: lowerIsBetter(latest?.restingHr.map(Double.init), base: rhrBase),
                word: word(lowerIsBetter(latest?.restingHr.map(Double.init), base: rhrBase)),
                detail: latest?.restingHr.map { "\($0) bpm" } ?? "—",
                tint: StrandPalette.gold),             // recovery contributor = gold
            Contributor(
                label: "Sleep",
                strength: higherIsBetter(latest?.totalSleepMin, base: sleepBase),
                word: word(higherIsBetter(latest?.totalSleepMin, base: sleepBase)),
                detail: latest?.totalSleepMin.map { sleepText($0) } ?? "—",
                tint: StrandPalette.sleepLight),       // sleep = blue
            Contributor(
                label: "Respiratory",
                strength: lowerIsBetter(latest?.respRateBpm, base: respBase),
                word: word(lowerIsBetter(latest?.respRateBpm, base: respBase)),
                detail: latest?.respRateBpm.map { String(format: "%.1f rpm", $0) } ?? "—",
                tint: StrandPalette.sleepLight),       // respiratory shares the blue world
        ]
    }

    /// Mean of a per-day column across prior nights (excludes the latest day so "vs baseline"
    /// compares the latest reading against history). nil until enough nights exist.
    private func baseline(_ key: (DailyMetric) -> Double?) -> Double? {
        let prior = repo.days.dropLast().compactMap(key).filter { $0 > 0 }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        return prior.reduce(0, +) / Double(prior.count)
    }

    /// Centre a "higher is better" reading on a 0…100 strength: at baseline → 70, scaling up to
    /// 100 by ~+30% above and down to 0 by ~-40% below. nil inputs return nil (no bar fill).
    private func higherIsBetter(_ value: Double?, base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        let ratio = value / base
        return clampStrength(70 + (ratio - 1) * 100)
    }
    /// Centre a "lower is better" reading (RHR, respiratory) — at baseline → 70, better as it falls.
    private func lowerIsBetter(_ value: Double?, base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        let ratio = value / base
        return clampStrength(70 - (ratio - 1) * 200)
    }
    private func clampStrength(_ v: Double) -> Double { min(100, max(0, v)) }

    /// The qualitative word under the bar's right edge — banded like the contributor strengths.
    private func word(_ strength: Double?) -> String {
        guard let s = strength else { return "—" }
        switch s {
        case ..<40:  return "Low"
        case ..<60:  return "Fair"
        case ..<78:  return "Good"
        default:     return "Strong"
        }
    }

    private func sleepText(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        return "\(m / 60)h \(m % 60)m"
    }
}

/// One README "zone / stage bar": a label + qualitative word on top, a rounded track
/// (`surfaceInset`, ~9pt tall, radius 5) with a metric-hue fill scaled to 0…100 strength, and a
/// right-aligned raw reading. Animates the fill in on appear. Used for the recovery contributors.
private struct ContributorBar: View {
    let label: LocalizedStringKey
    /// 0…100 strength; nil renders an empty (calibrating) track.
    let strength: Double?
    let word: String
    let detail: String
    let tint: Color

    @State private var drawn: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { min(1, max(0, (strength ?? 0) / 100)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).strandOverline()
                Text("· \(word)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(strength == nil ? StrandPalette.textTertiary : tint)
                Spacer()
                Text(detail)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(drawn))
                }
            }
            .frame(height: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail), \(word)")
        .onAppear {
            if reduceMotion { drawn = fraction }
            else { withAnimation(.easeOut(duration: 0.9)) { drawn = fraction } }
        }
        .onChangeCompat(of: strength) { _ in
            if reduceMotion { drawn = fraction }
            else { withAnimation(.easeOut(duration: 0.6)) { drawn = fraction } }
        }
    }
}

// MARK: - Fitness Age

/// The "Fitness Age" section: a weekly, on-device fitness comparison (NOT a biological age) computed by
/// IntelligenceEngine from the Nes/HUNT model and read back from the "fitness_age" metricSeries under the
/// strap source. Depends only on `repo` (the weekly value + the recent dailies that drive the readiness
/// checklist) and `profile` (age/sex/waist), so the ~1Hz live HR stream never re-renders it.
///
/// Two states, both honest about coverage:
///   • a value exists → a scenic hero "Fitness Age N" + a younger/older-than-your-age subtitle and a faint
///     ±band caption, tappable through to the metric's full trend, with an "ⓘ How accurate is this?"
///     affordance that reveals the readiness checklist.
///   • no value yet → the checklist card directly, with required-missing inputs deep-linking to Settings.
///
/// The checklist groups inputs by ROLE exactly as the engine reports them: "Drives your Fitness Age"
/// (age/sex/resting-HR/activity) vs "Unlocks your VO₂max" (height+weight/waist) — never implying the body
/// measurements sharpen the age (the body term cancels in the model).
private struct FitnessAgeSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Latest weekly Fitness Age (years) read from the "fitness_age" metricSeries, nil until loaded/computed.
    @State private var fitnessAge: Double?
    /// Latest estimated VO₂max (ml/kg/min) from "vo2max_est" — only present once a waist is set.
    @State private var vo2max: Double?
    @State private var loaded = false

    /// Reveal the readiness checklist (the "ⓘ How accurate is this?" disclosure under a shown value).
    @State private var showReadiness = false

    /// The two drill-downs this section can present, as ONE enum-driven sheet — two stacked
    /// `.sheet` modifiers race on macOS (only one wins) and neither carried a fixed frame, so a
    /// single item-driven sheet (mirrors WorkoutsView / FusedRecordView) is the reliable idiom.
    /// - `.trend`: the full metric trend (existing MetricDetailView for "fitness_age"). These shared
    ///   screens aren't hosted in a per-screen NavigationStack, so a sheet is the in-app drill-down.
    /// - `.settings`: Settings (the profile card) so a required-missing input can be filled in place.
    private enum FitnessSheet: String, Identifiable {
        case trend, settings
        var id: String { rawValue }
    }
    @State private var fitnessSheet: FitnessSheet?

    /// The catalog descriptor backing the trend sheet + accent.
    private var fitnessAgeMetric: MetricDescriptor? { MetricCatalog.all.first { $0.key == "fitness_age" } }

    /// Build the readiness verdict from the same signals IntelligenceEngine feeds the engine: the last 7
    /// computed/imported days give the resting-HR + activity coverage counts; the profile gives the rest.
    private var readiness: FitnessAgeReadiness {
        let last7 = repo.days.suffix(7)
        let rhrDays = last7.compactMap { $0.restingHr }.count
        let activityDays = last7.compactMap { $0.strain }.count
        return FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0,
            hasSex: !profile.sex.isEmpty,
            rhrDays: rhrDays,
            activityDays: activityDays,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0,
            hasWaist: profile.waistCm > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Fitness Age", overline: "Weekly",
                          trailing: fitnessAge != nil ? "vs age \(profile.age)" : nil)
            content
        }
        .sheet(item: $fitnessSheet) { which in
            NavigationStack {
                switch which {
                case .trend:
                    if let m = fitnessAgeMetric { MetricDetailView(metric: m) }
                case .settings:
                    SettingsView()
                }
            }
            #if os(macOS)
            .frame(width: 900, height: 820)
            #endif
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let age = fitnessAge {
            heroCard(age: age)
            if showReadiness {
                ReadinessChecklistCard(readiness: readiness,
                                       lead: nil,
                                       onFix: { fitnessSheet = .settings })
                    .transition(.opacity)
            }
        } else if loaded {
            // No value yet: lead with the checklist so the user sees exactly what's still needed.
            ReadinessChecklistCard(
                readiness: readiness,
                lead: readiness.canCompute
                    ? "A few more days and we can show your Fitness Age."
                    : "A few more days of wear — plus the basics below — and we can show your Fitness Age.",
                onFix: { fitnessSheet = .settings })
        } else {
            // Brief read of the weekly value; honest placeholder rather than an empty gap.
            ComingSoon(what: "Reading your Fitness Age…", symbol: "figure.run")
        }
    }

    /// The shown-value hero: a scenic Charge-world backdrop, the big Fitness Age number, a
    /// younger/older-than-your-age subtitle, the optional VO₂max, the ±band disclaimer, and the two
    /// affordances (tap-through to the trend + the "How accurate is this?" disclosure).
    private func heroCard(age: Double) -> some View {
        let shown = Int(age.rounded())
        let delta = Double(profile.age) - age        // +ve = fitness age younger than chronological
        let years = Int(abs(delta).rounded())
        let younger = delta >= 0
        return VStack(alignment: .leading, spacing: 14) {
            // Tap the hero body to open the full "fitness_age" trend.
            Button { fitnessSheet = .trend } label: {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fitness Age").strandOverline()
                        Text("\(shown)")
                            .font(StrandFont.display(64))
                            .foregroundStyle(StrandPalette.gold)
                            .contentTransition(.numericText())
                        Text(years == 0
                             ? "About the same as your age"
                             : "\(years) year\(years == 1 ? "" : "s") \(younger ? "younger" : "older") than your age")
                            .font(StrandFont.subhead)
                            .foregroundStyle(younger ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    }
                    Spacer(minLength: 0)
                    if let vo2 = vo2max {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("VO₂max").strandOverline()
                            Text(String(format: "%.0f", vo2))
                                .font(StrandFont.number(30))
                                .foregroundStyle(StrandPalette.metricCyan)
                            Text("ml/kg/min")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fitness Age \(shown), \(years) year\(years == 1 ? "" : "s") \(younger ? "younger" : "older") than your age. Tap to see the trend.")

            Text("± \(Int(FitnessAgeEngine.displayBandYears)) yr · a fitness comparison, not a biological age")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)

            Divider().overlay(StrandPalette.hairline)

            // The honest disclosure: what we have / what we still need, grouped by what it unlocks.
            Button {
                withAnimation(StrandMotion.interactive) { showReadiness.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("How accurate is this?")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: showReadiness ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How accurate is this? \(showReadiness ? "Hide" : "Show") the data behind your Fitness Age")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ScenicHeroBackground(domain: .charge)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(StrandPalette.gold.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    /// Load the latest weekly Fitness Age (+ optional VO₂max) from the strap's metricSeries. Uses the
    /// same `exploreSeries(key:source:)` path every other metric on this screen reads, with source
    /// "my-whoop" (the Repository merges the computed "-noop" rows under any real import). Takes the
    /// freshest point — the weekly value is keyed to the week's Saturday and refines through the week.
    private func load() async {
        let faPts = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        let vo2Pts = await repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        fitnessAge = faPts.last?.value
        vo2max = vo2Pts.last?.value
        loaded = true
    }
}

/// The readiness checklist card: an optional lead line, then the engine's `items` as ✓/⚠/○ rows with
/// their `detail` text, GROUPED by `.role` into "Drives your Fitness Age" and "Unlocks your VO₂max".
/// A required-but-missing input shows a "Fix in Settings" affordance (the engine's required+missing
/// rows are age/sex; resting-HR can only be earned by wearing the strap, so it gets no fix button).
private struct ReadinessChecklistCard: View {
    let readiness: FitnessAgeReadiness
    /// Optional intro line shown above the groups (e.g. the "a few more days" no-value message).
    let lead: LocalizedStringKey?
    /// Invoked when the user taps a required-missing row's "Fix in Settings".
    let onFix: () -> Void

    private var drivesAge: [FitnessReadinessItem] { readiness.items.filter { $0.role == .drivesAge } }
    private var unlocksVO2: [FitnessReadinessItem] { readiness.items.filter { $0.role == .unlocksVO2max } }

    var body: some View {
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    confidencePill
                    Spacer(minLength: 0)
                }
                if let lead {
                    Text(lead)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                group(title: "Drives your Fitness Age", items: drivesAge)
                group(title: "Unlocks your VO₂max", items: unlocksVO2)
                Text("Built from published methods (Nes/HUNT) on \(Platform.deviceNounPhrase). It's a fitness comparison against an average peer your age — not a biological or medical age.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The overall confidence chip, mapped onto the existing score-lifecycle pill vocabulary.
    @ViewBuilder private var confidencePill: some View {
        switch readiness.confidence {
        case .ready:    ScoreStatePill(.solid, text: "Ready")
        case .estimate: ScoreStatePill(.building, text: "Estimate — partial data")
        case .notReady: ScoreStatePill(.calibrating, text: "Not enough data yet")
        }
    }

    @ViewBuilder
    private func group(title: LocalizedStringKey, items: [FitnessReadinessItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).strandOverline()
                ForEach(items, id: \.key) { item in
                    readinessRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func readinessRow(_ item: FitnessReadinessItem) -> some View {
        // A required/optional input that's still unsatisfied earns a "Fix in Settings" affordance, but
        // only when it's actually fixable there (age/sex/body metrics/waist) — resting-HR and activity
        // coverage come from wearing the strap, so those get no fix button.
        let fixable = item.status != .satisfied
            && (item.key == "age" || item.key == "sex" || item.key == "bodyMetrics" || item.key == "waist")
        let row = HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: statusIcon(item.status))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor(item.status))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(item.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            if fixable {
                Button(action: onFix) {
                    Text("Fix in Settings")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.label): \(item.detail). Fix in Settings.")
            }
        }
        // When a Fix button is present keep it as its own VoiceOver stop (.contain); otherwise fold the
        // whole row into one labelled stop. Two branches so we never pass a nil accessibility label.
        if fixable {
            row.accessibilityElement(children: .contain)
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label), \(statusWord(item.status)). \(item.detail)")
        }
    }

    private func statusIcon(_ s: FitnessReadinessStatus) -> String {
        switch s {
        case .satisfied: return "checkmark.circle.fill"
        case .partial:   return "exclamationmark.triangle.fill"
        case .missing:   return "circle"
        }
    }
    private func statusColor(_ s: FitnessReadinessStatus) -> Color {
        switch s {
        case .satisfied: return StrandPalette.statusPositive
        case .partial:   return StrandPalette.statusWarning
        case .missing:   return StrandPalette.textTertiary
        }
    }
    private func statusWord(_ s: FitnessReadinessStatus) -> String {
        switch s {
        case .satisfied: return "ready"
        case .partial:   return "partial"
        case .missing:   return "missing"
        }
    }
}

// MARK: - Vitality / Body Age

/// The "Vitality" section: a weekly wellness score (0–100) + a Body Age in years, computed by
/// IntelligenceEngine from the published mortality-hazard model and read back from the metricSeries.
/// A wellness trend from your habits — NOT a clinical biological age. Recomputes the live best/worst
/// factor the same way the engine does, for the plain-English "why".
private struct VitalitySection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var vitality: Double?
    @State private var bodyAge: Double?
    @State private var loaded = false

    private var contributions: [VitalityEngine.Contribution] {
        let last7 = repo.days.suffix(7)
        let nights = last7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let hrvs = last7.compactMap { $0.avgHrv }
        let rhrs = last7.compactMap { $0.restingHr }.map(Double.init)
        let steps = last7.compactMap { $0.steps }.map(Double.init)
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        // Aggregate EXACTLY as the stored headline does (IntelligenceEngine), so this "what's driving it"
        // breakdown reconciles with the Vitality / Body Age number it explains rather than being recomputed
        // on different statistics: resting HR + HRV are MEDIANED (robust to one outlier night), sleep +
        // steps are MEANED. Using the mean for all four let a single bad RHR/HRV reading drift the breakdown
        // out of step with the median-based headline (code review).
        return VitalityEngine.contributions(.init(
            chronoAge: Double(profile.age),
            restingHR: rhrs.isEmpty ? nil : IntelligenceEngine.medianOf(rhrs),
            sleepHours: mean(nights),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: nights),
            rmssd: hrvs.isEmpty ? nil : IntelligenceEngine.medianOf(hrvs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: mean(steps)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Vitality", overline: "Weekly",
                          trailing: bodyAge != nil ? "Body Age \(Int((bodyAge ?? 0).rounded()))" : nil)
            if let v = vitality, let ba = bodyAge {
                hero(vitality: v, bodyAge: ba)
            } else if loaded {
                ComingSoon(what: "A few more days and we can show your Vitality.", symbol: "sparkles")
            } else {
                ComingSoon(what: "Reading your Vitality…", symbol: "sparkles")
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func hero(vitality v: Double, bodyAge ba: Double) -> some View {
        let delta = Double(profile.age) - ba
        let younger = delta >= 0
        let yrs = Int(abs(delta).rounded())
        let sorted = contributions.sorted { $0.lnHazard < $1.lnHazard }
        let best = sorted.first
        let worst = sorted.last
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vitality").strandOverline()
                    Text("\(Int(v.rounded()))")
                        .font(StrandFont.display(56))
                        .foregroundStyle(StrandPalette.gold)
                        .contentTransition(.numericText())
                    Text("out of 100").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Body Age").strandOverline()
                    Text("\(Int(ba.rounded()))")
                        .font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
                    Text(yrs == 0 ? "about your age"
                         : "\(yrs) yr\(yrs == 1 ? "" : "s") \(younger ? "younger" : "older")")
                        .font(StrandFont.footnote)
                        .foregroundStyle(younger ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            if (best?.lnHazard ?? 0) < 0 || (worst?.lnHazard ?? 0) > 0 {
                Divider().overlay(StrandPalette.hairline)
                if let best, best.lnHazard < 0 {
                    Text("Helping most: \(best.label)")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusPositive)
                }
                if let worst, worst.lnHazard > 0 {
                    Text("Holding you back: \(worst.label)")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                }
            }
            Text("A wellness estimate from your habits — not a clinical biological age.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ScenicHeroBackground(domain: .charge)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(StrandPalette.gold.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    private func load() async {
        vitality = (await repo.exploreSeries(key: "vitality", source: "my-whoop")).last?.value
        bodyAge = (await repo.exploreSeries(key: "body_age", source: "my-whoop")).last?.value
        loaded = true
    }
}

// MARK: - Vitals grid (uniform StatTiles)

/// Static vitals grid, split into its own view so it depends only on `repo` and is
/// not re-rendered by the ~1Hz live HR stream.
private struct VitalsSection: View {
    @EnvironmentObject var repo: Repository

    // Temperature display preference (D#103). Skin temp is stored in °C (absolute or a ±deviation); the
    // toggle re-labels it to °F. Display-only — banding still runs on the stored °C value.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }

    var body: some View {
        let readings = BodyVitalSigns.readings(
            sourceRows: repo.vitalMetricRows,
            temperatureUnit: temperatureUnit
        )
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Vital Signs", overline: "Latest", trailing: BodyVitalSigns.latestDayLabel(readings))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                alignment: .leading,
                spacing: NoopMetrics.gap
            ) {
                ForEach(readings) { v in
                    // Each vital is a frosted, metric-tinted StatTile — matching Today's Key-Metrics
                    // grid. `accent` carries the metric's colour world (rose RHR, purple HRV, cyan
                    // SpO₂, amber skin temp), washing the card and tinting its spark trail to match.
                    StatTile(
                        label: "\(v.label)",
                        value: v.formattedValue ?? "—",
                        caption: v.stateCaption,
                        accent: v.accent,
                        sparkline: v.sparkline,
                        sparkColor: v.metricColor
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(v.accessibilityText)
                }
            }
            Text("Once NOOP has 14 nights of history, in-range compares each vital to your own baseline (approximate — not medical advice); until then, typical adult ranges apply.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Skin-temperature suite (v5: illness heads-up · body clock · cycle awareness)

/// The v5 skin-temperature section: the confounder-suppressed illness "heads-up", the body-clock
/// estimate, and the OPT-IN cycle awareness card — each rendered from a pure StrandAnalytics engine
/// result the analytics pass computed and `AppModel` publishes. Honest throughout: the heads-up only
/// shows when the engine returns a non-quiet level; cycle awareness shows the opt-in card until the user
/// turns it on (default OFF); the body clock shows nil-state copy until it can read a rhythm.
private struct SkinTempSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    /// The cycle-awareness opt-in (default OFF). The same key AppModel reads, so a flip is consistent.
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Skin temperature", overline: "From your nightly sensor")

            // 1. Illness heads-up — only when the engine returned something worth surfacing.
            if let illness = model.illnessSignal, illness.level != .quiet {
                HeadsUpCard(result: illness)
            }

            // 2. Body clock — shows nil-state copy via the engine's own confidence handling.
            if let phase = model.circadianPhase {
                BodyClockCard(estimate: phase)
            }

            // 3. Cycle awareness — opt-in. The opt-in card until enabled; the awareness card after.
            if cycleEnabled, let cycle = model.cyclePhase {
                CycleAwarenessCard(result: cycle, curve: model.cycleCurve)
            } else if !cycleEnabled {
                CycleAwarenessOptInCard(onEnable: {
                    cycleEnabled = true
                    model.cycleAwarenessEnabled = true
                    Task { await model.refreshV5Signals() }
                })
            }

            // Honest empty state when the suite has nothing to show yet. (When cycle is OFF the opt-in
            // card always renders, so the section is never blank; this covers the cycle-ON-but-thin case.)
            if cycleEnabled && model.illnessSignal == nil && model.circadianPhase == nil && model.cyclePhase == nil {
                ComingSoon(what: "Wear the strap overnight and these read from your nightly skin temperature.",
                           symbol: "thermometer.medium")
            }
        }
    }
}

// MARK: - Health hub deep-links (Lab Book · Your Data, Fused)

/// Two drill-in rows that give the records logbook (Lab Book) and the multi-device fused record their
/// honest Health home without making either its own top-level destination — they route via `NavRouter`
/// (the macOS sidebar selects the item; iOS presents the pillar sheet).
private struct HealthHubLinksSection: View {
    @EnvironmentObject var router: NavRouter

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Records & sources", overline: "On \(Platform.deviceNounPhrase)")
            linkRow(title: "Lab Book",
                    subtitle: "Keep your bloods, BP and body numbers — private, on \(Platform.deviceNounPhrase).",
                    symbol: "books.vertical.fill", tint: StrandPalette.metricCyan) { router.openLabBook() }
            linkRow(title: "Your Data, Fused",
                    subtitle: "The best-sourced number per metric across every band you use.",
                    symbol: "square.stack.3d.up.fill", tint: StrandPalette.accent) { router.openFusedRecord() }
        }
    }

    private func linkRow(title: String, subtitle: String, symbol: String, tint: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NoopCard {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(subtitle)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Health Monitor") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 462, efficiency: 92,
            deepMin: 96, remMin: 108, lightMin: 240, disturbances: 7,
            restingHr: 52, avgHrv: 74, recovery: 81, strain: 11.4,
            exerciseCount: 1,
            spo2Pct: 97, skinTempDevC: 34.2, respRateBpm: 14.6
        )
    ]
    repo.loaded = true

    let live = LiveState()
    live.connected = true
    live.bonded = true
    live.heartRate = 132
    live.rr = [455, 460, 448, 470, 452, 461, 449, 458, 463, 451]

    return HealthView()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(ProfileStore())
        .environmentObject(AppModel())
        .environmentObject(NavRouter())
        .frame(width: 900, height: 760)
        .preferredColorScheme(.dark)
}

/// Deterministic render target for `--demo-screen fitnessage` (pair with `--demo-seed` to populate the
/// weekly value). Shows the REAL `FitnessAgeSection` on the production scaffold, so a screenshot matches
/// what ships. Reads the same injected `repo`/`profile` environment objects as the live app.
struct FitnessAgeDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Health Monitor", subtitle: "Fitness Age", onRefresh: {}) {
            FitnessAgeSection()
        }
    }
}

/// Deterministic render target for `--demo-screen vitality` (pair with `--demo-seed`).
struct VitalityDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Health Monitor", subtitle: "Vitality", onRefresh: {}) {
            VitalitySection()
        }
    }
}
#endif
