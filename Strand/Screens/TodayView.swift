import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Control Center (the home dashboard), HomeDensity rewrite
//
// The owner's complaint was "cards then random space". This rebuild is a tight,
// GAPLESS dashboard grid: one column of uniform sections, every gap == NoopMetrics.gap,
// every section break == NoopMetrics.sectionGap, equal margins from ScreenScaffold.
//
// Composition (top → bottom):
//   (a) HERO, full-width HStack that fills the width EQUALLY: RecoveryRing (left card)
//               + InsightCard "Today's Synthesis" (right card). No lone card, no gap.
//   (b) METRICS, one adaptive LazyVGrid of fixed-104pt StatTiles (Recovery, Strain,
//               Sleep, HRV, RHR, SpO2, Respiratory, Steps, Weight, Calories) each with
//               a 14-day sparkline so the grid tiles perfectly with no empty cells.
//   (c) LAST WORKOUTS, the SAME adaptive grid of fixed-104pt workout StatTiles.
//   (d) DATA SOURCES, one full-width NoopCard footer of SourceBadges + counts.
//
// Sparse series (weight) fall back to ALL history so a tile never shows an empty
// state when data exists. Only locked StrandDesign components are used.

/// #762: carries the hero ring ROW's measured width up so `scoreHeroRow` can size the three rings off the
/// real available width WITHOUT wrapping them in a height-clamped GeometryReader. The old GeometryReader was
/// pinned to `.frame(height: 150)`; once a Charge/Rest ring also showed a provenance badge (the two-line
/// SourceBadge + ScoreStatePill block), the column's intrinsic height climbed past 150 and the fixed frame
/// CLIPPED it, so the badge under the Rest ring overlapped the content below (the reported overlap glitch).
/// Measuring width via a zero-impact background reader instead lets the row self-size in height, so it grows
/// to fit the rings + labels + badges and never clips. Reduce keeps the max, ignoring any 0 default.
private struct HeroRingRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// #829 follow-up: the Today HR chart's frame in the day-swipe gesture's coordinate space, published by a
/// zero-impact background reader on the chart. The page-level day-swipe uses it as a MASK: a drag that
/// STARTS inside this frame belongs to the chart's own pinch/pan/double-tap gestures, so a chart pan can
/// never also flip the day underneath it. Both the gesture's locations and this frame are measured in the
/// SAME named space, so plain rect containment is layout-direction safe (no leading/trailing or
/// alignment-guide math to break under RTL). The frame is content-relative (the named space scrolls with
/// the content), so scrolling never churns the preference; it only re-publishes on a real layout change.
/// When the chart leaves the tree (the sparse-day empty card) no view emits, the value falls back to
/// `.null`, and `.null.contains(_:)` is always false, so the mask disarms itself.
private struct HRChartFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

// MARK: - Active-workout-in-progress indicator (Today)
//
// A "workout in progress" card the Today dashboard shows whenever a manual workout is active. Tapping it
// routes to the Live surface and opens the in-exercise screen (via NavRouter.openActiveWorkout()). Detection
// reads the single source of truth, `AppModel.activeWorkout`, which already survives an app kill (it's
// rehydrated from the durable snapshot on launch), so the card auto-appears and auto-clears with no new
// lifecycle wiring.

/// The Today indicator's value-typed view model: just the sport label + the workout's start, derived from
/// `AppModel.ActiveWorkout`. Equatable so the leaf below only re-renders when one of these actually changes,
/// and the elapsed clock is formatted from a pure function the tests pin.
struct ActiveWorkoutIndicatorModel: Equatable {
    let sport: String
    let startedAt: Date

    static func make(from workout: AppModel.ActiveWorkout?) -> ActiveWorkoutIndicatorModel? {
        guard let workout else { return nil }
        return ActiveWorkoutIndicatorModel(sport: workout.sport, startedAt: workout.start)
    }

    /// Elapsed time since `start`, formatted M:SS up to an hour and H:MM:SS once an hour has passed (so a
    /// 90-minute session reads "1:30:00", not "90:00"). Clamped at zero so a clock-skew negative reads 0:00.
    /// Pure + injectable `now` for deterministic tests. (StrandFont.bodyNumber already applies tabular figures,
    /// so the call site does NOT add `.monospacedDigit()`.)
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private struct ActiveWorkoutIndicatorCard: View {
    let model: ActiveWorkoutIndicatorModel
    let onReturn: () -> Void

    var body: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    // Decorative "live" dot, hidden from VoiceOver (the card itself reads the full state).
                    Circle()
                        .fill(StrandPalette.metricRose)
                        .frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
                        .accessibilityHidden(true)
                    Text("WORKOUT IN PROGRESS")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.metricRose)
                    Spacer(minLength: NoopMetrics.space2)
                    // A per-second live clock. The TimelineView re-evaluates ONLY this Text every second, so
                    // the tick never re-renders the rest of the card (let alone TodayView.body). bodyNumber
                    // already carries `.monospacedDigit()`, so no extra modifier here.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveWorkoutIndicatorModel.elapsed(since: model.startedAt, now: context.date))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: NoopMetrics.cardInnerSpacing) {
                        sportLabel
                        Spacer(minLength: NoopMetrics.space2)
                        NoopButton("Return to workout", systemImage: "arrow.forward.circle.fill",
                                   kind: .primary, action: onReturn)
                    }

                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        sportLabel
                        NoopButton("Return to workout", systemImage: "arrow.forward.circle.fill",
                                   kind: .primary, fullWidth: true, action: onReturn)
                    }
                }
            }
        }
        // Combine the card into one VoiceOver element so the dot + label + clock + button read as a single
        // "Workout in progress" actionable item rather than five separate stops.
        .accessibilityElement(children: .combine)
    }

    private var sportLabel: some View {
        Text(model.sport)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Leaf-isolated so an in-progress workout's ~per-sample `AppModel` churn (the elapsed clock tick + the
/// rewritten `activeWorkout`) re-renders ONLY this card, never the whole Today dashboard, the same
/// leaf-isolation pattern the file documents for the live status/sync rows. Renders nothing when no workout
/// is active, so the card auto-appears/clears purely off `AppModel.activeWorkout`.
///
/// Non-private so the liquid Home (`LiquidTodayView`) renders the SAME leaf — the liquid rewrite dropped this
/// indicator (#105), and sharing one implementation keeps the two Today screens (and Android's
/// `WorkoutInProgressCard`) from drifting. It carries its own `app`/`router` environment objects, so a caller
/// only needs to place `ActiveWorkoutIndicatorSection()` in its body.
struct ActiveWorkoutIndicatorSection: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: NavRouter

    var body: some View {
        if let model = ActiveWorkoutIndicatorModel.make(from: app.activeWorkout) {
            ActiveWorkoutIndicatorCard(model: model) {
                StrandHaptic.selection.play()
                router.openActiveWorkout()
            }
            .transition(.opacity)
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    // PERF (scroll stutter): TodayView deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (heart rate + each R-R packet), and an `@EnvironmentObject live`
    // here would invalidate the ENTIRE Today `body` on every tick, re-evaluating the scene backdrop, the
    // three rings, every sparkline tile, the HR chart and the cards while the user is mid-scroll, which is
    // the reported jank. Instead the handful of regions that actually show live values (the top-bar
    // recording light, the "syncing history" note, the strap battery + sync rows) are extracted into small
    // leaf subviews that each own their OWN `@EnvironmentObject live`, so a 1 Hz tick only re-renders those
    // dots/rows, never the rest of the dashboard. The memoized derivations below already absorbed the
    // EXPENSIVE recomputes; this removes the cheap-but-constant view-tree re-evaluation flood on top.
    //
    // #755 FIX-3 (DEFERRED, note only, not done): a `repo.refreshSeq` bump still re-evaluates the WHOLE
    // Today `body` (TodayView observes `repo` via @EnvironmentObject, and every section reads it). #755's
    // fixes 1+2 cut the bump FREQUENCY hard (a multi-chunk backfill now coalesces to a handful of refreshes,
    // and the Repository diff-guard already drops no-op bumps), so the per-bump full-body re-eval is no
    // longer a STORM, that was the scroll-stutter root cause and it is addressed. A true fix-3 (stop a
    // single bump re-evaluating the full body) would mean extracting each section, heroSection,
    // heartRateTrendSection, the Key-Metrics grid, yourCardsSection, workoutsSection, sourcesSection, into
    // its own leaf view that reads ONLY the @State snapshot loadAll commits (sparks / restScore / hrPoints /
    // workouts / provenanceByMetric / the your-cards values) plus the specific `repo`-derived values it
    // needs (displayDay, selectedDayKey, repo.today) passed in as plain values, so the parent no longer
    // re-renders them on every `repo` change, exactly the leaf-isolation pattern used for LiveState above,
    // but for `repo`. That touches 10+ sections and dozens of `repo.*` references; doing it minimally is not
    // possible without risking the reactivity regressions #755 warns about (a 7.0.3-class subtle break that
    // passes clean tests), so it is left as a follow-up rather than rushed in alongside the load-path fix.
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var router: NavRouter
    /// The "update ringer", the bell in the top bar opens this inbox; dismissed Today cards post into it.
    @EnvironmentObject var updateStore: UpdateStore

    // Imperial/Metric display preference (D#103). Only the Weight tile carries a convertible unit here.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    // Day-cycle scene backdrop (#698). Default ON. When the user turns it off in Settings → Appearance,
    // Today drops the SceneScreenBackground and falls back to the plain dark surfaceBase canvas. The
    // cards already sit on an opaque canvas, so readability is unchanged either way.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    // Effort display scale (#268), drives the Effort tile's value + caption. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    // #233: the HRV window setting, read here only to explain (never recompute) an empty Charge ring
    // caused by the Deep window finding no deep-stage sleep. Same key/default SettingsView reads.
    @AppStorage(UnitPrefs.hrvWindowKey) private var hrvWindowRaw = HrvWindow.whole.rawValue
    private var hrvWindow: HrvWindow { HrvWindow(rawValue: hrvWindowRaw) ?? .whole }

    // Editable Key-Metrics layout (#251), an ordered list of the enabled tiles, persisted display-only.
    // Empty/unset shows the full default order. Every edit affordance routes into one customization sheet.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // "Your cards" customisable dashboard (WHOOP "My Dashboard"), a persisted, reorderable selection of
    // metric cards. Empty/unset shows the sensible default set (Stress / Fitness age / Vitality + HRV +
    // Resting HR). The "CUSTOMISE" link on the section header opens a local sheet (no new nav destination).
    // Persistence is display-only, these cards read the SAME values the rest of Today already loads.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    /// #today-hosted-cards: the ordered Trends/Sleep cards hosted in Today (empty/opt-in). Shared key
    /// with Android; rendered by the `.addedCards` section.
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    private var sectionOrder: [TodaySection] {
        TodayLayoutPrefs.visibleOrder(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)
    }
    @State private var customizationDestination: TodayCustomizationDestination?
    // Hydration tracker (opt-in, default OFF). When off the hydration dashboard card is hidden even if a
    // user had it in their saved selection, the feature owns its own gate.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    /// Today's hydration total + goal (ml), loaded in loadAll when the feature is on. nil hides the value.
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?
    private var enabledDashboardCards: [DashboardCard] {
        // Opt-in gate (mirrors the Android TodayScreen filter `it != HYDRATION || hydrationEnabled`):
        // the hydration card only renders when the feature is on AND the user has added it via CUSTOMISE.
        // It's not in the default selection, so a fresh install never shows it until both are true.
        DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
            .filter { hydrationEnabled || $0 != .hydration }
    }

    // #755: a mirror of `LiveState.backfilling` (strap mid history-offload). TodayView must NOT observe
    // LiveState directly (the 1 Hz flood, see the top-of-type note), so a tiny leaf `BackfillFlagBridge`
    // owns the observation and pushes only the boolean EDGE into this @State. loadAll reads it to DEFER the
    // heavy history-wide reads while the offload's bulk writes are in flight, and the off→false edge re-runs
    // the deferred set immediately (belt-and-braces alongside the coalesced refreshSeq bump). A bare boolean
    // that flips ~twice per offload, so it costs nothing like the per-tick chunk count would.
    @State private var liveBackfillingFlag = false
    // #755: have the history-wide reads ever populated this session? Used so the FIRST load always runs them
    // (even mid-offload, so a cold launch during a sync is never a blank dashboard), while later re-loads can
    // safely defer them during an active backfill.
    @State private var loadedHistoryWideOnce = false

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State private var sparks: [String: [Double]] = [:]
    @State private var workouts: [WorkoutRow] = []
    @State private var appleDays: [AppleDaily] = []
    // Design Reset / #582, the pinned "Your cards" values (Stress / Fitness age / Vitality), surfaced
    // on Today so the buried Explore features sit on the home screen. Loaded in loadAll; nil hides the row.
    @State private var stressToday: Double?
    @State private var fitnessAgeToday: Double?
    @State private var vitalityToday: Double?
    /// Distinct days + sleep sessions imported from a Mi Band (Mi Fitness), for the Data Sources row.
    @State private var xiaomiDays = 0
    @State private var xiaomiSleeps = 0

    // The Rest SCORE (0–100) for the logical day, IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series (imported export wins, computed strap fills). The Key-Metrics
    // "Rest" tile shows THIS, formatted like Charge/Effort, with hours-in-bed kept as the caption, the
    // tile previously showed hours where the score belonged (#248). nil until loaded / no night yet.
    @State private var restScore: Double?

    // The raw per-day merge winners remain available for watch-specific confidence behavior.
    @State private var provenanceByMetric: [String: String] = [:]
    /// The sensor/import provider behind each score cell. Computed rows without durable provenance are
    /// omitted rather than guessed; direct imported rows always resolve.
    @State private var providerByMetric: [String: ScoreInputProvider] = [:]

    // On-device steps ESTIMATE per day (key "steps_est", computed "-noop" source). The Steps tile
    // prefers a REAL step count (strap @57 counter / Apple Health); only when a day has neither does it
    // fall back to this estimate, shown with an "est." caption so it's never read as a measured count.
    // Loaded once via exploreSeries (same merged read fitness_age/vitality use), keyed by day. (#150)
    @State private var stepsEstByDay: [String: Int] = [:]

    // The SELECTED day's representative activity class (#316 / @63): the most-recent non-nil step-sample
    // activityClass (0=still, 1=walk, 2=run) over the day's window. nil when the day has no classed step
    // sample (a 4.0 strap, a pre-v19 row, or every record's @63 byte was invalid), then the steps tile
    // shows NO activity icon. A lightweight on-device readout that rides alongside the @57 step counter.
    @State private var stepActivityClassToday: Int?

    // Today's heart rate as 5-minute bucket means (midnight → now), for the 24h trend chart.
    @State private var hrPoints: [TrendPoint] = []

    // The night's sleep session overlapping the HR window, shaded as a band on the HR chart and
    // used to anchor the recovery marker at wake time (WHOOP-style Overview HR annotations).
    @State private var sleepToday: CachedSleepSession?

    // #today-hosted-cards: the shared SleepModel backing every SleepModel-derived hosted sleep card (Stages
    // vs typical today; more to follow). Built in loadAll() from the SAME inputs the Sleep tab uses, and only
    // when a sleep-origin card is hosted. Twin of the LiquidTodayView `hostedSleepModel`.
    @State private var hostedSleepModel: SleepModel? = nil

    // TODAY's in-progress Effort (NOOP 0–100 axis), recomputed over the day's HR (local-midnight→now)
    // each load so the gauge tracks today as it accumulates rather than waiting on the heavy daily pass
    // to persist, which early in the day would otherwise surface yesterday's completed Effort or a stale
    // 0.0 (#402). nil below StrainScorer.minReadings (we then fall back to the stored daily row) and on
    // any navigated past day (those use the stored value).
    @State private var liveTodayStrain: Double?

    // The HR chart's x-axis window. Today → midnight…now; a navigated PAST day → the full calendar
    // day (midnight…next midnight) so a morning with no banked data reads as empty space rather than
    // the axis silently starting at the first sample (#overview-hr gap clarity).
    @State private var hrAxis: ClosedRange<Date>?

    // #829 - the Today HR chart's pinch/drag ZOOM window. nil falls back to the full `hrAxis` day (the
    // chart uses its xRange). Unlike the Deep Timeline, this never re-reads the DB: the day's 5-minute
    // buckets are already loaded, so pinch/pan only narrows the visible x-domain over the points in hand,
    // which keeps it cheap (no per-frame query) and never touches the read layer. A double-tap on the
    // chart (or the Reset link below it) drops it back to nil. Cleared on day change / fresh load so a new
    // day always opens at full scale, never inheriting the prior day's zoom. `zoomBounds: hrAxis` clamps
    // it to the loaded day, and a non-nil bound also tells OverviewHRChart to keep full point resolution.
    @State private var hrZoomDomain: ClosedRange<Date>?
    /// Reduce Motion gates the Today HR reset animation (the pinch/pan frames are never animated).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // #829 follow-up: the HR chart's frame in the day-swipe coordinate space (see HRChartFrameKey). The
    // day-swipe gesture skips any drag that STARTS inside it, giving the chart's pinch/pan/double-tap
    // exclusive ownership of touches over the chart. `.null` (no chart on screen) contains nothing, so
    // the swipe behaves exactly as before wherever the chart isn't.
    @State private var hrChartFrame: CGRect = .null

    // Day navigation, 0 = today (the logical day), 1 = yesterday, … The DayNavBar chevrons and date
    // jump drive this, and every day-scoped read-out (hero synthesis, the Key-Metrics tiles, the HR
    // trend and Rest score) resolves to the selected day instead of always showing today. Mirrors the
    // Android TodayScreen.selectedDayOffset. Loads re-run when this changes (see .task(id:)).
    @State private var selectedDayOffset = 0
    // #762: the hero ring row's measured width, set by a zero-impact background preference reader so the
    // three rings size off the real available width without a height-clamped GeometryReader clipping the
    // badge under the Rest/Charge ring. 0 until first layout (the row falls back to a sensible default
    // width then). Only changes on a genuine width change (rotation / size class), never on the ~1 Hz
    // live-HR re-render, so this @State doesn't add to the body-eval flood the type note warns about.
    @State private var heroRingRowWidth: CGFloat = 0
    // iOS top-bar state: the date-jump popover and the profile/settings sheet.
    @State private var showDayPicker = false
    @State private var showSettings = false
    @State private var showLiveSession = false
    /// The Updates inbox sheet (opened by the header bell). Shared across both platforms.
    @State private var showUpdatesInbox = false

    /// The NEWEST day-key (max yyyy-MM-dd in `repo.days`) announced to the inbox. Persisted (not @State)
    /// so a relaunch over the same history never re-announces (#521). We trigger on a strictly-newer KEY,
    /// not a count: a recompute that deletes-then-reinserts the window dips/recovers the count but keeps
    /// the same max key, so churn can't masquerade as new history. Empty = no baseline yet (first load
    /// just records the key silently, we only announce genuine forward growth).
    @AppStorage("today.lastAnnouncedDayKey") private var lastAnnouncedDayKey = ""

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // (via the shared `TodayCardDismissal.flagKey`). @AppStorage matches the file's existing prefs style.
    @AppStorage(TodayCardDismissal.flagKey("scoresBuilding")) private var scoresBuildingDismissed = false
    @AppStorage(TodayCardDismissal.flagKey("newHere")) private var newHereDismissed = false
    // #827: the Charge calibration countdown repeats for several consecutive nights, so it's dismissible
    // into the inbox (restorable) like the cards above, rather than nagging a returning user every day. Same
    // card id as Android ("calibratingBaseline") so a dismissed flag round-trips an export/import.
    @AppStorage(TodayCardDismissal.flagKey("calibratingBaseline")) private var calibratingDismissed = false

    // Memoized repo-derived values that are expensive (a full-history sort + per-call
    // `repo.days.map`) yet INDEPENDENT of the ~1 Hz live-HR ticks that re-evaluate `body`
    // while a strap streams. `LiveState` publishes R-R every second, so `body` (and every
    // section it renders) re-runs ~1 Hz; recomputing Readiness and the recovery calibration
    // over the whole history on each of those passes is pure waste. Cache them keyed on a
    // cheap repo fingerprint and rebuild only when that changes, the same memoization
    // SleepView and StressView already use to absorb the live-HR re-render flood.
    @State private var derived: TodayDerived?
    @State private var derivedKey: TodayInputKey?

    // "How your scores work" guide, presented at a specific score's section when the ⓘ on that
    // score (or the first-run card) is tapped. nil = not shown. ScoreSection is Identifiable, so
    // .sheet(item:) drives both presentation and the deep-link target in one binding.
    @State private var guideSection: ScoreSection?
    /// `nil` means the user tapped the generic first-run card / a non-section entry: open at the top.
    @State private var showGuideTop = false

    // One-time, dismissible first-run card pointing at the guide. Set true by either the primary tap
    // or the ✕, so it never shows again. @AppStorage matches the file's existing prefs style (#103).
    @AppStorage(Self.guideCardSeenKey) private var scoringGuideCardSeen = false
    static let guideCardSeenKey = "scoringGuideCardSeen"

    /// #860 item 1: the launch day-landing policy, as ONE pure decision so the rule can't drift between the
    /// view and its test and stays byte-identical to the Kotlin twin. A FRESH-PROCESS launch ALWAYS lands on
    /// today (offset 0), even when today has no data yet and the only banked data is N days back (that exact
    /// case is what stranded a calibrating user on an old day after an app update, the reporter's case). A
    /// non-fresh (in-session) call returns `savedOffset` UNCHANGED, so tabbing away to an old day and coming
    /// back within the same process preserves the user-navigated day (#739/#614). `hasTodayData` and
    /// `latestDataDayBack` are accepted so the signature documents the inputs the retired auto-land consumed,
    /// but on a fresh launch they intentionally have NO effect: the old "land on the most recent data day"
    /// behaviour (#605/#739) is retired. Mirror EXACTLY in Kotlin.
    static func launchDayOffset(isFreshLaunch: Bool,
                                savedOffset: Int,
                                hasTodayData: Bool,
                                latestDataDayBack: Int) -> Int {
        // Fresh process: snap to today unconditionally. The data-shape inputs are deliberately ignored so a
        // calibrating user whose newest data is days back still opens on today, not on that old day.
        guard isFreshLaunch else { return savedOffset }
        return 0
    }

    /// Dashboard-card placeholder for a baseline-relative metric (Stress) still seeding its window, an
    /// honest "building your baseline" state rather than a bare dash (#706/#684). Rendered dimmed.
    /// Localized: it shows in the card value slot, and the dimming check compares against this same
    /// constant, so localizing both sides keeps the placeholder/real-value distinction intact.
    static let calibratingPlaceholder = String(localized: "Calibrating")

    // H6, the steps-calibration sheet, opened from the Steps tile when it's showing an ESTIMATE (a WHOOP
    // 4.0 user, whose strap doesn't transmit steps). Presents the SAME StepsCalibrationSheet Settings uses,
    // so a 4.0 user can reach calibration from where they actually notice the "est." caption.
    @State private var showStepsCalibration = false

    // A1 (#514/#706): the Charge breakdown sheet, opened by tapping the Today hero Charge ring. Its body
    // builds LAZILY on tap (#819 lag) and reads the drivers/confidence DERIVED from the same `displayDay`
    // the ring shows (never a second store read) plus the folded Readiness, so the sheet can never disagree
    // with the ring. A calibrating night (empty drivers) taps through to the EXISTING calibration countdown.
    @State private var showChargeBreakdown = false

    // S4: the Synthesis card collapses to a single one-liner that expands on tap. Default collapsed so the
    // home screen stays tight; the live content (#506) is unchanged, only the chrome folds. @State (not
    // persisted) so a relaunch starts collapsed again.
    @State private var synthesisExpanded = false

    // S5: the Key Metrics grid caps at the first `metricsCollapsedCap` tiles behind a "Show all metrics"
    // expander, collapsing OVERFLOW only (never dropping or reordering a user-selected tile, #251). @State
    // (not persisted) so the home screen reopens compact.
    @State private var metricsExpanded = false
    /// The number of Key-Metric tiles shown before the "Show all metrics" expander (S5). Two columns, so
    /// six fills three clean rows; the rest fold behind the expander. Static so the cap is unit-testable.
    static let metricsCollapsedCap = 6

    // S5: the Data Sources footer collapses to a single "Synced from: …" summary line that expands inline
    // to the full per-source rows + strap battery/sync on tap. Default collapsed so the home screen ends
    // tight; nothing is removed, only folded behind a tap. @State (not persisted) so it reopens collapsed.
    @State private var sourcesExpanded = false

    // THE single grid definition, every tile group reuses it so margins line up. minimum 150 (not
    // 168) so two tiles reliably fit a phone's ~345pt content width; at 168 the grid sat on the
    // single-vs-two-column boundary and could collapse to one full-width column on a narrow phone.
    private let grid = [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)]

    /// #817 - the furthest-back offset the day-nav (swipe + chevrons + date jump) may reach: today's
    /// logical day back to the earliest banked day across all sources. 0 when there's no data yet, so
    /// today stays the only navigable day. Drives the swipe clamp so a swipe can't strand the user on a
    /// day with no data behind it.
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }

    /// The logical day the selector resolves to: offset 0 is today's logical day (rolls at 04:00 like
    /// `repo.today`), past offsets count back from it. Presentation-only, used to pick which stored row
    /// is on screen and to anchor the HR-trend window. Mirrors Android TodayScreen.selectedDay.
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    /// follows `repo.today?.day` so it tracks the row the resolver actually surfaces, including the
    /// non-UTC pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one.
    /// Falls back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }

    /// The DailyMetric shown for the selected day. Offset 0 prefers the live `repo.today` (so the small
    /// hours after midnight still show the logical day's banked row), past offsets look the stored row up
    /// by key. nil when no row exists for that day, every read-out then renders its honest empty state.
    private var displayDay: DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Recovery cold-start: recovery is nil until the HRV baseline crosses the seed gate
    /// (Baselines.minNightsSeed valid nights). While calibrating, this is the count of nights
    /// banked so far, it drives an honest "Calibrating, N of 4 nights" on the recovery ring,
    /// the synthesis card and the Key Metrics tile instead of a bare empty state. It self-clears
    /// the moment recovery populates, and never claims "calibrating" at/above the seed gate.
    /// Mirrors Android TodayScreen.recoveryCalibrationNights (7b5f212). Only meaningful for today,     /// a past day with no recovery is missing data, not mid-calibration, so navigated days return nil.
    private var recoveryCalibration: Int? {
        guard selectedDayOffset == 0 else { return nil }
        if derivedKey == todayInputKey, let d = derived { return d.calibration }
        return computeCalibration()
    }

    /// The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't
    /// been computed yet (#543). Right after the logical-day rollover the new day has no recovery (the new
    /// night isn't scored until you wear it tonight), so a baseline-established user, past calibration,
    /// so `recoveryCalibration` is nil, saw the whole recovery side blank ("No Data" Charge AND blank
    /// HRV / resting-HR / respiratory / SpO₂ tiles + Synthesis) while live HR kept ticking, which reads
    /// as broken. This is the ONE prior row every recovery-derived read-out carries over from, the way
    /// WHOOP keeps showing last recovery until the new one lands. It NEVER fabricates a number for the new
    /// day, each carried tile shows the REAL prior value, labelled as prior, and any metric the prior row
    /// genuinely lacks still falls through to ", ". Non-nil only when: it's today, today itself has no
    /// recovery, and we're not mid-calibration (calibration owns its own copy). Past offsets / scored
    /// today / mid-calibration all return nil so live behaviour is unchanged.
    private var lastScoredRecoveryDay: DailyMetric? {
        Self.lastScoredRecoveryDay(
            days: repo.days,
            selectedDayKey: selectedDayKey,
            isToday: selectedDayOffset == 0,
            todayScored: displayDay?.recovery != nil,
            isCalibrating: recoveryCalibration != nil)
    }

    /// The recovery-INDEPENDENT prior-day vitals carry for the recovery-VITALS card only (HRV / RHR /
    /// respiratory). Unlike `lastScoredRecoveryDay` (gated on the prior night's recovery), this carries the
    /// last night that recorded any vital, so a night with real HRV/RHR but a null recovery still feeds the
    /// vitals — it is read PER-FIELD, today-first, so today's own value always wins. Only on today (a
    /// navigated past day shows its own row verbatim); today's own key bounds it so it can't echo today.
    private var lastVitalsDay: DailyMetric? {
        guard selectedDayOffset == 0 else { return nil }
        return Repository.lastVitalsDay(days: repo.days, todayKey: displayDay?.day ?? selectedDayKey)
    }

    /// PER-FIELD SpO₂ carry — the twin of `lastVitalsDay` for the field its predicate does NOT check. The
    /// on-device engine writes `spo2Pct = nil` for WHOOP 5/MG (no raw red/IR in the v18 layout; the
    /// `spo2_candidate_82` @82 byte is surfaced behind an experimental toggle, never as `spo2Pct`), and
    /// for WHOOP 4.0 the ratio-of-ratios computation may still return nil on too few samples. Only
    /// imported rows carry a calibrated percentage. A whole-row carry (`lastScoredRecoveryDay` or
    /// `lastVitalsDay`) therefore lands on a row with null `spo2Pct` and the Blood Oxygen card reads
    /// "No Data" even though an imported row holds a real reading. Resolving SpO₂ independently (the last
    /// strictly-prior row that HAS it) mirrors the Android `lastSpo2Row`. Only on today; today's key bounds it.
    private var lastSpo2Day: DailyMetric? {
        guard selectedDayOffset == 0 else { return nil }
        return Repository.lastSpo2Day(days: repo.days, todayKey: displayDay?.day ?? selectedDayKey)
    }

    /// PER-FIELD skin-temperature-deviation carry — twin of `lastSpo2Day`; mirrors the Android `lastSkinTempRow`.
    private var lastSkinTempDay: DailyMetric? {
        guard selectedDayOffset == 0 else { return nil }
        return Repository.lastSkinTempDay(days: repo.days, todayKey: displayDay?.day ?? selectedDayKey)
    }

    /// Pure carry-over selector behind `lastScoredRecoveryDay`, extracted so the gate + selection can be
    /// unit-tested without a live view (mirrors `buildingHintCopy` / the Android `lastScoredRecoveryDay`).
    /// Returns the freshest scored prior row to carry over, or nil. `days` is oldest→newest; the chosen
    /// row is the last with a non-nil recovery that ISN'T today's (still-nil) key. nil unless: it's today,
    /// today itself isn't scored, and we're not mid-calibration (calibration owns its own copy), so past
    /// days / a scored today / a calibrating today all carry nothing and live behaviour is unchanged.
    static func lastScoredRecoveryDay(days: [DailyMetric], selectedDayKey: String,
                                      isToday: Bool, todayScored: Bool, isCalibrating: Bool) -> DailyMetric? {
        guard isToday, !todayScored, !isCalibrating else { return nil }
        // Defensive future-day guard (#547): the carry-over must NEVER select a day after today's key, or a
        // stray future-dated row (a bad-clock strap that slipped past the ingest gate / pre-heal DB) would
        // surface as "last night · 12 Jul". `selectedDayKey` is today's logical-day key here (isToday), and
        // yyyy-MM-dd compares lexicographically, so `$0.day < selectedDayKey` keeps only genuine prior days.
        // Belt-and-suspenders on top of the gate + one-time heal, cheap and never wrong.
        return days.last(where: { $0.recovery != nil && $0.day < selectedDayKey })
    }

    /// #817 - day-nav swipe/arrow clamp. Pure + unit-testable so the bounds can't drift between the
    /// swipe gesture, the chevrons and the date jump. `current` is the days-back offset (0 = today),
    /// `delta` is +1 to step one day OLDER, -1 to step one day NEWER. The result is clamped to
    /// `0 ... maxOffset`: never past today (no future day), never older than the earliest data day.
    /// `maxOffset` is the number of whole days from today's logical day back to the earliest banked day
    /// (0 when there's no data yet, so the only reachable day is today). Mirror EXACTLY in Kotlin.
    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        let upper = max(0, maxOffset)
        return min(upper, max(0, current + delta))
    }

    /// #16 - whole days-back offset for a date chosen in the day-nav picker, measured from the LOGICAL day
    /// (not raw Date()). Pure + unit-testable so the 00:00-04:00 rollover case is locked: in that window the
    /// logical day is the PREVIOUS calendar day, so anchoring the offset here (rather than on raw Date())
    /// keeps the picked day in step with the visible date and the a11y label. Clamped at 0 so a future-
    /// relative pick collapses to today. Both dates are reduced to their start-of-day before counting.
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }

    /// Whole days from today's logical day back to `earliestDayKey` (the oldest banked day across all
    /// sources). nil/unparseable earliest, or a key on/after today, both yield 0 - today is then the only
    /// navigable day. Both keys are "yyyy-MM-dd". Pure + unit-testable.
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }

    /// Carry-over recency cap (#779): the "Last night" framing only holds when the carried scored day is
    /// within this many days of today. A weeks-old import is still carried so the recovery side isn't a bare
    /// blank, but it is relabelled "Latest sleep · <date>" so a stale number is NEVER passed off as today's.
    static let carryFreshnessDays = 2

    /// True when the carried scored day is OLDER than the freshness cap (#779), which drives the "Latest
    /// sleep" relabel. Pure + unit-testable. Both keys are "yyyy-MM-dd"; an unparseable key (or non-positive gap)
    /// reads as fresh so we never over-claim staleness. `todayKey` is today's logical-day key (carry-over is
    /// today-only). Mirror EXACTLY in Kotlin.
    static func isCarryStale(priorDayKey: String, todayKey: String) -> Bool {
        guard let prior = dayKeyParser.date(from: priorDayKey),
              let today = dayKeyParser.date(from: todayKey) else { return false }
        let days = Calendar.current.dateComponents([.day], from: prior, to: today).day ?? 0
        return days > carryFreshnessDays
    }

    /// #977 — HONEST Rest resolution for the selected day. Today's own scored Rest wins; otherwise, ONLY on
    /// today, tail-fall-back to the last scored night — but ONLY when that night is within the carry-freshness
    /// window (`isCarryStale == false`). A live 5.0 whose sleep never scores (no overnight gravity ⇒ no
    /// `sleep_performance` point ever written) used to pin Rest to a weeks-old scored night while Charge kept
    /// advancing; gating the tail-fallback lets the Rest hero fall through to its No-Data/calibrating state
    /// instead of freezing on a stale number. The legitimate morning carry of last night's Rest (before today
    /// scores) is preserved unchanged. Pure + unit-testable. Mirror EXACTLY in Kotlin.
    static func freshRestScore(todayValue: Double?, lastDay: String?, lastValue: Double?,
                               isTodaySelected: Bool, todayKey: String) -> Double? {
        if let v = todayValue { return v }
        guard isTodaySelected, let lastDay, let lastValue,
              !isCarryStale(priorDayKey: lastDay, todayKey: todayKey) else { return nil }
        return lastValue
    }

    /// The carried recovery caption stamp, keyed on that scored day's own date and its recency. Within the
    /// freshness cap it reads "Last night · <date>"; once the carried day is older than the cap (#779) it
    /// reads "Latest sleep · <date>" so a weeks-old import is never surfaced as "Last night". Shared by every
    /// carried recovery read-out so the prior-day provenance reads identically. Mirror EXACTLY in Kotlin.
    static func carriedCaption(priorDayKey: String, todayKey: String) -> String {
        let date = lastChargeDateFmt(priorDayKey)
        return isCarryStale(priorDayKey: priorDayKey, todayKey: todayKey)
            ? String(localized: "Latest sleep · \(date)")
            : String(localized: "Last night · \(date)")
    }

    /// Instance convenience over the pure `carriedCaption`. `selectedDayKey` is today's logical-day key in
    /// every carry-over context (the selector gates `isToday`), so it supplies the recency anchor.
    private func carriedCaption(_ prior: DailyMetric) -> String {
        Self.carriedCaption(priorDayKey: prior.day, todayKey: selectedDayKey)
    }

    /// The most recent SCORED Charge to carry over on TODAY (#543), the prior row's recovery value plus
    /// its "Last night · <date>" caption. Derived from `lastScoredRecoveryDay` so Charge and every other
    /// recovery tile carry the SAME prior day; recovery is always present on that row by construction.
    private var lastScoredCharge: (value: Double, caption: String)? {
        guard let prior = lastScoredRecoveryDay, let rec = prior.recovery else { return nil }
        return (rec, carriedCaption(prior))
    }

    // MARK: A1/A3 Charge breakdown drivers (DERIVED from the displayed row, never a second read)

    /// The row the breakdown reads, mirroring the ring: today's own when scored, else the carried last-
    /// scored day (#543) so the sheet matches the carried ring instead of being empty at the rollover.
    private var chargeBreakdownRow: DailyMetric? { lastScoredRecoveryDay ?? displayDay }

    /// The ordered "What shaped it" Charge drivers for the displayed Charge ring, PLUS the confidence tier
    /// computed from the SAME folded HRV baseline. PURE derivation from the SAME `displayDay` (post-#814
    /// union-read row) the ring already shows, plus the HRV/RHR/resp baselines folded from `repo.days`
    /// (exactly the inputs `AnalyticsEngine` scored with), so a row can NEVER describe a term the ring's
    /// number didn't use. This is NOT a second store read: it reads only data already resolved into
    /// `repo.days`/`displayDay`. nil for a calibrating / cold-start night (no usable HRV baseline or no
    /// value), so the sheet gates through to the calibration countdown instead.
    ///
    /// PERF: this replaces the two separate computed properties (`chargeDrivers` +
    /// `chargeBreakdownConfidence`) that EACH re-folded the full `repo.days` history per body evaluation of
    /// the open sheet — four O(n) passes per eval, with the confidence's doc claiming it reused the drivers'
    /// fold while actually recomputing it. One call folds each series exactly once (three passes), and the
    /// sheet reads drivers + confidence out of a single sheet-local `let`.
    private func chargeBreakdown() -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let row = chargeBreakdownRow,
              let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        guard hrvBase.usable else { return nil }
        let rhrBase = Baselines.foldHistory(repo.days.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(repo.days.map(\.respRateBpm), cfg: Baselines.respCfg)
        // Rest-quality term = the Rest composite ÷100, matching AnalyticsEngine's `sleepPerf`. `restScore`
        // is the same merged sleep_performance value the Rest ring reads, so the term stays consistent.
        let sleepPerf = restScore.map { $0 / 100.0 }
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerf, skinTempDev: row.skinTempDevC)
        // Confidence tier SURFACED (never recomputed) from the existing `ScoreConfidence.charge` against
        // the SAME folded HRV baseline the drivers scored with, so the dot + tier tag in the sheet header
        // agree with the breakdown by construction.
        return (drivers, ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase))
    }

    /// The night's relative skin-temp marker for the displayed row (A5), or nil. Surfaced verbatim from
    /// `RecoveryScorer.skinTempRelative` (no recompute) so it reads identically to the Intelligence screen.
    private var chargeSkinTempRel: SkinTempRelative? {
        RecoveryScorer.skinTempRelative(deviationC: chargeBreakdownRow?.skinTempDevC)
    }

    /// #205 (one-word readiness read kept on the hero: Push / Maintain / Rest). PURE mapping of the
    /// existing `ReadinessEngine.Level` so the hero keeps a glanceable verdict even though the full
    /// Readiness card folds into the Charge breakdown sheet (S4). `insufficient` returns nil (the hero then
    /// shows no readiness word, matching the old card hiding itself). Mirror EXACTLY in Kotlin.
    static func readinessWord(_ level: ReadinessEngine.Level) -> String? {
        switch level {
        case .primed:       return String(localized: "Push")
        case .balanced:     return String(localized: "Maintain")
        case .strained:     return String(localized: "Rest")
        case .rundown:      return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    // MARK: Component 2, explained score states (calibrating / carriedLastNight / needsStrap)

    /// The Charge (recovery) score's explained state for the selected day. Built ENTIRELY from the
    /// bindings the rings/tiles already drive, today's recovery, the running calibration count, the
    /// #543 carry-over, re-expressed through the honest `MetricTileState` precedence so the hero/tile show
    /// a clear state, detail and next step rather than a bare blank when there's no number. `calibrating`
    /// reports the nights REMAINING (seed gate minus banked), never a fabricated value.
    private var chargeScoreState: MetricTileState {
        MetricTileState.resolve(
            hasTodayValue: displayDay?.recovery != nil,
            calibratingNightsRemaining: recoveryCalibration.map { max(1, Baselines.minNightsSeed - $0) },
            carriedDate: lastScoredRecoveryDay.map { Self.lastChargeDateFmt($0.day) },
            carriedStale: lastScoredRecoveryDay.map {
                Self.isCarryStale(priorDayKey: $0.day, todayKey: selectedDayKey)
            } ?? false)
    }

    // MARK: Component 3, recording status

    /// The strap's live recording state, mapped from the connection, the live heart-rate sample, and the
    /// last-sync timestamp. Only TODAY carries a recording chip (a navigated past day isn't "recording
    /// now"), so this returns the honest state at offset 0 and `nil` otherwise (the chip then isn't
    /// rendered). "Recording" requires BOTH a live connection AND a current live HR sample, so a connected
    /// strap that isn't yet streaming HR reads as a last-sync / not-recording state, not a false "Recording".
    /// Resolves the recording state for the selected day from a `LiveState` snapshot. Takes `live` as a
    /// parameter rather than reading `self.live` so TodayView itself doesn't observe `LiveState` (see the
    /// PERF note on the missing `@EnvironmentObject live`); the small `RecordingStatusLight` subview that
    /// DOES observe `live` calls this. Past days aren't "recording", so it's nil off offset 0.
    static func recordingState(live: LiveState, selectedDayOffset: Int) -> RecordingState? {
        guard selectedDayOffset == 0 else { return nil }
        // #580, a connected WHOOP 5/MG streaming live HR but offloading no history reads "Connected,         // history sync is experimental on 5.0" rather than a WHOOP-4-style "not recording"/sync-error.
        // BLEManager only flips this true while connected + streaming, so it overrides the honest mapper.
        if live.connected && live.historySyncExperimental { return .historyExperimental }
        return RecordingState.resolve(connected: live.connected,
                                      heartRate: live.heartRate,
                                      lastSyncedAt: live.lastSyncedAt,
                                      sustainedEmptyOffload: live.sustainedEmptyOffload)
    }

    // MARK: Component 4, provenance badge (the real per-day merge winner)

    /// The provider name behind a derived score, or nil when the attribution is unavailable.
    private func provenanceLabel(_ metricKey: String) -> String? {
        guard let provider = providerByMetric[metricKey] else { return nil }
        return Self.todayScoreProviderLabel(sourceId: provider.sourceId, brand: provider.brand)
    }

    /// PURE mapper (unit-testable), a raw resolver source id onto the spec's provenance labels, given
    /// the strap's real `deviceId`. ANY NOOP-computed strap sibling (a "-noop"-suffixed id, not just the
    /// active strap's) reads "On-device" — matching by suffix so a computed row from a non-active strap
    /// can't fall through to `FusionSource.noopComputed`'s raw "NOOP" displayName; the imported strap source
    /// (`deviceId`, normally "my-whoop") reads "Whoop"; the Apple-Health source reads "Apple Health".
    /// Any other real source (Mi Band, Health Connect, nutrition) keeps its `FusionSource.displayName`
    ///, still the genuine merge winner, never a blanket claim. Mirror EXACTLY in Kotlin.
    static func provenanceDisplayLabel(rawSource: String, deviceId: String) -> String {
        if rawSource.hasSuffix("-noop") { return "On-device" }
        if rawSource == deviceId || rawSource == Repository.whoopSource { return "Whoop" }
        if rawSource == Repository.appleHealthSource { return "Apple Health" }
        // Fall back to the FusionSource display name for any other known source; else the raw id.
        return FusionSource(rawValue: rawSource)?.displayName ?? rawSource
    }

    /// The tint for a provenance badge, gold for Whoop, cyan for Apple Health, the positive status hue
    /// for on-device, matching the Data Sources footer so the same source reads the same colour on Today.
    private func provenanceTint(_ metricKey: String) -> Color {
        switch provenanceLabel(metricKey) {
        case "Whoop":       return StrandPalette.accent
        case "Apple Health": return StrandPalette.metricCyan
        default:            return StrandPalette.statusPositive
        }
    }

    // MARK: Apple Watch provenance (M1): "the watch is the sensor, NOOP is the brain"

    /// True when the selected day's value for `metricKey` was supplied by the Apple-Health source (a
    /// watch-only user's Charge/Rest). The store source stays `apple-health` so the engines and the
    /// multi-source resolver are unchanged; the friendlier "Apple Watch" label + its confidence are a
    /// Today-only presentation layer over that source. We don't touch the cross-lane
    /// `provenanceDisplayLabel` (it's Kotlin-mirrored and feeds the Data Sources footer's "Apple Health").
    private func isWatchSourced(_ metricKey: String) -> Bool {
        Self.isWatchSource(provenanceByMetric[metricKey], appleHealthSource: Repository.appleHealthSource)
    }

    /// PURE (unit-testable), whether a resolved raw source id is the Apple-Health/watch source. Kept
    /// separate from the cross-lane `provenanceDisplayLabel` so the Today-only "Apple Watch" relabel never
    /// leaks into the Kotlin-mirrored footer mapping.
    static func isWatchSource(_ rawSource: String?, appleHealthSource: String) -> Bool {
        rawSource == appleHealthSource
    }

    /// PURE (unit-testable), the Today chip label for a resolved source, relabelling the Apple-Health
    /// source as "Apple Watch" (the device the audience knows) and otherwise deferring to the shared
    /// provenance label so Whoop / on-device read identically to the footer.
    static func todayProvenanceChipLabel(rawSource: String, deviceId: String, appleHealthSource: String) -> String {
        if rawSource == appleHealthSource { return "Apple Watch" }
        return provenanceDisplayLabel(rawSource: rawSource, deviceId: deviceId)
    }

    /// Today hero wording names the provider that supplied the score inputs, not where NOOP ran the math.
    /// Registered device brands cover every live source; stable import ids cover providers without a paired
    /// registry row. Unknown ids remain visible rather than being falsely labelled as Whoop.
    static func todayScoreProviderLabel(sourceId: String, brand: String?) -> String {
        let source = sourceId.lowercased()
        switch source {
        case Repository.appleHealthSource: return "Apple Watch"
        case Repository.healthConnectSource: return "Health Connect"
        case "oura-import", "oura-api": return "Oura"
        case "fitbit-import": return "Fitbit"
        case "garmin-import": return "Garmin"
        case "xiaomi-band": return "Mi Band"
        case Repository.activityFileSource: return "Workout files"
        default: break
        }

        if let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            return brand.caseInsensitiveCompare("WHOOP") == .orderedSame ? "Whoop" : brand
        }
        if source == Repository.whoopSource { return "Whoop" }
        return FusionSource(rawValue: sourceId)?.displayName ?? sourceId
    }

    /// True for a watch-context user with no strap supplying scores (Apple-Health days present and no WHOOP
    /// recovery banked anywhere). Used for the calibrating case, where there's no value yet so the resolver
    /// returns no winning source for `provenanceByMetric`, `isWatchSourced` can only fire once a number
    /// lands. Robust watch-only detection is the onboarding lane's job; this is the minimal Today-side gate
    /// so the "Needs more data" affordance shows for the obvious watch-only case without claiming a strap.
    private var isWatchOnlyContext: Bool {
        !appleDays.isEmpty && !repo.days.contains { $0.recovery != nil }
    }

    /// The Today chip label for a watch-sourced score: the audience knows the device, not the framework,
    /// so a watch-derived number reads "Apple Watch" rather than the generic "Apple Health" the footer uses.
    /// Delegates to the pure `todayProvenanceChipLabel` so the relabel logic is unit-tested.
    private func watchProvenanceLabel(_ metricKey: String) -> String {
        let raw = provenanceByMetric[metricKey] ?? Repository.appleHealthSource
        return Self.todayProvenanceChipLabel(rawSource: raw, deviceId: repo.deviceId,
                                             appleHealthSource: Repository.appleHealthSource)
    }

    /// The watch chip's confidence tier for the selected day, bound to the SAME `ScoreState` affordance the
    /// rest of the app uses (`ScoreStatePill`'s dot+label). Charge rides the HRV baseline exactly like the
    /// strap path, `.calibrating` until ~a week of nights, then `.building`, then `.solid` once trusted,     /// so an honest watch week reads differently from a thin one, never a blind number. Rest follows whether
    /// the night actually has a score; any other key falls back to `.building`.
    private func watchScoreState(_ metricKey: String) -> ScoreState {
        let conf: ScoreConfidence
        switch metricKey {
        case "recovery":
            // Same HRV-baseline gate the Charge engine uses, fed by the loaded nightly SDNN history.
            let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
            conf = ScoreConfidence.charge(recovery: displayDay?.recovery, hrvBaseline: hrvBase)
        case "sleep_performance":
            // A watch night with a Rest score reads as built; without one it's still calibrating.
            conf = restScore != nil ? .building : .calibrating
        default:
            conf = .building
        }
        return InsightsHubView.scoreState(conf)
    }

    /// Whether a watch-context score is still calibrating for the selected day, so the chip area shows an
    /// honest "Needs more data" rather than a bare dash/number. Only meaningful on today (a past day with no
    /// value is missing data, not mid-calibration), mirroring `recoveryCalibration`'s today-only gate, and
    /// only when the value itself is absent (a scored watch day shows its "Apple Watch" chip + confidence).
    private func watchNeedsMoreData(_ metricKey: String) -> Bool {
        guard selectedDayOffset == 0, isWatchOnlyContext, !ringHasValue(metricKey) else { return false }
        return watchScoreState(metricKey) == .calibrating
    }

    /// Parses a stored `yyyy-MM-dd` day key in the device-local zone (matching how DailyMetric.day
    /// is written), local so a key never shifts a day under timezone conversion.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption (#543). Falls
    /// back to the raw key if it can't be parsed so the caption is never empty.
    private static func lastChargeDateFmt(_ dayKey: String) -> String {
        guard let date = dayKeyParser.date(from: dayKey) else { return dayKey }
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    /// On-device training-readiness synthesis (HRV / resting-HR / load). Read through the
    /// memoized cache so the full-history sort inside `evaluate` runs once per data change,
    /// not once per ~1 Hz `body` pass while HR streams.
    private var readiness: ReadinessEngine.Readiness {
        if derivedKey == todayInputKey, let d = derived { return d.readiness }
        return computeReadiness()
    }

    // MARK: Memoization plumbing (absorbs the 1 Hz live-HR body flood)

    /// Cached expensive derivations and the inputs they were built from.
    private struct TodayDerived { let readiness: ReadinessEngine.Readiness; let calibration: Int? }

    /// A cheap, O(1) fingerprint of the inputs `derived` depends on. Recomputed every render
    /// (and per accessor call), but it only holds counts + the identity of the first/last and
    /// today rows + the selected offset, so equality is fast and never walks the history.
    private struct TodayInputKey: Equatable {
        let loaded: Bool
        let daysCount: Int
        let firstDay: String?
        let lastDay: DailyMetric?
        let today: DailyMetric?   // covers repo.today?.recovery (calibration) and day rollover
        let offset: Int
        let refreshSeq: Int
    }

    private var todayInputKey: TodayInputKey {
        TodayInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last,
            today: repo.today,
            offset: selectedDayOffset,
            refreshSeq: repo.refreshSeq)
    }

    private func computeReadiness() -> ReadinessEngine.Readiness {
        // Carry-over (#543): Readiness anchors on the day whose row carries today's vitals. Normally that's
        // today's logical day; right after the rollover today has no scored row, so `evaluate` would read
        // `.insufficient` and the whole Readiness card would VANISH while live HR ticks, the same blank
        // the carried Charge/Synthesis avoid. So when carrying, anchor Readiness on the last scored day's
        // key instead (the section header then stamps "Last night · <date>"). Honest: it's the real prior
        // read, not a fabricated today's, and today's own readiness wins the instant tonight is scored.
        let anchor = lastScoredRecoveryDay?.day ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor)
    }

    private func computeCalibration() -> Int? {
        guard selectedDayOffset == 0 else { return nil }
        return RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                                dayKeys: repo.days.map(\.day),
                                                hasRecovery: repo.today?.recovery != nil)
    }

    private func buildDerived() -> TodayDerived {
        TodayDerived(readiness: computeReadiness(), calibration: computeCalibration())
    }

    /// Synthesis-card copy while the recovery baseline calibrates; nil otherwise. Built as
    /// LocalizedStringKey literals so the String Catalog picks up the %lld patterns.
    private var calibrationStatus: LocalizedStringKey? {
        recoveryCalibration == nil ? nil : "Calibrating"
    }
    private var calibrationDetail: LocalizedStringKey? {
        guard let n = recoveryCalibration else { return nil }
        // #612: if the baseline aged out silently — connected, but no new night for > staleDays — say WHY
        // it's calibrating instead of only "learning your baseline". The honest calibrating state is correct;
        // this attaches its reason. `stale` is always > staleDays (14) here, so the copy is always plural.
        if let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return "No new nights from your strap for \(stale) days. Check it's connected and saving data."
        }
        return "Learning your baseline, \(n) of \(Baselines.minNightsSeed) nights."
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

    /// The big scaffold title, suppressed on iOS, where `todayTopBar` replaces it; macOS keeps its
    /// "Control Center" header.
    private var scaffoldTitle: LocalizedStringKey? {
        #if os(iOS)
        nil
        #else
        screenTitle
        #endif
    }

    #if os(iOS)
    /// The day-nav label: relative for today/yesterday, else a short date.
    private var dayNavLabel: String {
        switch selectedDayOffset {
        case 0:  return String(localized: "Today")
        case 1:  return String(localized: "Yesterday")
        default:
            // Anchor to the LOGICAL day, not raw Date(), so the a11y date label agrees with the visible
            // date and the picker highlight in the 00:00-04:00 window (a raw Date() reads a calendar day
            // ahead there, mismatching at offset >= 2) (#16).
            return Self.navDayFmt.string(from: selectedLogicalDay)
        }
    }

    private static let navDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// The selected day as a small locale-aware numeric date ("28/06/2026" or "6/28/2026" per region). The
    /// top bar shows just this now, no "Today" / "Yesterday" word and no prev/next arrows. Day-change is by
    /// horizontal swipe or by tapping to open the picker, and the rotating hint below teaches both.
    private var dayNavDateText: String {
        // At offset 0 date off the row the resolver actually surfaces (`repo.today?.day`, same as
        // `selectedDayKey`) so the top-bar date matches Android (which dates off `today?.day`) and the
        // data on screen, including the pre-04:00 case where `repo.today` is still the logical day's row
        // but raw `selectedLogicalDay` formatting could read a calendar day ahead (#15). Past offsets, and
        // a not-yet-banked today, fall back to the logical day.
        if selectedDayOffset == 0, let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return date.formatted(date: .numeric, time: .omitted)
        }
        return selectedLogicalDay.formatted(date: .numeric, time: .omitted)
    }

    /// Periodic one-word hint shown in place of the date for ~1.5s every ~10s (nil = show the date). With the
    /// arrows gone the day-nav affordances are otherwise invisible, so this teaches them in the accent colour.
    @State private var dayNavHint: String? = nil
    private static let dayNavHints = ["Swipe", "Tap"]
    #endif

    /// #829 follow-up: the named coordinate space the day-swipe drag and the HR-chart frame reader share,
    /// declared on the scaffold's content stack (the view the swipe gesture is attached to), so the mask's
    /// containment check compares like with like. Content-relative, so it is scroll-position independent.
    /// OUTSIDE the iOS conditional: the `.coordinateSpace` modifier and the chart's frame reader compile
    /// on macOS too (only iOS consults the mask), so the constant must exist on both platforms.
    private static let daySwipeSpace = "todayDaySwipeSpace"
    #if os(iOS)

    /// #817 - the day-nav swipe. A horizontal drag flips the day: swipe right (toward today) to the newer
    /// day, swipe left to the older one. Gated so it only fires on a clearly-horizontal drag past a small
    /// threshold (vertical scrolling keeps winning), and clamped to `0 ... earliestDayOffset` so it can't
    /// reach a future day or step older than the earliest banked day. Mirrors the chevron bounds exactly.
    /// #829 follow-up: measured in the named `daySwipeSpace` and MASKED over the HR chart, a drag that
    /// starts inside the chart's frame belongs to the chart's pinch/pan/double-tap, never a day flip.
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .named(Self.daySwipeSpace))
            .onEnded { value in
                // #829 follow-up: the chart owns every touch that starts within its frame (its pan is the
                // same horizontal drag). startLocation and hrChartFrame share the daySwipeSpace coordinate
                // space, so this containment check is layout-direction safe with no RTL special-casing.
                guard !hrChartFrame.contains(value.startLocation) else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                // Horizontal-dominant and far enough to count as a deliberate day flip.
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                // Swipe LEFT (dx < 0) -> OLDER day (+1 offset); swipe RIGHT -> NEWER day (-1 offset).
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    /// Picker binding that converts a chosen date back to a whole-day offset (capped at today).
    private var dayPickerBinding: Binding<Date> {
        Binding(
            // Pre-highlight the LOGICAL day for the current offset (not raw Date()), so in the 00:00-04:00
            // window the calendar opens on the day actually shown rather than a calendar day ahead (#16).
            get: { selectedLogicalDay },
            set: { newValue in
                // Offset from today's logical day (pure helper, unit-tested), so a pick in the rollover
                // window maps to the same offset the visible date and a11y label count back from (#16).
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }

    /// Compact WHOOP-style top bar: a profile/settings button (left), the centred ‹ Today › day-nav
    /// (bold, tappable to jump to a date), and the strap-battery badge (right).
    /// Apple-style large-title header: a tappable "Today ⌄" + full date on the left (taps to change day),
    /// then updates / quick-add / and an OBVIOUS menu avatar (opens Settings) on the right.
    @ViewBuilder private var todayTopBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { showDayPicker = true } label: {
                // Just the date, small (locale numeric), no relative word and no prev/next arrows. Every ~10s
                // it swaps for ~1.5s to a one-word "Swipe" / "Tap" hint in the accent colour so users learn
                // they can change the day by swiping across or tapping here. fixedSize makes it claim its own
                // width so a tight top bar never compresses it, and the trailing icon cluster keeps its room.
                Text(dayNavHint ?? dayNavDateText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(dayNavHint != nil ? StrandPalette.accent : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("\(dayNavLabel). Swipe or tap to change day")
            .popover(isPresented: $showDayPicker) {
                // Cap at the LOGICAL day (not raw Date()) so the calendar never offers a day ahead of the
                // data in the 00:00-04:00 window, matching the visible date + a11y label (#16).
                DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical).labelsHidden().padding(12)
                    // #840, give the graphical picker an explicit size so the iPad popover bubble doesn't
                    // clip the calendar grid (anchored to a 13pt label it otherwise sizes too small).
                    .frame(minWidth: 320, minHeight: 360)
            }

            Spacer(minLength: 8)

            // Uniform 36pt circular icon set: recording-status light, updates bell, quick-add (+), menu.
            HStack(spacing: 8) {
                // Recording status, a colour-coded light (green recording / amber synced / red not
                // recording), replacing the old full-width banner. Taps to Devices to connect. Its OWN
                // subview observes LiveState so a ~1 Hz HR tick re-renders just this 36pt dot, not all of
                // Today (the scroll-stutter fix, see the @EnvironmentObject note at the top of the type).
                RecordingStatusLight(selectedDayOffset: selectedDayOffset) {
                    StrandHaptic.selection.play(); router.openDevices()
                }
                // Updates bell.
                Button { showUpdatesInbox = true } label: {
                    Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                        .font(.system(size: 15, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.surfaceInset))
                        .overlay(alignment: .topTrailing) {
                            if updateStore.unreadCount > 0 {
                                Text("\(min(updateStore.unreadCount, 99))")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.goldDeepText)
                                    .padding(.horizontal, 3.5).padding(.vertical, 1)
                                    .frame(minWidth: 14)
                                    .background(Capsule().fill(StrandPalette.statusCritical))
                                    .offset(x: 2, y: -1)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Updates")
                // Quick-action + (the accented primary, gold, same 36 size as the rest).
                Button { router.requestQuickActions() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(StrandPalette.goldDeepText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quick actions")
                .accessibilityHint("Start a workout, log your journal, or breathe")
                // Menu (Settings), the avatar, same 36 size.
                Button { showSettings = true } label: {
                    ProfileAvatarView(imageData: profile.avatarImageData, size: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Menu and settings")
            }
        }
        .frame(height: 46)
        // Cycle the swipe/tap hint: roughly every 10s flash a one-word hint for ~1.5s, alternating "Swipe" /
        // "Tap", then return to the date. One async loop, auto-cancelled when Today goes away (no leaked timer).
        .task {
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.3)) { dayNavHint = Self.dayNavHints[i % Self.dayNavHints.count] }
                i += 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeInOut(duration: 0.3)) { dayNavHint = nil }
            }
        }
    }

    /// Settings presented as a sheet from the top-bar profile button (sheets inherit the app
    /// environment on iOS, so SettingsView gets the same objects it has under the More tab).
    private var settingsSheet: some View {
        NavigationStack {
            SettingsView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }
    #endif

    /// The Updates "ringer": a bell button (~30pt) with a small gold unread-count badge. Tapping opens
    /// the Updates inbox sheet. Shared by the iOS top bar and the macOS toolbar.
    private var updateBell: some View {
        Button { showUpdatesInbox = true } label: {
            Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 34, height: 34)
                .overlay(alignment: .topTrailing) {
                    if updateStore.unreadCount > 0 {
                        Text("\(min(updateStore.unreadCount, 99))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.goldDeepText)
                            // Fixed 14pt square + Circle() = a true CIRCLE on both platforms, kept INSIDE
                            // the 34pt bell frame (offset -1,1) so the macOS toolbar (at the window's top
                            // edge) no longer clips the badge's top (2026-06-23).
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(StrandPalette.statusCritical))
                            .offset(x: -1, y: 1)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(updateStore.unreadCount > 0
                            ? "Updates, \(updateStore.unreadCount) unread"
                            : "Updates")
    }

    /// The local hour driving the day-cycle scene. DEBUG promo harness: a pinned `--demo-hour` frame
    /// overrides it; otherwise (and always in Release) the live clock hour. Byte-identical in Release.
    private var demoSceneHour: Int {
        #if DEBUG
        return DemoDayHarness.hour ?? Calendar.current.component(.hour, from: Date())
        #else
        return Calendar.current.component(.hour, from: Date())
        #endif
    }

    var body: some View {
        ScreenScaffold(title: scaffoldTitle, onRefresh: { await repo.refresh() },
                       // PERF (scroll): lazy column so the scaffold materialises Today's content on demand.
                       // Today supplies its own inner eager VStack (below), so the staggered section reveal is
                       // unchanged, this only defers building the single inner stack until it scrolls in.
                       // Byte-identical layout (LazyVStack == eager VStack alignment/spacing/header).
                       lazy: true,
                       // PERF (scroll stutter): the day-cycle scene is a static masked Image. CoreAnimation
                       // already caches it as a stable image layer, so it does NOT re-rasterize on body
                       // re-evals or scroll. NO .drawingGroup(), wrapping this 600pt masked image in a
                       // second offscreen pass DOUBLED its cost and re-rasterised it on every TodayView
                       // body re-eval (the masked image is itself one offscreen pass). That was a v7.0.2
                       // lag regression; removing the flatten restores native layer caching.
                       topBackground: showDayCycleBackground
                           ? AnyView(SceneScreenBackground(hour: demoSceneHour)) : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                #if os(iOS)
                // Compact top bar: profile/settings (left) · ‹ Today › day-nav (centre, bold) · strap
                // battery (right). Replaces the big title + the full-width day-nav pill (WHOOP-style).
                todayTopBar
                HealthAlertBanner()
                #else
                HealthAlertBanner()
                // Browse past days: chevrons + a date jump capped at today (no future days). Anchored to
                // the LOGICAL day (the same anchor `selectedLogicalDay` uses) so the full-date label tracks
                // the data shown in the 00:00-04:00 window instead of jumping a calendar day ahead (#14).
                DayNavBar(selectedOffset: selectedDayOffset,
                          today: Repository.logicalDay(Date())) { selectedDayOffset = $0 }
                #endif
                // A "workout in progress" indicator whenever a manual workout is active. A tap routes to Live
                // and opens the in-exercise screen. Its own leaf owns the AppModel observation + per-second
                // clock, so the live tick never re-renders TodayView.body.
                ActiveWorkoutIndicatorSection()
                // The "still building" and "new here?" prompts are about getting today's scores going,
                // so they stay anchored to today rather than reappearing on every navigated past day.
                if selectedDayOffset == 0 && repo.today?.recovery == nil {
                    // While the strap is mid-offload, say so, empty tiles read as final otherwise (#77).
                    // Its own subview observes LiveState (backfilling + chunk count tick during an offload)
                    // so it refreshes without re-rendering the rest of Today (scroll-stutter fix).
                    SyncingHistoryNoteIfBackfilling()
                    if !scoresBuildingDismissed {
                        DataPendingNote(
                            title: "Live now. Your scores are building.",
                            message: "Your live heart rate is working from the strap, and charge, effort and rest build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                        )
                        // A small × dismisses the card INTO the Updates inbox (restorable from there).
                        .overlay(alignment: .topTrailing) {
                            todayCardDismissButton {
                                dismissTodayCard(
                                    id: "scoresBuilding",
                                    title: String(localized: "Live now. Your scores are building."),
                                    message: String(localized: "Charge, Effort and Rest build over your next few nights of wear.")
                                )
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                // Design Reset: the "New here?" first-run card is off the dashboard for the clean WHOOP
                // look. The scoring guide stays reachable from the i on each score and in Settings.
                // The hero rings sit over a WHISPER of time-of-day atmosphere (dawn/day/dusk/night), the
                // backdrop is confined to the ring region via `.background`, so it lifts the identity rings
                // without tinting the rest of the dashboard. The day-cycle scene wash caps at ~0.42 opacity
                // and fades top-down with a bottom dark scrim, no glow, so the white ring numbers + labels
                // stay crisp and high-contrast.
                // The same full order/visibility registry as Liquid Today and Android. Every editor row maps
                // to one real section here, so a change saved from the shared sheet immediately affects this
                // reference implementation too.
                ForEach(sectionOrder) { section in
                    todaySection(section)
                }
                // Opt-in "looks like a workout?" suggestion (default OFF). Renders only when the
                // Settings toggle is on AND the detector finds a recent unsaved, un-dismissed window.
                AutoWorkoutCard()
                sourcesSection
            }
            #if os(iOS)
            // #817 - horizontal swipe to change day. A right-swipe (positive X) steps to the NEWER day
            // (toward today), a left-swipe to the OLDER day, both clamped by `clampedDayOffset` so it can't
            // pass today or go older than the earliest banked day - the same bounds the chevrons use. A
            // height/width ratio gate keeps a near-vertical scroll from registering as a day swipe, and a
            // ~50pt minimum distance avoids stray taps flipping the day. minimumDistance lets the scroll view
            // win short drags so vertical scrolling is unaffected. #829 follow-up: the gesture is masked over
            // the HR chart's frame (see daySwipeGesture), the chart's own pinch/pan owns that region.
            .gesture(daySwipeGesture)
            #endif
            // #829 follow-up: the shared space the day-swipe drag + the HR-chart frame reader both measure
            // in (see daySwipeSpace). Declared on BOTH platforms so the chart's `.named` frame lookup is
            // always defined; only iOS reads it (the swipe is iOS-only, macOS never consults the mask).
            .coordinateSpace(name: Self.daySwipeSpace)
            .onPreferenceChange(HRChartFrameKey.self) { hrChartFrame = $0 }
            // #755: mirror `LiveState.backfilling` into `liveBackfillingFlag` WITHOUT TodayView observing
            // LiveState (which would re-flood `body` ~1 Hz, see the top-of-type note). The bridge is a
            // zero-size leaf in `.background` (no layout impact) that owns the observation and pushes only
            // the boolean EDGE up. loadAll reads the flag to defer the heavy history-wide reads during an
            // active offload; the off→false edge below re-runs them as a safety net to the coalesced refresh.
            .background(BackfillFlagBridge(flag: $liveBackfillingFlag))
        }
        // Reload when the data refreshes OR the selected day changes, the HR trend and Rest score are
        // day-scoped, so navigating must re-fetch them for the newly selected window.
        .task(id: TodayLoadKey(seq: repo.refreshSeq, offset: selectedDayOffset)) { await loadAll() }
        // #989: hydration writes don't bump refreshSeq, so the card needs its own triggers, a logged /
        // edited / deleted drink (hydrationSeq) and the Settings feature toggle both re-read just the two
        // hydration fields. Cheap (one metricSeries row), never re-runs the heavy loads.
        .task(id: repo.hydrationSeq) { await reloadHydration() }
        .onChangeCompat(of: hydrationEnabled) { _ in Task { await reloadHydration() } }
        // #755: NO per-edge safety net here, on purpose. A deep offload segments into many slices that each
        // flip `backfilling` false→true, so re-running the heavy history-wide reads on that edge would re-fire
        // them dozens of times mid-offload and re-create the very write-contention this fix removes. The
        // deferred reads land via the SINGLE coalesced trigger instead: AppModel's debounced `lastSyncedAt`
        // sink fires one refresh ~2s after the offload quiesces, which bumps `refreshSeq` and re-fires the
        // task above with `backfilling` now settled false (and a return-to-tab re-fires it too). If that final
        // refresh diffs byte-identical, nothing new landed, so the already-shown history-wide data is correct.
        // Persist the freshly-built derivations so subsequent (1 Hz) renders with the same
        // inputs hit the cache instead of recomputing. Writing @State during `body` is not
        // allowed, so commit it after layout, the memoized accessors already return the
        // correct value for the change frame, so there is no flash and no missed update.
        // macOS-13-safe single-param onChange.
        .onChangeCompat(of: todayInputKey) { newKey in
            derived = buildDerived()
            derivedKey = newKey
        }
        .onAppear {
            if derivedKey != todayInputKey {
                derived = buildDerived()
                derivedKey = todayInputKey
            }
        }
        #if os(macOS)
        .toolbar {
            // The Updates "ringer" on the TRAILING (top-right) edge of the window toolbar
            // (iOS hosts it in the compact top bar instead).
            ToolbarItem(placement: .primaryAction) {
                updateBell.help("Updates")
            }
        }
        #else
        // Profile/settings from the top-bar button.
        .sheet(isPresented: $showSettings) { settingsSheet }
        #endif
        // The scoring guide, opened at a specific score from its ⓘ.
        .sheet(item: $guideSection) { section in
            ScoringGuideView(initialSection: section, onClose: { guideSection = nil })
        }
        // The scoring guide opened at the top (the first-run card's primary action).
        .sheet(isPresented: $showGuideTop) {
            ScoringGuideView(onClose: { showGuideTop = false })
        }
        // The Updates inbox (the header bell). Both platforms.
        .sheet(isPresented: $showUpdatesInbox) {
            UpdatesInboxView(onClose: { showUpdatesInbox = false })
        }
        // H6, the steps-calibration sheet, opened from an estimated Steps tile (the same sheet Settings
        // hosts). Presented from Today so a WHOOP 4.0 user can calibrate from where the "est." caption shows.
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: repo, onClose: { showStepsCalibration = false })
        }
        // A1 (#514/#706): the Charge breakdown, opened by tapping the Today hero Charge ring. The body
        // builds lazily here (#819 lag) from the drivers DERIVED off the displayed row (never a second read).
        .sheet(isPresented: $showChargeBreakdown) { chargeBreakdownSheet }
        // Every Today layout/card affordance presents the same draft-based editor. Section-level buttons
        // deep-link to their child page; Cancel/Save semantics and Shown/Hidden rows stay identical.
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
        #if os(iOS)
        .fullScreenCover(isPresented: $showLiveSession) {
            LiveSessionView(onClose: { showLiveSession = false })
        }
        #else
        .sheet(isPresented: $showLiveSession) {
            LiveSessionView(onClose: { showLiveSession = false })
        }
        #endif
        // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the
        // card reappears (the inbox also clears the @AppStorage key directly, but this covers an
        // already-mounted Today). Cleared once handled.
        .onChangeCompat(of: updateStore.restoreRequest) { payload in
            guard let payload else { return }
            withAnimation(StrandMotion.interactive) { restoreTodayCard(payload) }
            updateStore.restoreRequest = nil
        }
    }

    /// Flip a Today info-card's dismissed flag back to false so it reappears (driven by the inbox's
    /// "Restore to Today"). Keyed on the card id stored in the update's `restorePayload`.
    private func restoreTodayCard(_ cardID: String) {
        switch cardID {
        case "scoresBuilding":      scoresBuildingDismissed = false
        case "newHere":             newHereDismissed = false
        case "calibratingBaseline": calibratingDismissed = false
        default:                    break
        }
    }

    /// Dismiss a Today info-card INTO the inbox: set its @AppStorage flag (so it stays gone) and post a
    /// `.dismissedCard` update carrying the card id so it can be restored.
    private func dismissTodayCard(id: String, title: String, message: String) {
        StrandHaptic.selection.play()
        switch id {
        case "scoresBuilding":      scoresBuildingDismissed = true
        case "newHere":             newHereDismissed = true
        case "calibratingBaseline": calibratingDismissed = true
        default:                    break
        }
        updateStore.post(UpdateItem(
            kind: .dismissedCard,
            title: title,
            message: message,
            restorePayload: id
        ))
    }

    /// A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
    /// `DataPendingNote`). Matches the "New here?" card's × styling.
    private func todayCardDismissButton(_ action: @escaping () -> Void) -> some View {
        Button { withAnimation(StrandMotion.interactive) { action() } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss to Updates")
    }

    // MARK: First-run scoring-guide card (one-time, dismissible)

    /// "New here?", a single, dismissible card that points first-time users at the guide. Tapping the
    /// card opens the guide; the ✕ closes it. Either action sets `scoringGuideCardSeen`, so it shows
    /// once and never again. Follows the in-flow, never-modal card pattern.
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
                    Text("See how Charge, Effort and Rest are calculated, and how they differ from WHOOP.")
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
                    // Dismiss INTO the Updates inbox (restorable), rather than permanently hiding.
                    withAnimation(StrandMotion.interactive) {
                        dismissTodayCard(
                            id: "newHere",
                            title: String(localized: "New here?"),
                            message: String(localized: "How Charge, Effort and Rest are calculated, and how they differ from WHOOP.")
                        )
                    }
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
                #if os(iOS)
                StrandHaptic.selection.play()
                #endif
                scoringGuideCardSeen = true
                showGuideTop = true
            }
        }
        // Press-down feedback for the tappable card surface.
        .strandPressable()
    }

    // MARK: Readiness, on-device training-readiness synthesis (HRV / resting-HR / load).

    /// S4: Readiness now lives behind the Charge-ring tap (in `chargeBreakdownSheet`), not as a standalone
    /// home-screen card. This wrapper is retained for the sheet's use: a titled header + the card body. A
    /// one-word readiness read (Push / Maintain / Rest, #205) stays on the hero so the home screen keeps a
    /// glanceable verdict. Hidden when there isn't enough history (the `.insufficient` level).
    @ViewBuilder
    private func readinessCard(_ r: ReadinessEngine.Readiness) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // When Readiness is anchored on the carried last-scored day (#543), the overline stamps its
            // date so the prior read isn't passed off as today's; otherwise the usual prompt.
            SectionHeader("Readiness",
                          overline: lastScoredRecoveryDay.map { "\(carriedCaption($0))" } ?? "Should you push today?")
            NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle().fill(readinessColor(r.level)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(r.headline)).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel("Readiness: \(levelWord(r.level)). \(r.headline)")
                            Spacer()
                            if let acwr = r.acwr {
                                Text("load \(String(format: "%.2f", acwr))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .help("Acute (7-day) vs chronic (28-day) training load. 0.8-1.3 is the sweet spot.")
                            }
                        }
                        Text(LocalizedStringKey(r.summary)).font(StrandFont.subhead)
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
                                        Text(LocalizedStringKey(s.label)).font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                        if let evidence = s.evidence {
                                            Text(evidence).font(StrandFont.captionNumber)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                    }
                                        .frame(width: 104, alignment: .leading)
                                    Text(LocalizedStringKey(s.detail)).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text("\(Text(LocalizedStringKey(s.label))), \(flagWord(s.flag)): \(Text(LocalizedStringKey(s.detail)))"))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

    // Word + glyph equivalents so the colour-coded severity isn't carried by hue
    // alone, read by VoiceOver and visible to colour-blind users.
    private func levelWord(_ l: ReadinessEngine.Level) -> String {
        switch l {
        case .primed:       return String(localized: "Primed")
        case .balanced:     return String(localized: "Balanced")
        case .strained:     return String(localized: "Strained")
        case .rundown:      return String(localized: "Run down")
        case .insufficient: return String(localized: "Not enough data")
        }
    }

    private func flagWord(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return String(localized: "Good")
        case .neutral: return String(localized: "Neutral")
        case .watch:   return String(localized: "Watch")
        case .bad:     return String(localized: "Alert")
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

    // MARK: (a) HERO, three ring scores (Charge / Effort / Rest) over a scenic backdrop,
    // then the green-tinted Synthesis coaching card. Bevel layout.

    @ViewBuilder
    private func todaySection(_ section: TodaySection) -> some View {
        switch section {
        case .hero:
            classicHeroSection
        case .liveSession:
            if liveSessionsBeta { liveSessionStartSection }
        case .synthesis:
            synthesisSection
        case .keyMetrics:
            metricsSection
        case .workouts:
            workoutsSection
        case .heartRate:
            heartRateTrendSection
        case .recoveryVitals:
            recoveryVitalsSection
        case .yourCards:
            yourCardsSection
        case .menstrualCycle:
            if selectedDayOffset == 0 { MenstrualCycleHomeCard() }
        case .journal:
            if selectedDayOffset == 0 { JournalReminderCard() }
        case .addedCards:
            hostedCardsSection
        }
    }

    private var classicHeroSection: some View {
        heroSection
            .padding(.vertical, NoopMetrics.space4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                    .fill(StrandPalette.surfaceBase.opacity(0.72))
            )
    }

    private var liveSessionStartSection: some View {
        Button { showLiveSession = true } label: {
            NoopCard(tint: StrandPalette.metricCyan) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.metricCyan)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Start session")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Silent strap coaching against today's Charge.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Text("BETA")
                        .strandOverline()
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    private var recoveryVitalsSection: some View {
        recoveryVitalsCard(displayDay)
    }

    @ViewBuilder
    private var heroSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Recording status now lives as a colour-coded light in the header icon row, not a full-width
            // banner sandwiched above the rings. The three clean rings lead the screen directly.
            scoreHeroRow(d: d, score: score)

            // #233: when THIS specific day's empty Charge is explained by the Deep-sleep HRV window
            // finding no deep-stage sleep, say so plainly instead of an unexplained blank ring. Checked
            // BEFORE the generic Component-2 note (and on every day, not just today): unlike an ordinary
            // "missing data" gap, here the exact cause and the fix are known, so a past day gets the same
            // honest explanation rather than the usual silent bare ring.
            if chargeDeepWindowGap {
                chargeDeepWindowGapNote
            } else if selectedDayOffset == 0 && !chargeScoreState.isCalibrating {
                // Component 2, when Charge has no real today value, an explained state with its detail +
                // next step replaces a bare blank, sitting directly under the rings. The CALIBRATING case is
                // already richly explained by the data-confidence pill + calibration Synthesis card + the ring
                // overlay below, so the note shows for the two states the existing UI doesn't spell out a next
                // step for, "Last night · <date>" (carry-over) and "Needs the strap", keeping the hero from
                // saying "calibrating" twice in two phrasings. `.scored` renders nothing (the ring has the
                // value). TODAY-only: the "No data for today" copy would be wrong on a navigated past day, and
                // a past day with no score is missing data the user can't act on now, so it keeps a bare ring.
                explainedScoreNote(chargeScoreState)
            }

            // A4 , while the Charge baseline is still building, a clear "N nights to go" countdown +
            // "more overnight wear to unlock your Charge baseline" sits under the rings, in place of an
            // empty/zero Charge. Uses the EXISTING calibrating-nights value (no recompute) and only on
            // TODAY (a past day with no Charge is missing data, not mid-calibration).
            // #827: this repeats nightly through the calibration window, so it's dismissible into the inbox
            // (restorable) instead of nagging a returning user every day. Hidden once dismissed.
            if selectedDayOffset == 0, !calibratingDismissed, let banked = recoveryCalibration {
                chargeCalibrationCountdown(banked: banked)
                    // A small × tucks the calibration note into the Updates inbox (restorable from there).
                    .overlay(alignment: .topTrailing) {
                        todayCardDismissButton {
                            dismissTodayCard(
                                id: "calibratingBaseline",
                                title: String(localized: "Building your baseline"),
                                message: String(localized: "Charge, Effort and Rest become personal after a few nights of wear.")
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    /// #233: whether the SELECTED day's empty Charge is explained by the Deep-sleep HRV window finding no
    /// deep-stage sleep that night (see `ChargeBreakdownFormat.chargeDeepWindowGap`). Reads only fields
    /// `displayDay` already carries (`avgHrv`, `deepMin`) — no recompute, no new analytics.
    private var chargeDeepWindowGap: Bool {
        guard let d = displayDay, d.recovery == nil else { return false }
        return ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: hrvWindow, avgHrv: d.avgHrv, deepMin: d.deepMin)
    }

    /// #233: the Deep-sleep HRV-window gap note, shown instead of a bare "-" when this specific day's
    /// Charge is empty because the Deep window found no deep-stage sleep. Distinct from the generic
    /// calibrating/needs-strap states because here the exact cause and fix are known, so it says so, on
    /// today AND a navigated past day alike.
    private var chargeDeepWindowGapNote: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ChargeBreakdownFormat.chargeDeepWindowGapTitle)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(ChargeBreakdownFormat.chargeDeepWindowGapDetail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChargeBreakdownFormat.chargeDeepWindowGapAccessibility)
    }

    /// A4 , the Charge calibrating countdown callout. `banked` is the existing `recoveryCalibration`
    /// (nights gathered so far); the nights-to-go and progress copy come from the pure
    /// `ChargeBreakdownFormat` helpers so they read identically here and in tests. Near-black Charge card,
    /// slate confidence tier, no fabricated number.
    @ViewBuilder
    private func chargeCalibrationCountdown(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Charge"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdown)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        ConfidenceTierChip(confidence: .calibrating)
                    }
                    Text(unlock)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progress)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    // #731: when the countdown restarted because the user tapped "Recalibrate baseline",
                    // say so — otherwise the natural response to a fresh countdown is to tap it again,
                    // which resets it once more. nil (and no line) for anyone who never recalibrated.
                    if let restarted = ChargeBreakdownFormat.currentCalibrationRestartCause() {
                        Text(restarted)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    // MARK: A1/S4 Charge breakdown sheet (the Charge-ring tap target)

    /// The sheet opened by tapping the Today hero Charge ring (A1). Its body builds LAZILY here (#819 lag),
    /// reading the drivers/confidence DERIVED from the same `displayDay` the ring shows (never a second
    /// store read). A scored night shows the existing `ChargeBreakdownSection` (the A3 confidence dot + tier
    /// ride in its header) plus the folded Readiness card (S4); a calibrating night (empty drivers) shows
    /// the EXISTING `chargeCalibrationCountdown` instead, so it never opens to a blank breakdown.
    @ViewBuilder
    private var chargeBreakdownSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // One chargeBreakdown() call per sheet body eval: drivers + confidence share the same
                    // baseline folds (see chargeBreakdown's PERF note).
                    let breakdown = chargeBreakdown()
                    if let breakdown, !breakdown.drivers.isEmpty {
                        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                            ChargeBreakdownSection(drivers: breakdown.drivers,
                                                   confidence: breakdown.confidence,
                                                   skinTempRel: chargeSkinTempRel)
                        }
                    } else {
                        // #233: a night with no deep sleep under the Deep HRV window has a known, specific
                        // cause, so it tap-throughs to that explanation rather than the generic empty note.
                        if chargeDeepWindowGap {
                            chargeDeepWindowGapNote
                        } else if let banked = recoveryCalibration {
                            // A calibrating / cold-start night has no contributions to attribute: tap through
                            // to the honest countdown rather than an empty breakdown.
                            chargeCalibrationCountdown(banked: banked)
                        } else {
                            chargeBreakdownEmptyNote
                        }
                    }
                    // S4: the SEPARATE Readiness block now lives here, behind the Charge-ring tap, instead of
                    // a full-width card on the home screen (a one-word read stays on the hero, #205).
                    readinessSheetBody

                    // UX differentiation: everything above is what shaped YOUR Charge today; this opens the
                    // general METHOD behind the score, so the two are clearly separated, not conflated. It
                    // pushes within this sheet's own NavigationStack, so there is no second modal to manage.
                    NavigationLink {
                        ScoringGuideView(initialSection: .charge, onClose: { showChargeBreakdown = false })
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "function")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(StrandPalette.chargeColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("How Charge is calculated")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("The method behind the score, not today's values.")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(14)
                        .background(NoopPanelSurface(cornerRadius: 14))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How Charge is calculated. The method behind the score.")
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What shaped your Charge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #endif
            }
        }
    }

    /// The honest fallback when the Charge ring is tapped but there is no value AND no running calibration
    /// (a navigated past day with no score, or a fresh strap with nothing banked), never a blank sheet.
    private var chargeBreakdownEmptyNote: some View {
        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("No Charge breakdown yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Self.needsStrapCaption)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// S4: the Readiness card folded into the breakdown sheet. Same content as the old standalone
    /// `readinessSection`, just hosted here behind the Charge-ring tap. Hidden when there isn't enough
    /// history (the `.insufficient` level), matching the old card's own hide.
    @ViewBuilder
    private var readinessSheetBody: some View {
        let r = readiness
        if r.level != .insufficient {
            readinessCard(r)
        }
    }

    /// Design Reset: the greeting + gold Synthesis read-out + vitals, lifted OUT of the hero so Today
    /// reads rings -> Heart rate -> Your cards (the flat mockup order). Same content + behaviour, it just
    /// sits below the HR card and the pinned cards now instead of crowding directly under the rings.
    @ViewBuilder
    private var synthesisSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(greetingWord)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                // S4 (#205): the one-word readiness read kept on the hero now the full Readiness card folded
                // into the Charge-ring tap. Push / Maintain / Rest, derived from the existing Readiness
                // level; hidden when there isn't enough history (nil word). Sits beside the confidence pill.
                if let word = Self.readinessWord(readiness.level) {
                    readinessHeroPill(word)
                }
                recoveryStatePill(score: score)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)

            // S4: the Synthesis card collapses to a single one-liner that EXPANDS on tap. Default collapsed
            // so the home screen stays tight; the live content (#506) is unchanged, only the chrome folds.
            // The headline (synthesisCardStatus / the calibration status / the DEBUG frame) stays visible in
            // both states, so a glance still reads today's verdict; the detail body reveals on tap.
            synthesisCollapsible(d: d, score: score)

            if let note = effortZeroNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }

        }
    }

    /// S4: the Synthesis card, collapsed to a one-liner that expands on tap. Collapsed: the category +
    /// status headline + a chevron. Expanded: the FULL `InsightCard` (status + detail), the existing locked
    /// component, unchanged. The headline is the SAME `synthesisCardStatus` / calibration / DEBUG-frame copy
    /// in both states (#506 content untouched), so only the chrome folds, never the read.
    /// Plain (non-ViewBuilder) resolver for the Synthesis headline + detail. Kept OUT of the @ViewBuilder
    /// body below because an if/else of assignments inside a ViewBuilder is read as a Void "view" and fails
    /// to compile. The copy is identical in the collapsed and expanded states (#506 content untouched).
    private func synthesisCopy(d: DailyMetric?, score: Double?) -> (status: LocalizedStringKey, detail: LocalizedStringKey) {
        #if DEBUG
        if let f = DemoDayHarness.active {
            return ("\(f.synthHeadline)", "\(f.synthBody)")
        }
        #endif
        return (calibrationStatus ?? "\(synthesisCardStatus(d, score: score))",
                calibrationDetail ?? "\(synthesisCardDetail(d, score: score))")
    }

    @ViewBuilder
    private func synthesisCollapsible(d: DailyMetric?, score: Double?) -> some View {
        // Resolve the headline + detail once so the collapsed line and the expanded card never disagree.
        let copy = synthesisCopy(d: d, score: score)
        let status = copy.status
        let detail = copy.detail

        if synthesisExpanded {
            // Expanded: the full locked InsightCard, then a tap target to collapse it again.
            Button {
                withAnimation(StrandMotion.interactive) { synthesisExpanded = false }
            } label: {
                InsightCard(
                    category: "Synthesis",
                    status: status,
                    detail: detail,
                    statusColor: StrandPalette.textPrimary,
                    tint: StrandPalette.chargeColor
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Synthesis. \(status)")
            .accessibilityHint("Collapse")
        } else {
            // Collapsed: a one-liner with the category overline, the status headline and a down-chevron.
            Button {
                withAnimation(StrandMotion.interactive) { synthesisExpanded = true }
            } label: {
                NoopCard(tint: StrandPalette.chargeColor) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Synthesis").strandOverline()
                            Text(status)
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Synthesis. \(status)")
            .accessibilityHint("Expand for the full read")
        }
    }

    /// S4 (#205): the one-word readiness pill on the hero (Push / Maintain / Rest). A small tinted capsule
    /// matching the score-pill chrome, coloured by the readiness level. Tapping it opens the Charge
    /// breakdown sheet, where the FULL Readiness card now lives, so the glanceable word still leads to the
    /// detail it summarises.
    private func readinessHeroPill(_ word: String) -> some View {
        Button {
            showChargeBreakdown = true
        } label: {
            Text(word)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(readinessColor(readiness.level))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(readinessColor(readiness.level).opacity(0.12)))
                .overlay(Capsule(style: .continuous).stroke(readinessColor(readiness.level).opacity(0.32), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Readiness: \(word)")
        .accessibilityHint("See your full readiness")
    }

    // MARK: - Your cards (#582 / Design Reset)

    /// The user-customisable "Your cards" dashboard (WHOOP "My Dashboard"). Surfaces a persisted, reorderable
    /// selection of metric cards on the home screen as flat WHOOP metric rows, each opens its detail screen,
    /// the original three (Stress / Fitness age / Vitality) keep their destinations. A blue "CUSTOMISE" link on
    /// the header opens a local toggle/reorder sheet. TODAY only. A card with no value yet renders ", " rather
    /// than vanishing, so the section is stable; it's hidden only when the user has no cards selected at all.
    @ViewBuilder
    private var yourCardsSection: some View {
        if selectedDayOffset == 0 && !enabledDashboardCards.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // Section header: the "Your cards" label + a right-aligned BLUE "CUSTOMISE" action link (the
                // WHOOP "My Dashboard" ✎ affordance). Opens a local sheet, no new nav destination.
                HStack(alignment: .firstTextBaseline) {
                    Text("Your cards").strandOverline()
                    Spacer(minLength: 8)
                    Button {
                        customizationDestination = .yourCards
                    } label: {
                        Label(String(localized: "Edit").uppercased(), systemImage: "slider.horizontal.3")   // #492/#563: unified "EDIT"
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Customise your cards")
                    .help("Choose which cards show and reorder them")
                }
                ForEach(enabledDashboardCards) { card in
                    dashboardCardRow(card)
                }
            }
        }
    }

    /// #today-hosted-cards: the Trends/Sleep cards the user hosted in Today, in arranged order. Each is the
    /// SAME view its home tab renders, carrying its own header, so this section adds none. Renders nothing
    /// until the user hosts a card (opt-in). TODAY only. Twin of the LiquidTodayView `hostedCardsSection`.
    @ViewBuilder
    private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if selectedDayOffset == 0 && !cards.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ForEach(cards) { card in
                    hostedCard(for: card)
                }
            }
        }
    }

    /// Dispatch a hosted card id to its native view (mirror, not a copy). P0 hosts only Sleep marks.
    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        case .stagesVsTypical:
            // Renders from the shared SleepModel built in loadAll() (same inputs as the Sleep tab). Until the
            // async build lands — or on a device with no usable latest night — show the graceful placeholder,
            // mirroring how AsleepDuration degrades on no data.
            if let m = hostedSleepModel {
                StagesVsTypicalCard(model: m)
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Stages vs typical", overline: "Last night")
                    Text("Not enough nights yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                        .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
                }
            }
        case .nightDetail:
            // Renders from the shared SleepModel built in loadAll() (same inputs as the Sleep tab). Until the
            // async build lands — or with no usable latest night — show the graceful placeholder, as above.
            if let m = hostedSleepModel {
                NightDetailCard(model: m)
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Night detail", overline: "Metrics")
                    Text("Not enough nights yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                        .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
                }
            }
        }
    }

    /// One "Your cards" dashboard row: resolves the card's CURRENT value from the values Today already loads
    /// (a card with no value yet shows ", "), then renders it as a WHOOP metric row that navigates to the
    /// card's detail screen. Branching keeps the destination type concrete (no AnyView) so navigation is
    /// exact and the original three cards reach the SAME screens as before.
    @ViewBuilder
    private func dashboardCardRow(_ card: DashboardCard) -> some View {
        let tint = dashboardTint(card)
        switch card {
        case .stress:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), route: .stress)
        case .fitnessAge, .vitality, .steps, .calories:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), route: .health)
        case .hrv, .restingHr, .respiratory, .bloodOxygen, .skinTemp:
            // The overnight vitals share the Health detail screen (the vital-signs surface).
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), route: .health)
        case .sleep:
            // #110: the value is `totalSleepMin` — WHOOP's imported TST, which can legitimately differ
            // from the Sleep tab's on-device re-staged night. Label the row with its source + which night
            // so a WHOOP figure (or an older night) is never silently shown as "last night" with no
            // provenance; fall back to the card's static description when there's no banked sleep.
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title,
                          subtitle: sleepSourceSubtitle(displayDay) ?? card.subtitle,
                          value: dashboardValue(card), route: .sleep)
        case .hydration:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), route: .hydration)
        case .coupled:
            // The Coupled view row (#43) carries NO metric value, it is a tap-through to the full
            // coupled day screen. An empty value renders just the icon + title + subtitle + chevron.
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), route: .coupled)
        }
    }

    /// A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals
    /// take their biometric hue; everything else takes the blue accent. No gold (WHOOP), tokens only.
    private func dashboardTint(_ card: DashboardCard) -> Color {
        switch card {
        case .stress:      return StrandPalette.effortColor
        case .fitnessAge:  return StrandPalette.chargeColor
        case .vitality:    return StrandPalette.restColor
        case .hrv:         return StrandPalette.metricPurple
        case .restingHr:   return StrandPalette.metricRose
        case .respiratory: return StrandPalette.accent
        case .bloodOxygen: return StrandPalette.metricCyan
        case .skinTemp:    return StrandPalette.metricAmber
        case .sleep:       return StrandPalette.restColor
        case .steps:       return StrandPalette.metricCyan
        case .calories:    return StrandPalette.metricAmber
        case .hydration:   return StrandPalette.metricCyan
        case .coupled:     return StrandPalette.chargeColor
        }
    }

    /// Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
    /// suffix appended. Returns ", " when the value isn't available yet, never a fabricated number. Reuses
    /// the same reads the Key-Metrics tiles use (displayDay vitals, restScore / sleep duration, the pinned
    /// Stress / Fitness age / Vitality, steps, calories).
    private func dashboardValue(_ card: DashboardCard) -> String {
        let d = displayDay
        func withUnit(_ s: String) -> String {
            guard s != "—" else { return "—" }
            return card.unit.isEmpty ? s : "\(s) \(card.unit)"
        }
        switch card {
        case .hrv:
            #if DEBUG
            if let f = DemoDayHarness.active { return withUnit("\(f.hrvMs)") }
            #endif
            return withUnit(d?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—")
        case .restingHr:
            #if DEBUG
            if let f = DemoDayHarness.active { return withUnit("\(f.rhrBpm)") }
            #endif
            return withUnit(d?.restingHr.map { "\($0)" } ?? "—")
        case .respiratory:
            // PER-FIELD carry: today → recovery-INDEPENDENT vitals carry → the sparkline tail. The
            // vitals carry (not the recovery-gated `lastScoredRecoveryDay`) feeds respiratory so a
            // night with real R-R but a null recovery still carries, matching the Android dashboard
            // card (`day?.respRateBpm ?: vitalsDay?.respRateBpm`). The sparkline tail is the last
            // resort so a sparse-but-recent value still reads.
            return withUnit(d?.respRateBpm.map { String(format: "%.1f", $0) }
                            ?? lastVitalsDay?.respRateBpm.map { String(format: "%.1f", $0) }
                            ?? sparks["resp_rate"]?.last.map { String(format: "%.1f", $0) } ?? "—")
        case .bloodOxygen:
            // PER-FIELD carry: today → whole-row vitals carry → the last row that actually HAS a reading
            // (computed "-noop" rows write spo2Pct = nil), so this card agrees with the Key Metrics tile
            // (`d?.spo2Pct ?? carriedVital(perField: lastSpo2Day)`). Mirrors the Android dashboardCardValue.
            // #103: when no calibrated spo2Pct exists AND the experimental toggle is ON, fall back to the
            // spo2_candidate @82 sparkline tail (strap estimate, unverified) so the card shows a number.
            let calibrated = (d?.spo2Pct ?? lastVitalsDay?.spo2Pct ?? lastSpo2Day?.spo2Pct)
            if let v = calibrated { return String(format: "%.0f%%", v) }
            if PuffinExperiment.spo2CandidateDisplayEnabled, let tail = sparks["spo2_candidate"]?.last {
                return String(format: "%.0f%%", tail)
            }
            return "—"
        case .skinTemp:
            // Stored as a deviation from baseline (°C); show it signed so +/- reads honestly. Same per-field
            // carry as Blood Oxygen.
            return (d?.skinTempDevC ?? lastVitalsDay?.skinTempDevC ?? lastSkinTempDay?.skinTempDevC)
                .map { String(format: "%+.1f°", $0) } ?? "—"
        case .sleep:
            return sleepValue(d)
        case .steps:
            // #843/#813, same-day real count only (strap @57 or same-day phone import); never the latest
            // imported row or the sparkline tail (both went stale). Else fall through to the estimate.
            let appleStepsForDay = appleDays.last(where: { $0.day == selectedDayKey })?.steps
            let real = (d?.steps).map { intString(Double($0)) }
                ?? appleStepsForDay.map { intString(Double($0)) }
            let est = stepsEstByDay[selectedDayKey].map { intString(Double($0)) }
            return real ?? est ?? "—"
        case .calories:
            return withUnit(caloriesValue(appleDays.last))
        case .stress:
            #if DEBUG
            // DEBUG promo harness: pin the Stress card (0–3) to the active frame's value. No-op otherwise.
            if let f = DemoDayHarness.active { return "\(f.stress0to3)" }
            #endif
            // #706/#684: Stress is baseline-relative, until the strap has banked enough worn nights to seed
            // the 30-day RHR/HRV baseline StressView reads, there's no number to show. A bare ", " read like a
            // broken card; show the honest calibrating state instead, matching StressView's empty/calibrating
            // copy and the owner's reply on #706.
            return stressToday.map { "\(Int($0.rounded()))" } ?? Self.calibratingPlaceholder
        case .fitnessAge:
            return withUnit(fitnessAgeToday.map { "\(Int($0.rounded()))" } ?? "—")
        case .vitality:
            return vitalityToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .hydration:
            // "<total> / <goal> L" in litres to 1 dp (the string bakes in the " L" itself). Always shows a
            // value (a fresh day reads "0.0 / 3.2 L"); the goal is always derivable from the profile.
            guard let goal = hydrationGoalML else { return "—" }
            return HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: goal)
        case .coupled:
            // A tap-through row with no metric value of its own, the row shows just the chevron. Returning
            // an empty string (not "—") renders no number and leaves it un-dimmed (it isn't a missing value).
            return ""
        }
    }

    /// One WHOOP "My Dashboard" metric row: a thin-line tinted icon, an UPPERCASE tracked label over a grey
    /// baseline caption, the big white value, and a chevron, the whole row navigates to `route`. Flat
    /// WHOOP styling (FrostedCardSurface, no glow), tokens only. Pushed by VALUE — the first hop off the
    /// Today root must ride the tab's `NavigationPath` so a re-tap of the Today tab can pop it (#198;
    /// see TabRoute.swift).
    private func pinnedCardRow(icon: String, tint: Color, title: String, subtitle: String,
                               value: String, route: TabRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // A real number reads white; a placeholder (, / Calibrating) reads dimmed so it doesn't
                // masquerade as a value.
                let isPlaceholder = (value == "—" || value == Self.calibratingPlaceholder)
                Text(value).font(StrandFont.rounded(18, weight: .semibold))
                    .foregroundStyle(isPlaceholder ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Component 2, explained score note (calibrating / carried / needs-strap)

    /// A small explained-state note for a score whose value isn't a real today number: the state title
    /// (Calibrating / Last night · <date> / Needs the strap), its detail line, and the implicit next step
    /// the detail copy carries. Renders NOTHING for `.scored` (the ring/tile shows the number itself), so
    /// a score never shows a bare blank without a state, a reason and a next step. (spec 2026-06-20)
    @ViewBuilder
    private func explainedScoreNote(_ state: MetricTileState) -> some View {
        if let title = state.title, let detail = state.detail {
            let symbol: String = {
                switch state {
                case .calibrating:      return "gauge.with.dots.needle.bottom.50percent"
                case .carriedLastNight: return "clock.arrow.circlepath"
                case .needsStrap:       return "exclamationmark.circle"
                case .scored:           return "info.circle"
                }
            }()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Inset to the card's content margin so the "Last night · <date>" clock-icon footnote sits a
            // proper distance from the hero's left edge rather than hugging it (it previously used a bare
            // 2pt). Matches NoopMetrics.cardPadding, the standard card content inset.
            .padding(.horizontal, NoopMetrics.cardPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityText ?? "")
        }
    }

    // MARK: Screen-4, data-confidence pill, vitals metric card, HRV-baseline insight

    /// The SOLID / CALIBRATING data-confidence chip beside the hero title (README screen 4).
    /// SOLID (gold) once today carries a settled recovery score; CALIBRATING (slate) while the
    /// HRV baseline is still forming (it shows the running "N of 4" count); for a navigated past
    /// day with no score it falls back to CALIBRATING without a count. Drives off the SAME
    /// recovery / calibration bindings the rings use, presentation only.
    @ViewBuilder
    private func recoveryStatePill(score: Double?) -> some View {
        #if DEBUG
        // DEBUG promo harness: pin the readiness badge to the active frame's word. "Solid" reads green
        // (.solid); anything else (e.g. "Moderate") uses the slate state so it's visibly distinct without
        // inventing a new hue. No-op when no `--demo-hour` frame is active.
        if let f = DemoDayHarness.active {
            ScoreStatePill(f.readiness == "Solid" ? .solid : .calibrating, text: "\(f.readiness)")
        } else if score != nil {
            ScoreStatePill(.solid)
        } else if let n = recoveryCalibration {
            ScoreStatePill(.calibrating, text: "Calibrating, \(n) of \(Baselines.minNightsSeed)")
        } else {
            ScoreStatePill(.calibrating)
        }
        #else
        if score != nil {
            ScoreStatePill(.solid)
        } else if let n = recoveryCalibration {
            ScoreStatePill(.calibrating, text: "Calibrating, \(n) of \(Baselines.minNightsSeed)")
        } else {
            ScoreStatePill(.calibrating)
        }
        #endif
    }

    /// Screen-4 "metric card": HRV / Resting HR / Respiratory as a stack of labelled metric rows
    /// inside one frosted card, the three vitals that feed recovery. HRV reads teal (its biometric
    /// hue), Resting HR burnt-orange, Respiratory gold. Values come straight from the selected day's
    /// `DailyMetric` (respiratory falls back to the loaded sparkline tail, as the tile does).
    ///
    /// When today isn't scored yet (the post-rollover state, #543), the recovery side carries over the
    /// last scored day's vitals, labelled with ONE card-level "Last night · <date>" footnote so the
    /// whole recovery side reads consistently with the carried Charge ring, never blanking to ", " while
    /// live HR ticks. Each row still falls through to ", " for a metric the carried row genuinely lacks
    /// (e.g. a BLE-only night with no SpO₂), and today's own value always wins the instant it lands.
    @ViewBuilder
    private func recoveryVitalsCard(_ d: DailyMetric?) -> some View {
        // PER-FIELD, today-first carry (not a whole-row swap): each vital reads today's own value, else
        // falls back to the last night that recorded THAT vital (`lastVitalsDay`, recovery-INDEPENDENT — a
        // night with real HRV/RHR but a null recovery is a valid source, which the old `lastScoredRecoveryDay`
        // row-swap skipped). Today's own value always wins the instant it lands.
        let vd = lastVitalsDay
        let hrv = d?.avgHrv ?? vd?.avgHrv
        let rhr = d?.restingHr ?? vd?.restingHr
        let resp = d?.respRateBpm ?? vd?.respRateBpm
        // The provenance row a shown vital fell back to (nil when every shown vital is today's own): stamps
        // that row's own date, so the footnote can't claim "Last night" for a value that IS today's.
        let carriedFromHrv = d?.avgHrv == nil && vd?.avgHrv != nil
        let carriedFromRhr = d?.restingHr == nil && vd?.restingHr != nil
        let carriedFromResp = d?.respRateBpm == nil && vd?.respRateBpm != nil
        let provenance: DailyMetric? = (carriedFromHrv || carriedFromRhr || carriedFromResp) ? vd : nil
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(spacing: 0) {
                // DEBUG promo harness: pin HRV / Resting HR to the active frame's values. No-op otherwise.
                #if DEBUG
                let demoHrv = DemoDayHarness.active.map { "\($0.hrvMs)" }
                let demoRhr = DemoDayHarness.active.map { "\($0.rhrBpm)" }
                #else
                let demoHrv: String? = nil
                let demoRhr: String? = nil
                #endif
                metricRow(icon: "waveform.path.ecg", label: "HRV",
                          value: demoHrv ?? (hrv.map { "\(Int($0.rounded()))" } ?? "—"), unit: "ms",
                          tint: StrandPalette.metricCyan)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "heart.fill", label: "Resting HR",
                          value: demoRhr ?? (rhr.map { "\($0)" } ?? "—"), unit: "bpm",
                          tint: StrandPalette.metricRose)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "lungs.fill", label: "Respiratory",
                          // Today's own respiratory, else the carried night's; a non-carrying today keeps the
                          // sparkline-tail fallback so a sparse-but-recent value still reads.
                          value: resp.map { String(format: "%.1f", $0) }
                              ?? (vd == nil ? latestString("resp_rate", decimals: 1) : "—"),
                          unit: "rpm",
                          tint: StrandPalette.accent)
                // ONE provenance footnote when a shown vital is a carried prior-day read (not today's),
                // stamped with THAT row's date via the shared caption (which relabels a weeks-old carry to
                // "Latest sleep", #779), so a prior read is never silently passed off as today.
                if let prior = provenance {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        Text(carriedCaption(prior))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("These vitals are from \(carriedCaption(prior))")
                }
            }
        }
    }

    /// One README "metric row": a metric-hue line icon, a secondary label, and a right-aligned bold
    /// value with a small unit. Rows are divided by a hairline. Shared by the Today vitals card.
    @ViewBuilder
    private func metricRow(icon: String, label: LocalizedStringKey, value: String, unit: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            // LocalizedStringKey so the vitals labels read from the catalog; `.textCase` uppercases the
            // translated word in the current locale rather than baking an English "HRV"/"RESTING HR" in.
            Text(label)
                .font(StrandFont.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.number(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }

    // MARK: Synthesis card, today's read, or the carried last-scored read (#543)

    /// The Synthesis status word, carrying the LAST scored day's read when today isn't scored yet (the
    /// post-rollover state), so the card mirrors the carried Charge ring instead of reading "No Data".
    /// When today IS scored (or there's nothing to carry) it's today's own `hrvInsightStatus`.
    private func synthesisCardStatus(_ d: DailyMetric?, score: Double?) -> String {
        if let prior = lastScoredRecoveryDay {
            return hrvInsightStatus(prior, score: prior.recovery)
        }
        return hrvInsightStatus(d, score: score)
    }

    /// The Synthesis detail line. When carrying a prior scored day it summarises THAT day and appends a
    /// "Last night · <date>" provenance, so the prior read is never silently passed off as today's.
    private func synthesisCardDetail(_ d: DailyMetric?, score: Double?) -> String {
        if let prior = lastScoredRecoveryDay {
            return hrvInsightDetail(prior, score: prior.recovery) + " " + carriedCaption(prior) + "."
        }
        return hrvInsightDetail(d, score: score)
    }

    /// The Synthesis status colour, keyed on the carried prior recovery when carrying, else today's.
    private func synthesisCardColor(score: Double?) -> Color {
        if let rec = lastScoredRecoveryDay?.recovery {
            return StrandPalette.recoveryColor(rec)
        }
        return score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
    }

    /// Screen-4 insight headline, when the HRV baseline is established, the gold "primed" read
    /// keyed on how far today's HRV sits above/below the learned baseline ("HRV 12% over baseline");
    /// otherwise the recovery-state word. Purely a re-presentation of the existing recovery + HRV
    /// bindings (no new computation beyond the baseline mean already available on `repo.days`).
    private func hrvInsightStatus(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisWord(score) }
        return pct >= 0
            ? String(localized: "HRV \(abs(pct))% over baseline")
            : String(localized: "HRV \(abs(pct))% under baseline")
    }

    /// The supporting line for the screen-4 insight: the primed/steady read tied to the HRV delta,
    /// folding in the recovery-state synthesis so the card still reads as a coaching summary.
    private func hrvInsightDetail(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisDetail(d) }
        let lead: String
        if pct >= 8 { lead = String(localized: "Your nervous system is well-recovered, so you're primed to push") }
        else if pct >= -8 { lead = String(localized: "You're in balance with your baseline, so moderate strain is well-judged") }
        else { lead = String(localized: "HRV is below your baseline, so ease into the day") }
        return lead + ". " + synthesisDetail(d)
    }

    /// Today's HRV as a percentage above/below the learned baseline (mean of prior nights' avgHrv),
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate), the insight then falls back to the state word.
    private func hrvBaselineDeltaPct(_ d: DailyMetric?) -> Int? {
        guard let today = d?.avgHrv, today > 0 else { return nil }
        // Baseline = mean of the prior nights' HRV, excluding the row being read so "vs baseline"
        // compares it against the rest of history. Excludes the row's OWN day (not always the selected
        // day) so a carried prior-day synthesis (#543) isn't compared against a baseline that includes
        // itself. Needs the same seed depth recovery uses to be honest.
        let excludeDay = d?.day ?? selectedDayKey
        let prior = repo.days
            .filter { $0.day != excludeDay }
            .compactMap(\.avgHrv)
            .filter { $0 > 0 }
        return Self.hrvBaselineDeltaPct(today: today, priorHrvs: prior)
    }

    /// Pure core of the HRV-vs-baseline delta: today's HRV against the mean of the prior nights' HRV,
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate), the insight then falls back to the state word.
    ///
    /// STOPGAP (#696): NOOP mixes HRV measurement methods on the shared `avgHrv` field,     /// strap/WHOOP-CSV HRV is RMSSD (~20-100 ms) while Apple-Health-imported HRV is SDNN
    /// (~100-200 ms). With no method awareness, an SDNN reading (e.g. an Oura ring's 176 ms)
    /// compared against an RMSSD baseline (~57 ms) yields a physiologically-impossible delta
    /// (+209%) and renders the alarming "210% over baseline" headline. Genuine night-to-night
    /// HRV variation essentially never exceeds ~±80-100%, so a magnitude beyond that is almost
    /// always a units/method artifact rather than a real swing. We suppress the misleading
    /// percentage comparison (return nil → callers fall back to the qualitative recovery-state
    /// word) when the delta is implausibly large. The raw HRV tile value stays honest; only the
    /// "X% over baseline" comparison is hidden. Proper fix = tag HRV provenance/method per row
    /// and isolate baselines (separate follow-up).
    static func hrvBaselineDeltaPct(today: Double, priorHrvs prior: [Double]) -> Int? {
        guard today > 0 else { return nil }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        let baseline = prior.reduce(0, +) / Double(prior.count)
        guard baseline > 0 else { return nil }
        let pct = ((today - baseline) / baseline * 100).rounded()
        // Stopgap method-mismatch guard (#696): a real night-to-night HRV move never doubles or halves
        // the value, so a reading outside [0.5x, 2x] of the baseline is almost always a units/method
        // artifact (SDNN reads ~2-3x RMSSD) rather than a genuine swing. Drop the comparison in that case
        // so the alarming "X% over/under baseline" headline never renders (the insight falls back to the
        // qualitative recovery word). Gated on the RATIO, not abs(pct): the percentage is bounded at -100%
        // on the low side but unbounded high, so a symmetric abs() threshold can't catch a near-zero
        // reading. Proper fix tags HRV provenance/method per row and isolates baselines (follow-up).
        guard today <= 2.0 * baseline, today >= 0.5 * baseline else { return nil }
        return Int(pct)
    }

    /// The three score rings over a scenic hero background, WHOOP-style, with the Charge (recovery)
    /// ring centred and enlarged as the hero and smaller Rest / Effort rings flanking it. Each ring
    /// floats cleanly on the scenic field (no per-ring card); a tappable label + chevron sits beneath
    /// each and opens that score's section in the scoring guide. Rings are sized off the available
    /// width so the trio never crushes on a narrow phone nor bloats on iPad.
    /// #762: the hero ring diameter for a given row width. Clamped to [82, 98] so the trio never crushes on
    /// a narrow phone nor bloats on iPad; the linear middle term divides the usable width (less the two 22pt
    /// gaps and a small margin) across the three columns. Pure + static so the clamp can be unit-tested
    /// without a live view, and so the value feeding the SELF-SIZING row (no fixed 150pt clip) is the same
    /// one the test asserts. Mirror on Android if the hero ever moves to a measured-width sizing there.
    static func heroRingDiameter(rowWidth: CGFloat) -> CGFloat {
        min(98, max(82, (rowWidth - 56) / 3.4))
    }

    @ViewBuilder
    private func scoreHeroRow(d: DailyMetric?, score: Double?) -> some View {
        // #762: size the three rings off the row's MEASURED width (read via a background preference reader,
        // not a height-clamped GeometryReader), then let the HStack SELF-SIZE its height. The old layout
        // wrapped the row in `GeometryReader { … }.frame(height: 150)`; that hard 150pt height clipped the
        // column once a Charge/Rest ring also rendered its provenance badge (ring + label + the two-line
        // SourceBadge/ScoreStatePill block exceeds 150), so the Rest badge overlapped the content beneath
        // (the reported overlap/clipping). With a self-sizing HStack the row grows to fit its tallest column
        // and never clips. Until the first layout measures width, fall back to a sensible phone width so the
        // rings render at a reasonable size on the very first frame rather than collapsing.
        let measured = heroRingRowWidth > 1 ? heroRingRowWidth : 345
        // Design Reset: three EQUAL clean rings (no glow, faint track) in Charge / Effort / Rest order with
        // generous spacing, mirroring the flat mockup. Sized off width so they stay equal on any phone.
        let ring = Self.heroRingDiameter(rowWidth: measured)
        HStack(alignment: .top, spacing: 22) {
            // Component 4: Charge/Rest badge their real per-day merge winner; Effort has no badge.
            // A1 (#514/#706): the Charge ring is TAPPABLE (a small chevron cue overlays the ring's bottom
            // edge, INSIDE the ring frame so it adds no stacked height, keeping the #762 self-sizing row
            // untouched). It opens the Charge breakdown sheet (the existing ChargeBreakdownSection), built
            // lazily on tap. No new badge/dot/tier sits under the ring (that would re-load the #762 stack).
            heroRingColumn(section: .charge, domain: .charge, provenanceKey: "recovery",
                           onRingTap: { showChargeBreakdown = true }) {
                chargeRing(score: score, d: d, diameter: ring)
            }
            heroRingColumn(section: .effort, domain: .effort) { effortRing(d: d, diameter: ring) }
            heroRingColumn(section: .rest, domain: .rest, provenanceKey: "sleep_performance") { restRing(diameter: ring) }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Zero-impact width reader: a clear background that publishes the row's width up via preference. It
        // adds no visual and no intrinsic size, so the HStack's own (self-sizing) height is what lays out.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeroRingRowWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(HeroRingRowWidthKey.self) { w in
            if w > 1 && abs(w - heroRingRowWidth) > 0.5 { heroRingRowWidth = w }
        }
    }

    /// The localized natural-case display word for a score domain (Charge / Effort / Rest / Stress). The
    /// hero label uppercases this via `.textCase(.uppercase)`, so the catalog only needs the title-case key.
    /// `domain.rawValue` stays the stable styling/lookup id; this is purely the user-facing word. Mirror in
    /// Kotlin (the Android hero already reads its label from a localized resource, not the enum name).
    private static func domainLabel(_ domain: DomainTheme) -> LocalizedStringKey {
        switch domain {
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .rest:   return "Rest"
        case .stress: return "Stress"
        }
    }

    /// The VoiceOver label for a hero ring's "how this score is calculated" button, with the domain word
    /// interpolated from a localized literal (so the spoken sentence is translated, not half-English).
    private static func domainGuideAccessibilityLabel(_ domain: DomainTheme) -> LocalizedStringKey {
        switch domain {
        case .charge: return "How Charge is calculated"
        case .effort: return "How Effort is calculated"
        case .rest:   return "How Rest is calculated"
        case .stress: return "How Stress is calculated"
        }
    }

    /// One hero ring column: the ring centred, with a tappable UPPERCASE domain label + chevron
    /// beneath it (the WHOOP affordance) that opens the matching scoring-guide section. The ring is
    /// intrinsically diameter×diameter, so the column just centres it and stretches to an equal share
    /// of the row width.
    @ViewBuilder
    private func heroRingColumn<RingBody: View>(
        section: ScoreSection, domain: DomainTheme, provenanceKey: String? = nil,
        onRingTap: (() -> Void)? = nil,
        @ViewBuilder ring: () -> RingBody
    ) -> some View {
        VStack(spacing: 8) {
            // A1: when the column is tappable (Charge), wrap the ring in a button (the body is just the ring
            // with a contentShape so the whole disc is hittable). The tappable ring carries NO in-ring cue:
            // the single affordance is the label chevron below it (see the comment near the Button below).
            // The non-tappable rings render unchanged.
            if let onRingTap {
                Button(action: onRingTap) {
                    ring().contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.domainLabel(domain))
                .accessibilityHint("See what shaped your Charge")
                .accessibilityAddTraits(.isButton)
            } else {
                ring()
            }
            // ONE chevron affordance under every ring, so the row reads uniformly (no second cue on the
            // Charge ring). Charge's chevron opens the "what shaped it" breakdown (its richest explanation);
            // Effort / Rest open their scoring-guide section.
            Button { if let onRingTap { onRingTap() } else { guideSection = section } } label: {
                HStack(spacing: 3) {
                    // #937: an invisible LEADING twin of the trailing chevron. The word + chevron used to
                    // centre as ONE block, which pushed the word visibly off the ring's axis (worst on short
                    // labels like REST). Balancing the row with a same-sized clear chevron re-centres the
                    // WORD itself under the ring while the real chevron stays visible on the trailing side.
                    // opacity(0) keeps its layout slot (a conditional would remove it), and the HStack stays
                    // plain leading-to-trailing content with no alignment-guide math, so LTR and RTL mirror
                    // identically. Hidden from VoiceOver: it is a spacer, not content.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0)
                        .accessibilityHidden(true)
                    // The CHARGE/EFFORT/REST hero label is localized: the catalog key is the natural-case
                    // domain word (Charge/Effort/Rest) and `.textCase(.uppercase)` does the uppercasing in
                    // the current locale, so a de/es/ru build shows the translated word, not the English id.
                    Text(Self.domainLabel(domain))
                        .textCase(.uppercase)
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(onRingTap == nil ? Self.domainGuideAccessibilityLabel(domain)
                                                  : "See what shaped your Charge")
            // Component 4, the real per-day source under the ring (only when this score has a value for
            // the day AND we resolved its winner; a calibrating / empty ring shows no provenance badge).
            // Apple Watch (M1): a watch-sourced score reads "Apple Watch" with its confidence bound to the
            // shared ScoreStatePill dot/label, and a calibrating watch score shows "Needs more data" rather
            // than a bare ring, the honest "the watch can't support this yet" state, never a fake number.
            if let key = provenanceKey {
                if ringHasValue(key), isWatchSourced(key) {
                    VStack(spacing: 4) {
                        SourceBadge("\(watchProvenanceLabel(key))", tint: StrandPalette.metricCyan)
                        ScoreStatePill(watchScoreState(key))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Source: Apple Watch")
                } else if watchNeedsMoreData(key) {
                    SourceBadge("Needs more data", tint: StrandPalette.textTertiary)
                        .accessibilityLabel("Apple Watch. Needs more data to score this yet.")
                } else if ringHasValue(key), let label = provenanceLabel(key) {
                    SourceBadge("\(label)", tint: provenanceTint(key))
                        .accessibilityLabel("Source: \(label)")
                }
            }
        }
    }

    /// Whether the score behind a provenance key has a real value for the selected day, gates the ring's
    /// provenance badge so it only appears alongside an actual number (Charge = recovery, Rest = restScore).
    private func ringHasValue(_ metricKey: String) -> Bool {
        switch metricKey {
        case "recovery":          return displayDay?.recovery != nil
        case "sleep_performance": return restScore != nil
        default:                  return false
        }
    }

    /// Charge (recovery 0–100) hero ring, the premium animated GlowRing, with a calibrating / no-data
    /// track when nil.
    @ViewBuilder
    private func chargeRing(score: Double?, d: DailyMetric?, diameter: CGFloat) -> some View {
        if let s = score {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.chargeColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else if recoveryCalibration == nil, let carried = lastScoredCharge {
            // #802: a CARRIED last-night Charge draws as a real (dimmed) ring, matching the Rest ring, rather
            // than a bare number on a faint track, which read as broken next to Rest's filled ring. Same
            // diameter, so the #762 self-sizing hero row is untouched; the dim + the row-level "Last night"
            // caption already beneath the rings mark it as carried, not today's fresh score.
            GlowRing(fraction: carried.value / 100, value: carried.value, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.chargeColor, diameter: diameter, lineWidth: diameter * 0.10)
                .opacity(0.8)
        } else {
            emptyHeroRing(diameter: diameter) { ringEmptyOverlay(d: d, diameter: diameter) }
        }
    }

    /// Effort (strain) hero ring, honouring the 0–100 / WHOOP-0–21 toggle (#313). Integer on the 0–100
    /// axis so it matches Charge/Rest; one decimal on the WHOOP 0–21 axis where the tenth matters.
    @ViewBuilder
    private func effortRing(d: DailyMetric?, diameter: CGFloat) -> some View {
        if effortStrain(d) != nil, let gv = effortGaugeValue(d) {
            GlowRing(fraction: gv / effortGaugeMax, value: gv,
                     format: { effortScale == .whoop ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" },
                     color: StrandPalette.effortColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData(diameter: diameter) }
        }
    }

    /// Rest (sleep composite 0–100) hero ring.
    @ViewBuilder
    private func restRing(diameter: CGFloat) -> some View {
        if let s = restScore {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.restColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else if displayDay?.recovery != nil {
            // #898: an aggregate-import user (a daily HRV/RHR import, no in-bed session) gets a Charge from
            // WatchRecovery but NO sleep_performance, so Rest read a bare "No data" next to a lit Charge ,
            // reading as broken. When a Charge IS present for the day but Rest is absent, say WHY honestly
            // instead. We do NOT fabricate a Rest number , an aggregate genuinely has no scored night. A day
            // with no Charge either (truly empty) still falls through to "No data". Mirrors Android.
            emptyHeroRing(diameter: diameter) { ringNeedsTrackedNight() }
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData(diameter: diameter) }
        }
    }

    /// #898: the Rest ring's overlay when a Charge exists for the day but there's no scored sleep (the
    /// aggregate-import case). Says why Rest is blank instead of a bare "No data", without fabricating a
    /// number. Mirrors Android's RingNeedsTrackedNight.
    @ViewBuilder
    private func ringNeedsTrackedNight() -> some View {
        VStack(spacing: 3) {
            Text("Calibrating").font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
            Text("needs a tracked night").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.6).fixedSize()
        }
    }

    /// The faint full-circle track with a centred overlay, shown when a score is still calibrating/absent.
    @ViewBuilder
    private func emptyHeroRing<Overlay: View>(diameter: CGFloat, @ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            Circle().stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: diameter * 0.10, lineCap: .round))
            overlay()
        }
        .frame(width: diameter, height: diameter)
    }

    /// The effective Effort strain (NOOP 0–100 axis) the gauge shows. For TODAY this prefers the live
    /// in-progress value computed over the day's HR (midnight→now) in `loadAll`, so the gauge reflects
    /// the accumulating day rather than the last persisted daily row, which only refreshes when the
    /// heavy daily pass runs, so early in the day the stored row is yesterday's Effort or a stale 0.0
    /// (#402). Falls back to the stored `strain` when there isn't yet enough of today's HR to score
    /// (StrainScorer.minReadings). Navigated past days always use the stored row.
    private func effortStrain(_ d: DailyMetric?) -> Double? {
        #if DEBUG
        // DEBUG promo harness: pin Effort (NOOP 0–100 axis) to the active frame's value. This single
        // point feeds the hero ring AND every Effort read-out, so they stay consistent. No-op when no
        // `--demo-hour` frame is active. Charge/Rest are intentionally left at their seeded values.
        if let f = DemoDayHarness.active { return f.effort }
        #endif
        // The never-drop floor and the live/stored preference both live in `StrainScorer.effectiveEffort`
        // (#1001), shared with the Kotlin twin so the two platforms cannot resolve Effort differently.
        // `d` (displayDay) for today is ALWAYS today's row or nil, never a prior day, so the floor cannot
        // resurrect a stale day; it only stops a read-out dropping below what today has already earned.
        return StrainScorer.effectiveEffort(live: selectedDayOffset == 0 ? liveTodayStrain : nil,
                                            stored: d?.strain)
    }

    /// When TODAY's Effort scores a genuine near-zero, there's enough HR to score, but it never
    /// crossed the cardiovascular "effort zone" (~50% of heart-rate reserve), explain the 0 instead
    /// of leaving a bare number that reads as a fault (#482/#480). A low-HR day honestly earns ~0, the
    /// same as a WHOOP low-strain day; the 5/MG just hits it more often (sparser HR, lower daytime
    /// peaks). Only for today, only when the score is ~0 and a score exists (a no-data ring shows its
    /// own overlay, a past day isn't annotated).
    private var effortZeroNote: String? {
        guard selectedDayOffset == 0, let s = effortStrain(displayDay), s < 1.0 else { return nil }
        return String(localized: "No cardio load yet. Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.")
    }

    /// Strain value to feed the Effort gauge, on the SELECTED display scale (#313). The effective
    /// `strain` is on NOOP's 0–100 Effort axis; `UnitFormatter.effortValue` converts it to the
    /// user's chosen scale (0–100 native, or ×21/100 down to WHOOP's 0–21) so the arc + number
    /// match the rest of the app's Effort read-outs. Pairs with `effortGaugeMax` for the "of N".
    private func effortGaugeValue(_ d: DailyMetric?) -> Double? {
        effortStrain(d).map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    /// The Effort gauge's scale maximum, 100 on NOOP's native axis, 21 on the WHOOP axis. Drives
    /// the arc fraction and the gauge's "of N" caption so both follow the toggle (#313).
    private var effortGaugeMax: Double { effortScale == .whoop ? 21 : 100 }

    /// Honest overlay shown over the Charge ring when today's recovery is nil: either the calibrating
    /// count or No data. The carried last-scored Charge case is NOT handled here anymore: chargeRing now
    /// intercepts it and draws a dimmed FILLED ring (so it reads like the Rest ring, not a bare number on
    /// an empty track, #802). This overlay therefore only covers the calibrating and no-data cases.
    @ViewBuilder
    private func ringEmptyOverlay(d: DailyMetric?, diameter: CGFloat) -> some View {
        VStack(spacing: 3) {
            if let n = recoveryCalibration {
                // "Calibrating" is a long word for the ring's interior, it reads as the centre label, with
                // the same lineLimit/scaleFactor guard so it never wraps, then its "N of 4" subtitle below.
                Text("Calibrating").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
                Text("\(n) of \(Baselines.minNightsSeed)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            } else {
                ringNoData(diameter: diameter)
            }
        }
    }

    @ViewBuilder
    private func ringNoData(diameter: CGFloat) -> some View {
        // "No data" reads as the centre label at the same weight family as the ring numbers. lineLimit +
        // fixedSize so a small flanking ring (Rest/Effort) never wraps it mid-word inside the ring's narrow
        // interior (#495/#549).
        Text("No data").font(StrandFont.headline).foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
    }

    // MARK: HEART RATE, today's continuous HR, off the strap's own ~1Hz history.

    /// A full-width 24-hour heart-rate trend, plotted from 5-minute bucket means of the strap's
    /// `hrSample` history (offloaded even while the app was closed, so the day reads continuously).
    /// When there are fewer than two buckets it shows an explicit calibrating/empty card rather than
    /// vanishing , a sparse day used to render NOTHING, which read as a frozen graph (#863). Mirrored on
    /// Android (TodayScreen.kt HeartRateTrendCard).
    @ViewBuilder
    private var heartRateTrendSection: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "\(selectedDayOverline)")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: selectedDayOffset == 0 ? String(localized: "5-minute average · since midnight") : String(localized: "5-minute average · selected day"),
                    trailing: v.last.map { String(localized: "\(Int($0.rounded())) bpm") },
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
                        // #829 - pinch/drag zoom over the loaded day. The bound window narrows the visible
                        // x-domain only (no DB re-read); zoomBounds clamps it to the loaded day and keeps the
                        // points at full resolution while zoomed.
                        zoomDomain: $hrZoomDomain,
                        zoomBounds: hrAxis,
                        valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                        dateFormat: { Self.hrTimeFmt.string(from: $0) }
                    )
                    // #829 follow-up: publish the chart's frame (in the shared day-swipe space) so the
                    // page-level day-swipe can mask itself over the chart, giving the pinch/pan/double-tap
                    // exclusive ownership of touches that start here. Zero-impact reader: a clear
                    // background adds no visual and no intrinsic size, and the frame is content-relative,
                    // so scrolling never re-publishes it (mirrors the HeroRingRowWidthKey pattern).
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: HRChartFrameKey.self,
                                                   value: geo.frame(in: .named(Self.daySwipeSpace)))
                        }
                    )
                } footer: {
                    ChartFooter([
                        ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                        ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                        ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                    ])
                }
                // #829 - pinch/drag hint + Reset, OUTSIDE the card (the card force-fits its chart() closure
                // to chartHeight, so an in-card hint would be squashed; the Deep Timeline places its hint
                // outside the card for the same reason).
                hrZoomHint
            }
        } else {
            // #863: an empty / single-bucket day. A calibrating 4.0 banks HR slowly, so an empty curve early
            // on isn't a fault , say so explicitly instead of leaving a blank where the chart was (which read
            // as the graph freezing). We don't silently swap in another day's curve here; the honest empty
            // state is the parity-matched fix. Mirrors the Android HeartRateTrendCard empty branch.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "\(selectedDayOverline)")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: selectedDayOffset == 0
                        ? String(localized: "Calibrating, no heart rate banked yet today")
                        : String(localized: "No heart rate for this day"),
                    trailing: nil,
                    tint: StrandPalette.metricRose
                ) {
                    Text(selectedDayOffset == 0
                        ? "Your curve fills in as the strap offloads its history."
                        : "Step back to a day the strap was worn.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// #829 - the affordance row under the Today HR chart: teaches pinch/drag, and (once zoomed) shows a
    /// Reset link beside it that mirrors the chart's own double-tap reset. Decorative icon hidden from
    /// VoiceOver; the Reset button stays a real focusable control. Only the wording differs by platform
    /// (macOS has drag-pan + double-tap here, no pinch).
    @ViewBuilder private var hrZoomHint: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: hrZoomDomain == nil
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(StrandFont.footnote.weight(.semibold))
                .accessibilityHidden(true)
            #if os(macOS)
            Text(hrZoomDomain == nil ? "Drag to pan · double-tap to reset" : "Zoomed in · drag to pan")
            #else
            Text(hrZoomDomain == nil ? "Pinch to zoom · drag to pan" : "Zoomed in · drag to pan")
            #endif
            Spacer()
            if hrZoomDomain != nil {
                Button("Reset") { resetHrZoom() }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.top, NoopMetrics.space1 / 2)
    }

    /// Drop the Today HR zoom back to the full day, snapping when Reduce Motion is on (#829).
    private func resetHrZoom() {
        withAnimation(NoopMotion.gated(StrandMotion.interactive, reduced: reduceMotion)) {
            hrZoomDomain = nil
        }
    }

    /// #829 - keep a Today HR zoom window valid as the loaded axis changes across reloads. Pure +
    /// unit-testable so the rule can't drift. nil zoom stays nil. When the day's START moves (a day step =
    /// a genuinely different day), the zoom is dropped (nil) so the new day opens at full scale. When only
    /// the END extended on the SAME day (today's window growing toward `now`), the existing zoom is kept but
    /// re-clamped into the grown bounds preserving its span, so a live refresh never yanks the user out of
    /// their zoom and the window can never sit outside the day. `oldAxis == nil` (first load) keeps the zoom
    /// re-clamped into the new bounds. Reuses `OverviewHRChart.panned(deltaSeconds: 0)` as the pure clamp.
    static func reclampHrZoom(_ zoom: ClosedRange<Date>?,
                              oldAxis: ClosedRange<Date>?,
                              newAxis: ClosedRange<Date>) -> ClosedRange<Date>? {
        guard let zoom else { return nil }
        // A moved start means we stepped to a different day, so open it un-zoomed.
        if let oldAxis, oldAxis.lowerBound != newAxis.lowerBound { return nil }
        // Same day (or first load): re-clamp the kept window into the current bounds, span preserved.
        return OverviewHRChart.panned(zoom, deltaSeconds: 0, bounds: newAxis)
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
        // Use the EFFECTIVE onset so a hand-corrected bedtime shows the same band/duration here as on
        // the Sleep tab (not the detected onset). (#318)
        return .init(
            start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
            end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
            label: hoursMinutes(s.endTs - s.effectiveStartTs)
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
        return .init(date: date, label: String(localized: "\(Int(rec.rounded()))% Charge"),
                     color: StrandPalette.recoveryColor(rec), alignment: .leading)
    }

    /// "Effort" marker pinned to the right edge (latest HR sample). Routed through the SAME formatter
    /// as the Effort tile (`UnitFormatter.effortDisplay`) so it honours the 0–100 / WHOOP-0–21 scale
    /// preference (#268) and reads identically, the stored strain is on the 0–100 axis, so a morning
    /// "21.2" is 21.2-of-100, not WHOOP's near-max 21-of-21.
    private var effortMarker: OverviewHRChart.EdgeMarker? {
        // #1001: the resolved Effort, not the daily row. Reading `displayDay.strain` here put the badge a
        // whole active morning behind the hero ring, which resolves through the same `effortStrain`.
        guard let strain = effortStrain(displayDay), let date = hrPoints.last?.date else { return nil }
        return .init(date: date,
                     label: String(localized: "\(UnitFormatter.effortDisplay(strain, scale: effortScale)) Effort"),
                     color: StrandPalette.effortTint(fraction: strain / StrainScorer.maxStrain), alignment: .trailing)
    }

    // MARK: (b) METRICS, one uniform grid of 104pt StatTiles, every cell filled.

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // The section header keeps its "14-day trend" trailing label; an Edit control sits beside it
            // to open the local layout editor (#251). No new nav destination, a sheet over Today.
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Key Metrics", overline: "\(selectedDayOverline)", trailing: String(localized: "14-day trend"))
                Button {
                    customizationDestination = .keyMetrics
                } label: {
                    Label(String(localized: "Edit").uppercased(), systemImage: "slider.horizontal.3")   // #492/#563: uppercase to match
                        .font(StrandFont.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Edit Key Metrics")
                .help("Choose which Key Metrics show and reorder them")
            }
            // Render the enabled tiles in the saved order; an empty layout still shows the default set.
            // S5: cap the grid to the first `metricsCollapsedCap` tiles behind a "Show all metrics" expander.
            // This collapses OVERFLOW ONLY (the visible tiles stay in the user's saved order), and no
            // pinned/selected tile is dropped or reordered (#251); the rest just fold until the expander.
            LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(visibleKeyMetrics) { metric in
                    // Pin every tile to one height so the grid reads as an even matrix. A LazyVGrid only
                    // offers a cell its own content height, so maxHeight: .infinity never stretched a
                    // shorter tile up to its row-mate: a tile carrying a sparkline (e.g. Rest) sat taller
                    // than a plain-value one and the row looked ragged. A single fixed height fixes that,
                    // and holds up as text scales because it clears the tallest tile layout.
                    keyMetricTile(metric)
                        .frame(maxWidth: .infinity)
                        .frame(height: NoopMetrics.keyMetricTileHeight)
                }
            }
            if metricsHasOverflow {
                metricsExpander
            }
        }
    }

    /// S5: the Key-Metric tiles actually rendered: all of them when expanded, else the first
    /// `metricsCollapsedCap` (overflow folds behind the expander). Order is the user's saved order, sliced
    /// from the front, so a pinned tile is never dropped or reordered (#251); only the tail collapses.
    private var visibleKeyMetrics: [KeyMetric] {
        let all = enabledKeyMetrics
        if metricsExpanded || all.count <= Self.metricsCollapsedCap { return all }
        return Array(all.prefix(Self.metricsCollapsedCap))
    }

    /// True when there are more enabled tiles than the collapsed cap, so the expander is worth showing.
    private var metricsHasOverflow: Bool { enabledKeyMetrics.count > Self.metricsCollapsedCap }

    /// S5: the "Show all metrics" / "Show fewer" expander under the capped grid. Toggles `metricsExpanded`
    /// only; it never changes WHICH tiles are enabled or their order (that stays the #251 editor's job).
    private var metricsExpander: some View {
        let hidden = max(0, enabledKeyMetrics.count - Self.metricsCollapsedCap)
        return Button {
            withAnimation(StrandMotion.interactive) { metricsExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(metricsExpanded ? "Show fewer" : "Show all metrics")
                    .font(StrandFont.footnote)
                if !metricsExpanded {
                    Text("\(hidden)")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Image(systemName: metricsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(StrandPalette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metricsExpanded ? "Show fewer metrics" : "Show all metrics, \(hidden) more")
    }

    /// A carried recovery-vital tile's (value, caption): today's own value wins (with the metric's
    /// static unit caption); otherwise, when we're carrying the last scored day (#543), the PRIOR row's
    /// value with a "Last night · <date>" caption so the whole recovery side stays consistent rather than
    /// blanking to ", " at the rollover. A metric the carried row genuinely lacks (e.g. SpO₂ on a BLE-only
    /// night) still falls through to ", " with its unit caption, we never fabricate the new day's value.
    /// `format` renders the stored Double; `today`/`prior` pull the metric off a row (Int metrics map up).
    private func carriedVital(
        unit: String,
        today: Double?,
        prior: (DailyMetric) -> Double?,
        perField: DailyMetric? = nil,
        format: (Double) -> String
    ) -> (value: String, caption: String?) {
        if let v = today { return (format(v), unit) }
        if let p = lastScoredRecoveryDay, let v = prior(p) {
            return (format(v), carriedCaption(p))
        }
        // PER-FIELD carry: the whole-row carry above (`lastScoredRecoveryDay`) can land on a row whose field
        // is nil (the engine writes spo2Pct = nil on computed "-noop" rows), so fall through to the freshest
        // strictly-prior row that HAS this field, stamped with its OWN carried date. Tried after the whole-row
        // carry so a genuine last-scored-night reading keeps its caption. Mirrors the Android per-field carry.
        if let pf = perField, let v = prior(pf) {
            return (format(v), carriedCaption(pf))
        }
        // H10, an empty vital on TODAY reads honestly ("After tonight's sleep") instead of a lone unit
        // beside a bare ", ", which looked like a fault; a navigated PAST day keeps the plain unit (it's
        // genuinely missing data the user can't act on now). Pure copy via `emptyVitalCaption`.
        if let honest = Self.emptyVitalCaption(unit: unit, isToday: selectedDayOffset == 0) {
            return ("—", honest)
        }
        return ("—", unit)
    }

    /// One Key-Metric tile, keyed so the grid can be filtered + reordered per the saved layout (#251).
    /// Each case is byte-for-byte the tile that used to be hard-coded in the grid, the refactor only
    /// changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    @ViewBuilder
    private func keyMetricTile(_ metric: KeyMetric) -> some View {
        let d = displayDay
        let aLatest = appleDays.last
        switch metric {
        case .charge:
            // Order of precedence: today's own scored recovery → mid-calibration "N of 4" → the last
            // scored day carried over ("Last night · <date>", #543) so a post-rollover today that
            // isn't scored yet keeps a real Charge instead of a bare "No Data" while live HR ticks →
            // ", " only when there is genuinely nothing banked anywhere. The carry-over shows the PRIOR
            // value labelled as prior, it never fabricates a number for the new day.
            let carried = lastScoredCharge
            StatTile(
                label: "Charge",
                value: d?.recovery.map { "\(Int($0.rounded()))%" }
                    ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" }
                    ?? carried.map { "\(Int($0.value.rounded()))%" } ?? "—",
                // Component 2: never a bare blank, when there's no number, no calibration count and
                // nothing to carry, the caption states the honest "Needs the strap" rather than nothing.
                caption: d?.recovery.map { StrandPalette.recoveryState($0).capitalized }
                    ?? recoveryCalibration.map { _ in String(localized: "Calibrating") }
                    ?? carried.map { $0.caption }
                    ?? Self.needsStrapCaption,
                accent: d?.recovery.map { StrandPalette.recoveryColor($0) }
                    ?? carried.map { StrandPalette.recoveryColor($0.value) } ?? StrandPalette.textPrimary,
                sparkline: sparks["recovery"],
                sparkColor: StrandPalette.accent
            )
        case .effort:
            // Unscored TODAY → a short "building" hint instead of the "of N" axis caption, so a
            // fresh user reads "coming" not "broken" (#527); a scored day keeps "of N".
            // #1001: resolve through `effortStrain` so this tile shows the hero ring's figure. Reading
            // `d.strain` straight off the daily row left it behind by the whole morning on an active day.
            let effort = effortStrain(d)
            StatTile(
                label: "Effort",
                value: effort.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                caption: effort != nil ? String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")
                                       : (buildingHint(.effort) ?? String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")),
                accent: effort.map { StrandPalette.effortTint(fraction: $0 / StrainScorer.maxStrain) } ?? StrandPalette.textPrimary,
                sparkline: sparks["strain"],
                sparkColor: StrandPalette.strain066,
                // Inline ⓘ in the tile header (not a corner overlay) so it never sits over the value (#495).
                accessory: { scoreInfoButton(.effort) }
            )
        case .rest:
            // Unscored TODAY → "building, wear it tonight" instead of a lone ", " caption (#527);
            // a scored day keeps its sleep-duration / efficiency caption.
            StatTile(
                label: "Rest",
                value: restScore.map { "\(Int($0.rounded()))%" } ?? "—",
                // Component 2: a scored day shows its duration/efficiency caption; an unscored TODAY shows
                // the "building" hint; a past day with no Rest falls to the honest "Needs the strap" rather
                // than a bare blank, so the tile always carries a state.
                caption: restScore != nil ? restCaption(d)
                    : (buildingHint(.rest) ?? restCaption(d) ?? Self.needsStrapCaption),
                accent: restScore.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                // The Rest composite (0–100) trend, not raw sleep minutes, tracks the score above (#614).
                sparkline: sparks["sleep_performance"],
                sparkColor: StrandPalette.metricPurple,
                // Inline ⓘ in the tile header (not a corner overlay) so it never sits over the value (#495).
                accessory: { scoreInfoButton(.rest) }
            )
        case .hrv:
            // Carry the last scored night's HRV at the rollover (#543), today's wins, the carried value
            // is stamped "Last night · <date>", and a never-scored metric still shows ", ".
            let hrv = carriedVital(unit: "ms", today: d?.avgHrv,
                                   prior: { $0.avgHrv }, format: { "\(Int($0.rounded()))" })
            StatTile(
                label: "HRV",
                value: hrv.value,
                caption: hrv.caption,
                accent: hrv.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricPurple,
                sparkline: sparks["hrv"],
                sparkColor: StrandPalette.metricPurple
            )
        case .restingHr:
            let rhr = carriedVital(unit: "bpm", today: d?.restingHr.map(Double.init),
                                   prior: { $0.restingHr.map(Double.init) }, format: { "\(Int($0.rounded()))" })
            StatTile(
                label: "Resting HR",
                value: rhr.value,
                caption: rhr.caption,
                accent: rhr.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricRose,
                sparkline: sparks["rhr"],
                sparkColor: StrandPalette.metricRose
            )
        case .bloodOxygen:
            // PER-FIELD carry (perField: lastSpo2Day): the whole-row `lastScoredRecoveryDay` carry lands on a
            // row whose spo2Pct is nil (computed rows never bank a percentage), so the tile falls through to
            // the last row that actually has a reading. Mirrors the Android Blood Oxygen tile's spo2CarryDay.
            let spo2 = carriedVital(unit: "SpO₂", today: d?.spo2Pct,
                                    prior: { $0.spo2Pct }, perField: lastSpo2Day,
                                    format: { String(format: "%.0f%%", $0) })
            // #103: SpO₂ candidate @82 fallback. When spo2Pct is nil (WHOOP 5/MG BLE-only, no import) AND
            // the experimental toggle is ON, surface the strap's own @82 nightly mean as a "strap estimate
            // (unverified)" so the tile shows a number instead of "—". The candidate has split cross-device
            // evidence (corr +0.99 on 8 nights, but 2 nights moved opposite on the original device), so it
            // ships behind a default-off toggle and is never written to `spo2Pct` (CLAUDE.md derived-
            // biosignal rule). The sparkline switches to the candidate trend when the fallback is active.
            // When the toggle is ON but NO candidate data exists (empty @82 stream, WHOOP 4.0, or the
            // engine hasn't re-scored yet), show "toggle ON · no @82 data" so the user can tell the
            // difference between "toggle off" and "toggle on but no data" — a silent blank reads as broken.
            let spo2CandidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let candidateTail = spo2CandidateOn ? sparks["spo2_candidate"]?.last : nil
            let spo2Value = spo2.value == "—" && candidateTail != nil
                ? String(format: "%.0f%%", candidateTail!)
                : spo2.value
            let spo2Caption: String = spo2.value == "—" && candidateTail != nil
                ? String(localized: "strap estimate (unverified)")
                : (spo2.value == "—" && spo2CandidateOn
                   ? String(localized: "toggle ON · no @82 data")
                   : (spo2.caption ?? ""))
            StatTile(
                label: "Blood Oxygen",
                value: spo2Value,
                caption: spo2Caption,
                accent: spo2Value == "—" ? StrandPalette.textPrimary : StrandPalette.metricCyan,
                sparkline: spo2.value == "—" && candidateTail != nil ? sparks["spo2_candidate"] : sparks["spo2"],
                sparkColor: StrandPalette.metricCyan
            )
        case .respiratory:
            // Respiratory keeps its sparkline-tail fallback for a NON-carrying today (a sparse-but-recent
            // value still reads); when carrying, the prior scored night's respiratory is shown + stamped.
            let respCarry = carriedVital(unit: "rpm", today: d?.respRateBpm,
                                         prior: { $0.respRateBpm }, format: { String(format: "%.1f", $0) })
            let respValue = respCarry.value == "—" && lastScoredRecoveryDay == nil
                ? latestString("resp_rate", decimals: 1) : respCarry.value
            StatTile(
                label: "Respiratory",
                value: respValue,
                // When the sparkline-tail fallback surfaces a real value (respValue ≠ ", " while respCarry
                // was empty), use the plain "rpm" caption, not carriedVital's empty "After tonight's sleep"
                // state, so the caption matches the shown number (H10 mustn't mislabel a real value).
                caption: (respValue != "—" && respCarry.value == "—") ? "rpm" : respCarry.caption,
                accent: respValue == "—" ? StrandPalette.textPrimary : StrandPalette.accent,
                sparkline: sparks["resp_rate"],
                sparkColor: StrandPalette.accent
            )
        case .steps:
            // Prefer a REAL step count: the strap's own @57 counter (DailyMetric.steps, WHOOP 5/MG),
            // then Apple Health FOR THE SELECTED DAY (#589, when the user imported phone steps for this
            // day, show THAT number directly, not the strap estimate), then the loaded Apple-Health steps
            // sparkline tail as a last-resort recent value. Only when a day has NONE of those real sources
            // do we fall back to the on-device ESTIMATE (steps_est) a WHOOP 4.0 user gets, flagged "est."
            // so it's never mistaken for a measured count. Mirrors Android (#276/#150).
            // #843/#813, a day shows a REAL count only from the strap (@57) or a SAME-DAY phone import.
            // Never the latest imported Apple-Health row (it can be days stale) or the sparkline tail (that
            // is the most-recent value, not this day's): both froze the tile on an old import. Otherwise
            // fall through to the on-device estimate ("est."). Mirrors Android stepsForDay (#276/#150).
            let appleStepsForDay = appleDays.last(where: { $0.day == selectedDayKey })?.steps
            let realSteps: String? = (d?.steps).map { intString(Double($0)) }
                ?? appleStepsForDay.map { intString(Double($0)) }
            let estSteps = stepsEstByDay[selectedDayKey]
            // H6, only an ESTIMATED day (no real strap/phone count, so the on-device estimate filled in)
            // gets the calibration entry; a real measured count needs no calibration.
            let isEstimated = realSteps == nil && estSteps != nil
            // #589, when the tile would be BLANK on a strap that estimates steps (WHOOP 4.0: the steps
            // pipeline has run, so there's calibration state recorded) explain WHY rather than a bare ", ",
            // and still expose the ⚙︎ so the user can reach the sheet to set a manual coefficient.
            let needsCalibration = realSteps == nil && estSteps == nil && stepsPipelineActive
            StatTile(
                label: "Steps",
                value: realSteps ?? estSteps.map { intString(Double($0)) } ?? "—",
                // An estimated day reads "est." plus the calibration STATUS (k / days / confidence) so a
                // frozen-looking estimate self-explains (#760/#792); a not-yet-calibrated day says how many
                // more phone-counted days are needed (so a blank tile is never silently unexplained, #589).
                caption: realSteps != nil ? String(localized: "today")
                    : (estSteps != nil ? stepsEstimateCaption
                       : (needsCalibration ? stepsCalibrationCaption : String(localized: "today"))),
                accent: (realSteps != nil || estSteps != nil) ? StrandPalette.metricCyan : StrandPalette.textPrimary,
                sparkline: sparks["steps"],
                sparkColor: StrandPalette.metricCyan,
                // H6, an estimated (or awaiting-calibration) steps tile carries a small ⚙︎ that opens the
                // steps-calibration sheet (the SAME one Settings hosts), so a WHOOP 4.0 user can tune or
                // hand-set the estimate from here even before enough auto-fit days exist (#589).
                // #316, a day with a REAL measured count (not an estimate) and a known @63 activity class
                // instead shows a small still/walk/run glyph, so the tile quietly says what the wrist was
                // doing. The two are mutually exclusive (the gear is only for estimated/blank days), so they
                // never collide in the single accessory slot.
                accessory: {
                    if isEstimated || needsCalibration {
                        stepsCalibrationButton
                    } else if realSteps != nil, let cls = stepActivityClassToday {
                        stepActivityIcon(cls)
                    }
                }
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
                caption: String(localized: "active"),
                accent: StrandPalette.metricAmber,
                sparkline: sparks["active_kcal"],
                sparkColor: StrandPalette.metricAmber
            )
        }
    }

    // MARK: (c) LAST WORKOUTS, SAME grid, uniform 104pt workout tiles.

    @ViewBuilder
    private var workoutsSection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Latest Workouts", overline: "Activity",
                              trailing: String(localized: "\(workouts.count) total"))
                LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StatTile(
                            label: "\(WorkoutSource.displaySport(w.sport))",
                            value: workoutDuration(w),
                            caption: workoutCaption(w),
                            accent: StrandPalette.effortTint(fraction: (w.strain ?? 0) / StrainScorer.maxStrain),
                            delta: w.energyKcal.map { "\(Int($0.rounded())) kcal" },
                            deltaColor: StrandPalette.metricAmber
                        )
                    }
                }
            }
        }
    }

    // MARK: (d) DATA SOURCES, one full-width footer card.

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data Sources", overline: "Provenance")
            // S5: collapsed to a single "Synced from: …" summary line by default; tapping expands the full
            // per-source rows + strap battery/sync inline. Nothing is removed, the detail is one tap away.
            if sourcesExpanded {
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        // A header row to collapse it back, so the expanded card has an obvious "less" cue.
                        Button {
                            withAnimation(StrandMotion.interactive) { sourcesExpanded = false }
                        } label: {
                            HStack {
                                Text("Synced from").strandOverline()
                                Spacer()
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide data source detail")
                        Divider().overlay(StrandPalette.hairline)
                        sourceRow(
                            badge: "Whoop",
                            tint: StrandPalette.accent,
                            present: !repo.days.isEmpty,
                            detail: String(localized: "\(repo.days.count) days · \(repo.sleeps.count) sleeps")
                        )
                        Divider().overlay(StrandPalette.hairline)
                        sourceRow(
                            badge: "Apple Health",
                            tint: StrandPalette.metricCyan,
                            present: !appleDays.isEmpty,
                            detail: String(localized: "\(appleDays.count) days · \(workouts.filter { WorkoutSource.isAppleHealth($0.source) }.count) workouts")
                        )
                        if xiaomiDays > 0 {
                            Divider().overlay(StrandPalette.hairline)
                            sourceRow(
                                badge: "Mi Band",
                                tint: StrandPalette.metricAmber,
                                present: true,
                                detail: String(localized: "\(xiaomiDays) days · \(xiaomiSleeps) sleeps")
                            )
                        }
                        strapBatteryRow
                        Divider().overlay(StrandPalette.hairline)
                        strapSyncRow
                    }
                }
            } else {
                sourcesSummaryRow
            }
        }
    }

    /// S5: the collapsed Data Sources footer: a single "Synced from: WHOOP, Apple Watch >" line that taps
    /// to expand the full per-source rows. Lists only the sources that actually have data (so a strap-only
    /// user doesn't read "Apple Health"), and falls back to an honest "No sources yet" when nothing's banked.
    private var sourcesSummaryRow: some View {
        Button {
            withAnimation(StrandMotion.interactive) { sourcesExpanded = true }
        } label: {
            NoopCard {
                HStack(spacing: 8) {
                    Text(Self.syncedFromSummary(
                        hasWhoop: !repo.days.isEmpty,
                        hasApple: !appleDays.isEmpty,
                        hasXiaomi: xiaomiDays > 0))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Data sources")
        .accessibilityHint("Show what NOOP is synced from")
    }

    /// PURE: the "Synced from: …" summary string for the collapsed footer (S5). Names the sources with
    /// data using the audience-facing words ("WHOOP", "Apple Watch" for Apple Health, "Mi Band"); "No
    /// sources yet" when nothing is banked. Unit-testable so the collapsed copy can't drift. The expanded
    /// card still uses the existing per-source rows, so the Apple-Health provenance footer is unchanged.
    static func syncedFromSummary(hasWhoop: Bool, hasApple: Bool, hasXiaomi: Bool) -> String {
        var names: [String] = []
        if hasWhoop { names.append("WHOOP") }
        if hasApple { names.append("Apple Watch") }
        if hasXiaomi { names.append("Mi Band") }
        guard !names.isEmpty else { return String(localized: "No sources yet") }
        return String(localized: "Synced from: \(names.joined(separator: ", "))")
    }

    @ViewBuilder
    private func sourceRow(badge: String, tint: Color, present: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            SourceBadge("\(badge)", tint: present ? tint : StrandPalette.textTertiary)
            Spacer()
            Text(present ? detail : String(localized: "Not connected"))
                .font(StrandFont.captionNumber)
                .foregroundStyle(present ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        }
    }

    /// Honest strap-sync outcome, the live-observing subview (StrapSyncRow) renders it. Kept as a
    /// property so `sourcesSection`'s call site is unchanged; the subview owns the `LiveState` observation
    /// so a 1 Hz HR tick refreshes only this row, not the whole dashboard (scroll-stutter fix).
    private var strapSyncRow: some View { StrapSyncRow() }

    /// Strap battery on the dashboard (#159), the live-observing subview (StrapBatteryRow) renders it,
    /// including its own leading divider when shown. Property wrapper keeps the call site unchanged.
    private var strapBatteryRow: some View { StrapBatteryRow() }

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
        .accessibilityLabel("How \(section.displayName) is calculated")
        .help("How this score is calculated")
    }

    /// H6, the small ⚙︎ on an ESTIMATED Steps tile that opens the steps-calibration sheet. A WHOOP 4.0
    /// strap doesn't transmit steps, so NOOP estimates them from motion calibrated to the phone's count;
    /// this puts the "tune that estimate" entry right where the user reads the "est." caption.
    private var stepsCalibrationButton: some View {
        Button {
            showStepsCalibration = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calibrate steps estimate")
        .help("Calibrate the steps estimate")
    }

    /// #316 / @63, the small still/walk/run glyph on a REAL (measured) Steps tile. Maps the decoded
    /// activity-class enum (0=still, 1=walk, 2=run) to an SF Symbol, tinted with the tile's own metric
    /// colour so it reads as part of the tile rather than an alert. Mirrors the Android DirectionsWalk/Run
    /// + AccessibilityNew icon set + semantics exactly (cross-platform parity). Subtle and optional-feeling:
    /// a day with no known class shows nothing (the caller only invokes this for a non-nil 0/1/2).
    private func stepActivityIcon(_ activityClass: Int) -> some View {
        let symbol: String
        let label: String
        switch activityClass {
        case 1:  symbol = "figure.walk"; label = String(localized: "Walking")
        case 2:  symbol = "figure.run";  label = String(localized: "Running")
        default: symbol = "figure.stand"; label = String(localized: "Still")   // 0 = still
        }
        return Image(systemName: symbol)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(StrandPalette.metricCyan)
            .accessibilityLabel(label)
            .help(label)
    }

    /// #589, true once the WHOOP-4.0 steps-ESTIMATE pipeline has run for this user, i.e. the
    /// IntelligenceEngine has mirrored some calibration state into the profile (a fitted/manual
    /// coefficient, OR a recorded count of overlapping phone-counted days while still gathering).
    /// Gates the "needs calibration" affordance so a user whose strap reports real steps (5/MG) or who
    /// has no strap at all never sees a steps-calibration prompt on a blank tile.
    private var stepsPipelineActive: Bool {
        profile.stepsCalibrationCoefficient > 0
            || profile.stepsManualCoefficient > 0
            || profile.stepsCalibrationSampleDays > 0
    }

    /// #589, the honest one-liner for a blank, not-yet-calibrated Steps tile: how many more days the
    /// phone also has to count steps before an estimate appears. Built from the SAME engine descriptor
    /// Settings uses (`StepsEstimateEngine.CalibrationStatus`) so the wording matches across surfaces.
    private var stepsCalibrationCaption: String {
        let status = StepsEstimateEngine.CalibrationStatus.needsMoreDays(
            have: profile.stepsCalibrationSampleDays,
            need: StepsEstimateEngine.minCalibrationDays)
        return status.headline
    }

    /// #760/#792: the caption under an ESTIMATED Steps tile: "est. · <status detail>", where the detail is
    /// the engine's own STATUS line (manual k, or k=… from N days + confidence tier) built from the SAME
    /// persisted calibration the estimate used. So a WHOOP 4.0 user can see WHY the number reads as it does
    /// (and why it may look frozen at low confidence) right where they notice the "est." flag, matching
    /// Android. Falls back to a bare "est." if no coefficient is recorded yet.
    private var stepsEstimateCaption: String {
        let status: StepsEstimateEngine.CalibrationStatus = profile.stepsCalibrationManual
            ? .manual(coefficient: profile.stepsCalibrationCoefficient,
                      sampleDays: profile.stepsCalibrationSampleDays)
            : .calibrated(coefficient: profile.stepsCalibrationCoefficient,
                          sampleDays: profile.stepsCalibrationSampleDays,
                          confidence: profile.stepsCalibrationConfidence)
        guard profile.stepsCalibrationCoefficient > 0 else { return String(localized: "est.") }
        return String(localized: "est. · \(status.detail)")
    }

    // MARK: - Loading

    /// #755: the dashboard load is split into a DAY-SCOPED set (the selected day's HR window, Rest score,
    /// sleep band, live Effort, provenance, axis, everything that must re-resolve when the user chevrons
    /// to another day) and a HISTORY-WIDE set (the 10 sparklines, workouts, the cross-source bundles, the
    /// "your cards" series, all independent of which day is selected). The day-scoped reads are a handful
    /// of queries and ALWAYS run, so a day-switch or a tab-return repaints the screen immediately. The
    /// history-wide reads are the bulk (~40 reads) and are DEFERRED while a multi-chunk backfill is actively
    /// writing to the single-connection store (`live.backfilling`), because running them then both stutters
    /// the screen and contends with the bulk writes. They are never permanently skipped: the coalesced
    /// trailing refresh after the backfill quiesces (AppModel's debounced `lastSyncedAt` sink) bumps
    /// `refreshSeq`, which re-fires this task with `live.backfilling` false, and the deferred set runs then.
    /// Values + provenance are byte-identical to the old single-pass `loadAll` whenever each part runs.
    private func loadAll() async {
        // Always refresh the selected day (cheap, and it's what a day-switch / return-to-tab needs). Since
        // #860 retired the launch auto-land, this pass no longer changes `selectedDayOffset`, so there's no
        // re-fire to bail for: the history-wide set + the new-day announce run straight through below.
        await loadDayScoped()
        // #today-hosted-cards: refresh the shared SleepModel for the hosted sleep cards. Runs on EVERY load
        // (before the cache-restore short-circuit below), so the card survives a tab-away/return; the gate
        // inside makes it a no-op unless a sleep card is actually hosted.
        await loadHostedSleepModel()
        // #849: a bare Today RE-MOUNT (tab-away + return, or an Apple-Health import that recreates the view)
        // re-fires this task with TodayView's `@State` reset, so the heavy history-wide pass re-ran in full
        // every time even when NOTHING in the data had changed: hundreds of redundant reads (incl. the
        // per-day raw-HR queries) that lag the screen on return. Guard on `refreshSeq`, which only advances
        // when a refresh() actually published new data: if we already loaded the history-wide set for the
        // CURRENT seq, the data on screen is correct and we skip the reload. The marker lives on the
        // long-lived `repo` (not @State), so it survives the re-mount that resets `loadedHistoryWideOnce`.
        // The day-scoped reads above ALWAYS run, so a day-switch / return still repaints instantly.
        let currentSeq = repo.refreshSeq
        // #849 no-op guard: have we ALREADY run the history-wide pass for this exact data state? If so the
        // dashboard data is unchanged, so a bare re-mount must NOT re-run the ~40 reads + per-workout strap-HR
        // pass. A TabView/module switch (and the post-import re-mount) tears down TodayView's `@State`, so we
        // RESTORE the history-wide outputs from the cache on `repo` (a handful of in-memory assignments)
        // rather than re-querying, otherwise the dashboard would flash empty. This wins over the
        // first-load-this-mount path below, which would otherwise treat the re-mount as a cold launch and
        // reload identical data. If the cache is somehow absent (defensive), fall through and reload.
        if repo.todayHistoryWideLoadedSeq == currentSeq, let cached = repo.todayHistoryWideCache {
            restoreHistoryWide(cached)
            // #989: hydration is excluded from the snapshot (a drink logged since would be stale), so a
            // restore re-reads it live, one cheap row.
            await reloadHydration()
            loadedHistoryWideOnce = true
            announceNewDaysIfNeeded()
            return
        }
        // Defer the heavy history-wide reads ONLY on a re-load while a backfill is actively writing, so they
        // don't contend with the offload's bulk writes on the single-connection store. But ALWAYS run them on
        // the FIRST load (even mid-offload): otherwise a cold launch during a sync would show a blank
        // dashboard (no sparklines / workouts / your-cards) until the offload ends (#755). Loading on the
        // first pass also makes the mount-during-sync flag race harmless: with no data yet we load regardless
        // of the flag. The deferred set is guaranteed to run later via the coalesced refresh (see .task note).
        if !backfillActivelyWriting || !loadedHistoryWideOnce {
            await loadHistoryWide()
            loadedHistoryWideOnce = true
            // Record the seq we just loaded so a later re-mount with unchanged data short-circuits above.
            repo.todayHistoryWideLoadedSeq = currentSeq
        }
        announceNewDaysIfNeeded()
    }

    /// #today-hosted-cards: build the shared SleepModel backing the hosted sleep cards, ONLY when a
    /// sleep-origin card is actually hosted (else Today pays no extra cost). Loads the inputs the SAME way
    /// SleepView does (`allSleepSessions` / `habitualMidsleepSec` / `sessionMotions`) and hands them to the
    /// SAME pure `SleepModel.build`, so a hosted card's numbers match the Sleep tab. Twin of the
    /// LiquidTodayView hostedSleepModel build.
    private func loadHostedSleepModel() async {
        let sleepOrigin = String(localized: "Sleep")
        guard HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(where: { $0.origin == sleepOrigin }) else {
            hostedSleepModel = nil
            return
        }
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
    }

    /// True while the strap is mid history-offload, the SAME signal the "Syncing strap history…" note
    /// reads (`LiveState.backfilling`, set across BLEManager.startBackfilling/exitBackfilling). Used to
    /// defer the bulk history-wide reads so they don't contend with the offload's bulk writes (#755).
    private var backfillActivelyWriting: Bool { liveBackfillingFlag }

    /// 14-day sparklines + the cross-source bundles + the "your cards" series + workouts, everything that
    /// does NOT depend on `selectedDayOffset`. The bulk of the dashboard's reads; deferred during an active
    /// backfill (see `loadAll`). Same reads, same derivations, same assignment order as before.
    private func loadHistoryWide() async {
        // 14-day sparklines, Whoop + Apple Health. These reads are mutually independent (distinct
        // metric keys/sources), so kick them all off concurrently with `async let` and await the
        // results below. Each hits the @MainActor Repository, fires its `await store.*` on the
        // WhoopStore actor and suspends, releasing the main actor so the next read can start,         // instead of fully round-tripping one at a time. The assignments below stay on the main
        // actor and the final values are byte-identical to the sequential version.
        async let recoverySpark      = sparkValues("recovery", source: "my-whoop", window: 14)
        async let strainSpark        = sparkValues("strain", source: "my-whoop", window: 14)
        async let sleepTotalSpark    = sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        async let hrvSpark           = sparkValues("hrv", source: "my-whoop", window: 14)
        async let rhrSpark           = sparkValues("rhr", source: "my-whoop", window: 14)
        async let spo2Spark          = sparkValues("spo2", source: "my-whoop", window: 14)
        // #103: SpO₂ candidate @82 nightly mean (WHOOP 5/MG only). Read via `exploreSeries` so the
        // computed "-noop" metricSeries backs the trend. Empty when the toggle is OFF (the engine
        // writes nothing) or on a WHOOP 4.0 (no v18 aux stream). Used as a fallback for the Blood
        // Oxygen tile when `spo2Pct` is nil, labelled "strap estimate (unverified)".
        async let spo2CandidateSpark = sparkValuesExplore("spo2_candidate", source: "my-whoop", window: 14)
        // `resp_rate` via `exploreSeries` so a BLE-only WHOOP 5 user's on-device computed
        // `DailyMetric.respRateBpm` backs the trend (the engine writes the column, not a metricSeries
        // point). The old `series(… source: "apple-health")` read only Apple Health's metricSeries,
        // which is empty without a Health import — parity bug vs Android's `DailyMetric.respRateBpm`
        // trend. "my-whoop" covers imported WHOOP CSV (Layer 1) + computed DailyMetric (Layer 3).
        async let respRateSpark      = sparkValuesExplore("resp_rate", source: "my-whoop", window: 14)
        async let stepsAppleSpark    = sparkValues("steps", source: "apple-health", window: 14)
        async let weightSpark        = sparkValues("weight", source: "apple-health", window: 90)
        async let activeKcalSpark    = sparkValues("active_kcal", source: "apple-health", window: 14)

        sparks["recovery"]        = await recoverySpark
        sparks["strain"]          = await strainSpark
        sparks["sleep_total_min"] = await sleepTotalSpark
        sparks["hrv"]             = await hrvSpark
        sparks["rhr"]             = await rhrSpark
        sparks["spo2"]            = await spo2Spark
        sparks["spo2_candidate"]  = await spo2CandidateSpark
        sparks["resp_rate"]   = await respRateSpark
        sparks["steps"]       = await stepsAppleSpark
        // Steps prefer the strap's own @57 daily total (no metricSeries, it lives on the daily row),
        // so a strap-only WHOOP 5/MG user gets a steps trend without Apple Health. Falls back to the
        // Apple Health series above when the strap supplied no steps (#276). This synchronous overwrite
        // must run AFTER sparks["steps"] is assigned from the Apple-Health read above (unchanged order).
        let strapSteps = repo.days.suffix(14).compactMap { $0.steps.map(Double.init) }
        if !strapSteps.isEmpty { sparks["steps"] = strapSteps }
        sparks["weight"]      = await weightSpark
        sparks["active_kcal"] = await activeKcalSpark

        // Steps ESTIMATE per day (WHOOP 4.0 motion → calibrated steps), the Mi-Band series, workout +
        // Apple-daily rows, and the three "your cards" series, all history-wide (none depends on the
        // selected day) and mutually independent (distinct keys/sources). Fire them concurrently with
        // `async let`, then await each where its result is first used, same data, same derivations, same
        // assignment order as before. (The Rest score + provenance resolves moved to loadDayScoped, #755.)
        async let stepsEstSeriesA    = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let workoutsA          = repo.workoutRows()
        async let appleDaysA         = repo.appleDailyRows()
        async let xStepsA            = repo.series(key: "steps", source: "xiaomi-band")
        async let xSleepA            = repo.series(key: "sleep_total_min", source: "xiaomi-band")
        // #753: the pinned Stress card must read its number the SAME way StressView (the detail page) does,
        // not off the merged stress series' last row. StressView builds `StressModel(days: repo.days,
        // stored:)` and shows `model.score`, which PREFERS today's stored stress row but otherwise DERIVES
        // today's score from the live `repo.days` RHR/HRV baseline. The old pinned read
        // (`exploreSeries("stress").last`) returned the latest *banked* day instead, so when today had no
        // stored stress row yet the pinned card sat on yesterday's number (e.g. "2") while the detail page
        // moved to today's freshly-derived value. They diverged because they computed from different sources
        // AND the pinned card never re-derived. Reading the SAME `repo.series` the detail uses, and building
        // the SAME StressModel below, ties the pinned card to today's score; both then refresh on the shared
        // `repo.refreshSeq` task key (loadAll's TodayLoadKey) and stay in sync.
        async let stressStoredA      = repo.series(key: "stress", source: "my-whoop")
        async let fitnessAgeSeriesA  = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitalitySeriesA    = repo.exploreSeries(key: "vitality", source: "my-whoop")

        // Steps ESTIMATE per day (WHOOP 4.0 motion → calibrated steps). exploreSeries reads the computed
        // "-noop" metricSeries the IntelligenceEngine writes, exactly like the Explore "steps_est" metric.
        // Only consulted when a day has no REAL step count (see the .steps tile), so it never overrides a
        // measured value, it just fills the gap a 4.0 user would otherwise see as ", ".
        let stepsEstSeries = await stepsEstSeriesA
        stepsEstByDay = Dictionary(stepsEstSeries.map { ($0.day, Int($0.value.rounded())) },
                                   uniquingKeysWith: { _, last in last })

        workouts = await workoutsA
        appleDays = await appleDaysA
        // Mi Band (Mi Fitness import), distinct days across its representative metric keys.
        let xSteps = await xStepsA
        let xSleep = await xSleepA
        xiaomiDays = Set(xSteps.map(\.day) + xSleep.map(\.day)).count
        // Your cards (#582 / Design Reset): Stress / Fitness age / Vitality for the pinned home cards.
        // #753: Stress mirrors StressView. `StressModel(days:stored:).score` is TODAY's score (stored row
        // preferred, else derived off the live RHR/HRV baseline), so the pinned card never lags the detail
        // page on a day with no banked stress row. nil (no usable signal) keeps the honest "Calibrating"
        // placeholder, matching StressView's empty state. Fitness age / Vitality keep their merged reads.
        stressToday = StressModel(days: repo.days, stored: await stressStoredA)?.score
        fitnessAgeToday = (await fitnessAgeSeriesA).last?.value
        vitalityToday = (await vitalitySeriesA).last?.value
        // Hydration card (opt-in): today's stored total + the sex/Effort goal. Only loaded when the
        // feature is on, so a disabled feature does zero work and the card stays hidden.
        await reloadHydration()
        if let store = await repo.storeHandle() {
            let farFuture = Int(Date.distantFuture.timeIntervalSince1970)
            xiaomiSleeps = ((try? await store.sleepSessions(deviceId: "xiaomi-band", from: 0, to: farFuture, limit: 4000))?.count) ?? 0
        }
        // #849: snapshot everything just computed onto the long-lived `repo`, keyed by the seq we loaded for,
        // so a later re-mount with unchanged data restores it in-memory instead of re-running this pass.
        // Note the Rest-tile spark (`sparks["sleep_performance"]`) is written by loadDayScoped, which always
        // runs after a restore, so it is intentionally NOT part of this history-wide snapshot.
        // Exclude the day-scoped Rest-tile spark from the snapshot: loadDayScoped owns it and rewrites it for
        // the selected day on every pass, so caching it here (then merging it back on a same-seq day-switch)
        // would clobber the new day's value with a stale one. Every other spark key is history-wide.
        var historyWideSparks = sparks
        historyWideSparks["sleep_performance"] = nil
        repo.todayHistoryWideCache = TodayHistoryWideCache(
            sparks: historyWideSparks,
            stepsEstByDay: stepsEstByDay,
            workouts: workouts,
            appleDays: appleDays,
            xiaomiDays: xiaomiDays,
            xiaomiSleeps: xiaomiSleeps,
            stressToday: stressToday,
            fitnessAgeToday: fitnessAgeToday,
            vitalityToday: vitalityToday
        )
    }

    /// #849: restore the history-wide outputs from a same-seq cache on a re-mount, so the dashboard repaints
    /// from memory without re-running the heavy reload (which is the lag returning to Today after an import).
    /// `sparks` is MERGED, not replaced: loadDayScoped writes `sparks["sleep_performance"]` (the Rest-tile
    /// spark) and runs before this in the same pass, so overwriting the whole dict would drop that day-scoped
    /// entry. Every other history-wide spark key is restored.
    private func restoreHistoryWide(_ c: TodayHistoryWideCache) {
        sparks.merge(c.sparks) { _, cached in cached }
        stepsEstByDay = c.stepsEstByDay
        workouts = c.workouts
        appleDays = c.appleDays
        xiaomiDays = c.xiaomiDays
        xiaomiSleeps = c.xiaomiSleeps
        stressToday = c.stressToday
        fitnessAgeToday = c.fitnessAgeToday
        vitalityToday = c.vitalityToday
        // Hydration is deliberately NOT part of the snapshot (#989): logging a drink never bumps
        // refreshSeq, so a restored total could be stale. It is re-read live instead (see loadAll).
    }

    /// #989: today's hydration total + goal, re-read wherever staleness could show: the history-wide load,
    /// the same-seq cache restore, a hydration mutation (`repo.hydrationSeq`), and the feature toggle.
    /// Two metricSeries rows (hand-logged + imported, #949) and a UserDefaults read — still cheap
    /// enough to run on every pass.
    private func reloadHydration() async {
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
    }

    /// #932: restore the day-scoped outputs from a same-(seq, day) cache on a re-mount, so the selected day
    /// repaints from memory without re-running the heavy HR reads. The Rest-tile spark is restored here
    /// (this pass owns `sparks["sleep_performance"]`, see loadDayScoped) BEFORE any history-wide restore
    /// merges the other keys around it, same ordering as a genuine load. The zoom is NOT cached (it is the
    /// user's transient gesture state): it is re-clamped against the restored axis exactly like a genuine
    /// load, which on the fresh-mount hit path is the nil → nil no-op (a re-mount resets `@State`).
    private func restoreDayScoped(_ c: TodayDayScopedCache) {
        sparks["sleep_performance"] = c.restSpark
        restScore = c.restScore
        provenanceByMetric = c.provenanceByMetric
        providerByMetric = c.providerByMetric
        hrPoints = c.hrPoints
        stepActivityClassToday = c.stepActivityClassToday
        liveTodayStrain = c.liveTodayStrain
        hrZoomDomain = Self.reclampHrZoom(hrZoomDomain, oldAxis: hrAxis, newAxis: c.hrAxis)
        hrAxis = c.hrAxis
        sleepToday = c.sleepToday
    }

    /// The reads that follow `selectedDayOffset`: the selected day's Rest score + provenance, its HR
    /// window + axis, the overlapping sleep band, today's in-progress Effort, and the one-shot auto-land.
    /// A handful of queries, so this ALWAYS runs on a refresh / day-switch / tab-return, the screen stays
    /// responsive even while the heavy history-wide set is deferred during a backfill (#755). The Rest tile
    /// sparkline (`sparks["sleep_performance"]`) is derived from the SAME `restSeries` read here so the
    /// tile's number and its mini-graph stay consistent and day-fresh. Byte-identical to the old inline
    /// values; only the read's location moved.
    ///
    /// #860 item 1: the launch "land on the most recent data day" (#605/#739) is RETIRED. A fresh launch now
    /// always shows today (offset 0, decided by `launchDayOffset` on the plain `@State selectedDayOffset`),
    /// so a calibrating user whose newest data is days back is no longer stranded on that old day after an
    /// app update. This pass therefore no longer mutates `selectedDayOffset`, so it has nothing to signal to
    /// the caller and returns void.
    ///
    /// #932: how long a TODAY snapshot may be served before a re-mount pays a genuine reload. Live banking
    /// does not bump `refreshSeq` (see the fast-path comment below), so this bounds the staleness of the
    /// restored HR curve / live Effort against the 1Hz stream. Rapid sidebar switching (the measured #932
    /// hitch) sits comfortably inside it, and even a genuine load runs up to ~30s behind live anyway (the
    /// Collector flush cadence), so two minutes of cache is the same order of freshness the screen had.
    private static let todayCacheMaxAge: TimeInterval = 120

    private func loadDayScoped() async {
        // #932: same-state re-mount → restore the prior day-scoped snapshot (no store queries). The exact
        // twin of the #849 history-wide short-circuit in loadAll, for the reads that follow the SELECTED
        // day: on a big library the day's hrBuckets + hrSamples reads cover 170k+ HR rows, and macOS
        // cold-mounts this screen on every sidebar switch, so re-running them for byte-identical data is
        // the measured #849/#932 frame degradation. The key pairs the seq with the VIEWED day's key, so
        // swiping to another day misses (another day's snapshot is never served) and a day rollover misses
        // even at an unchanged seq. FRESHNESS, stated honestly: continuous live banking does NOT bump
        // `refreshSeq` (Collector flushes insert hrSample rows without a refresh(), and refresh() diffs
        // only the day-level merged caches, never raw rows), so a TODAY snapshot goes quietly stale against
        // the live stream. Today hits are therefore AGE-GATED (`todayCacheMaxAge`): rapid sidebar switching,
        // the measured #932 pain, stays cached, while an older re-mount pays one genuine reload. A navigated
        // PAST day is immutable at a given seq, so past-day hits carry no age limit. On a today hit the
        // restored axis end is also re-extended to the current now (the cached end is the PREVIOUS load's
        // now), the reclamp's designed same-day end-extension, so the in-progress framing stays honest
        // without a query. Both key halves are captured HERE, before any await, so the snapshot at the tail
        // is keyed by the state this pass actually loaded for.
        let loadSeq = repo.refreshSeq
        let loadDayKey = selectedDayKey
        if repo.todayDayScopedLoadedSeq == loadSeq,
           repo.todayDayScopedLoadedDayKey == loadDayKey,
           let cached = repo.todayDayScopedCache,
           selectedDayOffset != 0 || Date().timeIntervalSince(cached.bankedAt) < Self.todayCacheMaxAge {
            restoreDayScoped(cached)
            if selectedDayOffset == 0, let axis = hrAxis {
                let nowEnd = Date()
                if nowEnd > axis.upperBound {
                    let extended = axis.lowerBound ... nowEnd
                    hrZoomDomain = Self.reclampHrZoom(hrZoomDomain, oldAxis: axis, newAxis: extended)
                    hrAxis = extended
                }
            }
            return
        }
        #if DEBUG
        // v7.7.2 regression guard: count only genuine day-scoped loads (the cache restore above returned
        // BEFORE this and must not increment it), so a test can assert one fire per (seq, day).
        repo.loadFireCounts["todayDayScoped", default: 0] += 1
        #endif

        // Rest series + the two provenance resolves, all day-keyed outputs, none consumes another's
        // result, so fire them concurrently and await where first used.
        async let restSeriesA       = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let recoveryResolvedA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource)
        async let restResolvedA     = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource)

        // Rest SCORE for the logical day. `exploreSeries` already merges imported + computed
        // `sleep_performance` (imported-wins), so a Bluetooth-only user sees the on-device Rest
        // composite and an importer sees the export's figure, exactly like the Rest detail screen.
        let restSeries = await restSeriesA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // The Rest TILE's sparkline (#614 follow-up). The tile's number is `restScore` (the Rest composite,
        // 0–100) but its mini-graph used to plot raw sleep MINUTES (`sparks["sleep_total_min"]`), so the
        // trend didn't track the score it sat under. Plot the SAME merged `sleep_performance` 0–100 series
        // the score reads instead, windowed to the trailing 14 calendar days like every other spark.
        let restSparkLocal = trailingWindow(restSeries, days: 14).map { $0.value }
        sparks["sleep_performance"] = restSparkLocal
        // The selected day's Rest, falling back to the series tail only when today itself is selected (a
        // navigated past day with no Rest row shows ", " rather than borrowing the newest value) AND that
        // tail night is still fresh. #977: a live 5.0 whose sleep never scores used to pin Rest to the
        // weeks-old series tail forever; gate the tail-fallback on freshness so a stale tail falls through
        // to the No-Data state instead of freezing.
        let restScoreLocal = Self.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        restScore = restScoreLocal

        // Resolve the displayed score row, then map computed rows through durable input provenance so the
        // badge names the sensor/import provider rather than the device that ran NOOP's math.
        var provenance: [String: String] = [:]
        var providers: [String: ScoreInputProvider] = [:]
        let recoveryResolved = await recoveryResolvedA
        if let win = recoveryResolved.points.last(where: { $0.day == selectedDayKey }) {
            provenance["recovery"] = win.source
            providers["recovery"] = await repo.scoreInputProvider(
                resolvedSource: win.source,
                day: win.day,
                metricKey: "recovery"
            )
        }
        let restResolved = await restResolvedA
        if let win = restResolved.points.last(where: { $0.day == selectedDayKey }) {
            provenance["sleep_performance"] = win.source
            providers["sleep_performance"] = await repo.scoreInputProvider(
                resolvedSource: win.source,
                day: win.day,
                metricKey: "sleep_performance"
            )
        }
        provenanceByMetric = provenance
        providerByMetric = providers

        // HR trend for the SELECTED day, 5-minute bucket means from that logical day's local midnight.
        // For today the window runs to now (an in-progress curve); for a navigated past day it runs the
        // full 24h to the next midnight. The logical day rolls at 04:00 (Repository.logicalDayStart), so
        // in the small hours after midnight today still starts at yesterday's midnight rather than
        // blanking to an empty new-calendar-day axis (#144).
        let dayStart = Calendar.current.startOfDay(for: selectedLogicalDay)
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let windowEnd: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        let hrPointsLocal = await repo.hrBuckets(from: windowStart, to: windowEnd, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        hrPoints = hrPointsLocal

        // #316 / @63, the selected day's representative activity class for the Steps tile icon. Reads the
        // day's step samples (now carrying `activityClass` after the v19 column) and takes the LAST non-nil
        // class in the window as "what the wrist was doing most recently today". Reads the active strap +
        // canonical UNION (like the HR curve / Effort above): a re-added strap banks its live step samples
        // under its OWN fresh id, so a read pinned to the canonical "my-whoop" would drop the icon for a
        // re-added strap (the #904/#908 family). nil (no classed sample) hides the icon.
        let stepClassLocal = await repo.stepActivityClassLatest(from: windowStart, to: windowEnd)
        stepActivityClassToday = stepClassLocal

        // #860 item 1: the launch auto-land (#605/#739 "snap to the most recent data day when today is
        // empty") is RETIRED here. A fresh launch lands on today via `launchDayOffset` against the plain
        // `@State selectedDayOffset` (which re-inits to 0 every process), so a calibrating user whose newest
        // banked day is days back opens on TODAY, not on that old day. In-session day memory (#739/#614) is
        // untouched: a tab-away + return keeps the navigated offset because this pass no longer rewrites it.

        // In-progress Effort for TODAY (#402): score today's strain over the SAME window the HR curve
        // above shows (logical-day midnight → now) so the gauge tracks the day live instead of lagging
        // on the last persisted daily row. Uses the identical params the daily pass uses, Tanaka HRmax
        // from age, today's resting HR (else the default), sex, so the live number matches what the
        // engine will eventually persist. Below StrainScorer.minReadings the scorer returns nil and the
        // gauge falls back to the stored row (never a fabricated value); a navigated past day clears it.
        let liveStrainLocal: Double?
        if selectedDayOffset == 0 {
            let todayHr = await repo.hrSamples(from: windowStart, to: windowEnd)
            let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
            let restHR = displayDay?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveStrainLocal = StrainScorer.strain(todayHr, maxHR: maxHR, restingHR: restHR, sex: profile.sex)
        } else {
            liveStrainLocal = nil
        }
        liveTodayStrain = liveStrainLocal
        // Pin the chart axis to the loaded window, today midnight→now, a past day the full 24h, so
        // a gap (e.g. a morning the strap wasn't banking) shows as empty space, not a late start.
        let newAxis = Date(timeIntervalSince1970: TimeInterval(windowStart))
            ... Date(timeIntervalSince1970: TimeInterval(windowEnd))
        // #829 - keep the HR zoom VALID across reloads. The window changes on a day step (a whole new day)
        // and, on today, each refresh nudges the end to a fresh `now`. A day step clears the zoom so the new
        // day opens at full scale; a same-day end-extension keeps the user's zoom but RE-CLAMPS it into the
        // grown bounds (preserving its span) so a live sync never yanks them out of their zoom yet the window
        // can never sit outside the day. `panned(deltaSeconds: 0)` is the pure re-clamp.
        hrZoomDomain = Self.reclampHrZoom(hrZoomDomain, oldAxis: hrAxis, newAxis: newAxis)
        hrAxis = newAxis

        // Sleep session overlapping the window. Uses `allSleepSessions` (BOTH the imported and the
        // on-device COMPUTED source), a Bluetooth-only user's sleep lives under the computed source,
        // so the imported-only `sleepSessions` returns nothing. Keep blocks that actually overlap the
        // displayed window, then resolve the day's bridged MAIN-night span via `SleepView.mainNightSpan`
        // (offloaded to the Sleep tab hero and `AnalyticsEngine`'s daily total), not an ad hoc "longest
        // single block" pick — that could disagree with the Sleep tab and the Coupled view's bed→wake
        // read for a night stored as more than one block (#294). Drives the HR sleep band + the recovery
        // marker's wake anchor.
        let overlapping = await repo.allSleepSessions(days: selectedDayOffset + 2)
            .filter { $0.endTs > windowStart && $0.startTs < windowEnd }
        let habitualMidsleepSecLocal = await repo.habitualMidsleepSec()
        let sleepTodayLocal = SleepView.mainNightSpan(overlapping, habitualMidsleepSec: habitualMidsleepSecLocal)
            .map { span in
                CachedSleepSession(startTs: span.start, endTs: span.end,
                                   efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
            }
        sleepToday = sleepTodayLocal

        // #932: snapshot everything just computed onto the long-lived `repo`, keyed by the (seq, day) this
        // pass loaded FOR (both captured at entry), so a later re-mount with the same (seq, day) restores it
        // in-memory instead of re-running the heavy reads. Skip the store when the pass was overtaken
        // mid-await: a day swipe moves `selectedDayKey` (and `.task(id:)` cancels this pass) while the body
        // runs to completion, so its outputs can straddle two days; caching that mix under the ENTRY key
        // would serve it again later. The re-fired pass for the new key reloads + snapshots genuinely, so
        // skipping here costs nothing but a cache miss. The snapshot is built from the LOCALS captured at
        // each computation point, never from `@State` at tail time: a cancelled sibling pass's interleaved
        // `@State` writes (its awaits still complete) can therefore never leak into this pass's bank.
        guard loadDayKey == selectedDayKey, !Task.isCancelled else { return }
        repo.todayDayScopedCache = TodayDayScopedCache(
            restSpark: restSparkLocal,
            restScore: restScoreLocal,
            provenanceByMetric: provenance,
            providerByMetric: providers,
            hrPoints: hrPointsLocal,
            stepActivityClassToday: stepClassLocal,
            liveTodayStrain: liveStrainLocal,
            hrAxis: newAxis,
            sleepToday: sleepTodayLocal,
            bankedAt: Date())
        repo.todayDayScopedLoadedSeq = loadSeq
        repo.todayDayScopedLoadedDayKey = loadDayKey
    }

    /// Post a single honest `.reading` update to the inbox when a refresh brought in genuinely NEWER
    /// history (a WHOOP import or an overnight backfill that pushed the newest day forward). We compare
    /// the MAX day-key in `repo.days`, not the count (#521): a background recompute rebuilds the window
    /// via delete-then-reinsert, so the count momentarily dips and recovers, but the newest key is
    /// unchanged, so churn never fires this. The very first load (empty baseline) records the key
    /// silently; a navigated past day is ignored; the persisted key means a relaunch over the same
    /// history never re-announces. The count of newly-forward days is real (keys strictly above the
    /// previous max), never fabricated. Links to Trends.
    private func announceNewDaysIfNeeded() {
        guard selectedDayOffset == 0 else { return }
        guard let newestKey = repo.days.map(\.day).max() else { return }   // no history yet
        let previousKey = lastAnnouncedDayKey
        defer { lastAnnouncedDayKey = newestKey }
        // No baseline yet → record silently, never announce historical data on first sight.
        guard !previousKey.isEmpty else { return }
        // Only a STRICTLY newer day-key counts as new history (yyyy-MM-dd sorts chronologically).
        guard newestKey > previousKey else { return }
        // Honest count of how many distinct days arrived ABOVE the old watermark.
        let added = Set(repo.days.map(\.day)).filter { $0 > previousKey }.count
        guard added > 0 else { return }
        updateStore.post(UpdateItem(
            kind: .reading,
            title: String(localized: "New data added"),
            message: added == 1 ? String(localized: "1 new day of history landed. Open Trends to see it.")
                                : String(localized: "\(added) new days of history landed. Open Trends to see them."),
            deepLink: NavRouter.Destination.trends.rawValue
        ))
    }

    /// Trailing-window values for a metric, NO fall back to all history. The section is labelled a
    /// current trend ("14-day trend"), so a stale import must not render months-old points as if they
    /// were recent (same spirit as the #23 trailing-window fix). The window is generous enough that a
    /// genuinely sparse-but-recent series still renders, weight uses 90 days, and the Sparkline view
    /// already handles 0/1 points (empty / a single head dot), so no fallback is needed for layout.
    /// `latestString` reads `.last` of this windowed series, so a value older than the window shows
    /// ", " rather than a stale number under a Today tile (#49).
    private func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        // PERF: clamp the read at the store level to the trailing window instead of materializing the
        // FULL history (the old default `days: 4000`) for a 14-point sparkline — this runs as ~10
        // concurrent reads on every Today load. `repo.series(days:)` anchors its from-key at
        // now − days·86400 while `trailingWindow` clamps at local-today − (window−1) calendar days, so
        // `window + 1` reads a strict superset of the displayed window across any TZ/DST edge and
        // `trailingWindow` below still applies the exact same calendar clamp as before — the rendered
        // points are byte-identical to the full-history read.
        let all = await repo.series(key: key, source: source, days: window + 1)   // windowed, asc
        guard !all.isEmpty else { return [] }
        return trailingWindow(all, days: window).map { $0.value }
    }

    /// Same as `sparkValues` but reads via `exploreSeries` so the on-device COMPUTED `DailyMetric`
    /// column backs the sparkline for a BLE-only WHOOP user (no CSV/Health import). `series` reads
    /// metricSeries only, which is empty for computed keys like `resp_rate` (the engine writes
    /// `respRateBpm` on the DailyMetric row, not a metricSeries point); `exploreSeries` Layer 3
    /// falls back to `dailyColumn` so the strap's own nightly respiratory rate fills the trend.
    /// Mirrors the Android `rememberTrendWindow` which builds the resp spark from
    /// `DailyMetric.respRateBpm` directly. Used for `resp_rate` (parity fix).
    private func sparkValuesExplore(_ key: String, source: String, window: Int) async -> [Double] {
        let all = await repo.exploreSeries(key: key, source: source, days: window + 1)
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

    /// Latest value of a loaded sparkline series, formatted, for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    private func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// The Weight tile's display string + an honest caption ("from profile" only on the fallback).
    /// Prefers a real Apple-Health reading (today's daily, else the "weight" series' newest point so a
    /// sparse-but-recent value still renders); when neither carries a weight, falls back to the user's
    /// self-reported profile weight instead of ", " (#204). Always formatted through the shared
    /// `UnitFormatter` so the Imperial/Metric toggle reaches this tile. Mirrors Android's `weightTile`.
    private func weightTile(_ appleWeightKg: Double?) -> (value: String, caption: String) {
        if let kg = appleWeightKg ?? sparks["weight"]?.last {
            return (UnitFormatter.massFromKilograms(kg, system: unitSystem), String(localized: "latest"))
        }
        return (UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem), String(localized: "from profile"))
    }

    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    private var greetingWord: String {
        #if DEBUG
        // DEBUG promo harness: pin the greeting to the active frame's wording. No-op otherwise.
        if let f = DemoDayHarness.active { return f.greeting }
        #endif
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return String(localized: "Good morning")
        case 12..<17: return String(localized: "Good afternoon")
        default:      return String(localized: "Good evening")
        }
    }

    // #perf: fixed-locale (en_US_POSIX), hoisted to static so the ~1 Hz Today body doesn't allocate a
    // DateFormatter every render. Behaviour-identical — the format + locale are pinned.
    private static let dateLineFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()
    private var dateLine: String {
        // The selected day's date when navigated; today's banked-row date (or today) at offset 0.
        if selectedDayOffset == 0, let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return Self.dateLineFmt.string(from: date)
        }
        return Self.dateLineFmt.string(from: selectedLogicalDay)
    }

    /// Hero title that names the selected day, "Today's"/"Yesterday's"/"Day's" Synthesis.
    private var synthesisTitle: LocalizedStringKey {
        switch selectedDayOffset {
        case 0:  return "Today’s Synthesis"
        case 1:  return "Yesterday’s Synthesis"
        default: return "Synthesis"
        }
    }

    /// Section overline naming the selected day, "Today"/"Yesterday"/"EEE d MMM".
    private var selectedDayOverline: String {
        switch selectedDayOffset {
        case 0:  return String(localized: "Today")
        case 1:  return String(localized: "Yesterday")
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE d MMM"
            return f.string(from: selectedLogicalDay)
        }
    }

    /// A short recovery state word for the synthesis hero.
    private func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return String(localized: "No Data") }
        switch s {
        case ..<25:  return String(localized: "Depleted")
        case ..<50:  return String(localized: "Low")
        case ..<70:  return String(localized: "Steady")
        case ..<88:  return String(localized: "Primed")
        default:     return String(localized: "Peak")
        }
    }

    /// Plain-English synthesis of recovery + sleep. Whole-phrase variants per (charge band × sleep
    /// state), never a stitched tail fragment, so every combination is one clean catalog key.
    private func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return String(localized: "No metrics yet. Import your Whoop export or wear the strap to begin.")
        }
        // true = slept 7h+; false = short; nil = no banked duration.
        let sleptWell: Bool? = d.totalSleepMin.map { $0 / 60.0 >= 7 }
        switch rec {
        case ..<50:
            switch sleptWell {
            case true?:  return String(localized: "Charge is low and sleep was consistent.")
            case false?: return String(localized: "Charge is low but sleep ran short.")
            case nil:    return String(localized: "Charge is low.")
            }
        case ..<70:
            switch sleptWell {
            case true?:  return String(localized: "Charge is steady and sleep was consistent.")
            case false?: return String(localized: "Charge is steady but sleep ran short.")
            case nil:    return String(localized: "Charge is steady.")
            }
        default:
            switch sleptWell {
            case true?:  return String(localized: "Charge is strong and sleep was consistent.")
            case false?: return String(localized: "Charge is strong but sleep ran short.")
            case nil:    return String(localized: "Charge is strong.")
            }
        }
    }

    private func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { String(localized: "\(Int($0.rounded())) ms") } ?? " - ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return String(localized: "HRV \(hrv) · RHR \(rhr)")
    }

    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return String(localized: "\(h)h \(mm)m")
    }

    /// #110: the Home sleep row's value is `totalSleepMin` — WHOOP's imported TST for the day, which can
    /// legitimately differ from the Sleep tab's on-device re-staged night (with a WHOOP CSV *and* Apple
    /// Health both imported). Label the row with its source + which night — the same "Whoop"/"On-device"
    /// winner logic the Sleep tab's `nightSource` badge uses (`repo.importedSleep` keyed by the row's
    /// wake-day, exactly as `sleepScoreSource` keys it) — so a WHOOP figure, or an older night at a
    /// split-sleep / timezone edge, is never silently presented as "last night" with no provenance.
    /// nil → the row keeps its static description (no banked sleep for the day).
    private func sleepSourceSubtitle(_ d: DailyMetric?) -> String? {
        guard let d, d.totalSleepMin != nil else { return nil }
        let source = repo.importedSleep[d.day] != nil
            ? String(localized: "Whoop") : String(localized: "On-device")
        // At offset 0 the row IS last night; a navigated past day names its real date so the label never
        // over-claims "last night".
        let night = selectedDayOffset == 0
            ? String(localized: "last night")
            : Self.lastChargeDateFmt(d.day)
        return String(localized: "\(source) · \(night)")
    }

    /// The Rest tile's caption, hours-in-bed for the day, the figure that used to be the tile's
    /// VALUE before #248 moved the Rest score there. Falls back to the efficiency read-out when no
    /// duration is banked, and to nil so the tile shows no caption line at all when neither exists.
    private func restCaption(_ d: DailyMetric?) -> String? {
        if d?.totalSleepMin != nil { return sleepValue(d) }
        return d?.efficiency.map { String(format: String(localized: "%.0f%% eff"), $0) }
    }

    /// Short "it's coming, not broken" caption for an unscored Effort/Rest tile on TODAY only. The
    /// call sites only reach here when the score is genuinely absent; this adds the today-only gate so
    /// a navigated PAST day with no score honestly stays a bare ", " (missing data, not mid-calibration).
    /// Mirrors the recoveryCalibration today-only rule the Charge tile uses for its "N of 4" treatment.
    private func buildingHint(_ metric: KeyMetric) -> String? {
        Self.buildingHintCopy(metric, isToday: selectedDayOffset == 0)
    }

    /// The Component-2 "needs the strap" tile caption, the honest no-data state word a Charge/Rest tile
    /// shows instead of a bare blank when there's no value, no calibration count and nothing to carry.
    /// Matches `MetricTileState.needsStrap.title` verbatim so the tile and the explained note say the same
    /// words, both resolve from the SAME catalog key, so they stay in lockstep in every locale.
    static let needsStrapCaption = String(localized: "Needs the strap")

    /// H10, the honest empty-state caption for a recovery-vital tile (HRV / Resting HR / SpO₂ / Respiratory)
    /// when TODAY has no value yet and there's nothing to carry over. Those vitals are measured overnight, so
    /// "After tonight's sleep" tells the user WHEN the tile fills rather than leaving a bare ", " beside a lone
    /// unit that read as broken. Returns nil off-today (a past day keeps the plain unit, it's missing data the
    /// user can't act on now). Pure copy/gate so it can be unit-tested without a live view. Mirror in Kotlin.
    static func emptyVitalCaption(unit: String, isToday: Bool) -> String? {
        guard isToday else { return nil }
        return String(localized: "After tonight's sleep")
    }

    /// Pure copy/gate behind `buildingHint`, extracted so it can be unit-tested without a live view.
    /// Rest fills in after a night's sleep; Effort fills in once cardio load is logged. Em-dash-free
    /// house style. Returns nil off-today and for any metric other than Effort/Rest (#527).
    static func buildingHintCopy(_ metric: KeyMetric, isToday: Bool) -> String? {
        guard isToday else { return nil }
        switch metric {
        case .rest:   return String(localized: "Building, wear it tonight")
        case .effort: return String(localized: "Building, moves as you do")
        default:      return nil
        }
    }

    /// Active calories (Apple) for the latest day, falling back to the sparkline tail.
    private func caloriesValue(_ a: AppleDaily?) -> String {
        if let kcal = a?.activeKcal { return intString(kcal) }
        return latestString("active_kcal", decimals: 0)
    }

    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return String(localized: "\(mins / 60)h \(mins % 60)m") }
        return String(localized: "\(mins)m")
    }

    /// "d MMM · HH:mm–HH:mm", start-only when the row has no real end (#157). The "· N bpm"
    /// segment was dropped: the StatTile caption is lineLimit(1) and date + range + bpm clips,     /// avg HR remains on the Workouts screen.
    // #perf: fixed-locale (en_US_POSIX), hoisted to static so a workout list doesn't allocate a
    // DateFormatter per row per render. Behaviour-identical — format + locale pinned. (mirrors `hrTimeFmt`)
    private static let workoutDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()
    private func workoutCaption(_ w: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let date = Self.workoutDateFmt.string(from: start)
        guard w.endTs > w.startTs else { return "\(date) · \(Self.hrTimeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
        return "\(date) · \(Self.hrTimeFmt.string(from: start))-\(Self.hrTimeFmt.string(from: end))"
    }

    /// Thousands-grouped integer string (steps / calories).
    private func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }

    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, LOCAL zone)
    //
    // Parses a `DailyMetric.day` key, which is written in the device's LOCAL zone
    // (Repository.dayKeyFormatter sets no zone, the post-#277 local-day bucketing).
    // It MUST parse in that same local zone: parsing a local-day key like "2026-06-14"
    // as UTC yields 00:00Z, which is still June 13 in any negative-UTC zone, so the
    // header subtitle then printed the previous day for everyone west of UTC (#319/#320).
    // Matching dayKeyFormatter (no explicit zone) makes the parse→format round-trip an identity.

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local wall-clock time for the HR trend's x-axis / tooltip, the chart spans one day, so it must
    /// show times, not the day-granularity default ("EEE d MMM"). Also formats the workout-tile caption's
    /// time range (#157). The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "7:10 AM"
    /// where 12-hour is preferred, "19:10" where 24-hour is, instead of forcing one on everyone.
    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}

/// `.task(id:)` key combining the data refresh sequence with the selected day so a reload runs on
/// either a data change or a day-navigation change (the HR trend + Rest score are day-scoped).
private struct TodayLoadKey: Equatable {
    let seq: Int
    let offset: Int
}

/// #849: an in-memory snapshot of everything `loadHistoryWide()` computes: the ~40 history-wide reads +
/// the per-workout strap-HR derivation. Held on the long-lived `Repository` (NOT TodayView's `@State`),
/// keyed by the `refreshSeq` it was built at, so a Today RE-MOUNT (TabView/module switch, or an
/// Apple-Health import that recreates the view, both tear down `@State`) can RESTORE these values without
/// re-running the heavy query pass. Restoring is a handful of in-memory assignments; the old code instead
/// re-ran the full history-wide reload on every re-mount, which is the lag #849 reports returning to Today
/// after an import. Built only after a real `loadHistoryWide()`; consumed when the seq still matches.
struct TodayHistoryWideCache {
    let sparks: [String: [Double]]
    let stepsEstByDay: [String: Int]
    let workouts: [WorkoutRow]
    let appleDays: [AppleDaily]
    let xiaomiDays: Int
    let xiaomiSleeps: Int
    let stressToday: Double?
    let fitnessAgeToday: Double?
    let vitalityToday: Double?
    // Hydration total/goal intentionally absent (#989): mutations don't bump refreshSeq, so a cached
    // value could restore stale. TodayView re-reads hydration live on restore instead.
}

/// #849/#932: an in-memory snapshot of everything `loadDayScoped()` computes for ONE viewed day: the Rest
/// score + its tile spark, the provenance winners, the selected day's 5-minute HR buckets, the day's step
/// activity class, the live Effort, the pinned chart axis and the overlapping sleep band. Held on the
/// long-lived `Repository` (NOT TodayView's `@State`), keyed by the (`refreshSeq`, viewed-day key) it was
/// built at, so a Today RE-MOUNT with unchanged data (macOS cold-mounts the screen on every sidebar switch)
/// can RESTORE these values without re-running the heavy `hrBuckets`/`hrSamples` reads, 170k+ HR rows/day
/// on a big library, the measured #932 frame degradation. The day key half of the pair is what makes day
/// navigation safe: another day's snapshot can never be served because its key differs. Built only after a
/// real `loadDayScoped()`; consumed when BOTH the seq AND the day key still match (see
/// `Repository.todayDayScopedLoadedSeq` / `todayDayScopedLoadedDayKey`).
struct TodayDayScopedCache {
    let restSpark: [Double]
    let restScore: Double?
    let provenanceByMetric: [String: String]
    let providerByMetric: [String: ScoreInputProvider]
    let hrPoints: [TrendPoint]
    let stepActivityClassToday: Int?
    let liveTodayStrain: Double?
    let hrAxis: ClosedRange<Date>
    let sleepToday: CachedSleepSession?
    /// When the snapshot was banked. TODAY hits are age-gated on this (`todayCacheMaxAge`): live banking
    /// does not bump `refreshSeq`, so an unbounded today snapshot would drift behind the 1Hz stream.
    let bankedAt: Date
}

// MARK: - Live-observing leaf subviews (scroll-stutter isolation)
//
// TodayView itself does NOT observe `LiveState` (see the @EnvironmentObject note at the top of the
// type). These small leaves each hold their OWN `@EnvironmentObject var live`, so a connected strap's
// ~1 Hz publish re-renders only the affected dot / note / row, never the rings, scene, sparklines,
// HR chart or cards. They render byte-for-byte what the inline code did before the extraction.

/// #245: the sync-status state used by the Devices screen's larger sync card, resolved once from
/// `LiveState`. THREE states mean the ABSENCE of active syncing reads as "caught up", not
/// "missing indicator" (the real #245 confusion): actively offloading → `⟳ N`; idle with a known
/// last-sync → `✓ Xm`; a 5/MG whose history sync is experimental (live-connected, no completed offload
/// yet) → `✓ live`. `.hidden` only on a true cold start (the building-scores note owns that case). Twin
/// of Android `SyncStatusChip`.
enum SyncChipState: Equatable {
    case syncing(chunks: Int)
    case synced(agoText: String)
    case experimentalLive
    case hidden

    @MainActor
    static func resolve(live: LiveState) -> SyncChipState {
        if live.backfilling { return .syncing(chunks: live.syncChunksThisSession) }
        if let ts = live.lastSyncedAt { return .synced(agoText: shortAgo(ts)) }
        if live.historySyncExperimental { return .experimentalLive }
        return .hidden
    }

    /// Compact relative age for the status card ("now" / "Nm" / "Nh" / "Nd") — deliberately terse.
    /// "now" is the only word in here (the rest is digits + a unit letter), so it's the only piece that
    /// needs a catalog entry to translate; localized here rather than at each of the two call sites.
    private static func shortAgo(_ ts: TimeInterval) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970 - ts))
        if secs < 60 { return String(localized: "now") }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        return "\(hrs / 24)d"
    }
}

/// The compact 36pt recording-status light in the iOS top bar, a colour-coded dot (green recording,
/// amber last-synced, red not recording, accent for experimental 5.0 history). Taps to Devices. Owns
/// the `LiveState` observation so a live-HR tick refreshes only this dot.
private struct RecordingStatusLight: View {
    @EnvironmentObject private var live: LiveState
    let selectedDayOffset: Int
    let onTap: () -> Void

    /// Drives the syncing pulse; toggled in `.task` while an offload runs (never during body eval).
    @State private var pulsing = false

    /// This `repeatForever` ring had NO motion gate of any kind — it pulsed under system Reduce
    /// Motion too, which was already a bug (the Android twin's ConnectionDot had the same one, fixed
    /// in #911). It also ran precisely while the strap was offloading history, i.e. while the app was
    /// already busy. Gated on all three quiet signals now.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    /// Colour for the light: green recording, amber last-synced, red not recording, accent for
    /// experimental history. Mirrors the prior `TodayView.recordingHue` semantics verbatim.
    private func hue(_ state: RecordingState) -> Color {
        switch state {
        case .recording:           return StrandPalette.statusPositive
        case .lastSynced:          return StrandPalette.statusWarning
        case .notRecording:        return Color(red: 0.98, green: 0.27, blue: 0.23)
        case .historyExperimental: return StrandPalette.accent
        case .connectedNoData:     return StrandPalette.accent
        }
    }

    var body: some View {
        // The 36pt chip ALWAYS renders so the top-bar icon row never jumps when you scrub to a past day.
        // A live recording state colours the dot (green / amber / red); a past day (no state) shows a muted
        // dot and the chip is non-actionable, recording status only means something for today.
        let state = TodayView.recordingState(live: live, selectedDayOffset: selectedDayOffset)
        // #245: while the strap is actively offloading history, surface a visible SYNC indicator right in
        // the header (users otherwise only saw progress under More → Live). This reads `live.backfilling`
        // directly rather than adding a `RecordingState` case, so the pure mapper + its Kotlin twin stay
        // untouched — a UI-only accent pulse, gated to today (a past day never syncs). The dot keeps its
        // recording hue underneath; an expanding accent ring says "handing over history now".
        let syncing = live.backfilling && selectedDayOffset == 0
        Button(action: onTap) {
            Circle().fill(StrandPalette.surfaceInset)
                .frame(width: 36, height: 36)
                .overlay {
                    if syncing {
                        // Expanding, fading accent ring behind a steady accent dot — a "pulling data" beat.
                        Circle()
                            .stroke(StrandPalette.accent, lineWidth: 2)
                            .frame(width: 10, height: 10)
                            .scaleEffect(pulsing ? 2.6 : 1.0)
                            .opacity(pulsing ? 0.0 : 0.9)
                        Circle().fill(StrandPalette.accent).frame(width: 10, height: 10)
                    } else {
                        Circle()
                            .fill(state.map(hue) ?? StrandPalette.textTertiary.opacity(0.4))
                            .frame(width: 10, height: 10)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == nil && !syncing)
        .accessibilityLabel(syncing ? syncingAccessibilityLabel
            : (state?.accessibilityText ?? String(localized: "Recording status, not shown for a past day")))
        // Run the repeating pulse only while syncing AND nothing is asking for quiet motion; the
        // `.task(id:)` auto-cancels when the flag flips, so there is no timer left running once the
        // offload ends (or Today goes away). Without the pulse the steady accent dot still says
        // "syncing" — the information survives, only the loop stops.
        .task(id: syncing) {
            guard syncing, !motion.poseStill(reduceMotion) else { pulsing = false; return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulsing = true }
        }
    }

    /// VoiceOver read-out while offloading: names the running chunk count so it matches the Live badge.
    private var syncingAccessibilityLabel: String {
        let n = live.syncChunksThisSession
        return n > 0
            ? String(localized: "Syncing strap history, chunk \(n)")
            : String(localized: "Syncing strap history")
    }
}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation so the chunk count ticks without re-rendering the rest of Today.
private struct SyncingHistoryNoteIfBackfilling: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}

/// #755: a zero-size leaf that mirrors `LiveState.backfilling` into a parent `@Binding` so TodayView can
/// read the offload state to defer its heavy reads WITHOUT itself observing LiveState (which would re-flood
/// the whole dashboard `body` on every ~1 Hz live tick, the scroll-stutter the rest of this file avoids).
/// This leaf owns the observation but renders nothing and re-renders only itself; it pushes only the
/// boolean EDGE up (not the per-tick chunk count), and writes the binding from `.onAppear`/`.onChange`
/// (never during its own body evaluation). The parent's @State therefore flips ~twice per offload, not 1 Hz.
private struct BackfillFlagBridge: View {
    @EnvironmentObject private var live: LiveState
    @Binding var flag: Bool
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { if flag != live.backfilling { flag = live.backfilling } }
            .onChangeCompat(of: live.backfilling) { now in if flag != now { flag = now } }
    }
}

/// Honest strap-sync outcome row for the Data Sources card (ports the Android Live line, ed6a31d): the
/// stalled-offload error when the last one died, else "History synced N ago". Hidden while an offload
/// runs, the SyncingHistoryNote already says so. The `TimelineView` re-renders the relative label each
/// minute. Owns the `LiveState` observation (scroll-stutter isolation).
private struct StrapSyncRow: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
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
}

/// Strap battery row for the Data Sources card (#159), shown ONLY while a strap is connected AND a
/// reading exists, with its own leading divider so the row + divider appear/vanish together (no empty
/// state). Owns the `LiveState` observation (scroll-stutter isolation).
private struct StrapBatteryRow: View {
    @EnvironmentObject private var live: LiveState

    /// Battery tint, same thresholds as the menu-bar stat (MenuBarContent.batteryTone).
    private func tint(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return StrandPalette.statusCritical
        case ..<35: return StrandPalette.statusWarning
        default:    return StrandPalette.statusPositive
        }
    }

    /// Level-banded battery glyph; the bolt variant when the strap reports charging.
    private func symbol(_ pct: Double) -> String {
        if live.charging == true { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    /// #713: "~X left" runtime from `live.batteryEstimate`. Under 48 hours we show hours so a nearly-flat
    /// strap reads honestly ("~6h left"); at two days or more we round to days ("~9 days left"). nil (no
    /// banked discharge yet, or charging) hides it, so the badge only ever shows an estimate we trust.
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

    var body: some View {
        if live.connected, let pct = live.batteryPct {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 10) {
                SourceBadge("Strap battery", tint: tint(pct))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: symbol(pct))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint(pct))
                    Text("\(Int(pct.rounded()))%")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                    // The runtime estimate sits beside the %, dimmer, only when we have a trusted one.
                    if let estimateText {
                        Text("·")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(estimateText)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(Int(pct.rounded())) percent\(live.charging == true ? ", charging" : "")\(estimateText.map { ", \($0)" } ?? "")")
            }
        }
    }
}

// MARK: - Explainability state models (Components 2 & 3 of the sleep-guidance spec)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Each enum carries its own
// verbatim copy from the 2026-06-20 spec so a score/tile never renders a lone blank. These are
// pure value types with pure mappers so they unit-test off the live view, and they mirror 1:1
// with the Kotlin Today lane (com.noop.ui, same case names, same order, same words).

/// COMPONENT 2, the explained state of one score/tile on Today. `scored` carries the real value;
/// the other three NEVER carry a number (the honesty rule, calibrating / needsStrap show no value,
/// carried always stamped with its date). Each non-scored case yields a title, a detail line, and a
/// next step the UI renders instead of a bare blank.
enum MetricTileState: Equatable {
    /// Today's own value exists, the caller renders the number itself; this case is the "all good" gate.
    case scored
    /// Baselines still cold-start: `nightsRemaining` more nights until the score is personal. No number.
    case calibrating(nightsRemaining: Int)
    /// A prior scored day shown pre-tonight (#543 carry-over). `date` is that scored day's own date.
    /// `stale` is true when that day is older than the freshness cap (#779): the carry is still shown so the
    /// recovery side isn't a bare blank, but it's relabelled "Latest sleep" so a weeks-old import is never
    /// passed off as "Last night".
    case carriedLastNight(date: String, stale: Bool)
    /// No data for the period, strap not worn / not connected / not synced. No number.
    case needsStrap

    /// The state's short title. `scored` has no title (the value is the headline) so it returns nil.
    /// Verbatim spec copy; `\(...)` interpolation feeds the dynamic value into the LocalizedStringKey slot.
    var title: LocalizedStringKey? {
        switch self {
        case .scored:                       return nil
        case .calibrating:                  return "Calibrating"
        case .carriedLastNight(let date, let stale):
            // A LocalizedStringKey literal so the extractor catalogues the "Latest sleep · %@" /
            // "Last night · %@" format keys; the rendered English string is unchanged.
            return stale ? "Latest sleep · \(date)" : "Last night · \(date)"
        case .needsStrap:                   return "Needs the strap"
        }
    }

    /// The one-line detail + next step. Verbatim spec copy.
    var detail: LocalizedStringKey? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            // Whole-phrase singular/plural variants, never a stitched "night(s)" fragment, so each
            // reads as one clean catalog key and still pluralises honestly.
            return n == 1
                ? "Building your baseline. About 1 more night until your scores are personal."
                : "Building your baseline. About \(n) more nights until your scores are personal."
        case .carriedLastNight(_, let stale):
            // A fresh post-rollover carry tells you tonight's score is on its way; a stale carry (an older
            // import, #779) instead explains the number is from that earlier session, not today.
            return stale
                ? "This is your last scored session. Wear the strap overnight for a fresh score."
                : "Tonight's lands after you sleep with the strap on."
        case .needsStrap:
            return "No data for today. Was your strap worn and connected overnight?"
        }
    }

    /// VoiceOver-friendly plain string of title + detail (no markdown interpolation surprises). nil when scored.
    var accessibilityText: String? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            // Whole-string singular/plural variants, one key each, never a stitched tail fragment.
            return n == 1
                ? String(localized: "Calibrating. Building your baseline. About 1 more night until your scores are personal.")
                : String(localized: "Calibrating. Building your baseline. About \(n) more nights until your scores are personal.")
        case .carriedLastNight(let date, let stale):
            return stale
                ? String(localized: "Latest sleep, \(date). This is your last scored session. Wear the strap overnight for a fresh score.")
                : String(localized: "Last night, \(date). Tonight's lands after you sleep with the strap on.")
        case .needsStrap:
            return String(localized: "Needs the strap. No data for today. Was your strap worn and connected overnight?")
        }
    }

    /// Convenience for the hero, where calibration is already richly explained by the data-confidence
    /// pill + Synthesis card + ring overlay, so the explained note defers to those for that one case.
    var isCalibrating: Bool {
        if case .calibrating = self { return true }
        return false
    }

    /// PURE mapper (unit-testable), the honest precedence behind every Today score/tile state, given
    /// the engine outputs already computed on the view. Mirror EXACTLY in Kotlin (same order of checks):
    ///   1. today's own value exists            → `.scored`
    ///   2. still mid-calibration (today only)  → `.calibrating(nightsRemaining)`
    ///   3. a prior scored day to carry (#543)  → `.carriedLastNight(date, stale)`
    ///   4. nothing banked anywhere             → `.needsStrap`
    /// `nightsRemaining` is clamped to AT LEAST 1 so a boundary count never reads "0 more nights" while
    /// calibration is genuinely still on (the singular/plural rule then reads the clamped value). Mirror
    /// the Kotlin `coerceAtLeast(1)` exactly. `carriedStale` (#779) relabels an out-of-cap carry to
    /// "Latest sleep" so a weeks-old import is never passed off as "Last night".
    static func resolve(hasTodayValue: Bool,
                        calibratingNightsRemaining: Int?,
                        carriedDate: String?,
                        carriedStale: Bool = false) -> MetricTileState {
        if hasTodayValue { return .scored }
        if let remaining = calibratingNightsRemaining { return .calibrating(nightsRemaining: max(1, remaining)) }
        if let date = carriedDate { return .carriedLastNight(date: date, stale: carriedStale) }
        return .needsStrap
    }
}

/// COMPONENT 3, the strap's live recording status, mapped honestly from the BLE connection + last-sync.
/// One clear chip on Today so people know it's working, or know it isn't and why. Mirrors the Kotlin
/// Today lane 1:1 (same cases, same order, same words).
enum RecordingState: Equatable {
    /// Connected and saving data live.
    case recording
    /// Not connected now but synced `minutesAgo` minutes back, reconnect to pull the latest.
    case lastSynced(minutesAgo: Int)
    /// Strap not connected and nothing fresh to fall back on.
    case notRecording
    /// #580, a connected WHOOP 5/MG streaming live HR fine, but its firmware hands over no history
    /// offload yet. NOT the WHOOP-4 "not recording" failure: the link is live, history sync is just
    /// experimental on 5.0. Surfaced from `LiveState.historySyncExperimental`, overriding the mapper.
    case historyExperimental
    /// #612, connected with no live HR AND no evidence data is actually flowing — either this is the
    /// strap's first-ever pairing (never once synced) or a WHOOP-4/generic strap whose last several
    /// offloads all came back empty (`LiveState.sustainedEmptyOffload`). Distinct from `.notRecording`:
    /// the link genuinely IS up, so claiming "Strap not connected" would be false.
    case connectedNoData

    /// The chip's short label. Verbatim spec copy; the dynamic "Xm" goes into the LocalizedStringKey slot.
    var label: LocalizedStringKey {
        switch self {
        case .recording:                 return "Recording"
        case .lastSynced(let mins):      return "Last synced \(mins)m ago"
        case .notRecording:              return "Not recording"
        case .historyExperimental:       return "Connected"
        case .connectedNoData:           return "Connected"
        }
    }

    /// The supporting detail line. Verbatim spec copy.
    var detail: LocalizedStringKey {
        switch self {
        case .recording:           return "Your strap is connected and saving data."
        case .lastSynced:          return "Reconnect to pull the latest."
        case .notRecording:        return "Strap not connected. Tap to connect."
        case .historyExperimental: return "History sync is experimental on 5.0."
        case .connectedNoData:     return "No live heart rate or synced history yet this session."
        }
    }

    /// VoiceOver plain string (label + detail).
    var accessibilityText: String {
        switch self {
        case .recording:
            return String(localized: "Recording. Your strap is connected and saving data.")
        case .lastSynced(let mins):
            return String(localized: "Last synced \(mins) minutes ago. Reconnect to pull the latest.")
        case .notRecording:
            return String(localized: "Not recording. Strap not connected. Tap to connect.")
        case .historyExperimental:
            return String(localized: "Connected. History sync is experimental on 5.0.")
        case .connectedNoData:
            return String(localized: "Connected. No live heart rate or synced history yet this session.")
        }
    }

    /// PURE mapper (unit-testable), `recording` IFF (connected AND a live heart-rate sample is currently
    /// present). A connection with no live HR yet (handshaking, no PPG, strap off the wrist) is honestly
    /// NOT recording — but a genuinely connected strap that has never once synced, or one whose recent
    /// offloads are a SUSTAINED streak of empty (`sustainedEmptyOffload`, #612), still IS connected, so
    /// it reads `.connectedNoData` rather than the false "Strap not connected". Otherwise, if a last-sync
    /// time is known, reads "Last synced Xm ago"; else "Not recording". `lastSyncedAt` / `now` are unix
    /// seconds; the minute count clamps at >= 0 (strap-clock skew can't read negative) and uses ceil so a
    /// 30-second-old sync reads "1m ago" rather than "0m ago". Mirror EXACTLY in Kotlin.
    static func resolve(connected: Bool,
                        heartRate: Int?,
                        lastSyncedAt: TimeInterval?,
                        sustainedEmptyOffload: Bool = false,
                        now: TimeInterval = Date().timeIntervalSince1970) -> RecordingState {
        if connected && heartRate != nil { return .recording }
        if connected && heartRate == nil && (lastSyncedAt == nil || sustainedEmptyOffload) {
            return .connectedNoData
        }
        if let at = lastSyncedAt {
            let secs = max(0, now - at)
            let mins = Int((secs / 60).rounded(.up))
            return .lastSynced(minutesAgo: mins)
        }
        return .notRecording
    }
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
