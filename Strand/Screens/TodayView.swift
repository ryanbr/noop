import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Control Center (the home dashboard) — HomeDensity rewrite
//
// The owner's complaint was "cards then random space". This rebuild is a tight,
// GAPLESS dashboard grid: one column of uniform sections, every gap == NoopMetrics.gap,
// every section break == NoopMetrics.sectionGap, equal margins from ScreenScaffold.
//
// Composition (top → bottom):
//   (a) HERO  — full-width HStack that fills the width EQUALLY: RecoveryRing (left card)
//               + InsightCard "Today's Synthesis" (right card). No lone card, no gap.
//   (b) METRICS — one adaptive LazyVGrid of fixed-104pt StatTiles (Recovery, Strain,
//               Sleep, HRV, RHR, SpO2, Respiratory, Steps, Weight, Calories) each with
//               a 14-day sparkline so the grid tiles perfectly with no empty cells.
//   (c) LAST WORKOUTS — the SAME adaptive grid of fixed-104pt workout StatTiles.
//   (d) DATA SOURCES — one full-width NoopCard footer of SourceBadges + counts.
//
// Sparse series (weight) fall back to ALL history so a tile never shows an empty
// state when data exists. Only locked StrandDesign components are used.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    // Imperial/Metric display preference (D#103). Only the Weight tile carries a convertible unit here.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    // Effort display scale (#268) — drives the Effort tile's value + caption. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // Editable Key-Metrics layout (#251) — an ordered list of the enabled tiles, persisted display-only.
    // Empty/unset shows the full default order. The "Edit" affordance on the section opens a local sheet.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @State private var showingMetricsEditor = false
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State private var sparks: [String: [Double]] = [:]
    @State private var workouts: [WorkoutRow] = []
    @State private var appleDays: [AppleDaily] = []

    // The Rest SCORE (0–100) for the logical day — IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series (imported export wins, computed strap fills). The Key-Metrics
    // "Rest" tile shows THIS, formatted like Charge/Effort, with hours-in-bed kept as the caption — the
    // tile previously showed hours where the score belonged (#248). nil until loaded / no night yet.
    @State private var restScore: Double?

    // Today's heart rate as 5-minute bucket means (midnight → now), for the 24h trend chart.
    @State private var hrPoints: [TrendPoint] = []

    // The night's sleep session overlapping the HR window — shaded as a band on the HR chart and
    // used to anchor the recovery marker at wake time (WHOOP-style Overview HR annotations).
    @State private var sleepToday: CachedSleepSession?

    // The HR chart's x-axis window. Today → midnight…now; a navigated PAST day → the full calendar
    // day (midnight…next midnight) so a morning with no banked data reads as empty space rather than
    // the axis silently starting at the first sample (#overview-hr gap clarity).
    @State private var hrAxis: ClosedRange<Date>?

    // Day navigation — 0 = today (the logical day), 1 = yesterday, … The DayNavBar chevrons and date
    // jump drive this, and every day-scoped read-out (hero synthesis, the Key-Metrics tiles, the HR
    // trend and Rest score) resolves to the selected day instead of always showing today. Mirrors the
    // Android TodayScreen.selectedDayOffset. Loads re-run when this changes (see .task(id:)).
    @State private var selectedDayOffset = 0

    // Support sheet (donate + contact) — opened from the home toolbar on macOS, and from an
    // in-content control on iOS (a primary tab has no NavigationStack, so a `.toolbar` item never
    // renders on iPhone — the affordance was dead there before this in-flow button + sheet, #185-class).
    @State private var showingSupport = false

    // "How your scores work" guide — presented at a specific score's section when the ⓘ on that
    // score (or the first-run card) is tapped. nil = not shown. ScoreSection is Identifiable, so
    // .sheet(item:) drives both presentation and the deep-link target in one binding.
    @State private var guideSection: ScoreSection?
    /// `nil` means the user tapped the generic first-run card / a non-section entry: open at the top.
    @State private var showGuideTop = false

    // One-time, dismissible first-run card pointing at the guide. Set true by either the primary tap
    // or the ✕, so it never shows again. @AppStorage matches the file's existing prefs style (#103).
    @AppStorage(Self.guideCardSeenKey) private var scoringGuideCardSeen = false
    static let guideCardSeenKey = "scoringGuideCardSeen"

    // THE single grid definition — every tile group reuses it so margins line up.
    private let grid = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// The logical day the selector resolves to: offset 0 is today's logical day (rolls at 04:00 like
    /// `repo.today`), past offsets count back from it. Presentation-only — used to pick which stored row
    /// is on screen and to anchor the HR-trend window. Mirrors Android TodayScreen.selectedDay.
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    private var selectedDayKey: String { Repository.localDayKey(selectedLogicalDay) }

    /// The DailyMetric shown for the selected day. Offset 0 prefers the live `repo.today` (so the small
    /// hours after midnight still show the logical day's banked row), past offsets look the stored row up
    /// by key. nil when no row exists for that day — every read-out then renders its honest empty state.
    private var displayDay: DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Recovery cold-start: recovery is nil until the HRV baseline crosses the seed gate
    /// (Baselines.minNightsSeed valid nights). While calibrating, this is the count of nights
    /// banked so far — it drives an honest "Calibrating — N of 4 nights" on the recovery ring,
    /// the synthesis card and the Key Metrics tile instead of a bare empty state. It self-clears
    /// the moment recovery populates, and never claims "calibrating" at/above the seed gate.
    /// Mirrors Android TodayScreen.recoveryCalibrationNights (7b5f212). Only meaningful for today —
    /// a past day with no recovery is missing data, not mid-calibration, so navigated days return nil.
    private var recoveryCalibration: Int? {
        guard selectedDayOffset == 0 else { return nil }
        return RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                                hasRecovery: repo.today?.recovery != nil)
    }

    /// Synthesis-card copy while the recovery baseline calibrates; nil otherwise. Built as
    /// LocalizedStringKey literals so the String Catalog picks up the %lld patterns.
    private var calibrationStatus: LocalizedStringKey? {
        recoveryCalibration == nil ? nil : "Calibrating"
    }
    private var calibrationDetail: LocalizedStringKey? {
        guard let n = recoveryCalibration else { return nil }
        return "Learning your baseline — \(n) of \(Baselines.minNightsSeed) nights."
    }

    /// The iOS tab is already labelled "Today", and "Control Center" collides with the OS feature of
    /// that name (on both platforms). Match the tab on iOS; keep the established name on macOS.
    private var screenTitle: LocalizedStringKey {
        #if os(iOS)
        "Today"
        #else
        "Control Center"
        #endif
    }

    var body: some View {
        ScreenScaffold(title: screenTitle, subtitle: "\(dateLine)",
                       onRefresh: { await repo.refresh() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HealthAlertBanner()
                // Browse past days — chevrons + a date jump capped at today (no future days).
                DayNavBar(selectedOffset: selectedDayOffset) { selectedDayOffset = $0 }
                // The "still building" and "new here?" prompts are about getting today's scores going,
                // so they stay anchored to today rather than reappearing on every navigated past day.
                if selectedDayOffset == 0 && repo.today?.recovery == nil {
                    // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
                    if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
                    DataPendingNote(
                        title: "Live now. Your scores are building.",
                        message: "Your live heart rate is working from the strap, and charge, effort and rest build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                    )
                }
                // One-time pointer to the scoring guide, shown once scores exist.
                if selectedDayOffset == 0 && repo.today?.recovery != nil && !scoringGuideCardSeen {
                    scoringGuideFirstRunCard
                }
                heroSection
                heartRateTrendSection
                readinessSection
                metricsSection
                workoutsSection
                // Honest, dismissible 12-hourly donation ask — a card in the flow, never a modal.
                DonationNudgeCard()
                #if os(iOS)
                // iOS entry point to Support (donate + contact). macOS opens the same sheet from the
                // toolbar heart, but a primary tab on iPhone has no nav bar to host a `.toolbar` item,
                // so the affordance lives in-content here and presents SupportView as an auto-sized sheet.
                supportRow
                #endif
                sourcesSection
            }
        }
        // Reload when the data refreshes OR the selected day changes — the HR trend and Rest score are
        // day-scoped, so navigating must re-fetch them for the newly selected window.
        .task(id: TodayLoadKey(seq: repo.refreshSeq, offset: selectedDayOffset)) { await loadAll() }
        #if os(macOS)
        // macOS hosts the Support affordance in the window toolbar (RootView's NavigationSplitView
        // supplies the toolbar) and presents it as the fixed-width SupportModalOverlay panel. On iOS
        // this path is unavailable (no nav bar on a primary tab) and the 560pt panel would overflow
        // iPhone, so the in-content `supportRow` + auto-sized `.sheet` below take over instead.
        .toolbar {
            ToolbarItem {
                Button { showingSupport = true } label: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(StrandPalette.metricRose)
                        .attentionWiggle(period: 4)
                }
                .help("Support NOOP — donate or get in touch")
                .accessibilityLabel("Support NOOP — donate or get in touch")
            }
        }
        .overlay {
            if showingSupport {
                SupportModalOverlay(isPresented: $showingSupport)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSupport)
        #else
        // iOS: present Support as an auto-sized sheet (sizes to the device, unlike the 560pt overlay).
        .sheet(isPresented: $showingSupport) { SupportView() }
        #endif
        // The scoring guide, opened at a specific score from its ⓘ.
        .sheet(item: $guideSection) { section in
            ScoringGuideView(initialSection: section, onClose: { guideSection = nil })
        }
        // The scoring guide opened at the top (the first-run card's primary action).
        .sheet(isPresented: $showGuideTop) {
            ScoringGuideView(onClose: { showGuideTop = false })
        }
    }

    // MARK: First-run scoring-guide card (one-time, dismissible)

    /// "New here?" — a single, dismissible card that points first-time users at the guide. Tapping the
    /// card opens the guide; the ✕ closes it. Either action sets `scoringGuideCardSeen`, so it shows
    /// once and never again. Mirrors the DonationNudgeCard's in-flow, never-modal pattern.
    private var scoringGuideFirstRunCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New here?")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("See how Charge, Effort and Rest are calculated — and how they differ from WHOOP.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        scoringGuideCardSeen = true
                        showGuideTop = true
                    } label: {
                        Label("How your scores work", systemImage: "arrow.right")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button {
                    scoringGuideCardSeen = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            // The whole card is tappable as the primary action; the ✕ stops the tap from also firing.
            .contentShape(Rectangle())
            .onTapGesture {
                scoringGuideCardSeen = true
                showGuideTop = true
            }
        }
    }

    #if os(iOS)
    // MARK: Support entry point (iOS) — the in-content stand-in for the macOS toolbar heart.

    /// An in-flow card that opens the Support sheet (donate + contact). The whole card is the tap
    /// target; reuses the heart.fill + metricRose styling and the accessibility copy of the macOS
    /// toolbar button so both platforms read identically. iOS-only — macOS keeps the toolbar item.
    private var supportRow: some View {
        Button { showingSupport = true } label: {
            NoopCard {
                HStack(spacing: 14) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.metricRose)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Support NOOP")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Donate or get in touch — totally optional.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Support NOOP — donate or get in touch")
    }
    #endif

    // MARK: Readiness — on-device training-readiness synthesis (HRV / resting-HR / load).

    @ViewBuilder
    private var readinessSection: some View {
        let r = ReadinessEngine.evaluate(days: repo.days, today: Repository.logicalDayKey(Date()))
        if r.level != .insufficient {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Readiness", overline: "Should you push today?")
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle().fill(readinessColor(r.level)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(r.headline).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel("Readiness: \(levelWord(r.level)). \(r.headline)")
                            Spacer()
                            if let acwr = r.acwr {
                                Text("load \(String(format: "%.2f", acwr))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .help("Acute (7-day) vs chronic (28-day) training load. 0.8–1.3 is the sweet spot.")
                            }
                        }
                        Text(r.summary).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !r.signals.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(r.signals, id: \.key) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    // Glyph + colour (not colour alone) so the flag reads
                                    // for colour-blind users; hidden from VoiceOver since the
                                    // flag word is folded into the row's combined label below.
                                    Image(systemName: flagSymbol(s.flag))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(flagColor(s.flag))
                                        .padding(.top, 4)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.label).font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                        if let evidence = s.evidence {
                                            Text(evidence).font(StrandFont.captionNumber)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                    }
                                        .frame(width: 104, alignment: .leading)
                                    Text(s.detail).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(s.label), \(flagWord(s.flag)): \(s.detail)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Word + glyph equivalents so the colour-coded severity isn't carried by hue
    // alone — read by VoiceOver and visible to colour-blind users.
    private func levelWord(_ l: ReadinessEngine.Level) -> String {
        switch l {
        case .primed:       return "Primed"
        case .balanced:     return "Balanced"
        case .strained:     return "Strained"
        case .rundown:      return "Run down"
        case .insufficient: return "Not enough data"
        }
    }

    private func flagWord(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "Good"
        case .neutral: return "Neutral"
        case .watch:   return "Watch"
        case .bad:     return "Alert"
        }
    }

    /// Colour-independent glyph so severity isn't conveyed by hue alone.
    private func flagSymbol(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "checkmark.circle.fill"
        case .neutral: return "minus.circle.fill"
        case .watch:   return "exclamationmark.circle.fill"
        case .bad:     return "exclamationmark.triangle.fill"
        }
    }

    private func readinessColor(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    private func flagColor(_ f: ReadinessEngine.Flag) -> Color {
        switch f {
        case .good:    return StrandPalette.accent
        case .neutral: return StrandPalette.textTertiary
        case .watch:   return StrandPalette.statusWarning
        case .bad:     return StrandPalette.metricRose
        }
    }

    // MARK: (a) HERO — three ring scores (Charge / Effort / Rest) over a scenic backdrop,
    // then the green-tinted Synthesis coaching card. Bevel layout.

    @ViewBuilder
    private var heroSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(synthesisTitle, overline: "At a glance",
                          trailing: greetingWord)

            // The three daily scores as layered ring gauges, side by side, each in its own
            // colour world, floated over a scenic Charge-tinted backdrop. The grid reflows to a
            // single column on a narrow (iPhone) width so the rings never crush.
            scoreHeroRow(d: d, score: score)

            // The plain-English read-out — a green-tinted Synthesis coaching card under the rings.
            InsightCard(
                category: "Synthesis",
                status: calibrationStatus ?? "\(synthesisWord(score))",
                detail: calibrationDetail ?? "\(synthesisDetail(d))",
                statusColor: score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary,
                tint: StrandPalette.chargeColor
            )
        }
    }

    /// The three score rings (Charge / Effort / Rest) over a scenic hero background.
    @ViewBuilder
    private func scoreHeroRow(d: DailyMetric?, score: Double?) -> some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)]
        ZStack {
            ScenicHeroBackground(domain: .charge)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            LazyVGrid(columns: cols, spacing: NoopMetrics.gap) {
                // CHARGE — recovery 0–100. Honest empty / calibrating overlay when nil.
                heroScoreCell(domain: .charge, section: .charge) {
                    ZStack {
                        RecoveryRing(
                            score: score ?? 0, diameter: 132,
                            lineWidth: 13,
                            showsLabel: score != nil, showsHover: score != nil
                        )
                        if score == nil { ringEmptyOverlay(d: d) }
                    }
                }
                // EFFORT — strain on the 0–21 gauge.
                heroScoreCell(domain: .effort, section: .effort) {
                    ZStack {
                        StrainGauge(
                            strain: effortGaugeValue(d) ?? 0, diameter: 132,
                            lineWidth: 13,
                            showsLabel: d?.strain != nil, showsHover: d?.strain != nil
                        )
                        if d?.strain == nil { ringNoData() }
                    }
                }
                // REST — sleep composite 0–100, reusing the recovery ring's scale.
                heroScoreCell(domain: .rest, section: .rest) {
                    ZStack {
                        RecoveryRing(
                            score: restScore ?? 0, diameter: 132,
                            lineWidth: 13,
                            showsLabel: restScore != nil, showsHover: restScore != nil,
                            valueFormat: { "Rest \(Int($0.rounded()))" }
                        )
                        if restScore == nil { ringNoData() }
                    }
                }
            }
            .padding(NoopMetrics.gap)
        }
    }

    /// One score-ring cell: a frosted tinted card carrying the ring + a domain label + the ⓘ.
    @ViewBuilder
    private func heroScoreCell<RingBody: View>(domain: DomainTheme, section: ScoreSection,
                                               @ViewBuilder ring: @escaping () -> RingBody) -> some View {
        NoopCard(padding: 12, tint: domain.color) {
            VStack(spacing: 8) {
                Text(domain.rawValue.capitalized)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(domain.color)
                ring().frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { scoreInfoButton(section) }
        }
    }

    /// Strain value to feed the Effort gauge (0–21 scale). The stored `strain` is on NOOP's
    /// 0–100 Effort axis, so map it back down to the gauge's 0–21 span for the arc + number.
    private func effortGaugeValue(_ d: DailyMetric?) -> Double? {
        d?.strain.map { ($0 / 100.0) * 21.0 }
    }

    /// Honest overlay shown over the Charge ring when recovery is nil: calibrating count or No data.
    @ViewBuilder
    private func ringEmptyOverlay(d: DailyMetric?) -> some View {
        VStack(spacing: 3) {
            if let n = recoveryCalibration {
                Text("Calibrating").font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
                Text("\(n) of \(Baselines.minNightsSeed)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else {
                ringNoData()
            }
        }
    }

    @ViewBuilder
    private func ringNoData() -> some View {
        Text("No data").font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: HEART RATE — today's continuous HR, off the strap's own ~1Hz history.

    /// A full-width 24-hour heart-rate trend, plotted from 5-minute bucket means of the strap's
    /// `hrSample` history (offloaded even while the app was closed, so the day reads continuously).
    /// Hidden until there are at least two buckets — a strap-only user with no wear today sees nothing
    /// rather than an empty axis. Mirrored on Android (TodayScreen.kt HeartRateTrendCard).
    @ViewBuilder
    private var heartRateTrendSection: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "\(selectedDayOverline)")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: selectedDayOffset == 0 ? "5-minute average · since midnight" : "5-minute average · selected day",
                    trailing: v.last.map { "\(Int($0.rounded())) bpm" },
                    tint: StrandPalette.metricRose
                ) {
                    OverviewHRChart(
                        points: hrPoints,
                        sleep: sleepSpan,
                        workouts: workoutSpans,
                        recovery: recoveryMarker,
                        effort: effortMarker,
                        gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                        valueRange: hrRange(v),
                        xRange: hrAxis,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { "\(Int($0.rounded())) bpm" },
                        dateFormat: { Self.hrTimeFmt.string(from: $0) }
                    )
                } footer: {
                    ChartFooter([
                        ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                        ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                        ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                    ])
                }
            }
        }
    }

    /// Padded HR axis range so the line never sits flush against an edge (mirrors MetricExplorer.valueRange).
    private func hrRange(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 40...120 }
        if hi <= lo { return (lo - 5)...(hi + 5) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: Overview HR markers (sleep band · workout glyphs · Charge / Effort)

    /// The HR chart's x-window, derived from the loaded points (used to scope workout glyphs).
    private var hrWindow: ClosedRange<Date>? {
        guard let lo = hrPoints.first?.date, let hi = hrPoints.last?.date, lo < hi else { return nil }
        return lo...hi
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06").
    private func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    /// Last night's sleep as a shaded band, labelled with its duration.
    private var sleepSpan: OverviewHRChart.SleepSpan? {
        guard let s = sleepToday else { return nil }
        return .init(
            start: Date(timeIntervalSince1970: TimeInterval(s.startTs)),
            end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
            label: hoursMinutes(s.endTs - s.startTs)
        )
    }

    /// Each workout overlapping the HR window, as a sport glyph anchored at its HR peak.
    private var workoutSpans: [OverviewHRChart.WorkoutSpan] {
        guard let win = hrWindow else { return [] }
        return workouts.compactMap { w in
            let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
            guard end >= win.lowerBound, start <= win.upperBound else { return nil }
            return .init(start: start, end: end, symbol: sportSymbol(w.sport))
        }
    }

    /// "Charge" marker (NOOP's name for recovery) at wake time (sleep end), else at the window start.
    /// Hidden while calibrating.
    private var recoveryMarker: OverviewHRChart.EdgeMarker? {
        guard let rec = displayDay?.recovery else { return nil }
        let at = sleepToday.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
            ?? hrPoints.first?.date
        guard let date = at else { return nil }
        return .init(date: date, label: "\(Int(rec.rounded()))% Charge",
                     color: StrandPalette.recoveryColor(rec), alignment: .leading)
    }

    /// "Effort" marker pinned to the right edge (latest HR sample). Routed through the SAME formatter
    /// as the Effort tile (`UnitFormatter.effortDisplay`) so it honours the 0–100 / WHOOP-0–21 scale
    /// preference (#268) and reads identically — the stored strain is on the 0–100 axis, so a morning
    /// "21.2" is 21.2-of-100, not WHOOP's near-max 21-of-21.
    private var effortMarker: OverviewHRChart.EdgeMarker? {
        guard let strain = displayDay?.strain, let date = hrPoints.last?.date else { return nil }
        return .init(date: date,
                     label: "\(UnitFormatter.effortDisplay(strain, scale: effortScale)) Effort",
                     color: StrandPalette.strainColor(strain), alignment: .trailing)
    }

    // MARK: (b) METRICS — one uniform grid of 104pt StatTiles, every cell filled.

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // The section header keeps its "14-day trend" trailing label; an Edit control sits beside it
            // to open the local layout editor (#251). No new nav destination — a sheet over Today.
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Key Metrics", overline: "\(selectedDayOverline)", trailing: "14-day trend")
                Button {
                    showingMetricsEditor = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(StrandFont.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Edit Key Metrics")
                .help("Choose which Key Metrics show and reorder them")
            }
            // Render the enabled tiles in the saved order; an empty layout still shows the default set.
            LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(enabledKeyMetrics) { metric in
                    keyMetricTile(metric)
                }
            }
        }
        .sheet(isPresented: $showingMetricsEditor) {
            KeyMetricsEditorSheet(layoutRaw: $keyMetricsRaw)
        }
    }

    /// One Key-Metric tile, keyed so the grid can be filtered + reordered per the saved layout (#251).
    /// Each case is byte-for-byte the tile that used to be hard-coded in the grid — the refactor only
    /// changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    @ViewBuilder
    private func keyMetricTile(_ metric: KeyMetric) -> some View {
        let d = displayDay
        let aLatest = appleDays.last
        switch metric {
        case .charge:
            StatTile(
                label: "Charge",
                value: d?.recovery.map { "\(Int($0.rounded()))%" }
                    ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" } ?? "—",
                caption: d?.recovery.map { StrandPalette.recoveryState($0).capitalized }
                    ?? recoveryCalibration.map { _ in "Calibrating" },
                accent: d?.recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                sparkline: sparks["recovery"],
                sparkColor: StrandPalette.accent
            )
        case .effort:
            StatTile(
                label: "Effort",
                value: d?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                caption: "of \(UnitFormatter.effortScaleMax(effortScale))",
                accent: d?.strain.map { StrandPalette.strainColor($0) } ?? StrandPalette.textPrimary,
                sparkline: sparks["strain"],
                sparkColor: StrandPalette.strain066
            )
            .overlay(alignment: .topTrailing) { scoreInfoButton(.effort) }
        case .rest:
            StatTile(
                label: "Rest",
                value: restScore.map { "\(Int($0.rounded()))%" } ?? "—",
                caption: restCaption(d),
                accent: restScore.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                sparkline: sparks["sleep_total_min"],
                sparkColor: StrandPalette.metricPurple
            )
            .overlay(alignment: .topTrailing) { scoreInfoButton(.rest) }
        case .hrv:
            StatTile(
                label: "HRV",
                value: d?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—",
                caption: "ms",
                accent: StrandPalette.metricPurple,
                sparkline: sparks["hrv"],
                sparkColor: StrandPalette.metricPurple
            )
        case .restingHr:
            StatTile(
                label: "Resting HR",
                value: d?.restingHr.map { "\($0)" } ?? "—",
                caption: "bpm",
                accent: StrandPalette.metricRose,
                sparkline: sparks["rhr"],
                sparkColor: StrandPalette.metricRose
            )
        case .bloodOxygen:
            StatTile(
                label: "Blood Oxygen",
                value: d?.spo2Pct.map { String(format: "%.0f%%", $0) } ?? "—",
                caption: "SpO₂",
                accent: StrandPalette.metricCyan,
                sparkline: sparks["spo2"],
                sparkColor: StrandPalette.metricCyan
            )
        case .respiratory:
            StatTile(
                label: "Respiratory",
                value: d?.respRateBpm.map { String(format: "%.1f", $0) } ?? latestString("resp_rate", decimals: 1),
                caption: "rpm",
                accent: StrandPalette.accent,
                sparkline: sparks["resp_rate"],
                sparkColor: StrandPalette.accent
            )
        case .steps:
            StatTile(
                label: "Steps",
                value: aLatest?.steps.map { intString(Double($0)) } ?? latestString("steps", decimals: 0),
                caption: "today",
                accent: StrandPalette.metricCyan,
                sparkline: sparks["steps"],
                sparkColor: StrandPalette.metricCyan
            )
        case .weight:
            StatTile(
                label: "Weight",
                value: weightTile(aLatest?.weightKg).value,
                caption: weightTile(aLatest?.weightKg).caption,
                accent: StrandPalette.accent,
                sparkline: sparks["weight"],
                sparkColor: StrandPalette.accent
            )
        case .calories:
            StatTile(
                label: "Calories",
                value: caloriesValue(aLatest),
                caption: "active",
                accent: StrandPalette.metricAmber,
                sparkline: sparks["active_kcal"],
                sparkColor: StrandPalette.metricAmber
            )
        }
    }

    // MARK: (c) LAST WORKOUTS — SAME grid, uniform 104pt workout tiles.

    @ViewBuilder
    private var workoutsSection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last Workouts", overline: "Activity",
                              trailing: "\(workouts.count) total")
                LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StatTile(
                            label: "\(WorkoutSource.displaySport(w.sport))",
                            value: workoutDuration(w),
                            caption: workoutCaption(w),
                            accent: StrandPalette.strainColor(w.strain ?? 0),
                            delta: w.energyKcal.map { "\(Int($0.rounded())) kcal" },
                            deltaColor: StrandPalette.metricAmber
                        )
                    }
                }
            }
        }
    }

    // MARK: (d) DATA SOURCES — one full-width footer card.

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data Sources", overline: "Provenance")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(
                        badge: "Whoop",
                        tint: StrandPalette.accent,
                        present: !repo.days.isEmpty,
                        detail: "\(repo.days.count) days · \(repo.sleeps.count) sleeps"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    sourceRow(
                        badge: "Apple Health",
                        tint: StrandPalette.metricCyan,
                        present: !appleDays.isEmpty,
                        detail: "\(appleDays.count) days · \(workouts.filter { WorkoutSource.isAppleHealth($0.source) }.count) workouts"
                    )
                    strapBatteryRow
                    Divider().overlay(StrandPalette.hairline)
                    strapSyncRow
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(badge: String, tint: Color, present: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            SourceBadge("\(badge)", tint: present ? tint : StrandPalette.textTertiary)
            Spacer()
            Text(present ? detail : "Not connected")
                .font(StrandFont.captionNumber)
                .foregroundStyle(present ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        }
    }

    /// Honest strap-sync outcome for a cloud-free app (ports the Android Live line, ed6a31d): the
    /// stalled-offload error when the last one died, else "History synced N ago". Hidden while an
    /// offload runs — SyncingHistoryNote already says so. TimelineView re-renders the relative label
    /// each minute so "5 min ago" can't go stale while the window sits open with no strap connected
    /// (LiveState publishes nothing then).
    @ViewBuilder
    private var strapSyncRow: some View {
        if !live.backfilling {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: 10) {
                    SourceBadge("Strap sync",
                                tint: live.lastSyncError != nil ? StrandPalette.statusWarning
                                    : live.lastSyncedAt != nil ? StrandPalette.accent
                                    : StrandPalette.textTertiary)
                    Spacer()
                    if let error = live.lastSyncError {
                        Text(error)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let at = live.lastSyncedAt {
                        Text("History synced \(relativeAgo(at, now: context.date.timeIntervalSince1970))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Not synced yet")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// Strap battery on the dashboard (#159) — the live reading the keep-alive refreshes, so a glance
    /// covers charge without opening Live. Rendered ONLY while a strap is connected AND a reading
    /// exists; otherwise the row (and its divider) isn't there at all — no empty state.
    @ViewBuilder
    private var strapBatteryRow: some View {
        if live.connected, let pct = live.batteryPct {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 10) {
                SourceBadge("Strap battery", tint: batteryTint(pct))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol(pct))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(batteryTint(pct))
                    Text("\(Int(pct.rounded()))%")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(Int(pct.rounded())) percent\(live.charging == true ? ", charging" : "")")
            }
        }
    }

    /// Battery tint — same thresholds as the menu-bar stat (MenuBarContent.batteryTone).
    private func batteryTint(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return StrandPalette.statusCritical
        case ..<35: return StrandPalette.statusWarning
        default:    return StrandPalette.statusPositive
        }
    }

    /// Level-banded battery glyph; the bolt variant when the strap reports charging.
    private func batterySymbol(_ pct: Double) -> String {
        if live.charging == true { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    // MARK: - Scoring-guide info affordance

    /// A small ⓘ that opens the scoring guide at the given score's section. Sized + tinted as
    /// unobtrusive chrome so it sits in a tile/card corner without competing with the value.
    private func scoreInfoButton(_ section: ScoreSection) -> some View {
        Button {
            guideSection = section
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How \(section.rawValue.capitalized) is calculated")
        .help("How this score is calculated")
    }

    // MARK: - Loading

    private func loadAll() async {
        // 14-day sparklines — Whoop.
        sparks["recovery"]        = await sparkValues("recovery", source: "my-whoop", window: 14)
        sparks["strain"]          = await sparkValues("strain", source: "my-whoop", window: 14)
        sparks["sleep_total_min"] = await sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        sparks["hrv"]             = await sparkValues("hrv", source: "my-whoop", window: 14)
        sparks["rhr"]             = await sparkValues("rhr", source: "my-whoop", window: 14)
        sparks["spo2"]            = await sparkValues("spo2", source: "my-whoop", window: 14)

        // 14-day sparklines — Apple Health.
        sparks["resp_rate"]   = await sparkValues("resp_rate", source: "apple-health", window: 14)
        sparks["steps"]       = await sparkValues("steps", source: "apple-health", window: 14)
        sparks["weight"]      = await sparkValues("weight", source: "apple-health", window: 90)
        sparks["active_kcal"] = await sparkValues("active_kcal", source: "apple-health", window: 14)

        // Rest SCORE for the logical day. `exploreSeries` already merges imported + computed
        // `sleep_performance` (imported-wins), so a Bluetooth-only user sees the on-device Rest
        // composite and an importer sees the export's figure — exactly like the Rest detail screen.
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // The selected day's Rest, falling back to the series tail only when today itself is selected —
        // a navigated past day with no Rest row shows "—" rather than borrowing the newest value.
        restScore = restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)

        workouts = await repo.workoutRows()
        appleDays = await repo.appleDailyRows()

        // HR trend for the SELECTED day — 5-minute bucket means from that logical day's local midnight.
        // For today the window runs to now (an in-progress curve); for a navigated past day it runs the
        // full 24h to the next midnight. The logical day rolls at 04:00 (Repository.logicalDayStart), so
        // in the small hours after midnight today still starts at yesterday's midnight rather than
        // blanking to an empty new-calendar-day axis (#144).
        let dayStart = Calendar.current.startOfDay(for: selectedLogicalDay)
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let windowEnd: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: windowStart, to: windowEnd, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        // Pin the chart axis to the loaded window — today midnight→now, a past day the full 24h — so
        // a gap (e.g. a morning the strap wasn't banking) shows as empty space, not a late start.
        hrAxis = Date(timeIntervalSince1970: TimeInterval(windowStart))
            ... Date(timeIntervalSince1970: TimeInterval(windowEnd))

        // Sleep session overlapping the window. Uses `allSleepSessions` (BOTH the imported and the
        // on-device COMPUTED source) — a Bluetooth-only user's sleep lives under the computed source,
        // so the imported-only `sleepSessions` returns nothing. Keep blocks that actually overlap the
        // displayed window, then pick the LONGEST — the main night, not an afternoon nap. Drives the
        // HR sleep band + the recovery marker's wake anchor.
        sleepToday = await repo.allSleepSessions(days: selectedDayOffset + 2)
            .filter { $0.endTs > windowStart && $0.startTs < windowEnd }
            .max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) })
    }

    /// Trailing-window values for a metric — NO fall back to all history. The section is labelled a
    /// current trend ("14-day trend"), so a stale import must not render months-old points as if they
    /// were recent (same spirit as the #23 trailing-window fix). The window is generous enough that a
    /// genuinely sparse-but-recent series still renders — weight uses 90 days — and the Sparkline view
    /// already handles 0/1 points (empty / a single head dot), so no fallback is needed for layout.
    /// `latestString` reads `.last` of this windowed series, so a value older than the window shows
    /// "—" rather than a stale number under a Today tile (#49).
    private func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        let all = await repo.series(key: key, source: source)   // full history, asc
        guard !all.isEmpty else { return [] }
        return trailingWindow(all, days: window).map { $0.value }
    }

    /// Keep only points within the trailing `days` CALENDAR days ending TODAY (the phone's local date).
    /// Was anchored to the most-recent point, which on a stale import pinned the window to months-old
    /// data shown as a current trend (issue #23). ISO yyyy-MM-dd compares chronologically.
    private func trailingWindow(_ points: [(day: String, value: Double)], days: Int) -> [(day: String, value: Double)] {
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return points.filter { $0.day >= cutoffKey }
    }

    /// Latest value of a loaded sparkline series, formatted — for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    private func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// The Weight tile's display string + an honest caption ("from profile" only on the fallback).
    /// Prefers a real Apple-Health reading (today's daily, else the "weight" series' newest point so a
    /// sparse-but-recent value still renders); when neither carries a weight, falls back to the user's
    /// self-reported profile weight instead of "—" (#204). Always formatted through the shared
    /// `UnitFormatter` so the Imperial/Metric toggle reaches this tile. Mirrors Android's `weightTile`.
    private func weightTile(_ appleWeightKg: Double?) -> (value: String, caption: String) {
        if let kg = appleWeightKg ?? sparks["weight"]?.last {
            return (UnitFormatter.massFromKilograms(kg, system: unitSystem), "latest")
        }
        return (UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem), "from profile")
    }

    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    private var greetingWord: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        // The selected day's date when navigated; today's banked-row date (or today) at offset 0.
        if selectedDayOffset == 0, let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return f.string(from: date)
        }
        return f.string(from: selectedLogicalDay)
    }

    /// Hero title that names the selected day — "Today's"/"Yesterday's"/"Day's" Synthesis.
    private var synthesisTitle: LocalizedStringKey {
        switch selectedDayOffset {
        case 0:  return "Today’s Synthesis"
        case 1:  return "Yesterday’s Synthesis"
        default: return "Synthesis"
        }
    }

    /// Section overline naming the selected day — "Today"/"Yesterday"/"EEE d MMM".
    private var selectedDayOverline: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE d MMM"
            return f.string(from: selectedLogicalDay)
        }
    }

    /// A short recovery state word for the synthesis hero.
    private func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return "No Data" }
        switch s {
        case ..<25:  return "Depleted"
        case ..<50:  return "Low"
        case ..<70:  return "Steady"
        case ..<88:  return "Primed"
        default:     return "Peak"
        }
    }

    /// Plain-English synthesis of recovery + sleep.
    private func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return "No metrics yet. Import your Whoop export or wear the strap to begin."
        }
        let recPart: String
        switch rec {
        case ..<50:  recPart = "Charge is low"
        case ..<70:  recPart = "Charge is steady"
        default:     recPart = "Charge is strong"
        }
        let sleepPart: String
        if let mins = d.totalSleepMin {
            let h = mins / 60.0
            sleepPart = h >= 7 ? " and sleep was consistent" : " but sleep ran short"
        } else {
            sleepPart = ""
        }
        return recPart + sleepPart + "."
    }

    private func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "— ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return "HRV \(hrv) · RHR \(rhr)"
    }

    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }

    /// The Rest tile's caption — hours-in-bed for the day, the figure that used to be the tile's
    /// VALUE before #248 moved the Rest score there. Falls back to the efficiency read-out when no
    /// duration is banked, and to nil so the tile shows no caption line at all when neither exists.
    private func restCaption(_ d: DailyMetric?) -> String? {
        if d?.totalSleepMin != nil { return sleepValue(d) }
        return d?.efficiency.map { String(format: "%.0f%% eff", $0) }
    }

    /// Active calories (Apple) for the latest day, falling back to the sparkline tail.
    private func caloriesValue(_ a: AppleDaily?) -> String {
        if let kcal = a?.activeKcal { return intString(kcal) }
        return latestString("active_kcal", decimals: 0)
    }

    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    /// "d MMM · HH:mm–HH:mm", start-only when the row has no real end (#157). The "· N bpm"
    /// segment was dropped: the StatTile caption is lineLimit(1) and date + range + bpm clips —
    /// avg HR remains on the Workouts screen.
    private func workoutCaption(_ w: WorkoutRow) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let date = f.string(from: start)
        guard w.endTs > w.startTs else { return "\(date) · \(Self.hrTimeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
        return "\(date) · \(Self.hrTimeFmt.string(from: start))–\(Self.hrTimeFmt.string(from: end))"
    }

    /// Thousands-grouped integer string (steps / calories).
    private func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }

    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, UTC)

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local wall-clock time ("HH:mm") for the HR trend's x-axis / tooltip — the chart spans one day,
    /// so it must show times, not the day-granularity default ("EEE d MMM"). Also formats the
    /// workout-tile caption's time range (#157).
    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// `.task(id:)` key combining the data refresh sequence with the selected day so a reload runs on
/// either a data change or a day-navigation change (the HR trend + Rest score are day-scoped).
private struct TodayLoadKey: Equatable {
    let seq: Int
    let offset: Int
}

// MARK: - Preview

#if DEBUG
#Preview("Control Center") {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    var sample: [DailyMetric] = []
    for i in stride(from: 39, through: 0, by: -1) {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        let day = Repository.dayString(date)
        let phase = Double(i)
        let rec = 48 + 34 * sin(phase / 5.0) + Double((i * 7) % 11)
        let strain = 8 + 7 * abs(sin(phase / 4.0))
        let total = 380 + 70 * sin(phase / 6.0)
        sample.append(DailyMetric(
            day: day, totalSleepMin: total, efficiency: 88 + 6 * sin(phase / 3.0),
            deepMin: 95, remMin: 110, lightMin: total - 200, disturbances: 4,
            restingHr: 50 + (i % 6), avgHrv: 58 + 16 * sin(phase / 4.0),
            recovery: min(max(rec, 8), 99), strain: strain, exerciseCount: i % 3,
            spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6
        ))
    }
    repo.days = sample
    repo.loaded = true

    return TodayView()
        .environmentObject(repo)
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif
