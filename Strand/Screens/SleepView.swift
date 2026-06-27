import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - SleepView
//
// Whoop-sleep clarity on the locked Noop component system. Scannable in two seconds:
//   1. HERO ChartCard "Last night" — the stage breakdown (Hypnogram if intervals
//      reconstruct from stagesJSON, else a clean proportional stacked stage bar),
//      trailing = total asleep, footer = REM/Deep/Light/Awake each "Xh Ym · NN%".
//   2. A uniform grid of fixed StatTiles, each with a sparkline and a "vs typical"
//      caption: Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
//      Respiratory, Sleep Debt.
//   2b. The sleep-debt LEDGER card — a rolling 14-night running balance of (slept −
//      personal need) with a plain-English read and a diverging per-night delta bar.
//   3. "Stages vs typical" NoopCard — Deep/REM/Light as horizontal bars, last-night
//      minutes with a marker at the personal typical (mean) so highs/lows pop.
//   4. A 30-day asleep-hours ChartCard trend.
//
// Every surface is a NoopCard / StatTile / ChartCard — no hand-sized cards, one grid,
// equal margins. Data wiring is preserved from the previous screen (stagesJSON =
// minutes for light/deep/rem/awake; typical = mean of repo.days).

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: SleepView itself deliberately does NOT observe `LiveState`. A connected strap publishes
    // at ~1 Hz; observing here would re-evaluate this heavy body on every tick. The only two live
    // dependencies — the "going to sleep / awake" mark card (it appends to the strap log) and the
    // "Syncing strap history…" note — each own their OWN `@EnvironmentObject var live` in a small
    // leaf below (mirrors the Today leaf-scoping pattern), so a tick refreshes only that leaf.
    @EnvironmentObject var intelligence: IntelligenceEngine

    // The standard tile grid: ONE adaptive column set, used for every tile group.
    private let tileColumns = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?

    /// Which night the hero hypnogram shows: 0 = last night, N = N sleep-sessions back.
    /// Snaps back to 0 whenever the data key changes — a stale offset would silently point
    /// at a different session after a sync. The memoized trend `model` stays cached since
    /// the trends are night-independent. (#160)
    @State private var nightOffset = 0
    /// Memoized decode of the NAVIGATED night (nil when `nightOffset == 0` — the hero reads
    /// `model.night` then). Rebuilt only in the `nightOffset` / data-key onChange handlers;
    /// `decodedNight` JSON-decodes, which must never run per body pass (1Hz HR ticks). (#160)
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main
    /// sleep on the same day) into a single block. The hero groups these by day (`navDays`) and
    /// merges each day into one Night, so a split day reads as one correctly-totalled night with the
    /// gaps preserved. Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State private var allSessions: [CachedSleepSession] = []

    /// The user's LEARNED habitual midsleep (local time-of-day seconds), or nil under the cold-start
    /// threshold. Loaded from `repo.habitualMidsleepSec()` — the SAME value `AnalyticsEngine.analyzeDay`
    /// threads into the daily total — and fed into the main-night selector so the hero, the naps split,
    /// and the edit target pick the SAME block the analytics rollup did, for a shift/late sleeper too. nil
    /// keeps the existing cold-start overnight-band fallback. (#547) Refreshed with `allSessions`.
    @State private var habitualMidsleepSec: Int? = nil

    /// Persisted per-epoch MOTION series keyed by each session's detected `startTs` (#407). Loaded in the
    /// same `.task` as `allSessions` from `repo.sessionMotions(starts:)`, then laid along the hypnogram for
    /// the SAME main-night GROUP blocks the hero resolved (mergeDay's group) — we do NOT re-resolve the
    /// night, only read the already-chosen group's stored motion. A block with no stored series stays absent
    /// (honest empty state for older rows whose `motionJSON` is NULL). Refreshed with `allSessions`.
    @State private var motionByStart: [Int: [Double]] = [:]

    /// Draw-in fraction for the Rest hero gauge — owned here so the gauge animates the arc on appear /
    /// when the sleep-performance score changes, exactly as TodayView drives its rings. Presentation-only.
    @State private var heroFraction: Double = 0

    /// Non-nil while the wake-time editor sheet is open. Carries the night's stable key (`startTs`) and
    /// current wake time so the editor seeds its picker; saving routes through `repo.editSleepWakeTime`,
    /// which marks the session `userEdited` so a later strap sync can't revert the correction. (#318)
    @State private var wakeEdit: WakeEdit?

    /// Non-nil while the "Add nap" picker sheet is open (#508). Carries a seed bed/wake for the picker;
    /// saving routes through `repo.addManualNap`, which stages the chosen window from raw and writes it as
    /// its OWN separate session row (`userEdited = 1`) — never folded into the night's main sleep.
    @State private var addNap: AddNapSeed?

    /// True while the hero's "why this is your main sleep" popover is open. The reason text comes
    /// straight from the foundation `MainNightReason` for the displayed night's blocks — never
    /// re-derived here — so the explainer says exactly what the selector decided. (spec 2026-06-20 C1)
    @State private var showMainSleepWhy = false
    /// The stable detected key of the nap whose "why this is a nap" popover is open, or nil. Keyed by
    /// the nap's own `startTs` so one popover shows at a time even with several nap rows. (C1)
    @State private var napWhyStartTs: Int?

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        ScreenScaffold(title: "Sleep", subtitle: "Last night, read in two seconds.",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header), builds trailing trend/ledger cards on demand. Combined
                       // with dropping the top-level LiveState observation (the sleep-mark card + the
                       // syncing note now own `live` in their own leaves), so a 1 Hz HR tick no longer
                       // re-evaluates this heavy body.
                       onRefresh: { await repo.refresh() },
                       lazy: true) {
            Group {
                if let resolved {
                    // Each top-level section fades + rises in sequence on first appear (Reduce-Motion safe).
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                        restHero(resolved).staggeredAppear(index: 0)
                        SleepMarkCard().staggeredAppear(index: 1)
                        hero(resolved).staggeredAppear(index: 2)
                        metricGrid(resolved).staggeredAppear(index: 3)
                        sleepDebtLedger(resolved).staggeredAppear(index: 4)
                        stagesVsTypical(resolved).staggeredAppear(index: 5)
                        durationTrend(resolved).staggeredAppear(index: 6)
                    }
                } else {
                    emptyState
                }
            }
            // Animate the Rest hero gauge in once content resolves, and re-draw when the
            // sleep-performance score changes (a sync / re-import). macOS-13-safe single-param onChange.
            .onChangeCompat(of: heroScoreFraction(resolved)) { newFraction in
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = newFraction }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = heroScoreFraction(resolved) }
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChangeCompat(of: key) { newKey in
                modelKey = newKey
                model = buildModel()
                // New data invalidates a navigated offset — the same offset would silently
                // point at a different session. Snap back to last night. (#160)
                nightOffset = 0
                navNight = nil
            }
            // The navigated night is decoded once per ◀/▶ press, never per body pass —
            // `decodedNight` JSON-decodes and body re-evaluates at 1Hz while HR streams. (#160)
            .onChangeCompat(of: nightOffset) { newOffset in
                navNight = newOffset == 0 ? nil : decodedNight(at: newOffset)
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                    nightOffset = 0
                    navNight = nil
                }
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the hero's ◀/▶ can
            // browse split-sleep days the dashboard collapses — including Bluetooth-only nights,
            // whose blocks live under the computed source. Re-runs whenever a sync/import bumps
            // refreshSeq; snaps back to the newest day and rebuilds the model so offset 0 reflects
            // the freshly-loaded blocks. (#170)
            .task(id: repo.refreshSeq) {
                allSessions = await repo.allSleepSessions()
                // Load the learned habitual midsleep the engine used, so the main-night pick aligns to it
                // (a shift/late sleeper) instead of only the cold-start band. nil under threshold. (#547)
                habitualMidsleepSec = await repo.habitualMidsleepSec()
                // Per-epoch motion for every block (#407), keyed by detected start. mergeDay reads only the
                // already-resolved group's entries — this just pre-fetches them all so the model build is sync.
                motionByStart = await repo.sessionMotions(starts: allSessions.map { $0.startTs })
                nightOffset = 0
                navNight = nil
                modelKey = dataKey
                model = buildModel()
            }
            .sheet(item: $wakeEdit) { edit in
                SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                                onSave: { newBedTs, newWakeTs in
                    await repo.editSleepTimes(detectedStartTs: edit.detectedStartTs, oldEndTs: edit.wakeTs,
                                              storedStagesJSON: edit.stagesJSON,
                                              newStartTs: newBedTs, newEndTs: newWakeTs)
                    // Re-score the day so the dashboard aggregates (Rest / recovery) honor the corrected
                    // sleep window, not just the Sleep tab's session view; then refresh the read cache.
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }, onDelete: {
                    // Delete = the edit path minus the re-insert: drop this session so every metric
                    // recomputes immediately as if the night were never recorded, durably tombstoned so a
                    // re-detect doesn't bring it back, then re-score + refresh exactly like an edit. (#68)
                    await repo.deleteSleepSession(detectedStartTs: edit.detectedStartTs, endTs: edit.wakeTs)
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                })
            }
            // Manually add a missed nap (#508): same picker, but the chosen window is staged from raw and
            // stored as its OWN separate session — never folded into main sleep (which would mislabel the
            // awake daytime gap as light sleep).
            .sheet(item: $addNap) { seed in
                SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                                title: "Add a nap",
                                blurb: "Pick when the nap started and ended. NOOP stages it from your data as its own session, separate from the night's sleep.",
                                bedLabel: "Nap started", wakeLabel: "Nap ended") { startTs, endTs in
                    await repo.addManualNap(startTs: startTs, endTs: endTs)
                    // Re-score so the day's aggregates pick up the new session, exactly like an edit.
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }
            }
        }
    }

    // MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)

    /// The fill fraction (0…1) the Rest hero gauge animates to — the night's sleep-performance
    /// score over 100. 0 when no score exists (the headline-hours hero shows instead). Cheap, so
    /// it's read every render to drive the draw-in animation.
    private func heroScoreFraction(_ model: SleepModel?) -> Double {
        guard let p = model?.performance.latest else { return 0 }
        return min(max(p / 100.0, 0), 1)
    }

    /// The Rest world's opening: a scenic indigo backdrop with — when the night carries a 0–100
    /// sleep-performance score — a layered `BevelGauge` in the Rest gradient; otherwise a big
    /// SF-Rounded hours-slept headline over the same backdrop. A `SourceBadge` states whether the
    /// score is WHOOP's own imported figure or NOOP's on-device estimate. Presentation-only — the
    /// number comes straight from the existing `model.performance.latest` / hours computation. (Bevel)
    @ViewBuilder
    private func restHero(_ model: SleepModel) -> some View {
        let score = model.performance.latest
        let frac = heroScoreFraction(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep performance", overline: "Last night", trailing: "Rest")
            // A subtle night atmosphere sits behind the sleep hero ONLY (the Rest world's whisper:
            // faint indigo wash + crescent moon over the near-black canvas, no glow), clipped to the
            // card. Replaces the now-flat ScenicHeroBackground here.
            VStack(spacing: NoopMetrics.space4) {
                if let score {
                    BevelGauge(
                        fraction: frac,
                        stops: StrandPalette.restGradient.stops,
                        tipColor: StrandPalette.restColor,
                        numberText: "\(Int(score.rounded()))",
                        captionText: "of 100",
                        stateText: sleepScoreWord(score),
                        diameter: 184,
                        lineWidth: 15,
                        animatedFraction: heroFraction
                    )
                    .padding(.top, NoopMetrics.space1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sleep performance \(Int(score.rounded())) of 100")
                } else {
                    // No 0–100 score for the night — lead with hours slept as a big rounded headline
                    // whose minutes tick up on appear (the same count-up the scored hero gets).
                    VStack(spacing: NoopMetrics.space1) {
                        CountUpText(
                            value: model.night.stages.asleep,
                            format: { durationText($0) },
                            font: StrandFont.number(46),
                            color: StrandPalette.restBright
                        )
                        Text("asleep last night")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding(.vertical, NoopMetrics.space5)
                    .accessibilityElement(children: .combine)
                }
                SourceBadge(score != nil ? sleepScoreSource(model) : "On-device", tint: StrandPalette.restColor)
            }
            .padding(NoopMetrics.cardInnerPadding + NoopMetrics.space1)
            .frame(maxWidth: .infinity)
            .timeOfDayBackground(.night)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    /// A short Rest state word for the hero gauge — same banding the synthesis hero uses.
    private func sleepScoreWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return "Poor"
        case ..<70:  return "Fair"
        case ..<85:  return "Good"
        default:     return "Optimal"
        }
    }

    /// Whether the night's sleep-performance score is WHOOP's own imported figure or NOOP's
    /// on-device approximation — so the hero is honest about provenance, like Today's badges.
    private func sleepScoreSource(_ model: SleepModel) -> LocalizedStringKey {
        if let lastDay = repo.days.last?.day, repo.importedSleep[lastDay]?.performancePct != nil {
            return "Whoop"
        }
        return "On-device"
    }

    // MARK: - Provenance for the displayed night (COMPONENT 4, spec 2026-06-20)

    /// The REAL per-day merge winner for the DISPLAYED night's sleep numbers, as the same brand wording the
    /// By-Day badge / Today / Intelligence use ("On-device" / "Whoop"). A WHOOP export covering the night's
    /// wake-day wins the dashboard merge (imports win field-by-field, Repository.mergeDaily), so the badge
    /// says "Whoop"; otherwise the night was scored on-device by NOOP. Keyed by the night's LOCAL wake-day
    /// (the `mergeSleep` / importer convention, sleep is filed under the day you woke), so a navigated past
    /// night reads its OWN provenance, not last night's. Honest: never a blanket "on-device". Apple Health
    /// carries no sleep into `importedSleep`, so the sleep merge winner is only ever Whoop vs on-device. (C4)
    private func nightSource(_ night: Night) -> String {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        return repo.importedSleep[wakeDay] != nil ? "Whoop" : "On-device"
    }

    // MARK: - 0b. SLEEP MARKS — tap to log "going to sleep" / "I'm awake" (#461, Phase 1)
    //
    // Extracted to the `SleepMarkCard` leaf at the foot of this file. It owns its OWN `@EnvironmentObject
    // var live` (it appends to the shareable strap log) + `repo`, plus the `lastMark` confirmation state,
    // so SleepView itself no longer observes LiveState and a 1 Hz HR tick can't re-render this body. The
    // card renders byte-for-byte what the inline `sleepMarkCard` did (same copy, buttons, haptic, layout).

    // MARK: - 1. HERO — stage breakdown

    @ViewBuilder
    private func hero(_ model: SleepModel) -> some View {
        // Offset 0 reads the memoized latest night; navigated offsets read the cached
        // `navNight` — never a fresh decode here (this runs on every 1Hz HR tick). When a
        // navigated session decoded to no usable stages, the header stays on that REAL
        // session's date/times with an honest placeholder in the chart slot — never the
        // latest night silently rendered under a navigated label. (#160)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if nightOffset == 0 {
                nightNavHeader(trailing: model.night.spanLabel)
                sleepWindowRow(model.night)
                stageCard(model.night, intervals: model.intervals)
                napSection(model.night)
            } else if let night = navNight {
                nightNavHeader(trailing: night.spanLabel)
                sleepWindowRow(night)
                stageCard(night, intervals: night.intervals)
                napSection(night)
            } else if let session = sessionRow(at: nightOffset) {
                // Stage-less stub purely to reuse Night's date/time formatting.
                let stub = Night(session: session, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                                 sourceBlocks: dayBlocks(at: nightOffset),
                                 habitualMidsleepSec: habitualMidsleepSec)
                nightNavHeader(trailing: stub.spanLabel)
                sleepWindowRow(stub)
                ChartCard(
                    title: "Stage breakdown",
                    subtitle: "\(durationText(Double(session.endTs - session.startTs) / 60.0)) in bed",
                    height: NoopMetrics.chartHeight,
                    tint: StrandPalette.restColor,
                    chart: { noStagePlaceholder }
                )
                napSection(stub)
            }
        }
    }

    /// Naps card (#508): each of the day's sleep blocks OTHER than the night's main block, individually
    /// editable + deletable with the SAME durable mechanism main sleep uses, plus an "Add nap" affordance.
    /// A nap is always its own session row (never folded into main sleep), so editing or adding one here
    /// never touches the night's main hypnogram and the awake daytime is never mislabelled as light sleep.
    @ViewBuilder
    private func napSection(_ night: Night) -> some View {
        // The day's main sleep is the bridged main-night GROUP (#561): a briefly-interrupted / biphasic
        // night's sibling fragments are part of the night, NOT naps. Only blocks OUTSIDE that group are
        // naps. This matches the hero and AnalyticsEngine.analyzeDay; the old `!= editTarget.startTs` split
        // labelled the bridged siblings as phantom naps (#555). The summary stays explainable: Main X /
        // Nap(s) Y / Total Z, with Main = the whole bridged night. (#508, #518, #555)
        let groupStarts = night.mainGroupStarts
        let naps = night.sourceBlocks
            .filter { !groupStarts.contains($0.startTs) }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let mainMin = night.stages.total
        let napMin = naps.reduce(0.0) { $0 + Double($1.endTs - $1.effectiveStartTs) / 60.0 }
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    SectionHeader("Naps", overline: "Daytime sleep", trailing: nil)
                    Spacer(minLength: 8)
                    Button { addNap = AddNapSeed(forNight: night) } label: {
                        Label("Add nap", systemImage: "plus.circle.fill")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.restColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a nap")
                }
                // Daily split (#518): only meaningful once the day has a nap; a single-night day reads
                // exactly as before. Total = main + naps, the time that drives the day's Rest.
                if !naps.isEmpty {
                    napSummaryRow(mainMin: mainMin, napMin: napMin)
                    Divider().overlay(StrandPalette.hairline)
                }
                if naps.isEmpty {
                    Text("No naps recorded for this day.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    ForEach(naps, id: \.startTs) { nap in
                        napRow(nap)
                        if nap.startTs != naps.last?.startTs {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    /// The Main / Naps / Total split for a day that has at least one nap, so what drives the day's Rest
    /// total is explainable at a glance. Minutes formatted with the shared `durationText`. (#518)
    @ViewBuilder
    private func napSummaryRow(mainMin: Double, napMin: Double) -> some View {
        HStack(spacing: 0) {
            napSummaryCell(label: "Main sleep", value: durationText(mainMin))
            Spacer(minLength: 8)
            napSummaryCell(label: "Nap(s)", value: durationText(napMin))
            Spacer(minLength: 8)
            napSummaryCell(label: "Total", value: durationText(mainMin + napMin))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func napSummaryCell(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).strandOverline()
            Text(value).font(StrandFont.number(18)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    /// One nap row: its clock window + an edit affordance opening the SAME `SleepTimeEditor` main sleep
    /// uses. Editing a nap re-stages it from raw over the corrected window and sticks (`userEdited`), and
    /// can never spawn a duplicate (the detected `startTs` PK is immutable) — exactly the #318/#395 path,
    /// here keyed on the nap's own row. (#508)
    @ViewBuilder
    private func napRow(_ nap: CachedSleepSession) -> some View {
        let isEdited = nap.userEdited
        HStack(spacing: 10) {
            Image(systemName: "powersleep")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(napWindowText(nap)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(durationText(Double(nap.endTs - nap.effectiveStartTs) / 60.0))
                    .strandOverline()
            }
            Spacer(minLength: 8)
            // C1 — "why this is a nap" explainer: the nap-row nudge that everything other than the chosen
            // main block is logged as a nap, with the Edit next-step. Keyed by the nap's stable startTs so
            // one popover shows at a time across several nap rows. (spec 2026-06-20)
            Button { napWhyStartTs = (napWhyStartTs == nap.startTs) ? nil : nap.startTs } label: {
                Image(systemName: "info.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Why this is logged as a nap")
            .accessibilityLabel("Why this is logged as a nap")
            .popover(isPresented: Binding(
                get: { napWhyStartTs == nap.startTs },
                set: { if !$0 { napWhyStartTs = nil } }), arrowEdge: .bottom) {
                whyPopover(text: "", napSuffix: true)
            }
            Button {
                wakeEdit = WakeEdit(detectedStartTs: nap.startTs,
                                    bedTs: nap.effectiveStartTs,
                                    wakeTs: nap.endTs,
                                    stagesJSON: nap.stagesJSON)
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit nap times")
            .accessibilityLabel(isEdited ? "Edit nap times (edited)" : "Edit nap times")
        }
    }

    /// "HH:mm–HH:mm" clock window for a nap row (device 12-/24-h setting via the shared Night formatter).
    private func napWindowText(_ nap: CachedSleepSession) -> String {
        let start = Night.clockString(nap.effectiveStartTs)
        let end = Night.clockString(nap.endTs)
        return "\(start)–\(end)"
    }

    /// The stage-breakdown ChartCard for a decoded night: hypnogram when intervals
    /// reconstruct, else the proportional stage bar. Intervals are passed in so offset 0
    /// uses the memoized `model.intervals` rather than re-deriving them. (#160)
    @ViewBuilder
    private func stageCard(_ night: Night, intervals: [SleepInterval]) -> some View {
        let s = night.stages
        let isPersisted = (night.realSegments?.count ?? 0) >= 2
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ChartCard(
                title: "Stage breakdown",
                subtitle: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency"
                    + (isPersisted ? " · stages approximate (on-device)" : ""),
                trailing: durationText(s.asleep),
                height: NoopMetrics.chartHeight,
                tint: StrandPalette.restColor,
                chart: {
                    if intervals.count >= 2 {
                        Hypnogram(intervals: intervals,
                                  height: NoopMetrics.chartHeight,
                                  showsStageAxis: true,
                                  nightStart: night.onsetDate,
                                  showsTimeAxis: true)
                    } else {
                        stageBar(s)
                    }
                },
                footer: {
                    // WHOOP sleep-detail stage rows: swatch + UPPERCASE stage + coloured % + bar +
                    // right-aligned duration. Same minutes/percentages the old footer grid carried.
                    stageBreakdownRows(s)
                }
            )
            // #407 — subordinate movement/restlessness trace UNDER the hypnogram, on the SAME timeline, for
            // the SAME main-night GROUP blocks the hero resolved (mergeDay's group). Shown only for a real
            // (≥2-segment) hypnogram so the strip aligns with a genuine timeline; the proportional stage-bar
            // fallback has no timeline to anchor to. Placed OUTSIDE the fixed-height ChartCard so it doesn't
            // clip the hypnogram. Honest empty state inside `motionStrip` when no group fragment has motion.
            if intervals.count >= 2 {
                motionStrip(night)
            }
            // H9 — when the engine's Rest confidence flags this night's staging as low-confidence (a
            // high-efficiency night whose deep+REM share is implausibly low → a likely staging miss, not
            // a real night with no restorative sleep), say so honestly under the breakdown rather than
            // presenting the suspect split as fact. Read straight from `ScoreConfidence.rest(...)` — the
            // SAME engine call the daily pass uses — so the badge can never disagree with the score.
            if stageStagingIsLowConfidence(night) {
                stageLowConfidenceNote
            }
        }
    }

    /// #407 — the per-epoch movement/restlessness strip drawn UNDER the hypnogram, on the SAME timeline.
    /// Reads the already-resolved main-night GROUP's persisted motion off `night.motionEpochs` (laid
    /// fragment-by-fragment in `mergeDay`, NO re-resolution of the night). The left inset (44pt axis + 12pt
    /// spacing) matches the Hypnogram's `HStack` so the strip's plot lines up under the stage bands above.
    /// When the night has no persisted motion (older rows whose `motionJSON` is NULL) it shows an HONEST
    /// empty note rather than a fabricated flat zero trace.
    @ViewBuilder
    private func motionStrip(_ night: Night) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // 44 = Hypnogram axis width; 12 = its HStack spacing — keep the strip's plot under the bands.
            Text("Move")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 44, alignment: .trailing)
            Spacer().frame(width: 12)
            if night.motionEpochs.count >= 2 {
                MotionTrace(epochs: night.motionEpochs, height: 40, tint: StrandPalette.restColor)
            } else {
                Text("No movement detail for this night")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .accessibilityLabel(Text("No movement detail recorded for this night"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// H9 — true when this night's staging is LOW-CONFIDENCE: a high-efficiency night (lots of measured
    /// sleep) whose restorative (deep+REM) share is implausibly low, which the EEG-free classifier is far
    /// more likely to have mis-staged than a genuine night with no deep or REM. Delegates to the engine's
    /// pure `ScoreConfidence.rest(...)` H9 overload (efficiency in [0,1], seconds for the totals) so the UI
    /// and the persisted Rest confidence agree by construction. Needs staged sleep + a real efficiency
    /// reading; a pooled/no-stage or unknown-efficiency night is never flagged (its base tier already
    /// reads honestly). (#H9)
    private func stageStagingIsLowConfidence(_ night: Night) -> Bool {
        let s = night.stages
        guard let effPct = efficiencyPct(night) else { return false }
        return SleepView.isStagingLowConfidence(
            asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem, efficiency: effPct / 100.0)
    }

    /// Pure H9 gate (unit-testable without a live view) — true when a night's staging is low-confidence:
    /// a high-efficiency night whose deep+REM share is below the restorative floor. Built on the engine's
    /// own `ScoreConfidence.rest(...)` so the UI flag and the persisted Rest confidence agree. `asleepMin`,
    /// `deepMin`, `remMin` are minutes; `efficiency` is asleep/in-bed in [0,1]. Returns false for an unstaged
    /// or zero-asleep night (no staging to doubt). Mirror EXACTLY in Kotlin. (#H9)
    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        // An UNSTAGED night (no deep+REM at all) has no staging split to doubt — its base Rest
        // confidence already reads honestly as `.building` (NOT a downgrade), so it must never be
        // flagged. Only a night that DID stage some sleep can be a suspicious "high efficiency yet
        // implausibly little restorative" staging miss.
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: asleepMin * 60.0,
            restorativeSeconds: restorativeMin * 60.0,
            efficiency: efficiency)
        // The H9 overload only DOWNGRADES solid → building on the suspicious case; a genuinely
        // low-restorative-AND-low-efficiency night keeps its honest base tier and isn't flagged here.
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }

    /// The H9 low-confidence note shown beneath the stage breakdown — a warning-tinted badge plus a
    /// one-line honest explanation. No faked stages, no tanked score; just a clear "treat this split with
    /// care" so a user doesn't read a likely staging miss as a real deep/REM drought. (#H9)
    private var stageLowConfidenceNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("Low confidence", tint: StrandPalette.statusWarning)
            Text("This night scored high efficiency but very little deep or REM — more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Low confidence staging. This night scored high efficiency but very little deep or REM, more likely an estimate miss than a real restorative shortfall.")
    }

    /// The night's clock window — when you fell asleep and when you woke — as its own clearly
    /// labelled row. These were previously only in the nav-header's trailing caption, which
    /// truncates between the two chevrons on a phone, so in practice the two times people look for
    /// first were effectively hidden. The header now carries just the date span.
    @ViewBuilder
    private func sleepWindowRow(_ night: Night) -> some View {
        // A frosted Rest-tinted card (was a flat surfaceRaised block) so the window row sits in the
        // same colour world as the rest of the screen. Bevel treatment — content unchanged.
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                HStack(spacing: 0) {
                    sleepTime(icon: "moon.zzz.fill", label: "Asleep", value: night.onsetText)
                    Spacer(minLength: 12)
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 30)
                    Spacer(minLength: 12)
                    sleepTime(icon: "sun.max.fill", label: "Woke", value: night.wakeText)
                    Spacer(minLength: 8)
                    wakeEditButton(night)
                }
                .frame(maxWidth: .infinity)
                // Provenance (C4) + the "why this is your main sleep" explainer (C1). The badge names the
                // REAL per-day merge winner; the info button reveals the foundation reason for the pick.
                Divider().overlay(StrandPalette.hairline)
                mainSleepFooter(night)
            }
        }
    }

    /// The hero's footer: the night's provenance badge (the real merge winner) next to a tappable "why
    /// this is your main sleep" affordance. Tapping reveals the foundation `MainNightReason` copy in a
    /// popover, so the pick is explainable on the spot without leaving the hero. (spec 2026-06-20 C1/C4)
    @ViewBuilder
    private func mainSleepFooter(_ night: Night) -> some View {
        HStack(spacing: 10) {
            // C4 — provenance. Dynamic String into the badge slot, so wrap in "\()" (the
            // String vs LocalizedStringKey SwiftUI footgun) to show it verbatim, not as a lookup key.
            SourceBadge("\(nightSource(night))", tint: StrandPalette.restColor)
            Spacer(minLength: 8)
            if mainSleepReasonText(night) != nil {
                Button { showMainSleepWhy.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                        Text("Why this sleep?")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Why this is your main sleep")
                .accessibilityLabel("Why this is your main sleep")
                .popover(isPresented: $showMainSleepWhy, arrowEdge: .bottom) {
                    whyPopover(text: mainSleepReasonText(night) ?? "", napSuffix: false)
                }
            }
        }
    }

    /// A compact explainer popover: the verbatim foundation reason text, with the nap suffix appended for a
    /// nap row. Plain English, no jargon, no em-dashes (the words come straight from `mainSleepReasonText`
    /// and the spec's nap-row suffix). Sized for both macOS and iOS. (spec 2026-06-20 C1)
    @ViewBuilder
    private func whyPopover(text: String, napSuffix: Bool) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(StrandPalette.restColor)
                    .accessibilityHidden(true)
                Text(napSuffix ? "About this nap" : "About your main sleep")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if napSuffix {
                Text("Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.cardInnerPadding)
        .frame(width: 260)
        .background(StrandPalette.surfaceOverlay)
        .accessibilityElement(children: .combine)
    }

    private func sleepTime(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).strandOverline()
                Text(value).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Pencil affordance that opens the wake-time editor for `night`. Auto-detection misreads the wake
    /// time most often (a late lie-in, or a morning stir read as still-asleep), so a one-tap correction
    /// lives right next to the "Woke" value. A filled pencil marks a night already hand-corrected. (#318)
    ///
    /// The hero shows a MERGED/synthetic Night — its `session` carries no `stagesJSON` and a reset
    /// `userEdited` (mergeDay), with the real stage data in `night.stages`. So resolve the actual stored
    /// block we're editing — the one whose wake time IS the night's wake — and edit against its detected
    /// startTs key, current effective bed/wake (to seed the pickers), stagesJSON, and edited state.
    @ViewBuilder
    private func wakeEditButton(_ night: Night) -> some View {
        // Resolve the real stored block by identity (the night's main block), never by re-scanning
        // `allSessions` for a wake-time match — that guess could pick the wrong source/night and, when
        // it missed, fall back to the synthetic effective onset (not a real key) so the edit no-oped.
        if let target = night.editTarget {
            let isEdited = target.userEdited
            Button {
                wakeEdit = WakeEdit(detectedStartTs: target.startTs,
                                    bedTs: target.effectiveStartTs,
                                    wakeTs: target.endTs,
                                    stagesJSON: target.stagesJSON)
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
            }
            .buttonStyle(.plain)
            .help("Edit sleep times")
            .accessibilityLabel(isEdited ? "Edit sleep times (edited)" : "Edit sleep times")
        }
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    private func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(pct(s.deep, s.total)) percent, light \(pct(s.light, s.total)) percent, REM \(pct(s.rem, s.total)) percent, awake \(pct(s.awake, s.total)) percent")
            HStack(spacing: 16) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    private func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - WHOOP stage rows (swatch + UPPERCASE stage + coloured % + bar + duration)

    /// The four stage rows that replace the old footer "label · value" grid, read like WHOOP's sleep
    /// detail: a colour swatch, the UPPERCASE stage name, the share-of-night % in the stage colour, a
    /// proportional bar in the stage colour over a faint track, and the right-aligned duration. Same data
    /// as the prior footer (`s.rem` / `s.deep` / `s.light` / `s.awake` over `s.total`) — no new numbers.
    @ViewBuilder
    private func stageBreakdownRows(_ s: Stages) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            stageBreakdownRow(.rem,   minutes: s.rem,   total: s.total)
            stageBreakdownRow(.deep,  minutes: s.deep,  total: s.total)
            stageBreakdownRow(.light, minutes: s.light, total: s.total)
            stageBreakdownRow(.awake, minutes: s.awake, total: s.total)
        }
    }

    /// One WHOOP-style stage row. `fraction = minutes / total` sets both the % and the bar fill.
    @ViewBuilder
    private func stageBreakdownRow(_ stage: SleepStage, minutes: Double, total: Double) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let fraction = total > 0 ? min(1, max(0, minutes / total)) : 0
        let percent = Int((fraction * 100).rounded())
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(stage.label.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text("\(percent)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(color)
                .frame(width: 38, alignment: .leading)
            // The NOOP signature: a segmented PipBar that counts up to the share-of-night fraction,
            // tinted in the stage colour over the canonical inset track. Flat, crisp, no glow.
            PipBar(value: fraction * 100, segments: 20, tint: color, height: 8)
            Text(durationText(minutes))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 60, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(percent) percent of the night")
    }

    // MARK: - 2. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)

    @ViewBuilder
    private func metricGrid(_ model: SleepModel) -> some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean.
        // All seven series are computed ONCE in the model build (each is a full pass over
        // repo.days/repo.sleeps) — here we only read the memoized results.
        let perf  = model.performance
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: "vs typical")
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

                StatTile(
                    label: "Rest",
                    value: pctValue(perf.latest),
                    caption: vsTypical(perf.latest, perf.typical, suffix: "%"),
                    accent: perf.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(perf.series),
                    sparkColor: StrandPalette.restColor)

                StatTile(
                    label: "Efficiency",
                    value: pctValue(eff.latest),
                    caption: vsTypical(eff.latest, eff.typical, suffix: "%"),
                    accent: StrandPalette.statusPositive,
                    sparkline: spark(eff.series),
                    sparkColor: StrandPalette.statusPositive)

                StatTile(
                    label: "Consistency",
                    value: pctValue(cons.latest),
                    caption: vsTypical(cons.latest, cons.typical, suffix: "%"),
                    accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(cons.series),
                    sparkColor: StrandPalette.metricCyan)

                StatTile(
                    label: "Hours vs Needed",
                    value: pctValue(need.latest),
                    caption: vsTypical(need.latest, need.typical, suffix: "%"),
                    accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                    sparkline: spark(need.series),
                    sparkColor: StrandPalette.restColor)

                StatTile(
                    label: "Restorative",
                    value: pctValue(rest.latest),
                    caption: vsTypical(rest.latest, rest.typical, suffix: "%"),
                    accent: StrandPalette.sleepREM,
                    sparkline: spark(rest.series),
                    sparkColor: StrandPalette.sleepREM)

                StatTile(
                    label: "Respiratory",
                    value: rrValue(resp.latest),
                    caption: vsTypical(resp.latest, resp.typical, suffix: " rpm", decimals: 1),
                    accent: StrandPalette.metricPurple,
                    sparkline: spark(resp.series),
                    sparkColor: StrandPalette.metricPurple)

                StatTile(
                    label: "Sleep Debt",
                    value: debt.latest.map { durationText($0) } ?? "—",
                    caption: debtCaption(debt.latest),
                    accent: debtColor(debt.latest),
                    sparkline: spark(debt.series),
                    sparkColor: StrandPalette.metricRose)
            }
        }
    }

    // MARK: - 2b. Sleep-debt ledger (rolling 14-night running balance)

    /// A running balance of (slept − personal need) across the recent fortnight, surfaced
    /// as one card: the net debt/surplus headline, a plain-English read, and a diverging
    /// bar of each night's delta (surplus above the line, deficit below). Honest: a simple
    /// accumulator — a surplus night offsets a deficit one — capped at 14 nights, no-data
    /// nights skipped. (#242)
    @ViewBuilder
    private func sleepDebtLedger(_ model: SleepModel) -> some View {
        let ledger = model.sleepDebtLedger
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep-debt ledger", overline: "Last 14 nights",
                          trailing: "running balance")
            NoopCard(tint: StrandPalette.restColor) {
                if ledger.nightCount == 0 {
                    Text("No nights with sleep data yet — your ledger fills in as you wear the strap to bed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        // Headline: net balance (count-up on appear) + the short tag (DEBT / SURPLUS / ON
                        // TARGET). The number ticks from the accumulated magnitude via the same formatter.
                        HStack(alignment: .firstTextBaseline) {
                            CountUpText(
                                value: ledger.magnitudeMin,
                                format: { debtHeadline(forMagnitudeMin: $0, ledger: ledger) },
                                font: StrandFont.number(26),
                                color: debtBalanceColor(ledger)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            Spacer(minLength: NoopMetrics.space2)
                            Text(debtTag(ledger))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(debtBalanceColor(ledger))
                        }
                        // Plain-English read.
                        Text(debtRead(ledger))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Per-night diverging delta bars (surplus up, deficit down).
                        debtDeltaBars(ledger)
                        Divider().overlay(StrandPalette.hairline)
                        ChartFooter([
                            ("Balance", debtSigned(ledger.balanceMin)),
                            ("Per-night need", durationText(ledger.needMin)),
                            ("Nights", "\(ledger.nightCount)"),
                        ])
                    }
                }
            }
        }
    }

    /// The diverging per-night delta strip: each night a bar from the centre line — up
    /// (accent) for a surplus, down (rose) for a deficit — scaled to the largest |delta|.
    @ViewBuilder
    private func debtDeltaBars(_ ledger: SleepDebtLedger) -> some View {
        let deltas = ledger.nights.map { $0.deltaMin }
        let scale = max(deltas.map { abs($0) }.max() ?? 1, 1)
        GeometryReader { geo in
            let n = max(deltas.count, 1)
            let slot = geo.size.width / CGFloat(n)
            let barW = max(2, slot * 0.6)
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                // Centre (zero) line.
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .position(x: geo.size.width / 2, y: midY)
                ForEach(Array(deltas.enumerated()), id: \.offset) { i, d in
                    let frac = CGFloat(abs(d) / scale)
                    let h = max(2, frac * (midY - 2))
                    let x = slot * CGFloat(i) + slot / 2
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(d >= 0 ? StrandPalette.accent : StrandPalette.metricRose)
                        .frame(width: barW, height: h)
                        // Surplus grows upward from the centre, deficit downward.
                        .position(x: x, y: d >= 0 ? midY - h / 2 : midY + h / 2)
                }
            }
        }
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-night sleep balance: \(ledger.nightCount) nights, net \(debtSigned(ledger.balanceMin))")
    }

    // MARK: - 3. Stages vs typical

    @ViewBuilder
    private func stagesVsTypical(_ model: SleepModel) -> some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night",
                          trailing: "hatch = typical")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    stageRow(stage: "Deep",  last: s.deep,  typical: model.typicalDeepMin,  nightTotal: s.total, color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: "REM",   last: s.rem,   typical: model.typicalRemMin,   nightTotal: s.total, color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: "Light", last: s.light, typical: model.typicalLightMin, nightTotal: s.total, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage row, WHOOP sleep-detail style: a colour swatch + UPPERCASE stage + the share-of-night %
    /// (in the stage colour), then a bar that reads "solid = you, hatch = the context" — a diagonal-hatch
    /// track spanning the TYPICAL (the personal mean for this stage) with the user's last-night value as a
    /// solid coloured fill on top, plus a thin marker at the typical mean and the right-aligned duration.
    /// Same data as before (`last` minutes, `typical` personal mean) — the hatch just renders the typical
    /// context the prior vertical-only marker implied.
    @ViewBuilder
    private func stageRow(stage label: String, last: Double, typical: Double?, nightTotal: Double, color: Color) -> some View {
        // Scale both values against a shared per-row max so the typical hatch + marker are meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        // Share of the night this stage took (drives the WHOOP coloured %); over time-in-bed, matching the
        // stage-breakdown rows above.
        let sharePct = nightTotal > 0 ? Int((last / nightTotal * 100).rounded()) : 0
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return "\(sign)\(durationText(abs(diff))) vs typ"
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(sharePct)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(color)
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Track.
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // Typical-range CONTEXT: a diagonal-hatch track spanning the personal mean for this
                    // stage. "Hatch = the context" — the user's solid value sits over it.
                    if let typical, typical > 0 {
                        DiagonalHatch(spacing: 5, lineWidth: 1)
                            .stroke(color.opacity(0.5), lineWidth: 1)
                            .frame(width: w * CGFloat(min(1, typical / max)))
                            .clipShape(Capsule(style: .continuous))
                    }
                    // Last-night SOLID value fill — "solid = you".
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: w * CGFloat(min(1, last / max)))
                    // Crisp typical-mean marker so the exact mean still reads at a glance.
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 16)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(durationText(last)) last night, \(sharePct) percent of the night\(typical.map { ", typical \(durationText($0))" } ?? "")")
        }
    }

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    private func durationTrend(_ model: SleepModel) -> some View {
        // Trailing-30 trend points and the typical total are precomputed in the model build
        // (full passes over repo.days) — read here, not recomputed per render.
        let pts = model.trendPoints
        let avg = model.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend", trailing: "Last 30 days")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: avg.map { String(format: "%.1f h avg", $0) },
                height: NoopMetrics.chartHeight,
                tint: StrandPalette.restColor,
                chart: {
                    if pts.count >= 2 {
                        TrendChart(points: pts,
                                   gradient: StrandPalette.restGradient,
                                   valueRange: trendRange(pts),
                                   showsArea: true,
                                   height: NoopMetrics.chartHeight,
                                   valueFormat: { String(format: "%.1f h", $0) },
                                   accessibilityLabel: "Hours asleep trend")
                    } else {
                        sparsePlaceholder
                    }
                },
                footer: {
                    ChartFooter([
                        ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Nights", "\(pts.count)"),
                    ])
                }
            )
        }
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    private var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    private func buildModel() -> SleepModel? {
        guard let night = latestNight else { return nil }
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            performance: performanceSeries,
            efficiency: efficiencySeries,
            consistency: consistencySeries,
            hoursVsNeeded: hoursVsNeededSeries,
            restorative: restorativeSeries,
            respiratory: respiratorySeries,
            sleepDebt: sleepDebtSeries,
            typicalTotalMin: typicalTotalMin,
            typicalDeepMin: typicalStageMin(\.deepMin),
            typicalRemMin: typicalStageMin(\.remMin),
            typicalLightMin: typicalStageMin(\.lightMin),
            trendPoints: durationTrendPoints,
            sleepDebtLedger: debtLedger)
    }

    /// The rolling 14-night sleep-debt ledger from the cached daily metrics. Uses the
    /// SAME personal sleep need the tiles use (`sleepNeedMin`, ≥ 7.5 h, the per-user
    /// override over the 8 h default), measured against each night's `totalSleepMin`.
    /// Skips nights with no sleep (the analytics function does the skip). (#242)
    private var debtLedger: SleepDebtLedger {
        SleepDebt.ledger(
            series: repo.days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) },
            needHours: sleepNeedMin / 60.0)
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations. TWO stagesJSON formats exist:
    /// imported nights store a dict of MINUTES {"light","deep","rem","awake"}; on-device computed
    /// nights store a SEGMENT ARRAY [{start,end,stage}] (AnalyticsEngine.encodeStages). Only the
    /// dict was decoded before, so a Bluetooth-only user's night vanished from this tab entirely
    /// while Intelligence showed it (#77). Computed nights also carry their REAL timeline now —
    /// the hypnogram draws genuine segments instead of the synthetic reconstruction.
    private var latestNight: Night? { decodedNight(at: 0) }

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop, so a split-sleep day reads as a single night and the "N nights ago" label
    /// stays truthful — two blocks of the same day are never "1 night ago" AND "2 nights ago". (#170)
    private var navDays: [[CachedSleepSession]] {
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: navSessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
    }

    /// The day's MAIN sleep block — the night people mean by "last night" — and the rest (naps). (#518)
    /// A day can hold an overnight AND an afternoon nap (both end on the same calendar day, so both
    /// bucket here). The pick is the SINGLE shared selector (`SleepStageTotals.mainNightIndex`) the
    /// analytics rollup uses — the LEARNED-TIMING score (asleep span + alignment bonus), NOT a re-derived
    /// overnight gate — so the hero, the edit affordance, the analytics total, and the Sleep tab ALL
    /// resolve to the identical block (the whole point of #525/#547). Delegates to `mainNightSession`,
    /// passing the LEARNED habitual midsleep (the same value the engine threaded into the daily total) so
    /// a shift/late sleeper's hero and analytics total agree — not just at cold-start. (#547)
    private func mainBlock(_ sessions: [CachedSleepSession]) -> CachedSleepSession? {
        SleepView.mainNightSession(sessions, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The device's current UTC offset (seconds east), evaluated once per pick. Feeds the selector's
    /// `offsetSec` so the timing test reads the user's clock via the SAME `offsetSec` math the engine
    /// uses (`SleepStageTotals.localSecOfDay`), instead of `Calendar.current.component(.hour:)` which was
    /// the duplicated, DST-fragile gate the audit flagged. (#547)
    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The day's single WINNING main block — the durable-edit anchor (`editTarget`) and the one block whose
    /// learned-timing score won. Scores by learned timing on each block's EFFECTIVE onset (what the user
    /// sees) and returns the owning session. This is the BARE single-block pick (no gap-bridge), because the
    /// edit affordance writes against ONE real row so it must resolve to one block. The HERO display and the
    /// nap split do NOT use this alone: they use `mainNightGroup`, which bridges the winner's adjacent
    /// fragments (a wake gap shorter than `gapBridgeMaxMin`) into ONE night the way `AnalyticsEngine`
    /// does (#561), so a biphasic / briefly-interrupted night is shown as one continuous sleep instead of
    /// phantom naps (#555). `habitualMidsleepSec` is the SAME learned value the engine threads into the
    /// persisted totals (loaded via `repo.habitualMidsleepSec()`), so a shift/late sleeper's pick matches
    /// the analytics rollup; nil keeps the cold-start overnight-band bonus. (#525 / #547 / #561)
    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Soft nap-duration hint retained for callers/tests; the nap CLASSIFICATION is now purely "not the
    /// chosen main block" (see `isNap`), never an independent duration/onset test. (#518/#547)
    static let napMaxHours: Double = 3.0
    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    // MARK: - Why-this-is-your-main-sleep explainer (COMPONENT 1, spec 2026-06-20)

    /// The verbatim reason copy for the displayed night, with {DUR} filled as "Xh Ym" from the chosen
    /// block's asleep duration — driven entirely by the foundation `MainNightReason`, so the explainer
    /// states exactly what the selector decided (never a re-derived guess). Resolved over the day's blocks
    /// via the same `mainNightSelection` API the analytics pick uses, with the SAME learned habitual the
    /// hero used, so the words match the block the hero shows. nil only when the day has no blocks. (C1)
    private func mainSleepReasonText(_ night: Night) -> String? {
        guard let sel = SleepStageTotals.mainNightSelection(
            night.sourceBlocks.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: SleepView.tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let dur = durationText(sel.asleepMinutes)
        switch sel.reason {
        case .onlyBlock:
            return "This is your only sleep block today."
        case .longest:
            return "Picked as your main sleep because it was your longest block (\(dur))."
        case .longestNearUsual:
            return "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime."
        case .alignedToUsual:
            return "Picked as your main sleep because it started near your usual sleep time."
        }
    }

    /// Build the hero `Night` for a day around its MAIN-night GROUP — the winning block PLUS any fragments
    /// a brief wake split it into, bridged the way `AnalyticsEngine.analyzeDay` bridges them (#561), so a
    /// biphasic / interrupted night shows as ONE continuous sleep whose total matches the day's headline.
    /// It does NOT merge the whole day: an afternoon nap sits OUTSIDE the bridged group (its gap exceeds
    /// `gapBridgeMaxMin`), so it never folds in and stays a nap (the impossible 1 AM→5 PM merge #518 guarded
    /// against). Stage minutes are SUMMED over the group (the inter-fragment wake gap belongs to no
    /// fragment, so it is excluded from the minutes exactly as the engine excludes it), the hypnogram lays
    /// each fragment's real timeline end-to-end, and `sourceBlocks` keeps every block so the naps card and
    /// the daily Main/Nap/Total summary can read them. A single-block day is byte-identical to the prior
    /// behaviour. Returns nil if the group decodes to no usable stages. (#170, #318, #518, #555, #561)

    /// The night's DISPLAYED onset (bedtime), aligned to the SAME fragment the pencil edit targets so the
    /// shown "Asleep" time and the editor agree (#736). The bug: a night sometimes records a brief, all-awake
    /// pre-sleep stub (e.g. lying in bed scrolling at 21:41) as its own block. The gap-bridge folds it into
    /// the main-night group, so it became `group.first` and drove the shown bedtime, while the pencil edited
    /// the MAIN block (`mainNightSession`, which scores by sleep span/timing and skips the all-awake stub) —
    /// the two diverged and editing couldn't move the displayed bedtime. Fix: skip a leading spurious stub
    /// when deriving the shown onset so it lands on the first fragment with real sleep, which IS the edit
    /// target. A stub is spurious only when it's BRIEF and essentially sleepless AND a later fragment carries
    /// the real sleep; otherwise the earliest effective onset stands (single-block and normal biphasic nights
    /// are byte-identical). Returns a real fragment's `effectiveStartTs`, never a synthetic value.
    private func nightOnsetTs(_ group: [CachedSleepSession]) -> Int {
        // group is ascending by effective onset; first is the earliest fragment.
        guard let first = group.first else { return 0 }
        // Walk past any leading spurious pre-onset awake stubs to the first real-sleep fragment.
        for frag in group {
            if !isPreOnsetAwakeStub(frag) { return frag.effectiveStartTs }
        }
        // Whole group is stub-like (shouldn't reach the hero, mergeDay gates on stages.asleep > 0): keep the
        // earliest onset rather than inventing one.
        return first.effectiveStartTs
    }

    /// A fragment is a spurious pre-onset awake stub when it's within the lie-in cap (<= `preOnsetStubMaxMin`)
    /// and carries essentially no sleep (asleep minutes <= `preOnsetStubAsleepMaxMin`). Used only to skip such
    /// a stub when it leads the main-night group, so the displayed bedtime tracks where real sleep began. (#736)
    private func isPreOnsetAwakeStub(_ frag: CachedSleepSession) -> Bool {
        let spanMin = Double(frag.endTs - frag.effectiveStartTs) / 60.0
        let asleepMin = decodeStages(frag.stagesJSON)?.asleep ?? 0
        return SleepView.isPreOnsetAwakeStub(spanMin: spanMin, asleepMin: asleepMin)
    }

    /// Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
    /// before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of
    /// pre-sleep awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first
    /// sleep fragment is `preOnsetStubAsleepMaxMin`: a stub must be essentially SLEEPLESS, which a real sleep
    /// block never is. The cap only stops a pathological all-day awake block from being silently dropped.
    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    static let preOnsetStubAsleepMaxMin: Double = 3

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. BRIEF and essentially sleepless = a spurious pre-onset awake stub. (#736)
    static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double) -> Bool {
        spanMin <= preOnsetStubMaxMin && asleepMin <= preOnsetStubAsleepMaxMin
    }

    /// The index into an ascending-by-onset group whose fragment supplies the DISPLAYED bedtime: the first
    /// fragment that is NOT a spurious leading pre-onset awake stub, falling back to 0 when every fragment is
    /// stub-like. Pure mirror of `nightOnsetTs`'s walk, driven by per-fragment (spanMin, asleepMin) so a
    /// golden test can pin the #736 behaviour without view internals. (#736)
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(spanMin: spansMin[i], asleepMin: asleep) { return i }
        }
        return 0
    }

    private func mergeDay(_ sessions: [CachedSleepSession]) -> Night? {
        let fullGroup = SleepView.mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        // The displayed bedtime is the night's MAIN onset, aligned to the same fragment the pencil edits.
        // The latest wake closes the span. (#318, #736)
        guard let last = fullGroup.last else { return nil }
        let onset = nightOnsetTs(fullGroup), wake = last.endTs
        // Aggregate (stages, hypnogram, motion) from the displayed onset fragment onward so the chart and
        // the totals start where the bedtime label does — a spurious leading pre-sleep awake stub is dropped
        // from the night's reconstruction (#736). It still rides in `sourceBlocks`/`mainGroupStarts`, so it's
        // never lost and never mislabelled as a nap. Without a leading stub this is the whole group (unchanged).
        let group = fullGroup.drop { $0.effectiveStartTs < onset }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        // #407: lay the GROUP's per-epoch motion fragment-by-fragment in the SAME order the stage timeline
        // is laid, reading the already-chosen group's stored series (NOT a re-resolution). The detected key
        // (`startTs`, not `effectiveStartTs`) is the motion store's key. A fragment with no persisted series
        // contributes nothing; if NO fragment has one, `motionEpochs` stays empty → honest empty state.
        var motion: [Double] = []
        for frag in group {
            if let seg = decodeSegments(frag.stagesJSON, sessionStart: frag.effectiveStartTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start, end: iv.end))
                }
            } else if let st = decodeStages(frag.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
            if let m = motionByStart[frag.startTs] { motion.append(contentsOf: m) }
        }
        guard stages.asleep > 0 else { return nil }
        // (#777) Count the out-of-bed time BETWEEN the night's fragments as awake, so a mid-night get-up
        // (e.g. a 20-min walk) shows on the stage bar too — matching analyzeDay's in-bed gap. effectiveStartTs
        // honours a bedtime edit so the gaps line up with the displayed fragment spans.
        let gapSec = SleepStageTotals.interFragmentWakeSeconds(group.map { (start: $0.effectiveStartTs, end: $0.endTs) })
        stages.awake += Double(gapSec) / 60.0
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs, sourceBlocks: sessions,
                     motionEpochs: motion, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    private func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Backs the hero's ◀/▶ navigation via the `navNight` cache — JSON-decodes, so it only runs
    /// from `buildModel()` and the onChange handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        let days = navDays
        guard offset >= 0, offset < days.count else { return nil }
        return mergeDay(days[offset])
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window (not the
    /// whole day), for the honest no-stage-data header when the day's blocks don't decode to usable
    /// stages. Using the main block (#518) keeps the stub header on the real night rather than a
    /// 1 AM→5 PM overnight+nap span. (#160, #170)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        let days = navDays
        guard offset >= 0, offset < days.count, let main = mainBlock(days[offset]) else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// Header above the hypnogram with ◀/▶ to browse past nights. ◀ goes older (increasing offset),
    /// ▶ goes newer; each is disabled at its bound. The canonical SectionHeader carries the
    /// hierarchy so the hero reads like every other section. (#160)
    @ViewBuilder
    private func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let title: LocalizedStringKey = nightOffset == 0 ? "Last night"
            : (nightOffset == 1 ? "1 night ago" : "\(nightOffset) nights ago")
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            HStack(spacing: NoopMetrics.cardInnerSpacing) {
                Button { if nightOffset < lastIndex { nightOffset += 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(nightOffset >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .disabled(nightOffset >= lastIndex)
                .accessibilityLabel("Previous night")

                SectionHeader(title, overline: "Sleep", trailing: trailing)

                Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                    Image(systemName: "chevron.right")
                        .font(StrandFont.headline)
                        .foregroundStyle(nightOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .disabled(nightOffset == 0)
                .accessibilityLabel("Next night")
            }
            // When the older-night arrow is disabled because no earlier night is banked yet, the
            // chevron just greying out reads as broken. Show a short, honest hint instead — earlier
            // nights only appear once the strap has offloaded them (next-morning sync). (#614 follow-up)
            if nightOffset >= lastIndex {
                Text("No earlier night stored yet. Earlier nights sync in the morning.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    private var typicalTotalMin: Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    private func typicalStageMin(_ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    // MARK: - Per-tile series (latest, typical mean, sparkline history)

    private typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    /// Build a metric from a per-day transform, keeping only finite positive-ish values.
    private func metric(_ transform: (DailyMetric) -> Double?) -> Metric {
        let series = repo.days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance %: the imported WHOOP figure (sleep_performance, 0–100) when the
    /// export carried one for that day; else the REAL resolved Rest composite for that day —
    /// the same single source of truth the Today Rest score reads (AnalyticsEngine.Rest.composite,
    /// what Repository.dailyColumn resolves "sleep_performance" to), NOT a local hours-vs-need
    /// approximation. Keeps the Rest detail graph in agreement with the Today Rest score. (#614
    /// follow-up) Values land 0–100 via the composite; the metric() finite filter drops the rest.
    private var performanceSeries: Metric {
        let imported = repo.importedSleep
        return metric { d in
            if let p = imported[d.day]?.performancePct { return p }   // export-verbatim
            return AnalyticsEngine.Rest.composite(daily: d)            // real resolved Rest composite
        }
    }

    private var efficiencySeries: Metric {
        metric { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency: prefer the imported sleep_consistency series, but only when it covers
    /// the latest night — otherwise "latest" would silently be a months-old import-era
    /// value. Fallback is the APPROXIMATE rolling bedtime-spread score (per session, lower
    /// spread → higher score, same SD→score mapping).
    private var consistencySeries: Metric {
        let imported = repo.importedSleep
        if let lastDay = repo.days.last?.day, imported[lastDay]?.consistencyPct != nil {
            let series = repo.days.compactMap { imported[$0.day]?.consistencyPct }
            return (series.last, mean(series), series)
        }
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = repo.sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need (can exceed 100 on a long night). The imported
    /// sleep_need_min wins per day; else the APPROXIMATE personal-mean need.
    private var hoursVsNeededSeries: Metric {
        let imported = repo.importedSleep
        let fallbackNeed = sleepNeedMin
        return metric { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    private var restorativeSeries: Metric {
        metric { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    private var respiratorySeries: Metric {
        metric { $0.respRateBpm }
    }

    /// Sleep debt (minutes): the imported sleep_debt_min when the export carried it; else
    /// the APPROXIMATE per-night need − asleep, floored at 0 (no "credit").
    private var sleepDebtSeries: Metric {
        let imported = repo.importedSleep
        let need = sleepNeedMin
        let series = repo.days.compactMap { d -> Double? in
            if let debt = imported[d.day]?.debtMin { return debt }   // minutes, export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return Swift.max(0, need - asleep)   // APPROXIMATE fallback
        }
        return (series.last, mean(series), series)
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    private var sleepNeedMin: Double {
        Swift.max(450, typicalTotalMin ?? 450)   // 450 min = 7.5h
    }

    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    private var durationTrendPoints: [TrendPoint] {
        let fmt = SleepView.dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = build(repo.days.suffix(30))
        if recent.count >= 2 { return recent }
        return build(repo.days[...])
    }

    private func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }

    // MARK: - Empty / sparse states

    @ViewBuilder
    private var emptyState: some View {
        // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77). The note
        // owns the `LiveState` observation in its own leaf so the chunk count ticks without re-rendering
        // SleepView (scroll-stutter isolation; identical output to the prior inline check).
        SleepSyncingNote()
        if repo.loaded {
            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")
        } else {
            ComingSoon(what: "Loading your sleep history…")
        }
    }

    private var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Hero chart slot for a NAVIGATED session with no decodable stages — honest about the
    /// gap instead of rendering the latest night under a navigated label. (#160)
    private var noStagePlaceholder: some View {
        Text("No stage data recorded for this night.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting helpers

    private func pct(_ minutes: Double, _ total: Double) -> Int {
        total > 0 ? Int((minutes / total * 100).rounded()) : 0
    }

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries.
    private func vsTypical(_ latest: Double?, _ typical: Double?, suffix: String, decimals: Int = 0) -> String {
        guard let latest, let typical, typical != 0 else { return "vs typical —" }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return "\(sign)\(num)\(suffix) vs typical"
    }

    private func debtCaption(_ debt: Double?) -> String {
        guard let debt else { return "vs need" }
        return debt < 15 ? "On target" : "Below need"
    }

    private func debtColor(_ debt: Double?) -> Color {
        guard let debt else { return StrandPalette.textPrimary }
        switch debt {
        case ..<15:  return StrandPalette.statusPositive
        case ..<60:  return StrandPalette.statusWarning
        default:     return StrandPalette.statusCritical
        }
    }

    // MARK: - Sleep-debt ledger formatting

    /// "≈2h 10m" magnitude headline — leading "≈" because it's an accumulated estimate.
    /// Reads "On target" inside the deadband so a few stray minutes don't show as debt.
    private func debtHeadline(_ ledger: SleepDebtLedger) -> String {
        debtHeadline(forMagnitudeMin: ledger.magnitudeMin, ledger: ledger)
    }

    /// The same headline formatter, but for an arbitrary (interpolated) magnitude so `CountUpText` can
    /// render a coherent string on every frame as the number ticks up. The on-target deadband check
    /// uses the LIVE magnitude `m` so the headline crosses from "On target" to "≈…" mid-count exactly
    /// once, matching the final reading. Final-value identical to `debtHeadline(_:)`.
    private func debtHeadline(forMagnitudeMin m: Double, ledger: SleepDebtLedger) -> String {
        if m < SleepDebt.onTargetBandMin { return "On target" }
        return "≈\(durationText(m))"
    }

    /// Short tag under/beside the headline: DEBT / SURPLUS / ON TARGET.
    private func debtTag(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return "balanced" }
        return ledger.isDebt ? "sleep debt" : "surplus"
    }

    /// Plain-English read of the running balance over the window.
    private func debtRead(_ ledger: SleepDebtLedger) -> String {
        let nights = ledger.nightCount
        let span = "the last \(nights) night\(nights == 1 ? "" : "s")"
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
            return "You're roughly on top of your sleep across \(span) — slept minutes balance out against your need."
        }
        let mag = durationText(ledger.magnitudeMin)
        if ledger.isDebt {
            return "You've banked about \(mag) of sleep debt over \(span). Surplus nights count back against it — an earlier night or two would clear it."
        }
        return "You're carrying about \(mag) of surplus over \(span) — you've slept past your need on balance. Nicely ahead."
    }

    /// Color the balance by sign + size: surplus/within-band → positive green, modest
    /// debt → warning, heavier debt → critical.
    private func debtBalanceColor(_ ledger: SleepDebtLedger) -> Color {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return StrandPalette.statusPositive
        }
        // A debt: amber up to ~3 h accumulated, red beyond.
        return ledger.magnitudeMin < 180 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    private func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return "0m" }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }

    private func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    private func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Stage decoding

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    private func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    private func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Live-observing leaf subviews (scroll-stutter isolation)
//
// SleepView itself does NOT observe `LiveState` (a connected strap publishes at ~1 Hz, which would
// re-evaluate the heavy Sleep body on every tick). These two small leaves each hold their OWN
// `@EnvironmentObject var live`, so a live tick re-renders only the mark card / syncing note — never
// the hero hypnogram, the stage chart, the metric grid or the trends. They render byte-for-byte what
// the inline code did before the extraction (mirrors the Today leaf-scoping pattern).

/// The "going to sleep / I'm awake" sleep-mark card (#461, Phase 1). Tapping logs a timestamped mark —
/// persisted to the `sleep_mark` metric series AND appended to the shareable strap log — then confirms
/// with a haptic and a transient line. LOGGING ONLY: a mark never touches the sleep detector or the
/// night boundaries. Owns `live` (it appends to the strap log) + `repo` (the metric-series write) and
/// the `lastMark` confirmation state, so its strap-log write keeps working without SleepView observing.
private struct SleepMarkCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons. Drives the SwiftUI haptic landing too. LOGGING-ONLY: a mark never feeds the sleep
    /// detector — it's persisted to the metric series + strap log. (#461)
    @State private var lastMark: SleepMark?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep marks", overline: "Tap to log", trailing: "Phase 1")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time — it doesn't change tonight's detected sleep.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NoopMetrics.gap) {
                        // Routed through the unified NoopButton system so the two marks sit identically
                        // (sentence-case label, leading icon at 8pt, controlHeight=48, no glow).
                        NoopButton("Going to sleep", systemImage: "moon.zzz.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.bedtime) }
                            .accessibilityLabel("Log going to sleep")

                        NoopButton("I'm awake", systemImage: "sun.max.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.wake) }
                            .accessibilityLabel("Log waking up")
                    }
                    if let lastMark {
                        Text(lastMark.confirmation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.restColor)
                            .transition(.opacity)
                            .accessibilityLabel(lastMark.confirmation)
                    }
                }
            }
        }
        // A success haptic lands when a new mark is captured (value-driven, not per-tap), matching the
        // app's sparse tactile vocabulary. No-op on macOS.
        .strandHaptic(.success, trigger: lastMark?.tsMs ?? 0)
    }

    /// Persist + log a tapped mark. Optimistically shows the confirmation immediately, fires the
    /// haptic via `lastMark`, appends the human-readable strap-log line, then writes the metric-series
    /// row through the repo's live store handle (no new Repository API, no schema change). The write is
    /// idempotent by (deviceId, day, key). (#461)
    private func logMark(_ type: SleepMarkType) {
        let mark = SleepMark(type: type)
        withAnimation(.easeOut(duration: 0.2)) { lastMark = mark }
        // The shareable strap log is the human-readable surface that lands in a debug export.
        live.append(log: mark.logLine)
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
        }
    }
}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation so the chunk count ticks without re-rendering the rest of the Sleep screen.
private struct SleepSyncingNote: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}

// MARK: - Diagonal-hatch track (WHOOP "typical range" context)

/// A repeating set of 45° diagonal lines for the "typical range" context track behind a stage bar
/// ("solid = you, hatch = the context"). Pure geometry — stroke it in the stage colour and clip it to a
/// capsule. `spacing` is the gap between lines; the lines run further than the bounds so the clip edges
/// stay clean. Presentation-only; no data of its own.
private struct DiagonalHatch: Shape {
    var spacing: CGFloat = 5
    var lineWidth: CGFloat = 1
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start well before the left edge so the 45° lines fully cover the rect after the diagonal shear.
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return p
    }
}

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `buildModel()` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the Night.intervals reconstruction no longer run on every render.
private struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView.Metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Stage intervals for the hypnogram — computed once (Night.intervals is a computed
    /// property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool

    let performance: Metric
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
    /// fortnight, with the per-night deltas behind it. Computed once per data change.
    let sleepDebtLedger: SleepDebtLedger
}

private struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

private struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil
    /// The actual stored block(s) this merged Night was built from. `session` above is a SYNTHETIC
    /// merge for display; an edit must target a real row, so it resolves it from here by identity
    /// rather than re-scanning by wake time. (#318)
    var sourceBlocks: [CachedSleepSession] = []

    /// Per-epoch MOTION for the MAIN-night GROUP, laid fragment-by-fragment in the SAME order `intervals`
    /// lays the group's stage timeline (#407). Empty when no group fragment has a persisted `motionJSON`
    /// (older rows) — the Sleep tab then shows an honest empty state instead of a fabricated zero trace.
    /// This is read off the already-resolved group, NOT a re-resolution of the night.
    var motionEpochs: [Double] = []

    /// The LEARNED habitual midsleep (local time-of-day seconds) the owning view loaded for the user — the
    /// SAME value the engine threaded into the daily total — so `editTarget` resolves the SAME main block
    /// the hero and the analytics rollup did, for a shift/late sleeper too. nil = cold-start band. (#547)
    var habitualMidsleepSec: Int? = nil

    /// The real stored block a sleep-time edit writes against — the day's MAIN block, resolved by the
    /// SAME shared selector (`SleepView.mainNightSession` → `SleepStageTotals.mainNightIndex`) the hero,
    /// the naps card, and `AnalyticsEngine.analyzeDay` use, so all of them and the edit affordance agree
    /// (no re-derived overnight gate). Passes the same learned habitual the hero used, so the edit target
    /// matches the hero block even for a shift/late sleeper. Its `startTs` is a genuine detected key, so
    /// `applySleepEdit` matches. nil when there's no underlying block (a synthetic stub) — the edit
    /// affordance is then hidden. (#318, #518, #547)
    var editTarget: CachedSleepSession? {
        SleepView.mainNightSession(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The `startTs` of every block in the day's bridged MAIN-night GROUP (the winning block plus the
    /// fragments bridged into it, #561), so the naps card excludes ALL of them — only blocks OUTSIDE the
    /// group are naps. Without this the tab treated every block except the single winner as a nap and a
    /// biphasic night rendered as phantom naps. (#555)
    var mainGroupStarts: Set<Int> {
        Set(SleepView.mainNightGroup(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec).map { $0.startTs })
    }

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)) }

    /// Stage intervals laid end-to-end across the night, in seconds from start.
    /// On-device computed nights use their REAL timeline; imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Lets an
    /// aggregated day that started the previous evening read honestly. (#170)
    var spanLabel: String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return Night.dateFmt.string(from: onsetDay) }
        return "\(Night.spanFmt.string(from: onsetDay)) → \(Night.dateFmt.string(from: wakeDay))"
    }

    /// A unix-second timestamp as a device-locale clock string ("11:42 PM" / "23:42"). Shared so the nap
    /// rows format their windows identically to the Asleep/Woke row. (#508)
    static func clockString(_ ts: Int) -> String {
        timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // Clock for the Asleep/Woke row — the times people read at a glance. The "jmm" skeleton
    // follows the device's 12-/24-hour setting ("11:42 PM" or "23:42") instead of forcing one
    // on everyone, matching the HR-tooltip / workout times (#337).
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}

// MARK: - Wake-time editor

/// Identifies the night being edited for `.sheet(item:)`. A night's `startTs` is its stable natural
/// key (wake-time edits never move it), so it doubles as the sheet identity.
private struct WakeEdit: Identifiable {
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    let stagesJSON: String?
    var id: Int { detectedStartTs }
}

/// Seeds the "Add nap" picker (#508). A nap is short, so seed a 30-minute window anchored to the night's
/// wake (a natural place to look for a missed afternoon nap), clamped to never start before the night's
/// onset. The identity is the seed start so `.sheet(item:)` presents once per request.
private struct AddNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    var id: Int { bedTs }
    init(forNight night: Night) {
        // Anchor an hour after the night's wake; a 30-min default window the user adjusts.
        let anchor = night.session.endTs + 3_600
        self.bedTs = anchor
        self.wakeTs = anchor + 30 * 60
    }
}

/// A small sheet to hand-correct a night's bed (onset) and wake (end) times. Seeds both pickers with the
/// current values; the wake picker is bounded to after the chosen bedtime. Hands the chosen unix-second
/// (bed, wake) back via `onSave`. Pure presentation + a single async save — persistence lives in the repo.
private struct SleepTimeEditor: View {
    let onSave: (Int, Int) async -> Void
    /// Optional destructive delete (#68). Non-nil for an existing main-sleep / nap edit (the editor then
    /// shows a "Delete this sleep" button gated behind a confirmation); nil for the "Add a nap" sheet,
    /// which has nothing to delete yet.
    let onDelete: (() async -> Void)?
    private let title: LocalizedStringKey
    private let blurb: LocalizedStringKey
    private let bedLabel: LocalizedStringKey
    private let wakeLabel: LocalizedStringKey
    private let deleteLabel: LocalizedStringKey

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller (#508) overrides them. The save logic + day-derived wake are identical either
    /// way — adding a nap is just an edit whose "existing" window is a seed. `onDelete` (#68) is the
    /// optional destructive action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync.",
         bedLabel: LocalizedStringKey = "Asleep",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(bedTs)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The wake instant to save: the picked wake TIME-OF-DAY landed on the FIRST occurrence strictly after
    /// bedtime (within 24h). The Woke picker is time-only — its calendar day is always DERIVED from bed
    /// here — so a wake can never be dragged onto an unrelated day. That independent wake-date drag was
    /// what silently re-bucketed a night onto the wrong day and split its stages/totals across two days
    /// (the edit-scramble half of #406). For a normal 23:00→07:00 night this resolves 07:00 to the next
    /// morning; for a short evening nap it resolves to the same evening.
    private func resolvedWake() -> Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: wake)
        // `nextDate(after:matching:)` returns the first instant with that hour:minute within 24h after the
        // anchor, so starting one minute past bed keeps wake strictly after bedtime and inside (bed, bed+24h].
        return cal.nextDate(after: bed.addingTimeInterval(60), matching: hm, matchingPolicy: .nextTime)
            ?? bed.addingTimeInterval(8 * 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(blurb)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NoopCard(padding: NoopMetrics.cardPadding, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(bedLabel, selection: $bed,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                    Divider().overlay(StrandPalette.hairline)
                    // Time-only on purpose — the wake's calendar day is derived from bed (see resolvedWake),
                    // so an edit can't move the night to a different day and scramble its stages/totals (#406).
                    DatePicker(wakeLabel, selection: $wake,
                               displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                }
            }

            // Destructive delete for an existing night/nap (#68). Confirmation-gated so a tap can't clear
            // a night by accident; nil for the "Add a nap" sheet (nothing to delete). Sits below the
            // pickers, visually separated from the primary Save action.
            if onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(deleteLabel, systemImage: "trash")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel(deleteLabel)
            }

            HStack(spacing: NoopMetrics.gap) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.noopGhost)
                    .disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        await onSave(Int(bed.timeIntervalSince1970), Int(resolvedWake().timeIntervalSince1970))
                        dismiss()
                    }
                }
                .buttonStyle(.noopPrimary)
                .disabled(saving)
            }
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 360)
        .background(StrandPalette.surfaceOverlay)
        // On-brand destructive confirm — the same role-tagged .alert DevicesView uses for "Remove this
        // device?", not a bare default. (#68 — Android parity: "Delete this sleep session?")
        .alert("Delete this sleep session?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            Text("Removes this recorded sleep and recomputes the day without it. This can't be undone.")
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    SleepView()
        .environmentObject(Repository.previewSleep())
        .environmentObject(LiveState())
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
