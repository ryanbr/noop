import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights
//
// The headline "interrogate what affects what" screen. Two halves:
//
//  1. BEHAVIOUR EFFECTS, split your logged journal answers (Alcohol, Caffeine,
//     Late meal, Meditation…) into the days each behaviour WAS logged vs NOT, then
//     compare a chosen outcome metric (Recovery / HRV / Sleep performance / RHR)
//     between the two groups. Ranked by effect size (Cohen's d) with significant
//     effects first; each card carries the plain-English sentence, the with/without
//     means, group counts, a significance pill, and the effect-size magnitude.
//     Tint is sign-aware: a behaviour that moves the outcome the "good" way
//     (respecting higherIsBetter) is positive/green, the "bad" way is critical/red.
//
//  2. METRIC RELATIONSHIPS, a curated set of Pearson correlations between daily
//     series (sleep ↔ recovery, today's strain ↔ next-day recovery via a 1-day lag,
//     HRV ↔ recovery, RHR ↔ recovery), each rendered as a one-line insight with r
//     and a plain-English reading of strength + direction.
//
// All math comes from StrandAnalytics (BehaviorInsights / CorrelationEngine); this
// view only loads the series, shapes them, and presents. Empty state via ComingSoon
// when there is no journal data to interrogate.

/// `.task(id:)` key for the Insights journal load: the data-refresh sequence plus today's day-key, so the
/// load re-runs both on a data change and on a calendar-day rollover (#860 item 4).
private struct InsightsLoadKey: Equatable {
    let seq: Int
    let dayKey: String
}

/// #833 (Insights freeze): the snapshot InsightsView.load() builds, parked on the long-lived Repository so a
/// re-mount (macOS keys the NavigationSplitView detail with `.id`, so every sidebar switch cold-mounts the
/// screen) can RESTORE it in-memory instead of re-running the full history read on the @MainActor. The exact
/// twin of Today's `TodayHistoryWideCache` for #849; holds load()'s six computed outputs. Consumed only when
/// the seq AND the dayKey still match (see `Repository.insightsLoadedSeq` / `insightsLoadedDayKey`).
struct InsightsLoadCache {
    let behaviours: [String: Set<String>]
    let importedQuestions: [String]
    let dayAnswers: [String: Bool]
    /// The journal day offset the `dayAnswers` were read for (0 = today, 1 = yesterday, -1 = tomorrow). The
    /// restore guards on it so a re-mount, which resets `journalDayOffset` to 0, only reuses the cache when
    /// the cached answers match that reset day, otherwise it falls through to a fresh read (#833).
    let journalDayOffset: Int
    let outcomeByKey: [String: [String: Double]]
    let seriesByKey: [String: [(day: String, value: Double)]]
    let activityCosts: [ActivityCost]
    /// #322: per-question numeric journal series (question → [day: value]) for numeric journal items
    /// (e.g. "caffeine mg", "alcohol units"). A numeric series feeds the same effect ranker the metric
    /// outcomes do, so a numeric behaviour can rank in Insights. Empty for a yes/no-only journal.
    let numericJournalByKey: [String: [String: Double]]
}

struct InsightsView: View {
    @EnvironmentObject var repo: Repository
    /// Deep-link into the v5 "What moves you" hub (the n-of-1 ranked-effect + dose-response surface).
    @EnvironmentObject var router: NavRouter
    /// #860 item 4: foreground signal for the day-rollover re-load (see `currentDayKey`).
    @Environment(\.scenePhase) private var scenePhase

    // MARK: Selected outcome (segmented)

    /// One interrogable outcome metric: how to fetch it and how to read its direction.
    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }

        /// Short segment label.
        var label: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return "RHR"
            }
        }
        /// The metricSeries key (source is always "my-whoop" for these).
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The human outcome name used by BehaviorInsights.sentence.
        var outcomeName: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return String(localized: "Resting HR")
            }
        }
        /// Whether a higher value is the "good" direction (drives tint).
        var higherIsBetter: Bool {
            switch self {
            case .recovery, .hrv, .sleep: return true
            case .rhr:                    return false
            }
        }
        /// The Bevel colour world each outcome belongs to, Charge→green, HRV→Rest
        /// (periwinkle, the HRV world), Rest→indigo, RHR→Stress (teal). Drives the
        /// section's domain accent + the segmented selection's wash.
        var domain: DomainTheme {
            switch self {
            case .recovery: return .charge
            case .hrv:      return .rest
            case .sleep:    return .rest
            case .rhr:      return .stress
            }
        }
    }

    /// One personal-experiment window length (and the matching baseline span).
    private enum ExperimentLength: Int, CaseIterable, Identifiable {
        case oneWeek = 7
        case twoWeeks = 14
        case fourWeeks = 28

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .oneWeek:  return String(localized: "7d")
            case .twoWeeks: return String(localized: "14d")
            case .fourWeeks: return String(localized: "28d")
            }
        }
    }

    @State private var outcome: Outcome = .recovery

    // MARK: Personal-experiment state (LOCAL ONLY, UserDefaults-backed, single user)
    //
    // A running n-of-1 plan: one behaviour, one outcome, a short window. All five
    // keys mirror the Android SharedPreferences keys (InsightsScreen.kt) for parity.
    @AppStorage("noop.experiment.behaviour")    private var experimentBehaviour = ""
    @AppStorage("noop.experiment.outcome")      private var experimentOutcomeRaw = Outcome.recovery.rawValue
    @AppStorage("noop.experiment.startedDay")   private var experimentStartedDay = ""
    @AppStorage("noop.experiment.durationDays") private var experimentDurationDays = ExperimentLength.twoWeeks.rawValue
    @AppStorage("noop.experiment.baselineDays") private var experimentBaselineDays = ExperimentLength.twoWeeks.rawValue

    /// The journal catalog, read for `hiddenQuestions` so a behaviour the user has
    /// hidden never resurfaces as an eligible experiment candidate (triage fix b).
    @StateObject private var catalog = JournalCatalogStore()

    // MARK: Loaded state

    /// behaviour question → set of days where it was answered yes.
    @State private var behaviours: [String: Set<String>] = [:]
    /// outcome key → [day: value].
    @State private var outcomeByKey: [String: [String: Double]] = [:]
    /// outcome key → ordered (day, value) series for correlations.
    @State private var seriesByKey: [String: [(day: String, value: Double)]] = [:]
    /// #322: numeric journal item (question) → [day: value]. A numeric journal series is a daily
    /// series the effect ranker can consume exactly like a metric series (it already ranks metrics),
    /// so "caffeine mg" / "alcohol units" can rank as a numeric outcome in Insights. Empty for a
    /// yes/no-only journal.
    @State private var numericJournalByKey: [String: [String: Double]] = [:]
    @State private var loaded = false

    // MARK: Memoized derived state
    //
    // The ranking and correlations are expensive (BehaviorInsights.rank +
    // four Pearson correlations) and were previously recomputed inside `body`
    // on EVERY render, including hover/animation/1Hz HR ticks. Cache them in
    // @State and recompute only when their inputs change.

    /// Ranked behaviour effects for the current outcome, recomputed via
    /// recomputeRanked() only when behaviours / outcomeByKey / outcome change.
    @State private var ranked: [BehaviorEffect] = []
    /// Curated metric relationships, recomputed via recomputeRelationships()
    /// only when the loaded series change.
    @State private var relationships: [Relationship] = []

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    // MARK: Native-logging state for the journal card

    /// Ranked activity-recovery costs (#439). Computed at load via ActivityCostEngine over the tagged
    /// activity days and daily Charge; empty when nothing clears the engine's minSessions gate.
    @State private var activityCosts: [ActivityCost] = []

    /// Distinct imported question strings, so the card adopts the export's exact wording.
    @State private var importedQuestions: [String] = []
    /// The selected day's native answers (question → answeredYes), drives the chip state.
    @State private var dayAnswers: [String: Bool] = [:]
    /// The selected day's native numeric values (question → value), drives the numeric fields (#322).
    @State private var dayNumeric: [String: Double] = [:]
    /// -1 = tomorrow (log ahead), 0 = today, 1 = yesterday (late logging).
    @State private var journalDayOffset = 0
    /// #860 item 4: today's local calendar-day key, captured on appear and refreshed on foreground. The
    /// journal day chips ("Today"/"Yesterday"/"Tomorrow") are relative to the CURRENT date, but the
    /// answers (`dayAnswers`) and the resolved day key are derived from `Date()` only inside `load()`,
    /// which re-runs on `repo.refreshSeq`. A day can pass with the screen alive and no data refresh (the
    /// app simply backgrounded overnight), so without re-keying on this the previous day's answers stayed
    /// pinned under "Today" instead of the new day starting blank. Folding it into the `.task(id:)` key
    /// re-runs the load the moment the date rolls over, so "Today" always resolves to the live day and
    /// prior answers move to their real date. Local CALENDAR day (matches the journal's `localDayKey`).
    @State private var currentDayKey = Repository.localDayKey(Date())

    var body: some View {
        ScreenScaffold(title: "Insights", subtitle: "Interrogate what affects what.",
                       // PERF (scroll): lazy column, byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so any nested
                       // staggered reveals are unchanged; this only defers building that stack on scroll-in.
                       lazy: true,
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Insights sits in one atmosphere ("the options change, not the page").
                       // Static + non-interactive; the cards below sit on the opaque canvas and stay legible.
                       topBackground: liquidScaffoldSky()) {
            if !loaded {
                ComingSoon(what: "Reading your journal and outcomes…")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    // v5: a single row into the "What moves you" hub, the lag-aware ranked-effect feed
                    // + alcohol/caffeine dose-response. Reachable as its own destination too; this is the
                    // honest in-Insights entry point.
                    whatMovesYouLink
                    // Native logging, always reachable: the account-free way into Insights.
                    JournalLogCard(importedQuestions: importedQuestions,
                                   answers: dayAnswers,
                                   numericAnswers: dayNumeric,
                                   dayOffset: $journalDayOffset,
                                   onChanged: { Task { await load() } })
                    // Mind, daily mood check-in + mood↔body correlations.
                    // Self-contained (owns its own load/state); sits with the
                    // journal card so the two daily-logging surfaces read as one
                    // "log today" block above the derived insights.
                    MindSection()
                    // Caffeine window (#526), log an intake + a rough on-device "still active" hint.
                    // Self-contained (owns its own UserDefaults-backed store); sits in the same
                    // "log today" block. Opt-in: shows nothing until the user logs an intake.
                    CaffeineLogCard()
                    experimentSection
                    if behaviours.isEmpty {
                        // No journal yet, explain, without dead-ending on a paid export.
                        NoopCard {
                            Text("Log behaviours above. After a few days of answers, NOOP ranks how each one moves your charge, HRV and rest. Importing a WHOOP export (which includes its journal) backfills history instantly.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        behaviourSection
                    }
                    activityCostSection
                    relationshipsSection
                }
            }
        }
        // #860 item 4: key on the data-refresh seq AND today's day-key, so the journal re-loads both on a
        // data change and the moment the calendar day rolls over (driven by the foreground/appear refresh
        // of `currentDayKey` below), so yesterday's answers leave "Today" and the new day starts fresh.
        .task(id: InsightsLoadKey(seq: repo.refreshSeq, dayKey: currentDayKey)) { await load(allowCache: true) }
        // Recompute the cached ranking only when the outcome selection changes.
        // (behaviours / outcomeByKey change only at load, which calls
        //  recomputeRanked() directly, so keying on `outcome` is sufficient.)
        .onChangeCompat(of: outcome) { _ in recomputeRanked() }
        // Refresh the day anchor on appear and whenever the app returns to the foreground; if the date has
        // advanced this bumps the `.task(id:)` key and the journal reloads for the new logical day (#860).
        .onAppear {
            refreshCurrentDayKey()
            // #656: honour a day the Today journal widget deep-linked to (tapping a bar opens the journal
            // at THAT day). Consumed once on arrival, then cleared. Reload explicitly — setting the offset
            // here doesn't run the pill's onChanged, and the `.task` keys on the day-key, not the offset.
            if let day = router.pendingJournalDayOffset {
                journalDayOffset = day
                router.pendingJournalDayOffset = nil
                Task { await load() }
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active { refreshCurrentDayKey() }
        }
    }

    /// Re-stamp `currentDayKey` to today's local calendar day. A no-op while the day is unchanged; when the
    /// date has rolled over it flips the value, which re-keys the journal load so the chips' "Today" and the
    /// answers behind them snap to the new day (#860 item 4).
    private func refreshCurrentDayKey() {
        let key = Repository.localDayKey(Date())
        if key != currentDayKey { currentDayKey = key }
    }

    /// The deep-link row into the v5 "What moves you" hub.
    private var whatMovesYouLink: some View {
        Button { router.openInsightsHub() } label: {
            NoopCard(tint: StrandPalette.chargeColor) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        // WHOOP tappable-card title: UPPERCASE tracked white + trailing "›" chevron
                        // glyph (mirrors "HEALTH MONITOR ›"). The descriptive line stays beneath.
                        Text("WHAT MOVES YOU \u{203A}")
                            .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Ranked, lag-aware: which of your habits actually move your Charge, plus your personal alcohol/caffeine dose-response.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        // Liquid tap response: the same physical settle-inward every tappable liquid card gets.
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What moves you. Ranked patterns in your own data, and your dose-response.")
    }

    // MARK: - Load

    /// Load the journal + outcome series + activity costs.
    ///
    /// #833 (Insights freeze): on macOS the NavigationSplitView detail is keyed with `.id` (RootView), so
    /// every sidebar switch DESTROYS and cold-mounts this view, tearing down its `@State`. Without a cache
    /// each visit re-ran the full history read on the @MainActor, which is the freeze. Mirroring Today's #849
    /// remount cache, when `allowCache` is set and the live data state is unchanged
    /// (`repo.insightsLoadedSeq == repo.refreshSeq` AND the same dayKey) we RESTORE the prior snapshot from
    /// the long-lived `repo` instead of re-querying. `allowCache` is true ONLY on the `.task(id:)`-driven
    /// path (a re-mount / data-refresh / day-rollover); the direct write-then-reload sites (journal toggle,
    /// experiment mark) leave it false so a change that doesn't bump `refreshSeq` always re-reads.
    private func load(allowCache: Bool = false) async {
        // #833: same-state re-mount → restore from the repo-level cache (no store queries). The dayKey guard
        // mirrors the `.task(id:)` key so a day-rollover still re-loads even at an unchanged seq.
        if allowCache,
           repo.insightsLoadedSeq == repo.refreshSeq,
           repo.insightsLoadedDayKey == currentDayKey,
           let cached = repo.insightsCache,
           cached.journalDayOffset == journalDayOffset {
            restoreFromCache(cached)
            return
        }

        // Journal → behaviours map (only "yes" answers count as the behaviour occurring).
        // journalEntries() is the imported ∪ native union (native wins per day+question). A numeric
        // log writes answeredYes=true too (#322), so a numeric item lands in the with/without split
        // here unchanged, on top of the numeric series read below.
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        var numericByBehaviour: [String: [String: Double]] = [:]
        for e in entries where e.answeredYes {
            byBehaviour[e.question, default: []].insert(e.day)
        }
        // #322: per-question numeric series (question → [day: value]) for numeric journal items. A
        // numeric series is the same [day: value] shape a metric outcome is, so the effect ranker can
        // consume it directly (dose-response lands in the v5 hub). Additive: yes/no-only journals
        // never populate this, so the boolean effect cards are untouched.
        for e in entries {
            if let v = e.numericValue { numericByBehaviour[e.question, default: [:]][e.day] = v }
        }

        // The logging card's inputs: the export's exact question strings (so logged days join
        // imported history) and the selected day's native chip state, a targeted read, since the
        // merged list carries no deviceId to filter on.
        let imported = await repo.importedJournalEntries()
        let importedQs = NSOrderedSet(array: imported.map(\.question)).array as? [String] ?? []
        let selectedDayKey = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -journalDayOffset, to: Date()) ?? Date())
        let nativeAnswers = await repo.nativeJournalAnswers(day: selectedDayKey)
        let nativeNumeric = await repo.nativeJournalNumeric(day: selectedDayKey)

        // Daily metrics for the strap-only outcome fallback (merged, imported-wins). The view is
        // MainActor-isolated, so reading the published cache here is on the right actor.
        let mergedDays = repo.days

        // Outcome series (Whoop) → both [day:value] dictionaries and ordered series. The imported
        // metricSeries only exists after a CSV import; fill the days it doesn't cover from the
        // merged daily metrics so an account-free user's logging still gets effects
        // (recovery/hrv/rhr have daily columns; sleep_performance stays import-only).
        var byKey: [String: [String: Double]] = [:]
        var seriesMap: [String: [(day: String, value: Double)]] = [:]
        for key in outcomeKeys {
            let s = await repo.series(key: key, source: "my-whoop")
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                if let v = Self.dailyOutcome(key: key, day: d) { dict[d.day] = v }
            }
            byKey[key] = dict
            seriesMap[key] = dict.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
        }

        // #322: fold each numeric journal item's series into the same day→value maps the effect ranker
        // consumes, under a namespaced "journal.numeric:<question>" key so it never collides with the
        // four fixed metric outcomes. This makes a numeric journal series (caffeine mg, alcohol units)
        // a first-class series the ranker/correlations can consume, exactly like a metric outcome; the
        // four boolean effect cards key on Outcome.key only, so they are untouched.
        for (question, series) in numericByBehaviour {
            let namespaced = Self.numericJournalKey(question)
            byKey[namespaced] = series
            seriesMap[namespaced] = series.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
        }

        // Activity Cost (#439): shape the engine's inputs in the VIEW, not the engine. From the loaded
        // sessions build [sport: Set<localDayKey>], collapsing detected/"Activity" into one bucket via
        // displaySport, keeping manual/imported labels, keyed by the LOCAL calendar day the session
        // STARTED (the same local-day calendar DailyMetric.day uses, so the engine's D+1 alignment is
        // honest). The recovery side is [localDayKey: Charge] off the merged DailyMetric.recovery.
        let costs = Self.computeActivityCosts(workouts: await repo.workoutRows(), days: mergedDays)

        await MainActor.run {
            self.behaviours = byBehaviour
            self.importedQuestions = importedQs
            self.dayAnswers = nativeAnswers
            self.dayNumeric = nativeNumeric
            self.outcomeByKey = byKey
            self.seriesByKey = seriesMap
            self.numericJournalByKey = numericByBehaviour
            self.activityCosts = costs
            self.loaded = true
            // Seed the memoized derived state from the freshly loaded inputs.
            self.recomputeRanked()
            self.recomputeRelationships()
            // #833: snapshot what we just read onto the long-lived `repo`, keyed by the seq + dayKey we
            // loaded for, so a later same-state re-mount restores it in-memory instead of re-querying. This
            // ALSO runs on the direct (non-cached) write-then-reload sites, so the cache always reflects the
            // freshest read, a subsequent re-mount never restores stale data behind a journal toggle.
            self.repo.insightsCache = InsightsLoadCache(
                behaviours: byBehaviour,
                importedQuestions: importedQs,
                dayAnswers: nativeAnswers,
                journalDayOffset: self.journalDayOffset,
                outcomeByKey: byKey,
                seriesByKey: seriesMap,
                activityCosts: costs,
                numericJournalByKey: numericByBehaviour)
            self.repo.insightsLoadedSeq = self.repo.refreshSeq
            self.repo.insightsLoadedDayKey = self.currentDayKey
        }
    }

    /// #833: restore the loaded snapshot from a same-state `repo` cache on a re-mount, so the screen repaints
    /// from memory without re-running the heavy load. Sets the same `@State` and re-seeds the same memoized
    /// derived state as the first-load `MainActor.run` block above, byte-identical screen, no store queries.
    @MainActor
    private func restoreFromCache(_ c: InsightsLoadCache) {
        behaviours = c.behaviours
        importedQuestions = c.importedQuestions
        dayAnswers = c.dayAnswers
        // Numeric journal rows are native-only (imported WHOOP rows never carry a numericValue), so the
        // selected day's numeric fields can be derived from the cached per-question series (#322).
        let selectedDayKey = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -c.journalDayOffset, to: Date()) ?? Date())
        dayNumeric = c.numericJournalByKey.compactMapValues { $0[selectedDayKey] }
        outcomeByKey = c.outcomeByKey
        seriesByKey = c.seriesByKey
        numericJournalByKey = c.numericJournalByKey
        activityCosts = c.activityCosts
        loaded = true
        recomputeRanked()
        recomputeRelationships()
    }

    /// The merged DailyMetric column backing an outcome key, for days the imported metricSeries
    /// doesn't cover (strap-only users). sleep_performance has no daily column, so it stays
    /// import-only, never seeded here.
    private static func dailyOutcome(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }

    // MARK: - Activity Cost input shaping (#439)
    //
    // The engine is pure + unit-tested; ALL the DB→input shaping lives here in the view. Sessions
    // become [sport: Set<localDayKey>] and the merged daily metrics become [localDayKey: Charge], then
    // ActivityCostEngine.evaluate ranks the per-sport recovery cost. Keying both sides on the LOCAL
    // calendar day (DailyMetric.day's calendar) keeps the engine's D+1 next-morning lookups aligned.

    // `internal` (not private) so the Workouts post-log note (#439) reuses the exact same input
    // shaping rather than duplicating it, one source of truth for [sport: days] / [day: Charge].
    static func computeActivityCosts(workouts: [WorkoutRow], days: [DailyMetric]) -> [ActivityCost] {
        // Local-day offset so the activity day key lands on the SAME calendar as DailyMetric.day
        // (which IntelligenceEngine/WhoopImporter both bucket by local midnight, #277).
        let tzOffset = TimeZone.current.secondsFromGMT()
        var activityDaysBySport: [String: Set<String>] = [:]
        for w in workouts {
            // displaySport collapses the detector's "detected" token into one "Activity" bucket and
            // de-camelCases WHOOP sport names; manual/imported labels pass through unchanged.
            let sport = WorkoutSource.displaySport(w.sport)
            guard !sport.isEmpty else { continue }
            let day = AnalyticsEngine.dayString(w.startTs, offsetSec: tzOffset)
            activityDaysBySport[sport, default: []].insert(day)
        }
        var recoveryByDay: [String: Double] = [:]
        for d in days {
            if let r = d.recovery { recoveryByDay[d.day] = r }
        }
        return ActivityCostEngine.evaluate(activityDaysBySport: activityDaysBySport,
                                           recoveryByDay: recoveryByDay)
    }

    // MARK: - Memoized recomputation

    /// Rebuild the cached behaviour ranking for the current inputs.
    /// Called at load and whenever `outcome` changes, NOT in `body`.
    private func recomputeRanked() {
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = BehaviorInsights.rank(
            behaviors: behaviours,
            outcomeByDay: outcomeDays,
            outcome: outcome.outcomeName
        )
    }

    /// Rebuild the cached metric relationships from the loaded series.
    /// Called at load only, the series don't change after that.
    private func recomputeRelationships() {
        relationships = computeRelationships()
    }

    // MARK: - Personal experiment section
    //
    // A LOCAL-ONLY n-of-1 protocol: pick ONE behaviour you actually log, one outcome,
    // and a short window, then compare the outcome on days you logged the behaviour
    // (the intervention) against your behaviour-ABSENT days before the start (the
    // baseline). The absent-day baseline mirrors the with/without model used by the
    // Behaviour Effects section above, so "Baseline" vs "Intervention" is an honest
    // present-vs-absent contrast rather than a raw pre/post window. Nothing leaves the
    // device: state is @AppStorage and "Mark done" writes a normal journal answer.

    private var experimentSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Personal Experiment",
                          overline: "N-of-1 protocol",
                          trailing: activeExperimentSnapshot?.phaseLabel ?? String(localized: "Setup"))
            NoopCard {
                if let snapshot = activeExperimentSnapshot {
                    activeExperimentCard(snapshot)
                } else {
                    experimentSetupCard
                }
            }
        }
    }

    @ViewBuilder private var experimentSetupCard: some View {
        let candidates = experimentCandidates
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run a clean personal test")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Pick one behaviour you log, one outcome, and a short window. NOOP compares the days you log the behaviour against your behaviour-free days before the start.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                StatePill("LOCAL ONLY", tone: .neutral, showsDot: false)
            }

            if candidates.isEmpty {
                Text("Log at least one behaviour above before starting an experiment.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    experimentField("Behaviour") {
                        Picker("Behaviour", selection: experimentBehaviourBinding) {
                            ForEach(candidates, id: \.self) { q in
                                Text(verbatim: q).tag(q)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Experiment behaviour")
                    }
                    experimentField("Outcome") {
                        SegmentedPillControl(Outcome.allCases, selection: experimentOutcomeBinding) { $0.label }
                            .accessibilityLabel("Experiment outcome metric")
                    }
                    experimentField("Window") {
                        SegmentedPillControl(ExperimentLength.allCases,
                                             selection: experimentLengthBinding) { $0.label }
                            .accessibilityLabel("Experiment window length")
                    }
                }

                NoopButton("Start experiment", systemImage: "flask.fill",
                           kind: .primary, fullWidth: true) { startExperiment() }
                    .disabled(resolvedExperimentBehaviour == nil)
                    .help("Start a local experiment using today's date as day one.")
            }
        }
    }

    private func activeExperimentCard(_ snapshot: ExperimentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: snapshot.behavior)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                    Text("Started \(snapshot.startDay) · testing \(snapshot.outcome.outcomeName.lowercased())")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 12)
                StatePill(LocalizedStringKey(snapshot.phaseLabel), tone: snapshot.phaseTone,
                          pulsing: snapshot.daysElapsed < snapshot.durationDays)
            }

            Text(experimentReading(snapshot))
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 154), spacing: NoopMetrics.gap)],
                alignment: .leading,
                spacing: NoopMetrics.gap
            ) {
                experimentMeasure("Baseline",
                                  value: snapshot.baselineMean.map { formatOutcome($0, as: snapshot.outcome) } ?? "—",
                                  caption: String(localized: "\(snapshot.baselineCount) days without it"),
                                  tint: StrandPalette.textSecondary)
                experimentMeasure("Intervention",
                                  value: snapshot.interventionMean.map { formatOutcome($0, as: snapshot.outcome) } ?? "—",
                                  caption: String(localized: "\(snapshot.interventionCount) logged days"),
                                  tint: StrandPalette.accent)
                experimentMeasure("Change",
                                  value: formatExperimentDelta(snapshot.delta, outcome: snapshot.outcome),
                                  caption: snapshot.deltaCaption,
                                  tint: experimentDeltaColor(snapshot))
                experimentMeasure("Compliance",
                                  value: "\(Int(snapshot.compliance.rounded()))%",
                                  caption: snapshot.loggedToday ? String(localized: "logged today") : String(localized: "not logged today"),
                                  tint: snapshot.loggedToday ? StrandPalette.statusPositive : StrandPalette.statusWarning)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Liquid progress: the experiment window as a filling LiquidTube (the same horizontal
                // vessel Today's Key Metrics + workout bars use) rather than a flat ProgressView. Static
                // (no live slosh needed for a progress read); carries the same a11y label + value.
                LiquidTube(frac: snapshot.progress, tint: StrandPalette.accent, height: 8, animated: false)
                    .accessibilityLabel("Experiment progress")
                    .accessibilityValue("\(snapshot.daysElapsed) of \(snapshot.durationDays) days")
                HStack {
                    Text("\(snapshot.daysElapsed) of \(snapshot.durationDays) days")
                    Spacer()
                    StatePill(LocalizedStringKey(snapshot.confidence.label),
                              tone: snapshot.confidence.tone,
                              showsDot: false)
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            }

            HStack(spacing: NoopMetrics.rowSpacing) {
                Button { Task { await markExperimentToday(true) } } label: {
                    Label("Mark done today", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(snapshot.loggedToday)

                Button { Task { await markExperimentToday(false) } } label: {
                    Label("Skip today", systemImage: "xmark.circle")
                }
                .buttonStyle(NoopButtonStyle(.secondary))

                Spacer(minLength: 8)

                Button(role: .destructive) { endExperiment() } label: {
                    Label("End", systemImage: "stop.circle")
                }
                .buttonStyle(NoopButtonStyle(.destructive))
                .help("End the experiment plan. Journal and metric history stay untouched.")
            }
        }
    }

    private func experimentField<Content: View>(_ title: LocalizedStringKey,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(NoopPanelSurface(cornerRadius: 8))
    }

    private func experimentMeasure(_ label: LocalizedStringKey,
                                   value: String,
                                   caption: String,
                                   tint: Color) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Text(value)
                .font(StrandFont.number(22))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(caption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(NoopPanelSurface(tint: tint, cornerRadius: 8))
    }

    /// Behaviours the user actually has data for: distinct logged journal questions
    /// (`behaviours.keys`) ∪ imported-export questions, minus the catalog's hidden set.
    /// Triage fix (a)/(b): we do NOT route this through `mergeCatalog`, which would inject
    /// the whole starter catalog (and re-surface hidden behaviours) as eligible, so the
    /// empty-state guard is real and only behaviours with history can be tested.
    private var experimentCandidates: [String] {
        let saved = experimentBehaviour.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = Set(catalog.hiddenQuestions.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        // Logged behaviours first (most relevant), then imported wording, then the saved
        // selection so an in-flight pick never vanishes mid-edit.
        let raw = behaviours.keys.sorted() + importedQuestions + (saved.isEmpty ? [] : [saved])
        var seen = Set<String>()
        var out: [String] = []
        for q in raw {
            let t = q.trimmingCharacters(in: .whitespaces)
            let key = t.lowercased()
            if !t.isEmpty, !hidden.contains(key), seen.insert(key).inserted { out.append(t) }
        }
        return out
    }

    private var resolvedExperimentBehaviour: String? {
        let candidates = experimentCandidates
        let saved = experimentBehaviour.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty, candidates.contains(saved) { return saved }
        return candidates.first
    }

    private var experimentBehaviourBinding: Binding<String> {
        Binding(
            get: { resolvedExperimentBehaviour ?? "" },
            set: { experimentBehaviour = $0 }
        )
    }

    private var experimentOutcomeBinding: Binding<Outcome> {
        Binding(
            get: { Outcome(rawValue: experimentOutcomeRaw) ?? .recovery },
            set: { experimentOutcomeRaw = $0.rawValue }
        )
    }

    private var experimentLengthBinding: Binding<ExperimentLength> {
        Binding(
            get: { ExperimentLength(rawValue: experimentDurationDays) ?? .twoWeeks },
            set: { experimentDurationDays = $0.rawValue }
        )
    }

    private var activeExperimentSnapshot: ExperimentSnapshot? {
        guard !experimentStartedDay.isEmpty,
              let outcome = Outcome(rawValue: experimentOutcomeRaw),
              let behavior = resolvedExperimentBehaviour
        else { return nil }

        let today = Repository.localDayKey(Date())
        let duration = max(1, experimentDurationDays)
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        let loggedDays = behaviours[behavior] ?? []

        // Baseline = behaviour-ABSENT days BEFORE the start (with/without model, matching
        // Behaviour Effects). Restricting to absent days is triage fix (c): "Baseline" vs
        // "Intervention" is now an honest present-vs-absent contrast, not a raw pre/post window.
        let baselineDays = outcomeDays.keys
            .filter { $0 < experimentStartedDay && !loggedDays.contains($0) }
            .sorted()
            .suffix(max(1, experimentBaselineDays))
        // Intervention = the first `duration` outcome days in the window where the behaviour
        // WAS logged.
        let interventionWindow = outcomeDays.keys
            .filter { $0 >= experimentStartedDay && $0 <= today }
            .sorted()
            .prefix(duration)
        let interventionDays = interventionWindow.filter { loggedDays.contains($0) }

        let baselineValues = baselineDays.compactMap { outcomeDays[$0] }
        let interventionValues = interventionDays.compactMap { outcomeDays[$0] }
        let daysElapsed = max(1, min(duration, dayDistance(from: experimentStartedDay, to: today) + 1))
        let complianceFraction = Double(interventionDays.count) / Double(max(daysElapsed, 1))
        let confidence = experimentConfidence(baselineCount: baselineValues.count,
                                              interventionCount: interventionValues.count,
                                              compliance: complianceFraction)

        return ExperimentSnapshot(
            behavior: behavior,
            outcome: outcome,
            startDay: experimentStartedDay,
            durationDays: duration,
            daysElapsed: daysElapsed,
            baselineMean: Self.mean(baselineValues),
            baselineCount: baselineValues.count,
            interventionMean: Self.mean(interventionValues),
            interventionCount: interventionValues.count,
            loggedToday: loggedDays.contains(today),
            compliance: complianceFraction * 100,
            confidence: confidence
        )
    }

    private func startExperiment() {
        guard let behavior = resolvedExperimentBehaviour else { return }
        experimentBehaviour = behavior
        if ExperimentLength(rawValue: experimentDurationDays) == nil {
            experimentDurationDays = ExperimentLength.twoWeeks.rawValue
        }
        if Outcome(rawValue: experimentOutcomeRaw) == nil {
            experimentOutcomeRaw = Outcome.recovery.rawValue
        }
        experimentBaselineDays = experimentDurationDays
        experimentStartedDay = Repository.localDayKey(Date())
    }

    private func endExperiment() {
        experimentStartedDay = ""
    }

    private func markExperimentToday(_ answeredYes: Bool) async {
        guard let behavior = activeExperimentSnapshot?.behavior else { return }
        await repo.saveJournalAnswer(day: Repository.localDayKey(Date()),
                                     question: behavior,
                                     answeredYes: answeredYes)
        await load()
    }

    private func experimentConfidence(baselineCount: Int,
                                      interventionCount: Int,
                                      compliance: Double) -> ExperimentConfidence {
        let pairedCount = min(baselineCount, interventionCount)
        if pairedCount >= 10, compliance >= 0.65 {
            return .init(label: String(localized: "STRONGER SIGNAL"), tone: .positive)
        }
        if pairedCount >= 5 {
            return .init(label: String(localized: "EARLY SIGNAL"), tone: .accent)
        }
        return .init(label: String(localized: "LOW SIGNAL"), tone: .warning)
    }

    private func experimentReading(_ snapshot: ExperimentSnapshot) -> String {
        guard let delta = snapshot.delta else {
            return String(localized: "Collect a few logged intervention days before reading the effect. Baseline and imported metrics stay in place.")
        }
        let absDelta = formatExperimentDelta(abs(delta), outcome: snapshot.outcome, includeSign: false)
        if abs(delta) < 0.05 {
            return String(localized: "\(snapshot.outcome.outcomeName) is flat against baseline on logged intervention days.")
        }
        // Whole-phrase variants per direction so translators never see a stitched better/worse fragment.
        let movedGood = snapshot.outcome.higherIsBetter ? delta > 0 : delta < 0
        return movedGood
            ? String(localized: "\(snapshot.outcome.outcomeName) is \(absDelta) better than baseline on days you logged this behaviour.")
            : String(localized: "\(snapshot.outcome.outcomeName) is \(absDelta) worse than baseline on days you logged this behaviour.")
    }

    private func experimentDeltaColor(_ snapshot: ExperimentSnapshot) -> Color {
        guard let delta = snapshot.delta, abs(delta) >= 0.05 else {
            return StrandPalette.textTertiary
        }
        let movedGood = snapshot.outcome.higherIsBetter ? delta > 0 : delta < 0
        return movedGood ? StrandPalette.statusPositive : StrandPalette.statusCritical
    }

    private func formatExperimentDelta(_ delta: Double?,
                                       outcome: Outcome,
                                       includeSign: Bool = true) -> String {
        guard let delta else { return "—" }
        let prefix: String
        if includeSign {
            prefix = delta > 0 ? "+" : (delta < 0 ? "−" : "")
        } else {
            prefix = ""
        }
        let absDelta = abs(delta)
        switch outcome {
        case .recovery, .sleep:
            return "\(prefix)\(Int(absDelta.rounded()))%"
        case .hrv:
            return "\(prefix)\(Int(absDelta.rounded())) ms"
        case .rhr:
            return "\(prefix)\(Int(absDelta.rounded())) bpm"
        }
    }

    private func dayDistance(from start: String, to end: String) -> Int {
        guard let startDate = Self.dateFromDayKey(start),
              let endDate = Self.dateFromDayKey(end)
        else { return 0 }
        return Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The namespaced outcome key a numeric journal item's series is folded under (#322). Prefixed so
    /// it can never collide with a fixed metric outcome key. Pure + tested (mirrors Android).
    static func numericJournalKey(_ question: String) -> String { "journal.numeric:" + question }

    private struct ExperimentSnapshot {
        let behavior: String
        let outcome: Outcome
        let startDay: String
        let durationDays: Int
        let daysElapsed: Int
        let baselineMean: Double?
        let baselineCount: Int
        let interventionMean: Double?
        let interventionCount: Int
        let loggedToday: Bool
        let compliance: Double
        let confidence: ExperimentConfidence

        var progress: Double { min(1, Double(daysElapsed) / Double(max(durationDays, 1))) }
        var phaseLabel: String {
            daysElapsed >= durationDays ? String(localized: "COMPLETE")
                                        : String(localized: "DAY \(daysElapsed)/\(durationDays)")
        }
        var phaseTone: StrandTone { daysElapsed >= durationDays ? .positive : .accent }
        var delta: Double? {
            guard let interventionMean, let baselineMean else { return nil }
            return interventionMean - baselineMean
        }
        var deltaCaption: String {
            guard delta != nil else { return String(localized: "needs baseline + logged days") }
            return String(localized: "vs behaviour-free baseline")
        }
    }

    private struct ExperimentConfidence {
        let label: String
        let tone: StrandTone
    }

    // MARK: - Behaviour effects section

    private var behaviourSection: some View {
        // `ranked` is memoized in @State (see recomputeRanked()); reading it
        // here does no expensive work per render.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Keep the outcome labels intrinsic while they fit beside the header. When either
            // localization or Dynamic Type needs more room, move the control to its own row.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    SectionHeader("Behaviour Effects",
                                  overline: "What moves your \(outcome.outcomeName.lowercased())")
                    Spacer(minLength: NoopMetrics.space2)
                    behaviourOutcomeControl
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    SectionHeader("Behaviour Effects",
                                  overline: "What moves your \(outcome.outcomeName.lowercased())")
                    behaviourOutcomeControl
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if ranked.isEmpty {
                noEffects
            } else {
                ForEach(ranked.indices, id: \.self) { i in
                    effectCard(ranked[i])
                        .staggeredAppear(index: i)
                }
            }
        }
    }

    private var behaviourOutcomeControl: some View {
        SegmentedPillControl(Outcome.allCases, selection: $outcome,
                             adaptsToAvailableWidth: true) { $0.label }
            .accessibilityLabel("Outcome metric")
    }

    private var noEffects: some View {
        NoopCard {
            Text(String(localized: "Not enough overlap between your journal answers and \(outcome.outcomeName.lowercased()) to measure an effect yet. Keep logging. Effects need days both with and without each behaviour."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One behaviour-effect card: sentence + with/without StatTiles + significance pill.
    private func effectCard(_ e: BehaviorEffect) -> some View {
        // Sign-aware tint: did this behaviour move the outcome the GOOD way?
        // good move = (delta > 0 when higherIsBetter) OR (delta < 0 when lower is better).
        let movedGood: Bool? = {
            if e.delta == 0 { return nil }
            let up = e.delta > 0
            return up == outcome.higherIsBetter
        }()
        let tint: StrandTone = {
            guard let good = movedGood else { return .neutral }
            // Only let strong-tint shine when significant; weak effects read muted.
            if e.significant { return good ? .positive : .critical }
            return good ? .positive : .warning
        }()
        let tintColor = toneColor(tint)
        let deltaText: String = {
            let arrow = e.delta > 0 ? "↑" : (e.delta < 0 ? "↓" : "→")
            if let pct = e.pctChange { return "\(arrow) \(Int(abs(pct).rounded()))%" }
            return "\(arrow) \(String(format: "%.1f", abs(e.delta)))"
        }()
        // Build the plain-English sentence ONCE and reuse it for both the visible
        // copy and the accessibility label (was computed twice per card).
        let sentence = BehaviorInsights.sentence(e)

        // The card wash reads as the OUTCOME's colour world (so the whole Behaviour
        // Effects section sits in one world), while the dot / StatTile accents stay
        // sign-aware to flag the good/bad direction.
        return NoopCard(tint: outcome.domain.color) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {

                // Header: behaviour name + significance pill. The old direction dot becomes a small liquid
                // vessel filled to the effect magnitude (|Cohen's d|, capped where large is about 0.8+) in
                // the sign-aware tint, the leading-gauge idiom Today uses, so the strength reads at a glance.
                HStack(alignment: .center) {
                    HStack(spacing: 10) {
                        LiquidVessel(value: min(1, abs(e.cohensD) / 0.8), tint: tintColor, animated: false)
                            .frame(width: 26, height: 26)
                            .accessibilityHidden(true)
                        Text(e.behavior)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    StatePill(e.significant ? "SIGNIFICANT" : "EXPLORATORY",
                              tone: e.significant ? .positive : .neutral,
                              showsDot: false)
                }

                // Plain-English sentence.
                Text(sentence)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // With / without means as uniform StatTiles.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    StatTile(label: "With",
                             value: formatOutcome(e.meanWith),
                             caption: "n = \(e.nWith)",
                             accent: tintColor,
                             delta: deltaText,
                             deltaColor: tintColor)
                    StatTile(label: "Without",
                             value: formatOutcome(e.meanWithout),
                             caption: "n = \(e.nWithout)",
                             accent: StrandPalette.textPrimary)
                }

                Divider().overlay(StrandPalette.hairline)

                // Effect-size footer: Cohen's d + interpretation.
                HStack {
                    Text("Effect size").strandOverline()
                    Spacer()
                    HStack(spacing: 6) {
                        Text(String(format: "d = %.2f", e.cohensD))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(tintColor)
                        Text(effectMagnitudeWord(e.cohensD))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        // Whole-string key per variant (never a concatenated localized tail on an a11y label).
        .accessibilityLabel(e.significant
            ? String(localized: "\(sentence) Cohen's d \(String(format: "%.2f", e.cohensD)). Statistically significant.")
            : String(localized: "\(sentence) Cohen's d \(String(format: "%.2f", e.cohensD)). Exploratory, not yet significant."))
    }

    // MARK: - Metric relationships section

    // MARK: - Activity Cost section (#439)

    /// "What each activity costs your recovery": one ranked NoopCard per sport that cleared the
    /// engine's minSessions gate, each carrying next-morning Charge vs rest baseline, days-to-baseline,
    /// the sample count + confidence pill, and the engine's plain-English sentence. Sign-aware tint:
    /// a positive cost (recovery dipped) reads warmer/critical, a recovery-POSITIVE delta reads green.
    @ViewBuilder private var activityCostSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Activity Cost", overline: "What each activity costs your recovery")
            if activityCosts.isEmpty {
                NoopCard {
                    Text("Tag a few sessions of the same activity and NOOP will learn its personal recovery cost.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(activityCosts.enumerated()), id: \.element.sport) { index, cost in
                    activityCostCard(cost)
                        .staggeredAppear(index: index)
                }
            }
        }
    }

    private func activityCostCard(_ cost: ActivityCost) -> some View {
        // Sign-aware accent: a POSITIVE delta means the next morning sat BELOW baseline (it cost you)
        // → warm/critical; a negative delta means you woke higher → green. A near-zero cost reads
        // neutral gold so "barely moves" doesn't shout either way.
        let costing = cost.delta >= ActivityCostEngine.barelyMovesPoints
        let lifting = cost.delta <= -ActivityCostEngine.barelyMovesPoints
        let accent: Color = costing ? StrandPalette.statusCritical
            : (lifting ? StrandPalette.statusPositive : StrandPalette.chargeColor)
        let scoreState: ScoreState = cost.confidence == .solid ? .solid : .building
        let pointsLabel = String(format: "%@%.0f", cost.delta >= 0 ? "−" : "+", abs(cost.delta))

        return NoopCard(tint: accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: sportSymbol(cost.sport))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 20)
                    Text(cost.sport)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ScoreStatePill(scoreState)
                }
                Text(cost.sentence())
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                          alignment: .leading, spacing: NoopMetrics.gap) {
                    StatTile(label: "Next morning",
                             value: "\(Int(cost.meanNextMorning.rounded()))",
                             caption: String(localized: "Charge · \(pointsLabel) pts"),
                             accent: accent)
                    StatTile(label: "Rest baseline",
                             value: "\(Int(cost.baselineMean.rounded()))",
                             caption: String(localized: "untouched days"),
                             accent: StrandPalette.textPrimary)
                    StatTile(label: "Bounce back",
                             value: cost.daysToBaseline.map { "\($0)d" } ?? "—",
                             caption: cost.daysToBaseline != nil ? String(localized: "to baseline") : String(localized: "not within 7d"),
                             accent: StrandPalette.chargeColor)
                    StatTile(label: "Sessions",
                             value: "\(cost.n)",
                             caption: cost.confidence == .solid ? String(localized: "solid") : String(localized: "building"),
                             accent: StrandPalette.textPrimary)
                }
            }
        }
    }

    private var relationshipsSection: some View {
        // `relationships` is memoized in @State (see recomputeRelationships());
        // the four Pearson correlations no longer run per render.
        let rels = relationships
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Metric Relationships", overline: "Pearson r")

            if rels.isEmpty {
                NoopCard {
                    Text("Not enough overlapping history to correlate your metrics yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Every curated relationship terminates in Charge, so the card sits in
                // the Charge (green) colour world via a faint wash.
                NoopCard(tint: DomainTheme.charge.color) {
                    VStack(spacing: 0) {
                        ForEach(Array(rels.enumerated()), id: \.element.id) { idx, rel in
                            relationshipRow(rel)
                            if idx < rels.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A curated metric relationship plus its computed correlation.
    private struct Relationship: Identifiable {
        let id: String
        let title: String        // "Sleep → Recovery"
        let blurb: String        // what the pairing probes
        let corr: Correlation
    }

    private func computeRelationships() -> [Relationship] {
        func series(_ key: String) -> [(day: String, value: Double)] { seriesByKey[key] ?? [] }
        var out: [Relationship] = []

        // Sleep performance ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("sleep_performance"), series("recovery"))) {
            out.append(.init(id: "sleep-rec",
                             title: String(localized: "Rest ↔ Charge"),
                             blurb: String(localized: "How closely a good night tracks next-morning charge."),
                             corr: c))
        }
        // HRV ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("hrv"), series("recovery"))) {
            out.append(.init(id: "hrv-rec",
                             title: String(localized: "HRV ↔ Charge"),
                             blurb: String(localized: "Heart-rate variability as the engine behind your charge score."),
                             corr: c))
        }
        // Resting HR ↔ recovery (same day), expected to be negative.
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("rhr"), series("recovery"))) {
            out.append(.init(id: "rhr-rec",
                             title: String(localized: "Resting HR ↔ Charge"),
                             blurb: String(localized: "A lower resting heart rate usually means a higher charge."),
                             corr: c))
        }
        // Today's recovery ↔ NEXT-day recovery (1-day lag) as a strain/carry-over proxy.
        // (Strain series isn't in the outcome set; recovery→next-day recovery shows
        //  how much yesterday carries into today.)
        if let c = CorrelationEngine.lagged(x: series("recovery"), y: series("recovery"), lagDays: 1) {
            out.append(.init(id: "rec-lag",
                             title: String(localized: "Charge → Next-day charge"),
                             blurb: String(localized: "How much one day's charge carries into the next."),
                             corr: c))
        }

        return out
    }

    private func relationshipRow(_ rel: Relationship) -> some View {
        let r = rel.corr.r
        let strength = correlationColor(r)
        // Build the reading sentence ONCE and reuse it for the visible copy and
        // the accessibility label (was computed twice per row).
        let sentence = relationshipSentence(rel)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // Liquid magnitude accent: a small filling vessel showing |r| in the correlation's
                // strength colour, the same leading-gauge idiom Today's card rows + vitals use. Static
                // (a small gauge doesn't need live slosh); decorative, the exact r + a11y read below.
                LiquidVessel(value: min(1, abs(r)), tint: strength, animated: false)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(rel.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(String(format: "r = %+.2f", r))
                    .font(StrandFont.number(16))
                    .foregroundStyle(strength)
                StatePill(rel.corr.pApprox < 0.05 ? "p < 0.05" : "n.s.",
                          tone: rel.corr.pApprox < 0.05 ? .accent : .neutral,
                          showsDot: false)
            }

            // r bar, visual magnitude/direction (hover reveals the exact value).
            rBar(r: r, color: strength, label: rel.title)

            Text(sentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(rel.blurb)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
    }

    /// A centred bar: zero in the middle, fills left (negative) or right (positive)
    /// proportional to |r|. Hovering reveals a tooltip with the exact r value, so the
    /// bar, like every Strand chart, is never an unexplained coloured shape.
    private func rBar(r: Double, color: Color, label: String) -> some View {
        RBar(r: r, color: color, label: label)
    }

    // MARK: - Formatting / interpretation helpers

    /// Map a tone to its public palette color (StrandTone.color is module-internal).
    private func toneColor(_ tone: StrandTone) -> Color {
        switch tone {
        case .neutral:  return StrandPalette.textSecondary
        case .accent:   return StrandPalette.accent
        case .positive: return StrandPalette.statusPositive
        case .warning:  return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        }
    }

    /// Format an outcome value with sensible units for the selected metric.
    private func formatOutcome(_ v: Double) -> String {
        formatOutcome(v, as: outcome)
    }

    /// Format an outcome value with sensible units for a specific metric (used by the
    /// experiment card, which formats against its own stored outcome rather than the
    /// segmented selection).
    private func formatOutcome(_ v: Double, as outcome: Outcome) -> String {
        switch outcome {
        case .recovery, .sleep: return "\(Int(v.rounded()))%"
        case .hrv:              return "\(Int(v.rounded())) ms"
        case .rhr:              return "\(Int(v.rounded())) bpm"
        }
    }

    /// Cohen's d → conventional magnitude word.
    private func effectMagnitudeWord(_ d: Double) -> String {
        switch abs(d) {
        case ..<0.2:  return String(localized: "negligible")
        case ..<0.5:  return String(localized: "small")
        case ..<0.8:  return String(localized: "moderate")
        default:      return String(localized: "large")
        }
    }

    /// |r| → strength word.
    private func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return String(localized: "no")
        case ..<0.3:  return String(localized: "a weak")
        case ..<0.5:  return String(localized: "a moderate")
        case ..<0.7:  return String(localized: "a strong")
        default:      return String(localized: "a very strong")
        }
    }

    /// Tint a correlation by strength, keyed on the recovery gradient so strong
    /// positive reads mint and strong negative reads red.
    private func correlationColor(_ r: Double) -> Color {
        // Map r∈[-1,1] → 0…1 of the recovery scale (−1 red, 0 gold, +1 mint).
        StrandPalette.sample(stops: StrandPalette.recoveryStops, at: (r + 1) / 2)
    }

    private func relationshipSentence(_ rel: Relationship) -> String {
        let r = rel.corr.r
        let dir = r > 0 ? String(localized: "positive") : (r < 0 ? String(localized: "negative") : String(localized: "flat"))
        let strength = strengthWord(r)
        return String(localized: "\(strength.capitalizedFirst) \(dir) relationship (r = \(String(format: "%.2f", r)), n = \(rel.corr.n)).")
    }
}

// MARK: - Correlation magnitude bar (hover-aware)

/// A centred correlation bar (zero in the middle, fills left/negative or
/// right/positive by |r|). On hover it shows the locked ChartTooltip with the exact
/// r value, matching the hover affordance every other Strand chart provides.
private struct RBar: View {
    let r: Double
    let color: Color
    let label: String

    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let mag = CGFloat(min(abs(r), 1.0)) * half
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                // centre tick
                Rectangle()
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1)
                    .position(x: half, y: geo.size.height / 2)
                // value fill
                Capsule()
                    .fill(color)
                    .frame(width: mag, height: geo.size.height)
                    .offset(x: r >= 0 ? half : half - mag)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        // Tooltip floats above the bar without affecting layout (overlays aren't
        // clipped), so the exact r value reads on hover, same affordance as charts.
        .overlay(alignment: .center) {
            if hovering {
                ChartTooltip(
                    value: String(format: "r = %+.2f", r),
                    label: label,
                    accent: color
                )
                .fixedSize()
                .offset(y: -26)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true
            case .ended:  hovering = false
            }
        }
        .animation(StrandMotion.fade, value: hovering)
        .accessibilityHidden(true)
    }
}

private extension String {
    /// Capitalise only the first letter (keeps "a weak" → "A weak").
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func insightsPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights") {
    InsightsView()
        .environmentObject(insightsPreviewRepo())
        .environmentObject(NavRouter())
        .frame(width: 920, height: 900)
        .preferredColorScheme(.dark)
}
#endif
