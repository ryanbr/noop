//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  This is the FULL Today, re-created faithfully from the locked mockup
//  (scratchpad/liquid-metal-home.html): sky title + record/add/battery controls,
//  the three scores as liquid vessels with a card-level source badge, the live heart-rate
//  thread, the five "your cards" as liquid chips, a greeting + readiness pills,
//  Synthesis, Recovery Vitals, a Key Metrics grid (incl. steps), Last Workouts
//  and Data Sources. Every value binds to the SAME real data the classic
//  TodayView reads (accessors verified against TodayView.swift), and every tap
//  routes to the same public destination. The sky is a fixed, full-bleed
//  background (edge-to-edge under the status bar, does not scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    // For the pull-to-sync gesture (#334): a pull kicks a manual strap history offload via ble.syncNow().
    // Observe BLEManager, NOT AppModel — AppModel @Publishes `bpm` on the ~1 Hz HR tick, so observing it
    // would re-render all of Today every second (the exact churn the LiveState leaves isolate). BLEManager
    // only publishes connect/discovery state, never HR. Injected at the app roots beside .environmentObject(model).
    @EnvironmentObject var ble: BLEManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode — and the in-app "Reduce motion in NOOP" toggle — pose the sky still too, the
    /// behaviour the comment on the sky branch below has always described. Neither has a SwiftUI
    /// environment key, hence the shared monitor.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    /// #today-hosted-cards: the ordered Trends/Sleep cards the user has hosted in Today. Empty by default
    /// (opt-in); rendered by the `.addedCards` section. Shared @AppStorage key with Android.
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    /// #989 parity with classic Today + Android: the hydration card is opt-in twice over — the feature
    /// toggle AND an explicit add in CUSTOMISE. Liquid filtered on neither, so a user who added the card
    /// and later switched the feature off kept a permanently-blank row.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    /// Today's hydration total + goal (ml), resolved in `load()`. nil → the card shows "—".
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    /// Input providers for the three scores, keyed by recovery / strain / sleep_performance.
    @State private var heroProviderByMetric: [String: ScoreInputProvider] = [:]
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vitality: Double?           // exploreSeries("vitality").last
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var importedStepsDay: Int?      // Apple Health steps for the selected day (middle tier)
    @State private var importedActiveKcalDay: Double?  // #616: Apple Health active energy for the day (calorie fallback)
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    @State private var workouts: [WorkoutRow] = [] // newest-first
    /// #today-hosted-cards: the shared SleepModel that backs every SleepModel-derived hosted sleep card
    /// (Stages vs typical today; more to follow). Built ONCE in `load()` from the SAME inputs the Sleep tab
    /// uses (`SleepModel.build`), and only when a sleep-origin card is actually hosted — so a Today with no
    /// hosted sleep card pays none of the extra Repository work. nil until (and unless) it's built.
    @State private var hostedSleepModel: SleepModel? = nil

    // sheets / expanders
    @State private var guideSection: ScoreSection?
    @State private var customizationDestination: TodayCustomizationDestination?
    @State private var showSettings = false
    @State private var synthesisExpanded = false
    @State private var showLiveSession = false

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    // #today-layout (parity with Android): the user-chosen section order, persisted under the byte-identical
    // "today.sectionOrder" key the Android TodayLayoutPrefs uses. Reordered via the Arrange sheet (native
    // drag-to-reorder rows); every section always renders (decode inserts a missing one at its default spot).
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    private var sectionOrder: [TodaySection] {
        TodayLayoutPrefs.visibleOrder(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)
    }
    // #430 parity: the Key-Metrics grid honours the SAME editor selection/order + Detailed-tiles switch as
    // Android (byte-identical @AppStorage keys). `kSparks` holds the trailing-30-day series the detailed
    // tiles graph (keyed by metric-catalog key), filled by the loader alongside everything else.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    /// The detailed graphs' trailing window — 1 week / 2 weeks / 1 month (shared key with Android). The
    /// loader banks a day-keyed 30-day superset; render filters down, so a window change applies instantly.
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    @State private var kSparks: [String: [(String, Double)]] = [:]
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// The Charge hero's resolved state (#543 carry + the honest label), resolved ONCE in load() alongside
    /// the other caches. It composes `TodayView.lastScoredRecoveryDay`, which is O(days) — exactly the scan
    /// this cache exists to keep out of body. Never resolved in body.
    @State private var cachedChargeDisplay: ChargeDisplay = .noData
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = Color(.sRGB, red: 0x9b / 255, green: 0x7b / 255, blue: 0xff / 255, opacity: 1)
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    /// Hero / session-start chrome uses theme-aware `NoopPanelSurface` (design-system surfaces that
    /// flip with Light/Dark). Upstream #1160/#1161 moved the classic RoundedRectangle hero onto
    /// `StrandPalette.heroFill` / `heroBorder` for the same theme-aware goal; #1068 keeps the panel
    /// surface treatment while preserving that Light/Dark readability.
    /// "Card transparency" (0–100, default 100): fades every liquid card surface here — the hero, the
    /// session-start row, the metric tiles and the `card` helper — in lockstep with the frosted cards.
    /// Content sits above the surface so it stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }
    /// "Sky behind cards" (default ON): extend the day-cycle sky behind the WHOLE scroll so the
    /// Card-transparency slider reveals it under every card. User-toggleable. Mirrors Kotlin `NoopPrefs.skyBehindCards`.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    /// Day-cycle scene backdrop (#698). Default ON. When off, the liquid Today drops the sky for the plain
    /// dark canvas — parity with Android and the classic TodayView, which already honour this pref. Mirrors
    /// Kotlin `NoopPrefs.showDayCycleBackground`.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    /// Custom background image (#custom-background): when active it overrides the sky in the backdrop below.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    /// The Charge hero's resolved state (see `cachedChargeDisplay`), read O(1) from the cache.
    private var chargeDisplay: ChargeDisplay { cachedChargeDisplay }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        // #1013: these must localize — the header showed English "Today"/"Yesterday"/weekday even when the
        // system UI (tab bar etc.) was another language. "Today"/"Yesterday" go through String(localized:)
        // (matching the classic TodayView.dayNavLabel), and the weekday name is formatted in the user's
        // locale, not the en_US_POSIX one used only for machine day-keys.
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (left = older, right = newer), clamped to [today, earliest].
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Scroll-to-top on an at-root Today re-tap (#198 follow-up); default 0 so macOS/other contexts stay inert.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    private static let topAnchorID = "liquidToday.top"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                // Zero-height scroll-to-top anchor (#198 follow-up): the target for an at-root Today re-tap.
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                liquidRefreshIndicator   // grows in the revealed space; a vessel filling with the pull

                VStack(alignment: .leading, spacing: 12) {
                    scene
                    // The strain/illness early-warning banner, dropped in the liquid Home rewrite. Liquid is
                    // the DEFAULT Today on both platforms (RootTabView.swift's liquidTodayEnabled = true,
                    // RootView.swift likewise), so while this was unmounted a RAISED health alert had no
                    // home-screen surface at all: it survived only as one push at the moment it fired
                    // (IllnessNotifier.post) and as HeadsUpCard two taps deep in More → Health. Pinned ABOVE
                    // the reorderable block — the same position classic TodayView uses on both platforms and
                    // the same one Android pins it to (TodayScreen.kt) — so a warning cannot be reordered
                    // below the fold. Renders nothing when model.healthAlert is nil.
                    HealthAlertBanner()
                    // #105: the live "workout in progress" card, dropped in the liquid Home rewrite. Restored
                    // here as the SAME leaf the classic TodayView renders (and Android's WorkoutInProgressCard),
                    // pinned above the reorderable block so an active manual workout is immediately visible
                    // and taps straight through to Live. Renders nothing when no workout is active.
                    ActiveWorkoutIndicatorSection()
                    // #today-layout (parity with Android): every Today section — the Charge/Effort/Rest hero
                    // and Start-session included — renders in the user's saved order. Reorder via the Arrange
                    // sheet (the header's up/down button; native drag rows); the order persists under the
                    // byte-identical "today.sectionOrder" key Android uses. A gated-off Start-session renders
                    // nothing and keeps its slot in the saved order.
                    ForEach(sectionOrder) { section in
                        switch section {
                        case .hero: heroCard
                        case .liveSession: if liveSessionsBeta { liveSessionStartRow }
                        case .synthesis: synthesisSection
                        case .keyMetrics: keyMetricsSection
                        case .workouts: lastWorkoutsSection
                        case .heartRate: heartRateSection
                        case .recoveryVitals: recoveryVitalsSection
                        case .yourCards: yourCardsSection
                        case .menstrualCycle:
                            if selectedDayOffset == 0 { MenstrualCycleHomeCard() }
                        // #656: the persistent journal widget (last-7-days strip + tap-through). Now a
                        // reorderable section like the others — the Arrange sheet moves it. Today only;
                        // the card self-hides when the reminder toggle is off (an empty branch renders
                        // nothing yet keeps its slot). Twin of Android TodayScreen's JOURNAL arm.
                        case .journal: if selectedDayOffset == 0 { JournalReminderCard() }
                        // #today-hosted-cards: cards the user pulled in from the Trends/Sleep tabs, in the
                        // order they arranged. Empty (renders nothing) until they add one in Customise.
                        // Today-only, matching Android's addedCards section gate + the classic TodayView.
                        case .addedCards: if selectedDayOffset == 0 { hostedCardsSection }
                        }
                    }
                    // Opt-in "looks like a workout?" suggestion, dropped in the liquid Home rewrite. Its
                    // Settings toggle (PuffinExperiment.autoDetectWorkoutsKey) had no visible effect on the
                    // DEFAULT screen: the card's only mount was classic TodayView, so a user could switch
                    // auto-detect on and never be shown a single suggestion. Same position classic uses
                    // (after the cards block, before Data Sources) and the same leaf Android renders.
                    // Self-gates on the toggle AND on the detector finding an unsaved, un-dismissed window,
                    // so it renders nothing by default.
                    AutoWorkoutCard()
                    dataSourcesSection
                    Color.clear.frame(height: 90) // floating tab-bar clearance
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 30) // sit the title lower into the sky, not jammed under the status bar
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .coordinateSpace(name: Self.pullSpace)
        .onPreferenceChange(PullOffsetKey.self) { handlePull($0) }
        // The sky is a FIXED full-bleed backdrop drawn behind the scroll content, edge-to-edge under the
        // status bar. A ScrollView background does not scroll with the content, so pulling down never
        // moves the sky (the exact behaviour the scaffold uses on the classic Today).
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                // Custom background image (#custom-background): a picked photo OVERRIDES the sky, filling
                // the whole backdrop (same cached image as every other tab, so it's seamless).
                if backgroundStore.isActive {
                    BackgroundImageBackdrop()
                }
                // Day-cycle scene (#698): the sky only paints when the toggle is ON AND no custom image is
                // active; off = the plain surfaceBase canvas above (parity with Android + classic TodayView).
                else if showDayCycleBackground {
                    // Reduce-motion (and low-power) users get the same sky posed still — no twinkle/breath.
                    // Also static until the first data load settles, so launch isn't fighting a live sky too.
                    // "Sky behind cards" (opt-in): fill the whole backdrop with a softer settle so the sky
                    // reads under every card, instead of the default 340 top band that dissolves to canvas.
                    Group {
                        if poseStill || !dataLoaded { LiquidSkyStatic(hour: liveHour, settleStrength: skyBehindCards ? 0.78 : 1) }
                        else { LiquidSky(hour: liveHour, settleStrength: skyBehindCards ? 0.78 : 1) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: skyBehindCards ? nil : 340, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea()
        }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        // hydrationSeq joins the id so logging a drink re-reads the card immediately, the same trigger set
        // classic TodayView's reloadHydration() uses.
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)") { await load() }
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        .sheet(item: $customizationDestination) { destination in
            TodayCustomizationSheet(
                initialDestination: destination,
                sectionOrderRaw: $sectionOrderRaw,
                hiddenSectionsRaw: $hiddenSectionsRaw,
                keyMetricsRaw: $keyMetricsRaw,
                keyMetricsDetailed: $keyMetricsDetailed,
                keyMetricsWindowDays: $keyMetricsWindowDays,
                dashboardCardsRaw: $dashboardCardsRaw,
                hostedCardsRaw: $hostedCardsRaw
            )
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root Today re-tap (#198 follow-up); iOS-only — the tab shell is the only driver.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Reserves the revealed space at the top and shows a vessel that fills with the pull, then sloshes
    /// while the refresh runs. A plain computed property (not a LiveState-isolated leaf) — it doesn't read
    /// LiveState itself, so it's cheap to re-evaluate as part of the main body. It hands the actual
    /// visibility decision to `LiquidRefreshIndicator` below, which DOES own LiveState.
    private var liquidRefreshIndicator: some View {
        LiquidRefreshIndicator(pullY: pullY, pullThreshold: pullThreshold, refreshing: refreshing,
                               liquidHeart: liquidHeart)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        pullY = max(0, y)
        guard !refreshing else { return }
        if pullY >= pullThreshold, !refreshArmed {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, pullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                // #334 (iOS twin of Android #426): a pull requests a fresh strap history offload, not just
                // a UI reload. syncNow() is internally gated (connected + bonded + not-already-backfilling),
                // so a pull while disconnected or mid-offload safely no-ops. The sync status chip owns the
                // ongoing offload progress; the pull spinner stays short (the reload below).
                ble.syncNow()
                await repo.refresh()
                await load()
                try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
                withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
            }
        }
    }

    // MARK: - Scene (sky title + controls + hero)

    private var scene: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button { showDayPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayTitle)
                            .font(StrandFont.rounded(28))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 1)
                        Text(dateLine)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
                .popover(isPresented: $showDayPicker) {
                    DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                               displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .frame(minWidth: 320, minHeight: 360)
                        .liquidPopoverAdaptation()
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    // Profile pic (the one set in Settings) → opens Settings, matching the classic Today.
                    Button { showSettings = true } label: {
                        Color.clear.frame(width: headerClusterControl, height: headerClusterControl)
                    }
                    .nativeLiquidGlassHeaderButton()
                    .overlay {
                        GeometryReader { proxy in
                            let diameter = min(proxy.size.width, proxy.size.height)
                            ProfileAvatarView(imageData: profile.avatarImageData, size: diameter)
                                .frame(width: diameter, height: diameter)
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                    .nativeLiquidGlassPhotoFinish()
                    .accessibilityLabel("Profile and settings")
                    LiquidAddButton()
                    LiquidBatteryButton()
                    // One entry point for section order/visibility and both nested card editors.
                    Button { customizationDestination = .today } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: headerClusterControl, height: headerClusterControl)
                    }
                    .nativeLiquidGlassHeaderButton()
                    .accessibilityLabel("Customize Today")
                }
            }
            // Subtle NOOP wordmark in the sky between header and hero. Perfectly centred (a letter row has
            // no trailing tracking gap the way `Text(...).tracking()` does), with a tap easter egg.
            // #today-layout: the hero + Start-session row moved OUT of the scene into the reorderable
            // section block below. The wordmark's bottom pad (10) + the section VStack's 12 spacing keeps
            // the default hero-under-wordmark gap at the original 22.
            LiquidWordmark()
                .padding(.top, 30)
                .padding(.bottom, 10)
        }
    }

    /// One-tap Live Session start (silent guardian, beta) — sits directly under the hero scores, the
    /// Charge its band is gated on. Same translucent chrome as the hero card so it reads as part of the
    /// sky scene, quiet by design.
    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                // Theme-aware session-start chrome (#1160 parity): NoopPanelSurface + normal text
                // tokens — light ink on Dark, dark ink on Light. (Was pinned-dark + on-dark tokens.)
                Text("Start session")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("BETA")
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(StrandPalette.surfaceInset.opacity(0.72))
                        .overlay(Capsule().strokeBorder(
                            StrandPalette.hairline,
                            lineWidth: NoopMetrics.hairlineWidth
                        )))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(NoopPanelSurface(cornerRadius: 18, surfaceOpacity: cardOpacity))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 4) {
            // #543 carry: an unscored today shows the last scored night's REAL Charge (labelled as prior by
            // the state pill) rather than an empty vessel, matching the classic Today, the widget/watch/Live
            // Activity (`Repository.widgetAnchor`) and Android. Effort deliberately does NOT carry — it is
            // today's own accumulation, so yesterday's number would be a false statement, not a stale one.
            HeroScoreCell(label: String(localized: "Charge"), score: chargeDisplay.pct, tint: StrandPalette.chargeColor,
                          animated: dataLoaded, onGuide: { guideSection = .charge })
            // #45: the hero Effort must honour the user's Effort scale like every other Effort read-out.
            // Show the value on the chosen scale (0–100 or WHOOP 0–21) with the matching vessel max, and
            // one decimal on the compressed 0–21 axis to match the app-wide `effortDisplay` convention
            // (12.6, not a rounded "13"); the 0–100 hero stays a whole number as before.
            HeroScoreCell(label: String(localized: "Effort"),
                          score: displayDay?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) },
                          tint: StrandPalette.effortColor, animated: dataLoaded,
                          onGuide: { guideSection = .effort },
                          maxValue: effortScale == .whoop ? 21 : 100,
                          decimals: effortScale == .whoop ? 1 : 0)
            HeroScoreCell(label: String(localized: "Rest"), score: restScore, tint: StrandPalette.restColor,
                          animated: dataLoaded, onGuide: { guideSection = .rest })
                .overlay(alignment: .top) {
                    if let sourceLabel = heroSourceLabel {
                        SourceBadge("\(sourceLabel)", tint: StrandPalette.textSecondary)
                            // Match the badge's trailing edge to the Rest vessel and centre it on the card border.
                            .fixedSize()
                            .frame(width: HeroScoreCell.vesselDiameter, alignment: .trailing)
                            .offset(y: -(NoopMetrics.space4 + NoopMetrics.sourceBadgeHeight / 2))
                            .allowsHitTesting(false)
                            .accessibilityLabel(Text("Source: \(sourceLabel)"))
                    }
                }
        }
        .padding(.vertical, NoopMetrics.space4)
        .padding(.horizontal, NoopMetrics.space3)
        .background(NoopPanelSurface(cornerRadius: 26, elevated: true, surfaceOpacity: cardOpacity))
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(spacing: 8) {
            sectionHead("HEART RATE", trailing: "Live")
            // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
            // Show all → Deep Timeline. The whole live HR card remains a one-tap route into it.
            NavigationLink(value: TabRoute.fullDayChart) {
                card {
                    // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY
                    // this card, never the whole Today. Shows the current bpm live with a rolling
                    // beat-by-beat trace; falls back to today's banked 5-minute trace when idle.
                    LiquidLiveHR(tint: liquidHeart, fallback: hrValues, animated: dataLoaded)
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint("Opens the full-day heart rate timeline")
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("YOUR CARDS").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { customizationDestination = .yourCards } label: {
                    // #492 item 4 parity: unify the Your Cards / Key Metrics edit affordance to "EDIT" across
                    // platforms (Android #563). Reuse the localized "Edit" key, uppercased at display, so this
                    // stays translated (BEARBEITEN / MODIFIER / …) without a new literal.
                    Text(String(localized: "Edit").uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live. The hydration filter mirrors classic
            // TodayView's `enabledDashboardCards` and Android's `it != HYDRATION || hydrationEnabled`.
            ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
                        .filter { hydrationEnabled || $0 != .hydration }) { card in
                liquidCard(for: card)
            }
        }
    }

    // MARK: - Added cards (#today-hosted-cards)

    /// The Trends/Sleep cards the user hosted in Today, in their arranged order. Data-driven off the SAME
    /// @AppStorage the Customise editor writes, so add / remove / reorder reflects live. Each hosted card
    /// is the SAME view its home tab renders (a mirror, not a copy) and carries its own header, so this
    /// section adds no header of its own. Renders nothing until the user hosts a card.
    @ViewBuilder
    private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if !cards.isEmpty {
            VStack(spacing: NoopMetrics.sectionGap) {
                ForEach(cards) { card in
                    hostedCard(for: card)
                }
            }
        }
    }

    /// Dispatch a hosted card id to its native view. Each case renders the exact view the originating tab
    /// uses, so the Today copy and the home-tab copy never diverge. P0 hosts only Sleep marks.
    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        case .stagesVsTypical:
            // Renders from the shared SleepModel built in load() (same inputs as the Sleep tab). Until that
            // async build lands — or on a device with no usable latest night — show the graceful placeholder
            // rather than a half-built card, mirroring how AsleepDuration degrades on no data.
            if let m = hostedSleepModel {
                StagesVsTypicalCard(model: m)
            } else {
                hostedSleepPlaceholder
            }
        case .nightDetail:
            // Renders from the same shared SleepModel built in load(). Until that async build lands — or on a
            // device with no usable latest night — show the graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                NightDetailCard(model: m)
            } else {
                hostedNightDetailPlaceholder
            }
        case .sleepDebt:
            // Renders from the same shared SleepModel built in load(). Until that async build lands — or on a
            // device with no usable latest night — show the graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                SleepDebtLedgerCard(model: m)
            } else {
                hostedSleepDebtPlaceholder
            }
        }
    }

    /// Graceful empty state for a SleepModel-backed hosted card whose model hasn't built yet (first frame)
    /// or is nil (no usable latest night). Keeps the hosted slot present + labelled so add/remove/reorder in
    /// Customise still reads, without rendering a partial card. #today-hosted-cards.
    private var hostedSleepPlaceholder: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night")
            Text("Not enough nights yet.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
        }
    }

    /// Graceful empty state for the hosted "Night detail" grid before its shared SleepModel builds (first
    /// frame) or when there is no usable latest night. Same treatment as `hostedSleepPlaceholder`, labelled
    /// for this card so add/remove/reorder in Customise still reads. #today-hosted-cards.
    private var hostedNightDetailPlaceholder: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics")
            Text("Not enough nights yet.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
        }
    }

    /// Graceful empty state for the hosted "Sleep-debt ledger" before its shared SleepModel builds (first
    /// frame) or when there is no usable latest night. Same treatment as `hostedSleepPlaceholder`, labelled
    /// for this card so add/remove/reorder in Customise still reads. #today-hosted-cards.
    private var hostedSleepDebtPlaceholder: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep-debt ledger", overline: "Last 14 nights")
            Text("Not enough nights yet.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
        }
    }

    /// One "Your cards" row for a given card type — honours the user's CUSTOMISE selection + order.
    /// Wired cards show real values; the rest render "–" for now (they still appear, so add/remove/
    /// reorder is reflected). stress → Stress screen, sleep → Sleep, everything else → Health.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardLink(.stress, title: card.title, sub: card.subtitle,
                     value: stressText, tint: StrandPalette.accent, frac: fracOver(stress, 3))
        case .fitnessAge:
            cardLink(.metric("fitness_age"), title: card.title, sub: card.subtitle,
                     value: unitText(fitnessAge, card.unit), tint: StrandPalette.chargeColor, frac: 0.5)
        case .vitality:
            cardLink(.metric("vitality"), title: card.title, sub: card.subtitle,
                     value: intText(vitality), tint: liquidPurple, frac: frac(vitality))
        case .hrv:
            cardLink(.metric("hrv"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.avgHrv, card.unit), tint: StrandPalette.metricCyan,
                     frac: fracOver(displayDay?.avgHrv, 120))
        case .restingHr:
            cardLink(.metric("rhr"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                     tint: StrandPalette.metricRose, frac: fracOver(displayDay?.restingHr.map(Double.init), 100))
        case .respiratory:
            cardLink(.metric("resp_rate"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                     tint: StrandPalette.accent, frac: fracOver(displayDay?.respRateBpm, 24))
        case .steps:
            // Route by the EXACT (key, source) the tile chose to display — measured my-whoop, imported
            // apple-health, or the my-whoop estimate — NOT by bare key (bare "steps" resolves to
            // apple-health and would mismatch a WHOOP-measured value). Order-independent.
            cardLink(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), title: card.title, sub: card.subtitle,
                     value: stepsText, tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            // Not wired to a real read yet — render EMPTY (not half-full) so it doesn't imply a reading.
            cardLink(.metric("spo2"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .skinTemp:
            cardLink(.metric("skin_temp"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            // #616: show the resolved imported-first value and route to the matching detail source, like
            // the Steps card — was a "–" placeholder wired to the imported-only detail.
            cardLink(.metricSourced(key: caloriesDetailKey, source: caloriesDetailSource), title: card.title, sub: card.subtitle,
                     value: intText(caloriesCount), tint: StrandPalette.metricAmber, frac: fracOver(caloriesCount, 800))
        case .sleep:
            cardLink(.sleep, title: card.title, sub: card.subtitle,
                     value: sleepText, tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            // #989: was hardcoded "–". `HydrationGoal.cardValueString` is unit-tested and byte-identical to
            // the Android twin, but classic TodayView was its only caller — so on the DEFAULT screen a
            // logged drink never appeared. Same "<total> / <goal> L" string and the same goal fraction on
            // the ring as classic; "—" only when the goal is genuinely underivable.
            cardLink(.hydration, title: card.title, sub: card.subtitle,
                     value: hydrationGoalML.map {
                         HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                     } ?? "—",
                     tint: StrandPalette.metricCyan,
                     frac: hydrationGoalML.map {
                         HydrationGoal.fraction(totalML: hydrationTotalML ?? 0, goalML: $0)
                     })
        case .coupled:
            // A tap-through to the full Coupled day screen. No value.
            cardLink(.coupled, title: card.title, sub: card.subtitle,
                     value: "", tint: StrandPalette.chargeColor, frac: 0.6)
        }
    }

    /// One card row pushing its `TabRoute` by value — the first hop off the Today root must ride
    /// the tab's `NavigationPath` so a re-tap of the Today tab can pop it (#198; see TabRoute.swift).
    private func cardLink(_ route: TabRoute, title: String, sub: String,
                          value: String, tint: Color, frac: Double?) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(value).font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(NoopPanelSurface(tint: tint, cornerRadius: 20, surfaceOpacity: cardOpacity))
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: - Synthesis (greeting + readiness pills + one-liner)

    /// Liquid parity with classic `effortZeroNote`: the "no cardio load yet" line shown in the synthesis
    /// card when today's Effort is ~0, so a calm day explains itself instead of a bare 0. Reuses classic's
    /// String Catalog entry verbatim — one key serves both Today screens.
    private var effortZeroNote: String? {
        guard EffortDisplay.showsZeroNote(strain: displayDay?.strain, isToday: selectedDayOffset == 0) else { return nil }
        return String(localized: "No cardio load yet. Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.")
    }

    private var synthesisSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(greeting).font(StrandFont.rounded(19)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)   // yield to the pills rather than push them to wrap
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let word = readinessWord {
                        Text(word)
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(StrandPalette.chargeColor.opacity(0.14))
                                .overlay(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1)))
                    }
                    HStack(spacing: 5) {
                        Circle().fill(StrandPalette.chargeColor).frame(width: 6, height: 6)
                        Text(chargeDisplay.stateLabel)
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1))
                }
                .fixedSize(horizontal: true, vertical: false)   // pills keep their natural width — no "Calibrating" wrap
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            Button { withAnimation(.easeInOut(duration: 0.2)) { synthesisExpanded.toggle() } } label: {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SYNTHESIS").font(StrandFont.overline).tracking(1.6)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Text(synthesisExpanded ? "hide" : "show").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        // While the baseline calibrates, the honest "N of 4 nights" progress replaces the
                        // readiness one-liner here — the same swap classic makes (`calibrationDetail ??
                        // synthesisCardDetail`), so the count the short greeting pill can't carry lands in
                        // the card and both Today screens read identically.
                        Text(chargeDisplay.calibrationDetail ?? synthLine)
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        // #530 follow-up: the classic hero's "no cardio load yet" note (effortZeroNote),
                        // shown on a calm day so today's ~0 Effort explains itself instead of a bare 0.
                        if let note = effortZeroNote {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.effortColor)
                                    .accessibilityHidden(true)
                                Text(note)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if synthesisExpanded {
                            Text(LocalizedStringKey(readiness.summary)).font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        // PER-FIELD, today-first carry: each vital reads today's own value, else falls back to the prior
        // day that recorded it (`vitalsDay`). Coalesce ONCE so the number and its fill fraction agree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let line = vitalsProvenanceLine {
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                vitalRow(String(localized: "Heart-rate variability"), unitText(hrv, "ms"),
                         StrandPalette.metricCyan, fracOver(hrv, 120))
                vitalRow(String(localized: "Resting heart rate"), unitText(rhr, "bpm"),
                         StrandPalette.metricRose, fracOver(rhr, 100))
                vitalRow(String(localized: "Breaths per minute"), unitText(resp, "rpm", decimals: 1),
                         StrandPalette.accent, fracOver(resp, 24))
            }
        }
    }

    private func vitalRow(_ label: String, _ value: String, _ tint: Color, _ frac: Double?) -> some View {
        HStack(spacing: 12) {
            LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 26, height: 26)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Key metrics grid

    /// The chosen detailed-graph window's oldest day key (1 week / 2 weeks / 1 month ending on the
    /// selected day). The loader banks a 30-day superset; render filters down so a window change in the
    /// editor applies instantly, no reload.
    private var sparkWindowCutoffKey: String {
        let days = (keyMetricsWindowDays == 7 || keyMetricsWindowDays == 30) ? keyMetricsWindowDays : 14
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: selectedLogicalDay)
        return Repository.localDayKey(cal.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor)
    }

    /// A metric's spark values inside the chosen window, oldest → newest.
    private func windowedSpark(_ key: String) -> [Double] {
        let cutoff = sparkWindowCutoffKey
        return (kSparks[key] ?? []).filter { $0.0 >= cutoff }.map { $0.1 }
    }

    /// The Key-Metrics header's trailing label for the chosen detailed-graph window (Android twin).
    private var trendWindowLabel: String {
        switch keyMetricsWindowDays {
        case 7: return String(localized: "7-day trend")
        case 30: return String(localized: "30-day trend")
        default: return String(localized: "14-day trend")
        }
    }

    private var keyMetricsSection: some View {
        // HRV / Rest HR (+ Blood Oxygen / Respiratory) tiles share the recovery vitals' per-field
        // today-first carry so they don't blank at the rollover while Recovery/Strain/Rest stay strictly
        // today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHead("KEY METRICS", trailing: trendWindowLabel)
                // #430 parity: the SAME editor the classic grid uses — selection + order + Detailed tiles.
                Button { customizationDestination = .keyMetrics } label: {
                    Text(String(localized: "Edit").uppercased())
                        .font(StrandFont.overlineScaled(11))
                        .tracking(1.0)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Key Metrics")
            }
            // #430 parity: the grid honours the Key-Metrics editor (selection + order, all ten metrics)
            // instead of a hard-coded six — the bespoke Sleep-hours ktile gives way to the shared REST
            // score tile, aligning the liquid grid with the classic macOS grid and Android.
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: NoopMetrics.gap),
                    count: 2
                ),
                spacing: NoopMetrics.gap
            ) {
                ForEach(enabledKeyMetrics) { metric in
                    ktileFor(metric, hrv: hrv, rhr: rhr)
                }
            }
            NavigationLink(value: TabRoute.metricExplorer) {
                LiquidFullWidthNavigationAction("Show all metrics")
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    /// One editor-selected Key-Metric tile: the metric's value/tint/fill exactly as the old hard-coded
    /// tiles read them (Android's descriptor map is the twin), plus the metric-catalog `key` that names
    /// both its 14-day spark series and its tap-through detail. Weight has no liquid value source yet —
    /// its tile reads "—" but still taps through to the weight trend detail (which has its own series).
    @ViewBuilder
    private func ktileFor(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> some View {
        switch metric {
        case .charge:
            // Reads the SAME resolved Charge the hero draws, not `displayDay?.recovery` raw — the tile and the
            // hero are the same number, so a carry that reached only one of them would put two answers for
            // Charge on one screen. (#543: one prior row feeds every recovery-derived read-out.) Strain below
            // stays raw, matching the Effort hero, which correctly does not carry.
            ktile(String(localized: "Recovery"), icon: keyMetricIcon(metric), intText(chargeDisplay.pct), "%", StrandPalette.chargeColor, frac(chargeDisplay.pct), key: "recovery")
        case .effort:
            ktile(String(localized: "Strain"), icon: keyMetricIcon(metric), intText(displayDay?.strain), "%", StrandPalette.effortColor, frac(displayDay?.strain), key: "strain")
        case .rest:
            ktile(String(localized: "Rest"), icon: keyMetricIcon(metric), intText(restScore), "%", StrandPalette.restColor, frac(restScore), key: "sleep_performance")
        case .hrv:
            ktile("HRV", icon: keyMetricIcon(metric), intText(hrv), "ms", StrandPalette.metricCyan, fracOver(hrv, 120), key: "hrv")
        case .restingHr:
            ktile(String(localized: "Rest HR"), icon: keyMetricIcon(metric), intText(rhr), "bpm", StrandPalette.metricRose, fracOver(rhr, 100), key: "rhr")
        case .bloodOxygen:
            let spo2 = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            ktile(String(localized: "Blood Oxygen"), icon: keyMetricIcon(metric), intText(spo2), "%", StrandPalette.metricCyan, fracOver(spo2, 100), key: "spo2")
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
            ktile(String(localized: "Respiratory"), icon: keyMetricIcon(metric), resp.map { String(format: "%.1f", $0) } ?? "—", "rpm", StrandPalette.accent, fracOver(resp, 24), key: "resp_rate")
        case .steps:
            ktile(String(localized: "Steps"), icon: keyMetricIcon(metric), stepsText, "", StrandPalette.chargeColor,
                  fracOver(stepCount, 10000), key: stepsDetailKey, detailMetric: stepsDetailMetric)
        case .weight:
            ktile(String(localized: "Weight"), icon: keyMetricIcon(metric), "—", "", StrandPalette.metricAmber, nil, key: "weight")
        case .calories:
            // #616: imported-first value (imported ?: activeKcalEst) + route the tap to the matching
            // detail source, so the number, its sparkline and the chart it opens all agree.
            ktile(String(localized: "Calories"), icon: keyMetricIcon(metric), intText(caloriesCount), "kcal", StrandPalette.metricAmber,
                  fracOver(caloriesCount, 800), key: "energy_kcal", detailMetric: caloriesDetailMetric)
        }
    }

    private func keyMetricIcon(_ metric: KeyMetric) -> String {
        switch metric {
        case .charge: return "heart.fill"
        case .effort: return "bolt.fill"
        case .rest: return "moon.stars.fill"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.circle.fill"
        case .bloodOxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .steps: return "figure.walk"
        case .weight: return "scalemass.fill"
        case .calories: return "flame.fill"
        }
    }

    private func ktile(_ label: String, icon: String, _ value: String, _ unit: String, _ tint: Color, _ frac: Double?,
                       key: String? = nil, detailMetric: MetricDescriptor? = nil) -> some View {
        let tile = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.72))
                    .frame(width: 14)
                Text(label.uppercased())
                    .font(StrandFont.overlineScaled(10))
                    .tracking(1.0)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            (Text(value).font(StrandFont.number(24))
                + Text(unit.isEmpty ? "" : (unit == "%" ? unit : " \(unit)"))
                    .font(StrandFont.number(24)))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            LiquidTube(frac: frac ?? 0, tint: tint, height: 9, animated: false,
                       showsHighlight: false, usesCleanFill: true)
            // #430 parity: DETAILED tiles grow the trend graph under the bar, tinted to the metric and
            // windowed to the editor's 1-week / 2-week / 1-month choice (the Android twin). A metric with no
            // windowed series keeps a clear placeholder of the same height so every tile in a detailed row
            // stays equal-height with its bars aligned.
            if keyMetricsDetailed {
                let spark = key.map { windowedSpark($0) } ?? []
                if spark.count >= 2 {
                    Sparkline(values: spark,
                              gradient: Gradient(colors: [tint.opacity(0.5), tint]))
                        .frame(height: 22)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: 22).padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: keyMetricsDetailed ? 154 : 116, alignment: .topLeading)
        .background(NoopPanelSurface(tint: tint, cornerRadius: 18, surfaceOpacity: cardOpacity))
        // #430 parity: tap -> the metric's trend detail (the same Explore dossier its MetricRow pushes,
        // closure-based NavigationLink per #38). A metric with no catalog entry stays inert.
        return Group {
            if let metric = detailMetric ?? key.flatMap({ key in
                MetricCatalog.all.first(where: { $0.key == key })
            }) {
                NavigationLink { MetricDetailView(metric: metric) } label: { tile }
                    .buttonStyle(.plain)
            } else {
                tile
            }
        }
    }

    // MARK: - Last workouts

    private var lastWorkoutsSection: some View {
        VStack(spacing: 8) {
            sectionHead("LAST WORKOUTS", trailing: "\(workouts.count) total")
            if let w = workouts.first {
                NavigationLink(value: TabRoute.workouts) { workoutCard(w) }
                    .buttonStyle(LiquidPressStyle())
            } else {
                card {
                    Text("No workouts yet")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func workoutCard(_ w: WorkoutRow) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.displaySport(w.sport)).font(StrandFont.number(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(workoutSub(w)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    (Text(effortText(w.strain)).font(StrandFont.number(15))
                        + Text(" EFFORT").font(StrandFont.overlineScaled(9)))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                LiquidTube(frac: (w.strain ?? 0) / 100, tint: StrandPalette.effortColor, height: 12, animated: false)
            }
        }
    }

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(spacing: 8) {
            sectionHead("DATA SOURCES", trailing: "Provenance")
            NavigationLink(value: TabRoute.dataSources) {
                card {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Synced from").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("View sources").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        LiquidStrapBatteryRow()
                        LiquidSyncStatusRow()
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Reusable chrome

    private func sectionHead(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title)).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(LocalizedStringKey(trailing)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 22, surfaceOpacity: cardOpacity))
    }

    // MARK: - Data

    private func load() async {
        // #989: today's hydration total + goal. One metricSeries row + a UserDefaults read, same as classic
        // TodayView.reloadHydration(). Cleared when the feature is off so the card can't show a stale total.
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: day?.day)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        // Charge carry (#543) + the honest label, resolved here for the same reason as the two above: the
        // selector below scans repo.days. Calibration nights come from the SAME `RecoveryScorer` helper the
        // classic Today reads, so the two screens agree on when a wearer is genuinely mid-calibration
        // rather than simply lacking a scored night.
        let calNights = (selectedDayOffset == 0)
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: tkey,
            isToday: selectedDayOffset == 0,
            todayScored: day?.recovery != nil,
            isCalibrating: calNights != nil
        )
        cachedChargeDisplay = ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: tkey)

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()
        // Ask the same cross-source resolver the Classic Today view uses which source actually won each
        // displayed score. Include the exact carried-Charge day; a fixed relative lookback can miss a
        // legitimately old carried score.
        let sourceDayKey = selectedDayKey
        let sourceFromDay = min(sourceDayKey, priorScored?.day ?? sourceDayKey)
        async let chargeSourceA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource,
                                                      from: sourceFromDay, to: sourceDayKey)
        async let effortSourceA = repo.resolvedSeries(key: "strain", source: Repository.whoopSource,
                                                      from: sourceDayKey, to: sourceDayKey)
        async let restSourceA = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                    from: sourceDayKey, to: sourceDayKey)

        let restSeries = await restA
        let stepsSeries = await stepsA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days

        // #430 parity: the day-keyed series the DETAILED Key-Metrics tiles graph — a trailing CALENDAR
        // window ending on the selected day (not the last-N stored rows, which on an old import showed
        // months-old data as a fresh trend, issue #23). The loader banks the 30-day SUPERSET; the chosen
        // 1-week/2-week/1-month window filters at render (windowedSpark), so a picker change applies without
        // a reload. Keys mirror the metric catalog so a tile's graph, its tap-through detail and Android's
        // Window all read the same signal. Rest reuses the already-loaded sleep_performance series.
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart)
        let sparkRows = daysSnapshot.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
        // #616: imported-first calorie spark (the day's imported Apple active energy ?: NOOP's on-device
        // estimate) over the window, so a Health-Connect / Apple-only calorie user gets a trend too —
        // matching the imported-first VALUE. Union of imported days + strap-row days. Mirrors Android's
        // caloriesSpark (windowed caloriesByDay).
        let appleRowsForSpark = await appleA
        var winImportedKcal: [String: Double] = [:]
        for r in appleRowsForSpark where r.day >= sparkCutoff && r.day <= selectedDayKey {
            if let k = r.activeKcal { winImportedKcal[r.day] = max(winImportedKcal[r.day] ?? 0, k) }
        }
        var winOnDeviceKcal: [String: Double] = [:]
        for r in sparkRows { if let k = r.activeKcalEst { winOnDeviceKcal[r.day] = k } }
        let energyKcalSpark: [(String, Double)] = Set(winImportedKcal.keys).union(winOnDeviceKcal.keys).sorted()
            .compactMap { day in (winImportedKcal[day] ?? winOnDeviceKcal[day]).map { (day, $0) } }
        kSparks = [
            "recovery": sparkRows.compactMap { r in r.recovery.map { (r.day, $0) } },
            "strain": sparkRows.compactMap { r in r.strain.map { (r.day, $0) } },
            "hrv": sparkRows.compactMap { r in r.avgHrv.map { (r.day, $0) } },
            "rhr": sparkRows.compactMap { r in r.restingHr.map { (r.day, Double($0)) } },
            "spo2": sparkRows.compactMap { r in r.spo2Pct.map { (r.day, $0) } },
            "resp_rate": sparkRows.compactMap { r in r.respRateBpm.map { (r.day, $0) } },
            "steps": sparkRows.compactMap { r in r.steps.map { (r.day, Double($0)) } },
            // #616: the Calories tile drew no trend line — this dict had no matching entry, so windowedSpark
            // returned []. Bank the imported-first calorie series (built above) so the sparkline matches the
            // tile's imported-first number and a Health-Connect / Apple-only user gets a trend.
            "energy_kcal": energyKcalSpark,
            "steps_est": stepsSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "sleep_performance": restSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
        ]
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value
        fitnessAge = (await fitA).last?.value   // history-wide latest banked (not day-scoped)
        vitality = (await vitA).last?.value
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        // Imported Apple Health steps for the SELECTED day (max across rows), the middle tier between the
        // measured strap count and the motion estimate. Health Connect is Android-only, so apple-health is
        // the sole import source on iOS. Mirrors Android `stepsForDay` (#377).
        importedStepsDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        // #616: same-day imported active energy — the calorie fallback when the strap banked no on-device
        // HR estimate for the day, so the tile/card/detail agree (imported-first, mirrors steps).
        importedActiveKcalDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.activeKcal }.max()
        hrValues = (await hrA).map { $0.bpm }
        workouts = await wkA

        let (chargeSource, effortSource, restSource) = await (chargeSourceA, effortSourceA, restSourceA)
        let sourceResolutions = [
            ("recovery", chargeSource),
            ("strain", effortSource),
            ("sleep_performance", restSource),
        ]
        var providers: [String: ScoreInputProvider] = [:]
        for (metric, resolution) in sourceResolutions {
            let selectedPoint = resolution.points.last(where: { $0.day == sourceDayKey })
            let winner = selectedPoint
                ?? (metric == "recovery"
                    ? priorScored.flatMap { prior in resolution.points.last(where: { $0.day == prior.day }) }
                    : nil)
            if let winner {
                providers[metric] = await repo.scoreInputProvider(
                    resolvedSource: winner.source,
                    day: winner.day,
                    metricKey: metric
                )
            }
        }
        heroProviderByMetric = providers

        // #today-hosted-cards: build the shared SleepModel that backs the hosted sleep cards, but ONLY when
        // at least one sleep-origin card is actually hosted — otherwise Today pays no extra Repository cost.
        // The inputs (allSleepSessions / habitualMidsleepSec / sessionMotions) are loaded exactly as the
        // Sleep tab loads them, then handed to the SAME pure `SleepModel.build`, so a hosted card renders
        // numbers byte-identical to the Sleep tab. Reused by every SleepModel-backed hosted card (built once).
        let sleepOrigin = String(localized: "Sleep")
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(where: { $0.origin == sleepOrigin }) {
            let hostedSessions = await repo.allSleepSessions()
            let hostedHabitual = await repo.habitualMidsleepSec()
            let hostedMotion = await repo.sessionMotions(starts: hostedSessions.map { $0.startTs })
            hostedSleepModel = SleepModel.build(SleepModelInputs(
                days: repo.days,
                sleeps: repo.sleeps,
                allSessions: hostedSessions,
                importedSleep: repo.importedSleep,
                habitualMidsleepSec: hostedHabitual,
                motionByStart: hostedMotion))
        } else {
            hostedSleepModel = nil
        }

        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    /// One card-level provenance label. Identical winners collapse to one name; mixed scores show at most
    /// two distinct winners in Charge / Effort / Rest order so the compact badge stays readable.
    private var heroSourceLabel: String? {
        Self.heroSourceLabel(
            providers: ["recovery", "strain", "sleep_performance"].compactMap { heroProviderByMetric[$0] })
    }

    /// Pure aggregation seam for the Liquid hero. The provider mapper names the sensors/imports that
    /// supplied the score inputs; identical names collapse and the compact badge is capped at two.
    static func heroSourceLabel(providers: [ScoreInputProvider]) -> String? {
        var seen = Set<String>()
        var labels: [String] = []
        for provider in providers {
            let label = TodayView.todayScoreProviderLabel(
                sourceId: provider.sourceId,
                brand: provider.brand
            )
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return String(localized: "Push")
        case .balanced: return String(localized: "Maintain")
        case .strained, .rundown: return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        // #612: when still calibrating BECAUSE the strap stopped delivering nights (connected, but no new
        // night for > staleDays), say so directly instead of "still learning your baseline" — the honest
        // calibrating state with its reason attached. `stale` is always > staleDays (14), so always plural.
        if readiness.level == .insufficient,
           let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return String(localized: "No new nights from your strap for \(stale) days. Check it's connected and saving data.")
        }
        switch readiness.level {
        case .primed: return String(localized: "You're primed. A hard session should land well today.")
        case .balanced: return String(localized: "You're in a good spot for training.")
        case .strained: return String(localized: "Signals are down a touch. Keep it easy today.")
        case .rundown: return String(localized: "Several recovery signals are down. Prioritise rest today.")
        case .insufficient: return String(localized: "Still learning your baseline. A few more nights and this fills in.")
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? String(localized: "Good morning")
            : h < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
    }

    // Measured strap count ?: imported Apple Health count ?: motion estimate — the same precedence the
    // detail routing follows below, so the tapped-through source always matches the number shown (#377).
    private var stepCount: Double? {
        displayDay?.steps.map(Double.init) ?? importedStepsDay.map(Double.init) ?? stepsEst
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMeasuredSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }

    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }
    private var stepsDetailSource: String { stepsDetailMetric?.source ?? "my-whoop" }

    // #616: calories resolved IMPORTED-FIRST (the day's imported Apple active energy — the figure these
    // surfaces already showed — else NOOP's on-device HR estimate `activeKcalEst`) — one number across the
    // tile, card and the detail it taps to. Mirrors the steps precedence above.
    private var caloriesCount: Double? {
        importedActiveKcalDay ?? displayDay?.activeKcalEst
    }

    private var caloriesDetailMetric: MetricDescriptor? {
        MetricCatalog.todayCaloriesMetric(hasImportedKcal: importedActiveKcalDay != nil,
                                          hasOnDeviceKcal: displayDay?.activeKcalEst != nil)
    }

    private var caloriesDetailKey: String { caloriesDetailMetric?.key ?? "energy_kcal" }
    private var caloriesDetailSource: String { caloriesDetailMetric?.source ?? "my-whoop" }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "–" }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String { stress.map { String(Int($0.rounded())) } ?? "Calibrating" }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "–" }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 { parts.append(String(format: "%.1f km", dm / 1000)) }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private var dateLine: String {
        // #1013: localize the sub-header date. The old en_US_POSIX "EEEE, d MMMM" formatter forced English
        // weekday + month names regardless of the UI language. A locale-aware field template localizes both
        // the names AND the field order (e.g. fr "mercredi 4 juillet") in the user's locale.
        return selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - NOOP wordmark (centred, with a tap easter egg)

/// The subtle NOOP wordmark. Built as a row of letters (not `Text(...).tracking()`, which adds a
/// trailing gap after the last glyph and pushes the word off-centre), so it sits DEAD centre. Tap it
/// for a little easter egg: it plays one of several random one-shot animations — wiggle, shake, flip,
/// spin, bounce, or a jelly squash — with a light haptic.
private struct LiquidWordmark: View {
    @State private var rot = 0.0      // z-rotation (wiggle / spin)
    @State private var scaleX = 1.0   // horizontal scale (jelly squash)
    @State private var scaleY = 1.0   // vertical scale (bounce / jelly)
    @State private var dx = 0.0       // horizontal offset (shake)
    @State private var flip = 0.0     // y-axis 3D flip
    @State private var token = 0      // drives the tap haptic

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array("NOOP".enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(StrandFont.rounded(16, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .rotationEffect(.degrees(rot))
        .scaleEffect(x: scaleX, y: scaleY)
        .offset(x: dx)
        .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { playRandomEgg() }
        .liquidTapHaptic(trigger: token)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The easter egg: one of several one-shot animations at random. The oscillating ones (wiggle/shake/
    /// squash) kick the value to an extreme then let an under-damped spring settle it back through zero,
    /// which reads as a natural wobble without hand-authored keyframes.
    private func playRandomEgg() {
        token &+= 1
        switch Int.random(in: 0..<6) {
        case 0: // wiggle
            rot = -14
            withAnimation(.spring(response: 0.5, dampingFraction: 0.28)) { rot = 0 }
        case 1: // shake
            dx = -12
            withAnimation(.spring(response: 0.45, dampingFraction: 0.26)) { dx = 0 }
        case 2: // flip
            withAnimation(.easeInOut(duration: 0.6)) { flip += 360 }
        case 3: // spin
            withAnimation(.easeInOut(duration: 0.55)) { rot += 360 }
        case 4: // bounce
            scaleX = 1.28; scaleY = 1.28
            withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { scaleX = 1; scaleY = 1 }
        default: // jelly (squash + stretch)
            scaleX = 1.35; scaleY = 0.7
            withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) { scaleX = 1; scaleY = 1 }
        }
    }
}

// MARK: - Hero score cell (count-up number over a filling vessel, tap-to-splash)

/// One of the three hero scores (Charge / Effort / Rest). The vessel fills from empty and the number
/// COUNTS UP to the value when data lands; tapping the gauge itself splashes (the number is
/// hit-transparent so the tap reaches the vessel). The label row taps through to the scoring guide.
private struct HeroScoreCell: View {
    static let vesselDiameter: CGFloat = 96

    let label: String
    let score: Double?            // on whatever scale the caller passes (nil = no data yet)
    let tint: Color
    let animated: Bool
    let onGuide: () -> Void
    // The scale `score` is already expressed on — 100 for Charge/Rest, or the user's chosen Effort scale
    // max (100 or 21, #45) — so the vessel fill matches the displayed number.
    var maxValue: Double = 100
    // Decimal places for the displayed number. 0 keeps the whole-number scores; the WHOOP 0–21 Effort
    // scale passes 1 to match the app-wide one-decimal `effortDisplay` convention (#45).
    var decimals: Int = 0

    var body: some View {
        VStack(spacing: 7) {
            LiquidScoreGauge(
                score: score,
                tint: tint,
                diameter: Self.vesselDiameter,
                animated: animated,
                maxValue: maxValue,
                decimals: decimals
            )
            Button(action: onGuide) {
                HStack(spacing: 3) {
                    // #74: one line, shrink-to-fit rather than wrap under large Dynamic Type (mirrors the
                    // score number above) so CHARGE/EFFORT/REST never grow the hero card to two lines.
                    Text(label.uppercased()).font(StrandFont.overline).tracking(1.6)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                }
                // Theme-aware hero label (#1160): normal text token — readable on Dark and Light
                // panel surfaces alike (was onDark* when the hero fill was pinned dark).
                .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(label), \(score.map { decimals > 0 ? String(format: "%.\(decimals)f", $0) : String(Int($0.rounded())) } ?? String(localized: "no data yet")). See how it is scored."))
        }
        .frame(maxWidth: .infinity)
    }
}


// MARK: - Scene controls (LiveState-isolated leaves)

/// The liquid pull-to-refresh vessel + a "Syncing…" label. Owns LiveState (isolated leaf, per the file's
/// convention — see `LiquidLiveHR`) so a live-HR notify doesn't re-render the whole Today, but the vessel
/// still knows about an ONGOING strap backfill.
///
/// Visibility used to be driven only by the local `refreshing` flag, which flips false ~350ms after the
/// pull releases (once the local repo reload + a short "let the fill read as done" delay complete) — but
/// `ble.syncNow()` kicks off a real BLE history offload that can run far longer than that. The vessel was
/// disappearing while the strap was still mid-sync, with no feedback beyond the easy-to-miss header
/// `SyncStatusChip`. `syncing` now also holds it (and the label) up while `live.backfilling` is true, so
/// releasing the pull and watching it go away actually means the sync finished.
private struct LiquidRefreshIndicator: View {
    let pullY: CGFloat
    let pullThreshold: CGFloat
    let refreshing: Bool
    let liquidHeart: Color

    @EnvironmentObject private var live: LiveState

    private var progress: CGFloat { min(1, max(0, pullY / pullThreshold)) }

    /// The RAW "a sync is happening" signal. `live.backfilling` toggles false→true between EVERY offload
    /// chunk (`exitBackfilling` at each HISTORY_END → auto-continue re-kick → `beginBackfill`), with a real
    /// BLE round-trip gap in between. A deep backlog is now up to ~24 chunks in ONE connection (#594 raised
    /// the auto-continue cap 6→24), so binding the vessel straight to this strobes it in/out on every chunk
    /// boundary. The MenuBar header pins a constant height for exactly this reason (see MenuBarContent).
    private var syncingRaw: Bool { refreshing || live.backfilling }

    /// Debounced visibility that drives the body: goes true INSTANTLY, but only goes false after riding out
    /// [hideDelay] with no new chunk — so a brief per-chunk `backfilling` gap can't flicker the vessel.
    @State private var syncing = false
    @State private var hideTask: Task<Void, Never>?
    private static let hideDelaySeconds: UInt64 = 3   // comfortably longer than an inter-chunk gap

    var body: some View {
        ZStack {
            if syncing {
                VStack(spacing: 6) {
                    LiquidVessel(value: 0.6, tint: liquidHeart, animated: true)
                        .frame(width: 34, height: 34)
                    Text("Syncing…")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if pullY > 2 {
                LiquidVessel(value: progress, tint: liquidHeart, animated: false)
                    .frame(width: 30, height: 30)
                    .opacity(progress)
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: syncing ? 64 : min(pullY, pullThreshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: syncing)
        .onAppear { syncing = syncingRaw }
        .onChangeCompat(of: syncingRaw) { raw in
            hideTask?.cancel()
            if raw {
                syncing = true                       // a sync (or pull) is active — show at once
            } else {
                // Might just be the gap between two chunks — wait it out; a new chunk cancels this.
                hideTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.hideDelaySeconds * 1_000_000_000)
                    if !Task.isCancelled { syncing = false }
                }
            }
        }
    }
}

/// The uniform diameter of the round Today-header controls — profile avatar, quick-add (+), strap battery
/// ring and Customize — so they sit level in the liquid cluster. Single source of truth (mirrors the
/// Android `HeaderClusterControl`); the syncing vessel is a separate affordance and keeps its own size.
private let headerClusterControl: CGFloat = 36

private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.requestQuickActions() } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: headerClusterControl, height: headerClusterControl)
        }
        .nativeLiquidGlassHeaderButton()
        .accessibilityLabel("Quick actions")
    }
}

/// Shared quiet, full-width navigation affordance used for a secondary dashboard destination.
/// The containing NavigationLink owns the destination and pressed interaction; this view owns one
/// consistent token-based surface, typography, geometry, and trailing chevron.
private struct LiquidFullWidthNavigationAction: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: NoopButtonMetrics.iconSpacing) {
            Text(title)
                .font(StrandFont.subhead.weight(.semibold))
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(StrandPalette.accent)
        .padding(.horizontal, NoopButtonMetrics.hPadding)
        .frame(maxWidth: .infinity)
        .frame(height: NoopButtonMetrics.height)
        .frame(minHeight: NoopButtonMetrics.minHitTarget)
        .contentShape(Rectangle())
        .background(NoopPanelSurface(cornerRadius: NoopButtonMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
    }
}

/// The live heart-rate readout leaf. Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card,
/// never the whole Today (the isolation the classic Today depends on). Keeps its own rolling buffer of
/// live samples, shows the current bpm live with a beat-by-beat trace, and falls back to today's banked
/// 5-minute trace when the strap isn't streaming.
private struct LiquidLiveHR: View {
    var tint: Color
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    var animated: Bool

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    private var bigBpm: Int? {
        if let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: String {
        if isLive { return String(localized: "Live · beat by beat") }
        if fallback.count >= 2 { return String(localized: "5-minute average · since midnight") }
        return live.connected ? String(localized: "Waiting for the strap") : String(localized: "Strap not connected")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                HStack(spacing: NoopMetrics.space1) {
                    Text("BEATS PER MINUTE")
                        .font(StrandFont.overline)
                        .tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .layoutPriority(1)
                Spacer(minLength: NoopMetrics.space2)
                if isLive {
                    // Reuses the existing incoming-HR event pulse; no timer or continuous redraw loop.
                    Image(systemName: "heart.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .scaleEffect(beat ? 1.18 : 0.88)
                        .opacity(beat ? 1 : 0.62)
                        .animation(.easeOut(duration: 0.28), value: beat)
                        .accessibilityHidden(true)
                }
                if let hr = bigBpm {
                    (Text("\(hr)").font(StrandFont.rounded(22)).monospacedDigit()
                        + Text(" bpm").font(StrandFont.caption))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: hr)
                }
            }
            Text(subtitle)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            if series.count >= 2 {
                ZStack {
                    LiquidHeartRateGrid()
                    LiquidThread(bpm: series, tint: tint, height: 92, animated: animated)
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.space2, style: .continuous))
                HStack {
                    stat(String(localized: "Min"), series.min())
                    Spacer()
                    stat(String(localized: "Avg"), series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat(String(localized: "Max"), series.max())
                }
            } else {
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect your strap to see live heart rate")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Static technical grid behind the live trace. Canvas draws only when layout/style changes, so the
/// incoming heart-rate samples remain the card's sole animation driver.
private struct LiquidHeartRateGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let columns = 8
            let rows = 4

            for column in 1..<columns {
                let x = size.width * CGFloat(column) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1..<rows {
                let y = size.height * CGFloat(row) / CGFloat(rows)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(path,
                           with: .color(StrandPalette.hairline.opacity(0.34)),
                           lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension LiquidTodayView {
    /// What the strap-battery ring can honestly say, resolved from the three live signals it has.
    /// Pure + static so the truth table is testable with no strap (`LiquidBatteryDisplayTests`).
    ///
    /// The three signals are INDEPENDENT and land separately, which is the whole reason this exists:
    ///  • `connected` — the CoreBluetooth link.
    ///  • `batteryPct` — standard 0x2A19 (5/MG) or the GET_BATTERY_LEVEL response (4.0).
    ///  • `charging` — a different source entirely: the strap's BATTERY_LEVEL event (~every 8 min),
    ///    which keeps arriving live even mid-offload (`FrameRouter`, "flag only — battery % keeps its
    ///    family-specific source", #77).
    ///
    /// So "charging, but no % yet" is REACHABLE, not hypothetical. The old code nested the bolt inside
    /// `if let pct`, so that state rendered as `bolt.slash` — a crossed-out bolt at a wearer whose strap
    /// was on the charger, which reads as "battery dead". And it drew the ring on `batteryPct` alone with
    /// no `connected` gate: `LiveState.batteryPct` is never cleared (`clearBiometrics` deliberately leaves
    /// it), so a dead strap kept showing its last % as if live — a 21 h old reading rendered identically
    /// to a fresh one. Gating on `connected` here also makes this ring agree with `LiquidStrapBatteryRow`
    /// directly below it, which already required `live.connected`.
    /// The Effort hero's "no cardio load yet" honest note (#530 follow-up — Liquid parity with classic
    /// `TodayView.effortZeroNote`). Pure + static so the gate is testable with no view: the note shows
    /// ONLY for today when a strain value exists and is ~0 — a genuinely calm day reads near zero, while a
    /// no-data day shows its own ring overlay and a past day is never annotated. Liquid reads
    /// `displayDay?.strain` directly (it has no live-strain accumulator like classic's `liveTodayStrain`),
    /// which is exactly the value its Effort hero draws.
    enum EffortDisplay {
        static func showsZeroNote(strain: Double?, isToday: Bool) -> Bool {
            guard isToday, let s = strain else { return false }
            return s < 1.0
        }
    }

    /// (A3/B2, docs/bugs/2026-07-15-strap-battery-backfill-observability.md)
    enum StrapBatteryDisplay: Equatable {
        /// No link — say nothing about charge. A stale % is worse than no %.
        case offline
        /// Linked, but no charge reading has landed yet. `charging` is still knowable on its own.
        case pending(charging: Bool)
        /// A reading from the current link.
        case charge(pct: Double, charging: Bool)

        static func resolve(connected: Bool, batteryPct: Double?, charging: Bool?) -> StrapBatteryDisplay {
            guard connected else { return .offline }
            guard let pct = batteryPct else { return .pending(charging: charging == true) }
            return .charge(pct: pct, charging: charging == true)
        }
    }

    /// What the Charge hero can honestly say for the selected day. Pure + static so the truth table is
    /// testable with no clock and no view (`LiquidChargeCarryTests`).
    ///
    /// See `LiquidChargeCarryTests` for the regression this closes: Liquid read `displayDay?.recovery`
    /// raw, so after the 04:00 rollover — or on any day with no scored night — Charge blanked while the
    /// Rest hero (`freshRestScore`) and the vitals (`Repository.lastVitalsDay`) carried right beside it,
    /// and the widget/watch/Live Activity (`Repository.widgetAnchor`, #911) all showed a number.
    ///
    /// The SELECTION is not re-implemented here: callers pass the row `TodayView.lastScoredRecoveryDay`
    /// picked (its #547 future-day guard included) and the caption comes from `TodayView.carriedCaption`,
    /// so the two Today screens cannot drift apart.
    enum ChargeDisplay: Equatable {
        /// The selected day scored its own Charge.
        case scored(pct: Double)
        /// No score for the selected day; showing a REAL prior night's, stamped with whose it is.
        case carried(pct: Double, caption: String)
        /// Pre-seed-gate: the baseline is still learning and owns its own "N of 4 nights" copy.
        case calibrating(nights: Int)
        /// Nothing honest to show — no score, no prior night, and not calibrating.
        case noData

        /// The number the hero vessel draws, or nil for the honest empty state. A carry draws the REAL
        /// prior value; the empty states draw nothing rather than a fabricated zero.
        var pct: Double? {
            switch self {
            case .scored(let p): return p
            case .carried(let p, _): return p
            case .calibrating, .noData: return nil
            }
        }

        /// The short Charge-state pill beside the greeting. It shares a row with the greeting under a
        /// `fixedSize`, so it stays SHORT — the carried day's full "Last night · <date>" stamp lives in
        /// `caption`, not here. Only `.calibrating` may say "Calibrating": the pill used to key off
        /// `recovery != nil` and so claimed a calibrating baseline on every unscored day, including a
        /// trusted wearer who simply hadn't worn the strap that night.
        var stateLabel: String {
            switch self {
            case .scored: return String(localized: "Solid")
            case .carried: return String(localized: "Last night")
            case .calibrating: return String(localized: "Calibrating")
            case .noData: return String(localized: "No data")
            }
        }

        /// The synthesis-card detail line while the baseline is still forming — the same "N of
        /// `Baselines.minNightsSeed` nights" progress classic `TodayView.calibrationDetail` surfaces, so a
        /// wearer in their first few nights reads identical calibration copy on both Today screens (before
        /// this, Liquid dropped the count and showed a bare "Calibrating"). Non-nil ONLY for `.calibrating`:
        /// the compact greeting pill stays short ("Calibrating") because it shares a `fixedSize` row with
        /// the greeting, so the count lives here in the card, exactly as classic keeps it out of its
        /// `ScoreStatePill`. Reuses classic's String Catalog key verbatim — one entry serves both screens.
        var calibrationDetail: String? {
            guard case .calibrating(let nights) = self else { return nil }
            return String(localized: "Learning your baseline, \(nights) of \(Baselines.minNightsSeed) nights.")
        }

        static func resolve(todayRecovery: Double?, priorScored: DailyMetric?,
                            calibrationNights: Int?, todayKey: String) -> ChargeDisplay {
            if let pct = todayRecovery { return .scored(pct: pct) }
            // Calibration owns its own copy and beats the carry — mid-calibration there is no trustworthy
            // prior score to stand in. Mirrors `lastScoredRecoveryDay`, which returns nil when calibrating.
            if let n = calibrationNights { return .calibrating(nights: n) }
            // `lastScoredRecoveryDay` only ever selects a row whose recovery is non-nil, so the second bind
            // is belt-and-suspenders: a nil falls through to noData rather than fabricating a carry.
            guard let prior = priorScored, let pct = prior.recovery else { return .noData }
            return .carried(pct: pct,
                            caption: TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
        }
    }
}

/// Strap-battery ring. Owns LiveState. Tap → Devices.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter
    private var display: LiquidTodayView.StrapBatteryDisplay {
        .resolve(connected: live.connected, batteryPct: live.batteryPct, charging: live.charging)
    }
    var body: some View {
        Button { router.openDevices() } label: {
            ZStack {
                switch display {
                case .charge(let pct, let charging):
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, pct / 100)))
                        .stroke(ringColor(pct), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2.5)
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if charging {
                        // #972: the default Today never surfaced charging state — only the % ring. A small
                        // bolt over the ring gives the same signal as the "· Charging" text on Mac/Android.
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .offset(y: -10)
                    }
                case .pending(let charging):
                    // Connected, no % yet. If the BATTERY_LEVEL event has told us we're charging, SAY so —
                    // that is the one thing we actually know, and it is the wearer's live question.
                    Image(systemName: charging ? "bolt.fill" : "ellipsis")
                        .font(.system(size: charging ? 11 : 9, weight: .bold))
                        .foregroundStyle(charging ? StrandPalette.chargeColor : StrandPalette.textTertiary)
                case .offline:
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: headerClusterControl, height: headerClusterControl)
        }
        .nativeLiquidGlassHeaderButton()
        .accessibilityLabel(batteryAccessibility)
    }
    /// Never "Strap battery" alone for a no-reading state — that was indistinguishable from a real one.
    private var batteryAccessibility: String {
        switch display {
        case .offline:
            return String(localized: "Strap battery, strap not connected")
        case .pending(let charging):
            return charging
                ? String(localized: "Strap battery charging, no reading yet")
                : String(localized: "Strap battery, no reading yet")
        case .charge(let pct, let charging):
            let n = Int(pct.rounded())
            return charging
                ? String(localized: "Strap battery \(n) percent, charging")
                : String(localized: "Strap battery \(n) percent")
        }
    }
    private func ringColor(_ p: Double) -> Color {
        p < 15 ? StrandPalette.statusCritical : p < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }
}

private extension View {
    /// The edge-to-edge photo is overlaid after the native button style so it can fill the face. Finish
    /// the composed control with interactive system glass as the topmost visual layer; otherwise the
    /// opaque photo would conceal the button style's refraction and highlight. macOS keeps the photo
    /// as-is (Liquid Glass is iOS-only).
    @ViewBuilder
    func nativeLiquidGlassPhotoFinish() -> some View {
        self.nativeLiquidGlassCircleFinish()
    }

    /// Platform-owned Home-header button chrome. iOS 26 supplies the interactive Liquid Glass button
    /// material; macOS and older iOS keep the same circular geometry with a native system material.
    @ViewBuilder
    func nativeLiquidGlassHeaderButton() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .small) {
            self
                .buttonStyle(LiquidPressStyle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
    }
}

/// Strap-history sync state inside the Data Sources card. Owns LiveState; display-only.
///
/// B1 (docs/bugs/2026-07-15-strap-battery-backfill-observability.md): the v8 Liquid redesign shipped no
/// backfill indication AT ALL, so on the iOS default Today a multi-hour history recovery was completely
/// invisible — the wearer could not tell a working strap mid-drain from a dead one. The classic
/// `TodayView` has always had this (`SyncStatusChip`), as do the Mac Sleep/Intelligence screens and the
/// menu bar (`SyncingHistoryNote`); Liquid simply dropped it. Same class of regression as #992, which
/// dropped the "~X days left" runtime estimate from the row directly above this one.
///
/// Deliberately scoped to what LiveState can honestly answer: THAT a drain is running, how many chunks
/// it has pulled, and when one last completed. It does NOT yet say "~15h behind" — that needs the
/// persisted data frontier (max HR ts) compared against `strapRange.newestUnix`, and the frontier is a
/// Repository read that LiveState does not carry. That remains open in B1. Kept here in the Data Sources
/// card as the detailed view; the Devices screen now owns the larger at-a-glance sync card.
private struct LiquidSyncStatusRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.backfilling {
            row(String(localized: "Strap history"), value: chunks, tone: StrandPalette.accent)
        } else if let ts = live.lastSyncedAt {
            row(String(localized: "Strap history"),
                value: String(localized: "Synced \(relativeAgo(ts)) ago"), tone: StrandPalette.textPrimary)
        }
    }

    /// "Syncing…" alone reads as a spinner that might be stuck; the chunk count is the cheapest available
    /// proof that the drain is actually moving. Suppressed at zero — a session that has pulled nothing yet
    /// should not claim "0 chunks pulled" as if that were progress.
    private var chunks: String {
        live.syncChunksThisSession > 0
            ? String(localized: "Syncing… \(live.syncChunksThisSession) chunks")
            : String(localized: "Syncing…")
    }

    private func row(_ label: String, value: String, tone: Color) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.subhead).foregroundStyle(tone)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The strap-battery readout inside the Data Sources card. Owns LiveState; display-only.
private struct LiquidStrapBatteryRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.connected, let pct = live.batteryPct {
            HStack {
                Text("Strap battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // #972: append "· Charging"; #992: append the "~X days left" runtime the v8 redesign dropped.
                Text(batteryText(pct: pct))
                    .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · Charging" }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: the v8 Liquid redesign dropped the "~X days left" estimate the classic Today showed (#713).
    /// Reproduced verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more round to
    /// days; nil (no banked discharge yet, or charging) hides it, so the row only ever shows an estimate we trust.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done).foregroundStyle(StrandPalette.accent)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).foregroundStyle(StrandPalette.accent)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
