import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

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

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The Sleep tab's stage-chart shape (Settings → Appearance → Sleep chart). Display-only; Filled/Ribbon
    /// draw the WHOOP-style stepped hypnogram, Classic keeps the per-stage rows. Mirrors Android. (#sleep-chart-style)
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
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

    /// WHOOP-style stage highlight: tapping a stage row under the timeline lights that stage up on the
    /// chart and recedes the rest (tap again to clear). Display-only selection state. (ryanAtriumAi #988)
    @State private var selectedStage: SleepStage? = nil

    /// Sleeping heart-rate for the displayed night (1-min buckets), for the WHOOP-style HR chart above
    /// the stage rows. Loaded once per night via `.task(id:)` on the stage card. (ryanAtriumAi #988)
    @State private var nightHR: [HRBucket] = []

    /// The transient UNDO banner shown after a suppressing delete (#65). Non-nil for ~7 seconds: carries
    /// the snapshot needed to restore the deleted night into its ORIGINAL namespace and the window text
    /// for the message. A user-created/edited delete writes no tombstone but still offers undo (restore).
    @State private var sleepUndo: SleepUndoBanner?
    /// The pending auto-dismiss task for `sleepUndo`, cancelled when a new delete replaces the banner or
    /// the user hits Undo, so a stale timer can't clear a fresh banner.
    @State private var sleepUndoTask: Task<Void, Never>?

    // #sleep-layout: the arrangeable analytical-card order + explicit hidden set, byte-identical to the
    // Android SleepLayoutPrefs keys. Reordered via the Arrange sheet; display-only, no metric changes.
    @AppStorage(SleepLayoutPrefs.orderKey) private var sleepSectionOrderRaw = ""
    @AppStorage(SleepLayoutPrefs.hiddenKey) private var sleepHiddenSectionsRaw = ""
    @State private var showSleepCustomize = false

    /// The analytical cards to render, in saved order minus the hidden set.
    private var sleepVisibleSections: [SleepSection] {
        SleepLayoutPrefs.visibleOrder(orderRaw: sleepSectionOrderRaw, hiddenRaw: sleepHiddenSectionsRaw)
    }

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        // Title lives inside the immersive night hero (Bevel-style composition). Omit the scaffold
        // header + generic sky so the Rest world owns the upper band and everything below returns to
        // the normal Sleep canvas. Empty state still gets a plain scaffold title for orientation.
        // Night scene is a FIXED ScrollView topBackground (Home sky pattern): edge-to-edge under the
        // status bar and stable on overscroll — pulling to the top reveals the scene, not surfaceBase.
        ScreenScaffold(title: resolved == nil ? "Sleep" : nil,
                       subtitle: resolved == nil ? "Last night, read in two seconds." : nil,
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header), builds trailing trend/ledger cards on demand. Combined
                       // with dropping the top-level LiveState observation (the sleep-mark card + the
                       // syncing note now own `live` in their own leaves), so a 1 Hz HR tick no longer
                       // re-evaluates this heavy body.
                       onRefresh: { await repo.refresh() },
                       lazy: true,
                       topBackground: resolved == nil ? nil : AnyView(sleepNightTopBackground)) {
            Group {
                if let resolved {
                    // Each top-level section fades + rises in sequence on first appear (Reduce-Motion safe).
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                        if let sleepUndo { sleepUndoBanner(sleepUndo) }
                        // Bleed past ScreenScaffold's 16/24 gutters so the hero column is edge-to-edge
                        // in the upper band; the night scene itself is the fixed topBackground.
                        // Customize sits at the end of the hero (not floating in a blank band).
                        restHero(resolved)
                            .padding(.horizontal, -16)
                            .padding(.top, -24)
                            .staggeredAppear(index: 0)
                        // #sleep-layout: the analytical cards render in the user's saved order minus the
                        // hidden set, below the pinned Rest hero. Reordered via the Arrange sheet.
                        ForEach(Array(sleepVisibleSections.enumerated()), id: \.element) { idx, section in
                            sleepSectionView(section, resolved).staggeredAppear(index: idx + 1)
                        }
                    }
                } else {
                    emptyState
                }
            }
            // LiquidScoreGauge owns its own count-up animation (same as Home heroes).
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
                // The night's RECORDED coverage for the #940 guards: from the immutable detected
                // onset (where the strap actually saw the night; an earlier hand-set onset widens
                // it) through the current wake. A corrected window that abandons this range has no
                // data to stage from, so the editor confirms the move instead of silently creating
                // a phantom night.
                let coverageLo = min(edit.detectedStartTs, edit.bedTs)
                SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                                coverage: coverageLo...max(edit.wakeTs, coverageLo + 1),
                                suppressesReDetection: !edit.userEdited,
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
                    // #65: the returned snapshot lets the user UNDO within a few seconds. It restores the
                    // deleted row into its ORIGINAL namespace and lifts the tombstone.
                    let snapshot = await repo.deleteSleepSession(detectedStartTs: edit.detectedStartTs,
                                                                 endTs: edit.wakeTs)
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                    // `edit.bedTs` is the effective (displayed) onset, so the banner shows the same clock
                    // time the user saw for this night.
                    if let snapshot { presentSleepUndo(snapshot, displayStart: edit.bedTs, windowEnd: edit.wakeTs) }
                })
            }
            // Manually add a missed nap (#508): same picker, but the chosen window is staged from raw and
            // stored as its OWN separate session — never folded into main sleep (which would mislabel the
            // awake daytime gap as light sleep).
            .sheet(isPresented: $showSleepCustomize) {
                SleepCustomizationSheet(
                    sectionOrderRaw: $sleepSectionOrderRaw,
                    hiddenSectionsRaw: $sleepHiddenSectionsRaw
                )
            }
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

    // MARK: - Delete undo (#65)

    /// Show the transient UNDO banner after a suppressing delete, and arm the 7-second auto-dismiss. A
    /// second delete replaces the banner (its old auto-dismiss task is cancelled first) so only the most
    /// recent delete is undoable. Single-level and transient, matching the WorkoutsView postLogNote idiom.
    private func presentSleepUndo(_ snapshot: SleepDeletionSnapshot, displayStart: Int, windowEnd: Int) {
        sleepUndoTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            sleepUndo = SleepUndoBanner(snapshot: snapshot, identityStart: snapshot.session.startTs,
                                        displayStart: displayStart, windowEnd: windowEnd)
        }
        let armed = snapshot.session.startTs
        sleepUndoTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if this is still the banner we armed (a newer delete would have replaced it).
                if sleepUndo?.identityStart == armed {
                    withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil }
                }
            }
        }
    }

    /// Undo the most recent suppressing delete: restore the row into its ORIGINAL namespace, lift the
    /// tombstone, re-score, then dismiss the banner.
    private func undoSleepDelete(_ banner: SleepUndoBanner) async {
        sleepUndoTask?.cancel()
        await repo.undoDeleteSleepSession(banner.snapshot)
        await intelligence.analyzeRecent()
        await repo.refresh()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil } }
    }

    /// Locale-formatted clock time (no date) for the banner's window range.
    private func clockTime(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(date: .omitted, time: .shortened)
    }

    /// The transient undo strip: a Rest-tinted frosted banner with the suppressed window and a real Undo
    /// Button. role-alert-ish for VoiceOver; the Undo button carries its own explicit label.
    @ViewBuilder
    private func sleepUndoBanner(_ banner: SleepUndoBanner) -> some View {
        // Branch the copy on userEdited: a hand-edited/added night writes NO tombstone (it is never
        // re-detected), so the suppression promise would be false for it. Only a DETECTED delete writes a
        // tombstone, so only it gets the "won't detect ... again" wording. (#65 banner honesty.)
        let message = banner.snapshot.session.userEdited
            ? String(localized: "Sleep deleted.")
            : String(localized: "Sleep deleted. NOOP won't detect sleep between \(clockTime(banner.displayStart)) and \(clockTime(banner.windowEnd)) again.")
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await undoSleepDelete(banner) }
            } label: {
                Text("Undo").font(StrandFont.footnote.weight(.semibold))
            }
            .buttonStyle(LiquidPressStyle())
            .foregroundStyle(StrandPalette.restColor)
            .accessibilityLabel("Undo sleep deletion")
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.restColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .strokeBorder(StrandPalette.restColor.opacity(0.22), lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }

    /// A short night-relative label ("Last night" / "1 night ago" / "N nights ago") for the
    /// ◀/▶-navigated night. Shared by the Rest hero overline and the hypnogram nav header so both
    /// name the SAME night the hero's score is now resolved for.
    private var nightRelativeLabel: LocalizedStringKey {
        let n = nightsAgo(nightOffset)
        return n == 0 ? "Last night" : (n == 1 ? "1 night ago" : "\(n) nights ago")
    }

    /// #1311: how many CALENDAR nights back the carousel night at `offset` is from the newest recorded
    /// night. The ◀/▶ carousel steps by RECORDED night (`navDays`, newest-first), so a night with no
    /// data (strap off-body) is a gap the flat index can't see — labelling by index makes two nights
    /// either side of a skipped night read as consecutive and desyncs the "N nights ago" labels (and the
    /// Rest value they name). Uses the same local start-of-day `navDays` is grouped by; falls back to the
    /// raw index if it can't resolve. 0 = last night. Mirrors Android SleepHeroLogic.calendarNightsAgo.
    private func nightsAgo(_ offset: Int) -> Int {
        let days = navDays
        guard offset >= 0, offset < days.count,
              let newestTs = days.first?.first?.endTs, let shownTs = days[offset].first?.endTs
        else { return offset }
        let cal = Calendar.current
        let shown = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(shownTs)))
        let newest = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(newestTs)))
        let d = cal.dateComponents([.day], from: shown, to: newest).day ?? offset
        return d >= 0 ? d : offset
    }

    /// The night the Rest hero reflects: the ◀/▶-navigated night while browsing (falling back to
    /// last night only if that navigated night hasn't decoded yet), else last night. Keeps the
    /// hero's score, vessel fill, state word, provenance badge and overline on the SAME night the
    /// hypnogram shows — the fix for the score freezing on last night's value during navigation.
    private func heroNight(_ model: SleepModel) -> Night {
        (nightOffset == 0 ? model.night : navNight) ?? model.night
    }

    /// The sleep-performance score (0–100) for a SPECIFIC night: the imported WHOOP figure for that
    /// night's LOCAL wake-day when the export carried one, else the resolved Rest composite for that
    /// day. Mirrors `performanceSeries`'s per-day transform exactly (the same single source of truth
    /// the Today Rest score reads), keyed by the wake-day (sleep is filed under the day you woke) so
    /// a navigated past night reads ITS OWN score, never last night's. nil when that day has no score.
    private func performanceScore(for night: Night) -> Double? {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if let p = repo.importedSleep[wakeDay]?.performancePct { return p }
        guard let daily = repo.days.last(where: { $0.day == wakeDay }) else { return nil }
        return AnalyticsEngine.Rest.composite(daily: daily)
    }

    /// Dispatch a reorderable Sleep section to its card. Naps rides with `.stages` (drawn inside the stages
    /// hero); the Rest hero is pinned outside this list. Mirrors the Android SleepScreen `when(section)`.
    @ViewBuilder
    private func sleepSectionView(_ section: SleepSection, _ model: SleepModel) -> some View {
        switch section {
        case .sleepMarks:      SleepMarkCard()
        case .stages:          hero(model)
        case .nightDetail:     NightDetailCard(model: model)
        case .sleepDebt:       SleepDebtLedgerCard(model: model)
        case .stagesVsTypical: StagesVsTypicalCard(model: model)
        case .asleepDuration:  durationTrend(model)
        }
    }

    /// The compact "Customize" affordance above the arrangeable cards — opens the Arrange sheet. Mirrors
    /// the Today tab's arrange entry and the Android Sleep affordance.
    private var sleepArrangeAffordance: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                showSleepCustomize = true
            } label: {
                Label("Customize", systemImage: "slider.horizontal.3")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Immersive Rest-world hero: compact Bevel-like hierarchy — centered "Sleep", muted circular
    /// performance ring, state word, source badge. Night scene lives on ScreenScaffold.topBackground
    /// (fixed under the status bar); this column only owns the readable content. Presentation-only.
    @ViewBuilder
    private func restHero(_ model: SleepModel) -> some View {
        let night = heroNight(model)
        let score = performanceScore(for: night)
        VStack(spacing: 0) {
            Text("Sleep")
                .font(StrandFont.rounded(24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)

            if let score {
                // Same LiquidVessel gauge as Home (`LiquidTodayView` / `HeroScoreCell`).
                VStack(spacing: 8) {
                    LiquidScoreGauge(
                        score: score,
                        tint: StrandPalette.restColor,
                        diameter: 184,
                        animated: true,
                        captionText: String(localized: "of 100"),
                        numberColor: Color.white.opacity(0.98),
                        captionColor: Color.white.opacity(0.52)
                    )
                    Text(sleepScoreWord(score))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.90))
                        .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Sleep performance \(Int(score.rounded())) of 100, \(sleepScoreWord(score))"))
            } else {
                VStack(spacing: NoopMetrics.space1) {
                    CountUpText(
                        value: night.stages.asleep,
                        format: { durationText($0) },
                        font: StrandFont.number(42),
                        color: Color.white.opacity(0.96)
                    )
                    Text("asleep last night")
                        .font(StrandFont.subhead)
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
            }

            SourceBadge(
                score != nil ? heroSource(for: night) : (repo.activeDeviceIsOura ? "Oura" : "On-device"),
                tint: StrandPalette.restColor
            )
            .padding(.top, 8)

            // Subtle Customize at the hero foot — functional, not competing with the gauge.
            sleepArrangeAffordance
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// Fixed night-scene band behind Sleep scroll content — same ScreenScaffold.topBackground pattern
    /// as Home's sky. Tall enough for safe-area + hero; fades to surfaceBase before the first card.
    private var sleepNightTopBackground: some View {
        SleepPerformanceNightScene()
            .frame(maxWidth: .infinity)
            .frame(height: 440, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A short Rest state word for the hero gauge — same banding the synthesis hero uses.
    private func sleepScoreWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return String(localized: "Poor")
        case ..<70:  return String(localized: "Fair")
        case ..<85:  return String(localized: "Good")
        default:     return String(localized: "Optimal")
        }
    }

    /// Whether a SPECIFIC night's sleep-performance score is WHOOP's own imported figure, an Oura
    /// ring-provided figure, or NOOP's on-device approximation — so the hero is honest about provenance,
    /// like Today's badges. Keyed by the night's wake-day (matching `performanceScore(for:)`) so a
    /// navigated night's badge tracks ITS OWN score's provenance, not last night's.
    private func heroSource(for night: Night) -> LocalizedStringKey {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if repo.importedSleep[wakeDay]?.performancePct != nil { return "Whoop" }
        return repo.activeDeviceIsOura ? "Oura" : "On-device"
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
        if repo.importedSleep[wakeDay] != nil { return String(localized: "Whoop") }
        // An Oura ring PROVIDES the night's stages (its own SleepNet hypnogram, banked as the imported
        // session that wins the merge), so name it "Oura" — not the generic "On-device" that implies a
        // NOOP computation. WHOOP import still wins above; only a night surfaced under a live Oura strap
        // reaches here as "Oura".
        if repo.activeDeviceIsOura { return String(localized: "Oura") }
        return String(localized: "On-device")
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
            // #940: when the NEWEST day failed to merge (model.isStubNight), offset 0 falls through
            // to the same honest stage-less stub path the navigated browse uses, instead of drawing
            // a zeroed stage card. History stays browsable and the edit pencil stays reachable.
            if nightOffset == 0, !model.isStubNight {
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
                    subtitle: String(localized: "\(durationText(Double(session.endTs - session.startTs) / 60.0)) in bed"),
                    height: NoopMetrics.chartHeight,
                    tint: StrandPalette.restColor,
                    chart: { noStagePlaceholder }
                )
                napSection(stub)
            }
        }
        // Stale-highlight guard: browsing to another night clears the stage selection. Attached to
        // the always-present hero container (not a branch that gets swapped out mid-navigation).
        .onChange(of: nightOffset) { _ in selectedStage = nil }
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
                    .buttonStyle(LiquidPressStyle())
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
            .buttonStyle(LiquidPressStyle())
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
                                    stagesJSON: nap.stagesJSON,
                                    userEdited: true)   // a nap row is always manually added → no tombstone on delete
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .help("Edit nap times")
            .accessibilityLabel(isEdited ? "Edit nap times (edited)" : "Edit nap times")
        }
    }

    /// "HH:mm–HH:mm" clock window for a nap row (device 12-/24-h setting via the shared Night formatter).
    private func napWindowText(_ nap: CachedSleepSession) -> String {
        let start = Night.clockString(nap.effectiveStartTs)
        let end = Night.clockString(nap.endTs)
        return "\(start)-\(end)"
    }

    /// The stage-breakdown ChartCard for a decoded night: hypnogram when intervals
    /// reconstruct, else the proportional stage bar. Intervals are passed in so offset 0
    /// uses the memoized `model.intervals` rather than re-deriving them. (#160)
    @ViewBuilder
    private func stageCard(_ night: Night, intervals: [SleepInterval]) -> some View {
        let s = night.stages
        let isPersisted = (night.realSegments?.count ?? 0) >= 2
        // An Oura night's stages are the ring's RAW on-device SleepNet classification (decoded off the 0x49
        // phase stream), NOT a NOOP approximation — so it gets its own honest caption instead of the
        // "stages approximate (on-device)" one that describes NOOP's own sparse-motion staging.
        let stageCaption = repo.activeDeviceIsOura
            ? String(localized: "raw on-device stages")
            : String(localized: "stages approximate (on-device)")
        let subtitle = isPersisted
            ? String(localized: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency · \(stageCaption)")
            : String(localized: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency")
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if intervals.count >= 2 {
                // #sleep-chart-style (Settings → Appearance): Classic keeps the per-stage timeline ROWS
                // (ryanAtriumAi #988) — hatched track = the whole night, solid segments = when that stage
                // occurred, tap a row to highlight it. Filled/Ribbon draw the WHOOP-style single stepped
                // hypnogram (filled to the baseline, or a slim band) with the breakdown rows as the legend.
                let chartStyle = SleepChartStyle.resolve(sleepChartStyleRaw)
                switch chartStyle {
                case .classic:
                    stageTimelineCard(s, subtitle: subtitle, intervals: intervals, night: night)
                case .filled, .garminFilled, .ribbon:
                    steppedHypnogramCard(s, subtitle: subtitle, intervals: intervals, night: night,
                                         style: chartStyle)
                }
            } else {
                ChartCard(
                    title: "Stage breakdown",
                    subtitle: subtitle,
                    trailing: durationText(s.asleep),
                    height: NoopMetrics.chartHeight,
                    tint: StrandPalette.restColor,
                    chart: { stageBar(s) },
                    footer: { stageBreakdownRows(s) }
                )
            }
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
            // #345 follow-up: when a night was staged on SPARSE motion coverage it can UNDER-detect — the
            // gravity-only spine fragments and the sub-60-min pieces are dropped, so a real ~8h night can
            // collapse to a fraction ("slept 8h, app shows 1h"). Say so honestly so the short total isn't
            // read as fact. Distinct from the H9 note above (a plausible-duration night with an off split).
            if stageStagingIsSparse(night) {
                stageIncompleteNote
            }
            // For an Oura-provided night, say plainly that this split is the ring's RAW on-device
            // classification — so the larger Awake / smaller Deep+REM here isn't misread as the polished
            // numbers the Oura app shows for the same night (the app post-processes the same stream).
            if repo.activeDeviceIsOura {
                ouraRawStagesNote
            }
        }
        // WHOOP top-chart data (ryanAtriumAi #988): 1-min sleeping-HR buckets for THIS night, reloaded
        // only when the displayed night changes (same `.task(id:)` pattern the other per-night loads use).
        .task(id: night.session.startTs) {
            nightHR = await repo.hrBuckets(from: night.session.startTs,
                                           to: night.session.endTs,
                                           bucketSeconds: 60)
        }
    }

    /// The detailed timeline has a variable-height insight footer, so forcing it into a fixed-height
    /// chart slot left a visibly empty shelf below the hint. This keeps the standard card header and
    /// surface while allowing the timeline to size to the content it actually has.
    private func stageTimelineCard(_ stages: Stages, subtitle: String,
                                   intervals: [SleepInterval], night: Night) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Stage breakdown").strandOverline()
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                stageTimeline(stages, intervals: intervals, night: night)
            }
        }
    }

    /// #sleep-chart-style — the WHOOP-style single stepped hypnogram (Filled = each stage banded down to
    /// the baseline, Ribbon = a slim band at each stage level), with the per-stage breakdown rows below as
    /// the legend. Mirrors the Android FilledHypnogram card; only routed here when the night has ≥2 real
    /// segments (the shared `intervals`). The stages/totals are identical to Classic — this only redraws.
    @ViewBuilder
    private func steppedHypnogramCard(_ s: Stages, subtitle: String, intervals: [SleepInterval],
                                      night: Night, style: SleepChartStyle) -> some View {
        ChartCard(
            title: "Stage breakdown",
            subtitle: subtitle,
            trailing: durationText(s.asleep),
            height: NoopMetrics.chartHeight,
            tint: StrandPalette.restColor,
            chart: {
                Hypnogram(
                    intervals: intervals,
                    height: NoopMetrics.chartHeight,
                    showsStageAxis: false,
                    showsHover: true,
                    nightStart: night.onsetDate,
                    showsTimeAxis: true,
                    filled: style.isFilled,
                    stagePalette: style.stagePalette
                )
            },
            // A colour-coded key in the chart's ramp so the bands are decodable (esp. the Garmin ramp's two
            // pinks), then the per-stage breakdown rows below.
            footer: {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    SleepStageLegend(palette: style.stagePalette)
                    stageBreakdownRows(s)
                }
            }
        )
    }

    /// #407 — the per-epoch movement/restlessness strip drawn UNDER the hypnogram, on the SAME timeline.
    /// Reads the already-resolved main-night GROUP's persisted motion off `night.motionEpochs` (laid
    /// fragment-by-fragment in `mergeDay`, NO re-resolution of the night). The left inset (44pt axis + 12pt
    /// spacing) matches the Hypnogram's `HStack` so the strip's plot lines up under the stage bands above.
    /// When the night has no persisted motion (older rows whose `motionJSON` is NULL) it shows an HONEST
    /// empty note rather than a fabricated flat zero trace.
    @ViewBuilder
    private func motionStrip(_ night: Night) -> some View {
        // Label above the trace, plot inset 10pt to line up with the stage-timeline rows' strips
        // (the old 44+12 gutter matched the removed Hypnogram's y-axis column). (ryanAtriumAi #988)
        VStack(alignment: .leading, spacing: 2) {
            Text("Move")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            if night.motionEpochs.count >= 2 {
                MotionTrace(epochs: night.motionEpochs, height: 40, tint: StrandPalette.restColor)
                    .padding(.horizontal, 10)
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

    /// True when this night was staged on SPARSE motion coverage — the persisted `stagingSparse` flag the
    /// engine sets from `SleepStager.isGravitySparse` (#345). Such a night can UNDER-detect: the gravity-only
    /// spine fragments and sub-60-min pieces are dropped, so a real night collapses to a fraction. Reads the
    /// day's REAL stored blocks (each carries the day's value), never the synthetic merged `session`; a nil
    /// flag (imported / pre-migration night) is never flagged. Mirror in Kotlin.
    private func stageStagingIsSparse(_ night: Night) -> Bool {
        night.sourceBlocks.contains { $0.stagingSparse == true }
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
            Text("This night scored high efficiency but very little deep or REM, more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Low confidence staging. This night scored high efficiency but very little deep or REM, more likely an estimate miss than a real restorative shortfall.")
    }

    /// The sparse-coverage caveat: a night staged on thin motion data can under-detect and collapse a real
    /// night to a fraction ("slept 8h, shows 1h"). Honest + actionable — tells the user to make sure the
    /// strap fully synced. Distinct from the H9 note (an off deep/REM split, not a short total). (#345)
    private var stageIncompleteNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("May be incomplete", tint: StrandPalette.statusWarning)
            Text("Your strap recorded little movement overnight (common on WHOOP 4.0), so this night may be under-detected and the sleep total can read short. Make sure the strap fully synced; the numbers are kept as-is.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        // `.combine` builds the a11y label from the badge + body Text (no separate localized string).
        .accessibilityElement(children: .combine)
    }

    /// Honest caveat for an Oura-provided night: the stage split shown here is the ring's RAW on-device
    /// SleepNet classification, read straight off the BLE phase stream — NOT the adjusted stages the Oura
    /// app displays. The app post-processes the same night, so its Deep/REM run higher and its Awake lower;
    /// cross-checks put our Awake well above the app's. Surfaced so the breakdown isn't taken for the app's.
    private var ouraRawStagesNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("Raw on-device stages", tint: StrandPalette.restColor)
            Text("This split is the ring's raw on-device classification read over Bluetooth, not the adjusted stages the Oura app shows. Expect more Awake and less Deep/REM here than in the Oura app for the same night.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Raw on-device stages. This split is the ring's raw on-device classification read over Bluetooth, not the adjusted stages the Oura app shows. Expect more awake and less deep or REM here than in the Oura app for the same night.")
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
                    // This is a compact metadata footer inside an already surfaced card. A forced
                    // 44-point label made the WHOOP / Why row look vertically padded despite having
                    // only one line of content.
                    .frame(minHeight: NoopMetrics.compactMetadataMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
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
        .background(NoopPanelSurface(cornerRadius: NoopVisualStyle.compactRadius, elevated: true))
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
                                    stagesJSON: target.stagesJSON,
                                    userEdited: isEdited)
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
            }
            .buttonStyle(LiquidPressStyle())
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
            .accessibilityLabel("Sleep stage breakdown: deep \(stageSharePercent(.deep, s)) percent, light \(stageSharePercent(.light, s)) percent, REM \(stageSharePercent(.rem, s)) percent, awake \(stageSharePercent(.awake, s)) percent")
            HStack(spacing: 16) {
                legend(.deep, String(localized: "Deep"))
                legend(.light, String(localized: "Light"))
                legend(.rem, String(localized: "REM"))
                legend(.awake, String(localized: "Awake"))
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
            stageBreakdownRow(.rem,   minutes: s.rem,   total: s.total, percent: stageSharePercent(.rem, s))
            stageBreakdownRow(.deep,  minutes: s.deep,  total: s.total, percent: stageSharePercent(.deep, s))
            stageBreakdownRow(.light, minutes: s.light, total: s.total, percent: stageSharePercent(.light, s))
            stageBreakdownRow(.awake, minutes: s.awake, total: s.total, percent: stageSharePercent(.awake, s))
        }
    }

    /// The night's four stages as whole percentages that sum to exactly 100 (largest-remainder), so the
    /// breakdown rows, the timeline rows and the stage-bar read-out all print ONE apportionment: they agree
    /// with each other and add up. The bar fills still track the raw `minutes / total` fraction. Falls back
    /// to 0 for a night with no minutes. Twin of Android `stageSharePercent`. (tanarchytan)
    private func stageSharePercent(_ stage: SleepStage, _ s: Stages) -> Int {
        guard let p = StagePercentages.wholePercentages([s.awake, s.light, s.deep, s.rem]) else { return 0 }
        switch stage {
        case .awake: return p[0]
        case .light: return p[1]
        case .deep:  return p[2]
        case .rem:   return p[3]
        }
    }

    /// One WHOOP-style stage row. `fraction = minutes / total` sets the bar fill; `percent` is the night's
    /// apportioned share (so the four rows sum to 100). Tappable (WHOOP, ryanAtriumAi #988): selecting a
    /// row highlights that stage and recedes the rest; tapping the selected row again clears the highlight.
    @ViewBuilder
    private func stageBreakdownRow(_ stage: SleepStage, minutes: Double, total: Double, percent: Int) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let fraction = total > 0 ? min(1, max(0, minutes / total)) : 0
        let isSelected = selectedStage == stage
        let othersSelected = selectedStage != nil && !isSelected
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
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isSelected ? 0.14 : 0))
        )
        .opacity(othersSelected ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StrandMotion.fade) {
                selectedStage = isSelected ? nil : stage
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(percent) percent of the night")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - WHOOP stage-timeline rows (the sleep-details reference design, ryanAtriumAi #988)

    /// Clock labels for the timeline axis; "jmm" respects the device 12/24-hour setting.
    private static let stageAxisFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = AppLanguage.activeLocale; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()

    /// The WHOOP sleep-stages chart: a stack of four per-stage timeline rows (AWAKE · LIGHT ·
    /// DEEP · REM, WHOOP's order) over a shared onset→wake time axis. Each row is independently
    /// legible no matter how fragmented the on-device staging is — segments in one row can never
    /// tangle with another stage's, which is exactly why WHOOP renders sleep this way.
    @ViewBuilder
    private func stageTimeline(_ s: Stages, intervals: [SleepInterval], night: Night) -> some View {
        // Light display smoothing (90s) keeps WHOOP's fine tick texture while dropping epoch noise;
        // the hypnogram needed 300s because stages shared one staircase — rows tolerate detail.
        let smoothed = Hypnogram.displaySmoothed(intervals.sorted { $0.start < $1.start }, minDuration: 90)
        let origin = smoothed.first?.start ?? 0
        let span = max(1, (smoothed.map(\.end).max() ?? 1) - origin)
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            // WHOOP's hero pair: HOURS OF SLEEP + RESTORATIVE SLEEP (deep + REM), each against
            // its 30-day typical.
            sleepHeadline(s)
            // WHOOP's sleeping heart-rate chart above the rows: thin HR trace across the night.
            // Selecting a stage tints the trace + washes the chart columns during that stage.
            sleepHRChart(intervals: smoothed, origin: origin, span: span, night: night)
                .frame(height: 124)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            stageTimelineRow(.awake, minutes: s.awake, percent: stageSharePercent(.awake, s), intervals: smoothed, origin: origin, span: span)
            stageTimelineRow(.light, minutes: s.light, percent: stageSharePercent(.light, s), intervals: smoothed, origin: origin, span: span)
            stageTimelineRow(.deep,  minutes: s.deep,  percent: stageSharePercent(.deep, s), intervals: smoothed, origin: origin, span: span)
            stageTimelineRow(.rem,   minutes: s.rem,   percent: stageSharePercent(.rem, s), intervals: smoothed, origin: origin, span: span)
            // onset · midpoint · wake clock labels, aligned with the rows' inner strips.
            HStack {
                Text(Self.stageAxisFormatter.string(from: night.onsetDate))
                Spacer()
                Text(Self.stageAxisFormatter.string(from: night.onsetDate.addingTimeInterval(span / 2)))
                Spacer()
                Text(Self.stageAxisFormatter.string(from: night.onsetDate.addingTimeInterval(span)))
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 10)
            .accessibilityHidden(true)
            // WHOOP's per-stage insight: with a stage selected, tonight vs the 30-day typical
            // range; otherwise a quiet hint that the rows are tappable. It grows only when a
            // selected-stage comparison needs a second line, avoiding a permanent empty footer.
            stageInsight(s)
                .frame(minHeight: NoopMetrics.compactHintMinHeight, alignment: .topLeading)
                .padding(.horizontal, 2)
        }
    }

    /// WHOOP's hero pair for the night: HOURS OF SLEEP and RESTORATIVE SLEEP (deep + REM), each
    /// with its trailing-30-day typical underneath — the "how does tonight compare" read without
    /// leaving the card.
    @ViewBuilder
    private func sleepHeadline(_ s: Stages) -> some View {
        let restorative = s.deep + s.rem
        HStack(alignment: .top, spacing: NoopMetrics.space6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(durationText(s.asleep))
                    .font(StrandFont.number(26))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("HOURS OF SLEEP")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let t = stageTypical(nil) {
                    Text("typically \(durationText(t.mean))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(durationText(restorative))
                    .font(StrandFont.number(26))
                    .foregroundStyle(StrandPalette.sleepREM)
                Text("RESTORATIVE SLEEP")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let t = restorativeTypical() {
                    Text("typically \(durationText(t))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// The tonight-vs-typical line under the stage rows. Selected: "REM 2h 45m · typically
    /// 1h 50m to 2h 20m, above your usual." Unselected: the tap affordance hint.
    @ViewBuilder
    private func stageInsight(_ s: Stages) -> some View {
        if let sel = selectedStage {
            let minutes = stageMinutes(sel, in: s)
            if let t = stageTypical(sel) {
                let phrase = minutes > t.hi ? String(localized: "above your usual")
                    : (minutes < t.lo ? String(localized: "below your usual")
                                      : String(localized: "about your usual"))
                (Text(sel.label).fontWeight(.semibold).foregroundColor(StrandPalette.sleepStageColor(sel))
                    + Text(" \(durationText(minutes)) · typically \(durationText(t.lo)) to \(durationText(t.hi)), \(phrase)."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            } else {
                Text("\(sel.label): \(durationText(minutes)). Not enough history yet for a typical range.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
        } else {
            Text("Tap a stage to compare with your 30-day typical.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Tonight's minutes for one stage out of the decoded totals.
    private func stageMinutes(_ stage: SleepStage, in s: Stages) -> Double {
        switch stage {
        case .awake: return s.awake
        case .light: return s.light
        case .deep:  return s.deep
        case .rem:   return s.rem
        }
    }

    /// Per-stage typical minutes over the trailing 30 scored days: the 25th–75th percentile band
    /// plus the mean — WHOOP's "typical range". Pass nil for total asleep. Returns nil below 5
    /// scored nights (honest cold-start: no fabricated range from a few days).
    private func stageTypical(_ stage: SleepStage?) -> (lo: Double, hi: Double, mean: Double)? {
        let values: [Double] = repo.days.suffix(30).compactMap { d in
            switch stage {
            case nil:     return d.totalSleepMin
            case .light?: return d.lightMin
            case .deep?:  return d.deepMin
            case .rem?:   return d.remMin
            case .awake?:
                // Awake isn't a stored daily column; derive from in-bed minus asleep via efficiency.
                guard let asleep = d.totalSleepMin, asleep > 0, var e = d.efficiency, e > 0 else { return nil }
                if e > 1.5 { e /= 100 }   // efficiency arrives as % on some import paths
                guard e > 0.3, e <= 1 else { return nil }
                return asleep * (1 - e) / e
            }
        }.filter { $0 > 0 }.sorted()
        guard values.count >= 5 else { return nil }
        func pct(_ p: Double) -> Double {
            let idx = p * Double(values.count - 1)
            let l = Int(idx.rounded(.down)), u = Int(idx.rounded(.up))
            let frac = idx - Double(l)
            return values[l] * (1 - frac) + values[u] * frac
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (pct(0.25), pct(0.75), mean)
    }

    /// 30-day mean restorative minutes (deep + REM per scored night).
    private func restorativeTypical() -> Double? {
        let values: [Double] = repo.days.suffix(30).compactMap { d in
            guard let deep = d.deepMin, let rem = d.remMin else { return nil }
            let v = deep + rem
            return v > 0 ? v : nil
        }
        guard values.count >= 5 else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// One WHOOP stage row: header (STAGE · coloured % · right-aligned duration) above a hatched
    /// night-long track with solid segments where the stage occurred. Tap toggles the highlight:
    /// the selected row keeps its colour + gains a border while every other row's segments grey out.
    @ViewBuilder
    private func stageTimelineRow(_ stage: SleepStage, minutes: Double, percent: Int,
                                  intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let isSelected = selectedStage == stage
        let dimmed = selectedStage != nil && !isSelected
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(stage.label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(percent)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(dimmed ? StrandPalette.textTertiary : color)
                Spacer()
                Text(durationText(minutes))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    StageHatchedTrack()
                    ForEach(intervals.filter { $0.stage == stage }) { iv in
                        let x0 = CGFloat((iv.start - origin) / span) * geo.size.width
                        let w = max(2, CGFloat((iv.end - iv.start) / span) * geo.size.width)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(dimmed ? StrandPalette.textTertiary.opacity(0.55) : color)
                            .frame(width: w, height: geo.size.height)
                            .offset(x: x0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 20)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StrandPalette.textPrimary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? StrandPalette.hairlineStrong : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StrandMotion.fade) { selectedStage = isSelected ? nil : stage }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(percent) percent of the night")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(.isButton)
    }

    /// WHOOP's sleeping heart-rate chart: a thin HR trace across the night with dashed onset/wake
    /// rules and quiet bpm gridlines. With a stage selected, the trace re-colours inside that
    /// stage's intervals and those time columns get a faint stage-tinted wash — WHOOP's "what did
    /// my heart do during REM" read. Canvas-drawn (~550 one-minute buckets), gaps in the data
    /// break the line honestly rather than interpolating across them.
    @ViewBuilder
    private func sleepHRChart(intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval, night: Night) -> some View {
        let nightStartTs = night.onsetDate.timeIntervalSince1970
        let buckets = nightHR.filter {
            let rel = TimeInterval($0.ts) - nightStartTs
            return rel >= origin - 60 && rel <= origin + span + 60
        }
        if buckets.count >= 2 {
            Canvas { ctx, size in
                let bpms = buckets.map(\.bpm)
                let lo = (bpms.min() ?? 40) - 5
                let hi = (bpms.max() ?? 90) + 5
                func point(_ b: HRBucket) -> CGPoint {
                    let rel = TimeInterval(b.ts) - nightStartTs
                    let x = CGFloat((rel - origin) / span) * size.width
                    let y = size.height * (1 - CGFloat((b.bpm - lo) / max(1, hi - lo)))
                    return CGPoint(x: x, y: y)
                }
                // Selected-stage column washes UNDER everything else.
                if let sel = selectedStage {
                    let wash = StrandPalette.sleepStageColor(sel).opacity(0.13)
                    for iv in intervals where iv.stage == sel {
                        let x0 = CGFloat((iv.start - origin) / span) * size.width
                        let w = max(1, CGFloat((iv.end - iv.start) / span) * size.width)
                        ctx.fill(Path(CGRect(x: x0, y: 0, width: w, height: size.height)), with: .color(wash))
                    }
                }
                // Quiet bpm gridlines + labels at ~3 nice values.
                let step = max(10.0, (((hi - lo) / 3) / 10).rounded() * 10)
                var grid = (lo / step).rounded(.up) * step
                while grid < hi {
                    let y = size.height * (1 - CGFloat((grid - lo) / max(1, hi - lo)))
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(line, with: .color(StrandPalette.hairline.opacity(0.5)), lineWidth: 1)
                    ctx.draw(Text(verbatim: "\(Int(grid))").font(.system(size: 9)).foregroundColor(StrandPalette.textTertiary),
                             at: CGPoint(x: 10, y: y - 7))
                    grid += step
                }
                // Base trace across the whole night; the line BREAKS across >5-min data gaps.
                // Split by signal confidence: clean/measured HR draws solid, weak-optical stretches
                // (PPG conf < 0.3) draw lighter + dashed, so a weak estimate is never presented as a
                // clean measured beat. NOTE: with the default acceptance floor (0.3) no stored PPG
                // sample carries conf < 0.3, so this weak branch is inert unless a future opt-in
                // weak-signal mode (which needs a faithfulness eval first) lowers the floor.
                let baseColor = selectedStage == nil
                    ? StrandPalette.restColor.opacity(0.9)
                    : StrandPalette.textTertiary.opacity(0.45)
                var strong = Path()
                var weakPath = Path()
                var prev: (ts: Int, pt: CGPoint, strong: Bool)? = nil
                for b in buckets {
                    let p = point(b)
                    let isStrong = b.conf >= 0.3
                    if let pr = prev, b.ts - pr.ts <= 300 {
                        // Bridge class transitions from the previous point so the trace stays
                        // continuous — the weak segment owns the bridging stroke.
                        if isStrong {
                            if pr.strong { strong.addLine(to: p) }
                            else { strong.move(to: pr.pt); strong.addLine(to: p) }
                        } else {
                            if !pr.strong { weakPath.addLine(to: p) }
                            else { weakPath.move(to: pr.pt); weakPath.addLine(to: p) }
                        }
                    } else {
                        if isStrong { strong.move(to: p) } else { weakPath.move(to: p) }
                    }
                    prev = (b.ts, p, isStrong)
                }
                ctx.stroke(strong, with: .color(baseColor), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                ctx.stroke(weakPath, with: .color(baseColor.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [2, 3]))
                // Selected-stage trace overlay: the HR line re-drawn in the stage colour, only
                // inside that stage's intervals.
                if let sel = selectedStage {
                    let ranges = intervals.filter { $0.stage == sel }.map { ($0.start, $0.end) }
                    var overlay = Path()
                    var lastIn: Int? = nil
                    for b in buckets {
                        let rel = TimeInterval(b.ts) - nightStartTs
                        let inside = ranges.contains { rel >= $0.0 && rel <= $0.1 }
                        if inside {
                            let p = point(b)
                            if let last = lastIn, b.ts - last <= 300 { overlay.addLine(to: p) } else { overlay.move(to: p) }
                            lastIn = b.ts
                        } else {
                            lastIn = nil
                        }
                    }
                    ctx.stroke(overlay, with: .color(StrandPalette.sleepStageColor(sel)),
                               style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
                // Dashed onset/wake rules (WHOOP's sleep-window markers).
                for x in [CGFloat(0.75), size.width - 0.75] {
                    var rule = Path()
                    rule.move(to: CGPoint(x: x, y: 0)); rule.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(rule, with: .color(StrandPalette.textTertiary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(Text("Sleeping heart rate through the night"))
        } else {
            Text("No heart-rate detail for this night")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// WHOOP's diagonal-hatched timeline track: subtle 45° stripes over a dark inset well — reads
    /// as "the whole night" behind the solid stage segments, and makes gaps (other stages) obvious
    /// without drawing anything for them.
    private struct StageHatchedTrack: View {
        var body: some View {
            ZStack {
                Rectangle().fill(StrandPalette.surfaceInset.opacity(0.9))
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 5
                    var x: CGFloat = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += step
                    }
                    context.stroke(path, with: .color(StrandPalette.textTertiary.opacity(0.16)), lineWidth: 1)
                }
            }
        }
    }

    // MARK: - 2. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)
    //
    // The "Night detail" grid now lives in `NightDetailCard` (a standalone view) so it can ALSO be hosted
    // in the Today tab from the SAME `SleepModel`. `sleepSectionView(.nightDetail)` renders `NightDetailCard`
    // directly; the grid body and its tile-formatting helpers (`pctValue` / `rrValue` / `vsTypical` /
    // `debtCaption` / `debtColor` / `spark` / `tileColumns`) moved there with it.

    // The "Sleep-debt ledger" card now lives in `SleepDebtLedgerCard` (a standalone view) so it can ALSO
    // be hosted in the Today tab from the SAME `SleepModel`. `sleepSectionView(.sleepDebt)` renders
    // `SleepDebtLedgerCard` directly; the card body, its `debtDeltaBars` strip and the debt-only
    // formatters (`debtHeadline` / `debtTag` / `debtRead` / `debtBalanceColor` / `debtSigned`) moved there
    // with it — they had no other caller in SleepView.

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    private func durationTrend(_ model: SleepModel) -> some View {
        // #today-hosted-cards: the card view was extracted to AsleepDurationCard so Today can host it.
        // The memoized model values keep the Sleep-tab perf (no per-render recompute); the Today host
        // builds AsleepDurationData itself from the same source, so the two render identical numbers.
        AsleepDurationCard(data: AsleepDurationData(points: model.trendPoints,
                                                    typicalTotalMin: model.typicalTotalMin))
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

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes, so each
    /// full pass over repo.days / repo.sleeps runs once per data change rather than once per render.
    /// A thin wrapper: it snapshots the view's current state into `SleepModelInputs` and hands off to
    /// the pure `SleepModel.build(_:)` (SleepModel.swift), which the Today host also calls. Returns
    /// nil when there is no usable latest night (renders empty state).
    private func buildModel() -> SleepModel? {
        SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: allSessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitualMidsleepSec,
            motionByStart: motionByStart))
    }

    // MARK: - Derived model

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list — a thin wrapper over the shared `SleepModel.navDays`, which is the
    /// source of truth the builder and the ◀/▶ nav both read (no duplicated grouping). (#170)
    private var navDays: [[CachedSleepSession]] {
        SleepModel.navDays(navSessions: navSessions)
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

    /// Actual asleep minutes in blocks outside a day's canonical main-night group. The Repository's
    /// all-session union has already removed cross-namespace duplicates; this helper only applies the
    /// same main-vs-nap classification the hero uses and decodes persisted stages. A stage-less nap
    /// contributes nothing rather than substituting its in-bed window. Mirrors Android
    /// `napSleepMinutesByDay`.
    static func napSleepMinutes(_ sessions: [CachedSleepSession],
                                habitualMidsleepSec: Int? = nil) -> Double {
        let mainStarts = Set(mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
            .map { $0.startTs })
        return sessions
            .filter { !mainStarts.contains($0.startTs) }
            .reduce(0) { total, nap in
                total + decodedAsleepMinutes(nap.stagesJSON, effectiveStartTs: nap.effectiveStartTs)
            }
    }

    /// The day's main-night bridged SPAN (onset → wake), the same window `mainNightGroup` bridges into
    /// one continuous night. The ONE canonical bed/wake read every glance screen (Coupled, Today's HR
    /// band) should show — never a screen-local "freshest" or "longest single block" heuristic, which
    /// can silently disagree with each other and with the Sleep tab hero on a night stored as more than
    /// one block (#294). nil only when `sessions` has nothing bridgeable.
    static func mainNightSpan(_ sessions: [CachedSleepSession],
                              habitualMidsleepSec: Int? = nil) -> (start: Int, end: Int)? {
        let group = mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let first = group.first, let last = group.last else { return nil }
        return (first.effectiveStartTs, last.endTs)
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
            return String(localized: "This is your only sleep block today.")
        case .longest:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)).")
        case .longestNearUsual:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime.")
        case .alignedToUsual:
            return String(localized: "Picked as your main sleep because it started near your usual sleep time.")
        }
    }

    // `mergeDay` / `nightOnsetTs` / the fragment-level `isPreOnsetAwakeStub(_:)` moved to
    // SleepModel.swift (pure statics reused by the builder and the ◀/▶ nav). The pure rule statics and
    // tuning constants below stay here — they are the shared source of truth reused by tests and by
    // those moved helpers.

    /// Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
    /// before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of
    /// pre-sleep awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first
    /// sleep fragment is `preOnsetStubAsleepMaxMin`: a stub must be essentially SLEEPLESS, which a real sleep
    /// block never is. The cap only stops a pathological all-day awake block from being silently dropped.
    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    static let preOnsetStubAsleepMaxMin: Double = 3
    /// A leading pre-onset fragment carrying SOME sleep is still spurious when it is minor RELATIVE to the
    /// night's main block: its asleep minutes are below this fraction of the largest fragment's. A genuine
    /// biphasic first sleep is comparable to the main block (well above this) and is kept; only a small stray
    /// lead is dropped. Extends the essentially-sleepless `preOnsetStubAsleepMaxMin` rule (#736), which missed
    /// a lead carrying a few minutes more than 3. Mirrors Android PRE_ONSET_STUB_MINOR_FRAC. (#259)
    static let preOnsetStubMinorFrac: Double = 0.15

    /// Absolute floor (ASLEEP minutes) under the #259 relative "minor lead" test: a leading fragment that
    /// carries at least this much real sleep is a genuine first sleep — a real sleep episode — and is NEVER
    /// a spurious pre-onset lead, however large the main block is. Without it a long main sleep inflates the
    /// 15% relative bar (a 6h night → ~54 min) so a genuine ~34-min first sleep was swallowed and the shown
    /// bedtime jumped hours late, hiding the real onset the bridged night (and the Health write-back, #364)
    /// already spans. 20 min ≈ the shortest standalone sleep episode; below it a handful of asleep minutes
    /// beside a long night is a stray lead. Mirrors Android PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN.
    /// (bridged-night headline: a real 2026-07-14 12:16 first sleep hidden behind the 1:29 main block)
    static let preOnsetStubMinorAsleepFloorMin: Double = 20

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. Spurious when BRIEF and EITHER essentially sleepless OR minor relative to the
    /// main block (`refAsleepMin`, the group's largest asleep span): asleep below `preOnsetStubMinorFrac` of
    /// it AND below the absolute `preOnsetStubMinorAsleepFloorMin` real-sleep-episode floor. `refAsleepMin`
    /// defaults to 0 (relative test off) so existing callers/tests are byte-identical. (#736 / #259)
    static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double, refAsleepMin: Double = 0) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        // #259 relative "minor lead" test, floored: a real sleep episode (>= the floor) is never a stray
        // lead, so a long main block can't inflate the 15% bar past a genuine short first sleep.
        return refAsleepMin > 0
            && asleepMin < preOnsetStubMinorFrac * refAsleepMin
            && asleepMin < preOnsetStubMinorAsleepFloorMin
    }

    /// The index into an ascending-by-onset group whose fragment supplies the DISPLAYED bedtime: the first
    /// fragment that is NOT a spurious leading pre-onset awake stub, falling back to 0 when every fragment is
    /// stub-like. Pure mirror of `nightOnsetTs`'s walk, driven by per-fragment (spanMin, asleepMin) so a
    /// golden test can pin the #736 behaviour without view internals. (#736)
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        let refAsleepMin = asleepsMin.max() ?? 0
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(spanMin: spansMin[i], asleepMin: asleep, refAsleepMin: refAsleepMin) { return i }
        }
        return 0
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    private func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night). Backs the
    /// hero's ◀/▶ navigation via the `navNight` cache — a thin wrapper over the shared
    /// `SleepModel.decodedNight`, which JSON-decodes, so it only runs from the builder and the onChange
    /// handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        SleepModel.decodedNight(at: offset, navDays: navDays,
                                habitualMidsleepSec: habitualMidsleepSec, motionByStart: motionByStart)
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window (not the
    /// whole day), for the honest no-stage-data header when the day's blocks don't decode to usable
    /// stages. Using the main block (#518) keeps the stub header on the real night rather than a
    /// 1 AM→5 PM overnight+nap span. (#160, #170)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        SleepView.stubDaySession(dayBlocks(at: offset), habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The stage-less stub SESSION for a day whose blocks decode to no usable sleep: the MAIN
    /// block's effective window (the same pick `sessionRow` always made), falling back to the day's
    /// first block so a day with ANY stored block renders a header. Static and pure so the #940
    /// no-blank rule is unit-testable without view internals (SleepPhantomNightFallbackTests): as
    /// long as a day has a block, the tab has something honest to show and `buildModel` never
    /// collapses the whole screen to the first-run empty state. nil only for an empty day.
    static func stubDaySession(_ blocks: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        guard let main = mainNightSession(blocks, habitualMidsleepSec: habitualMidsleepSec) ?? blocks.first
        else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// Header above the hypnogram with ◀/▶ to browse past nights. ◀ goes older (increasing offset),
    /// ▶ goes newer; each is disabled at its bound. The canonical SectionHeader carries the
    /// hierarchy so the hero reads like every other section. (#160)
    @ViewBuilder
    private func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let title = nightRelativeLabel
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            HStack(spacing: NoopMetrics.cardInnerSpacing) {
                Button { if nightOffset < lastIndex { nightOffset += 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(nightOffset >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(LiquidPressStyle())
                .disabled(nightOffset >= lastIndex)
                .accessibilityLabel("Previous night")

                HStack(alignment: .bottom, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleep").strandOverline()
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Text(trailing)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, NoopMetrics.space3)
                        .padding(.vertical, NoopMetrics.space2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(StrandPalette.surfaceInset)
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(StrandPalette.hairline, lineWidth: 1)
                                }
                        )
                        .padding(.bottom, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                    Image(systemName: "chevron.right")
                        .font(StrandFont.headline)
                        .foregroundStyle(nightOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(LiquidPressStyle())
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

    // The typical/need values, the per-tile `Metric` series (performance / efficiency / consistency /
    // hoursVsNeeded / restorative / respiratory / sleepDebt), the `napSleepMinutesByDay` credit map,
    // `durationTrendPoints`, and the `mean` helper moved to SleepModel.swift as pure statics over
    // explicit inputs. `buildModel()` calls them via `SleepModel.build(_:)`; the renderers read the
    // resulting `SleepModel` fields.


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


    /// Hero chart slot for a NAVIGATED session with no decodable stages — honest about the
    /// gap instead of rendering the latest night under a navigated label. (#160)
    private var noStagePlaceholder: some View {
        Text("No stage data recorded for this night.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
    }

    // MARK: - Formatting helpers

    // The metric-grid tile formatters (`pctValue` / `rrValue` / `vsTypical` / `debtCaption` / `debtColor`)
    // moved to `NightDetailCard` with the grid; they had no other caller in SleepView.

    // The Sleep-debt ledger formatters (`debtHeadline` / `debtTag` / `debtRead` / `debtBalanceColor` /
    // `debtSigned`) moved to `SleepDebtLedgerCard` with the card; they had no other caller in SleepView.

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
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }

    // The metric-grid `spark(_:)` sparkline helper moved to `NightDetailCard` with the grid.

    // MARK: - Stage decoding

    /// Asleep minutes decoded from a stored `stagesJSON` in EITHER of the two formats that exist in the
    /// DB: on-device COMPUTED nights store a SEGMENT ARRAY `[{"start":epoch,"end":epoch,"stage":…}]`
    /// (`AnalyticsEngine.encodeStages`); imported nights store a dict of MINUTES
    /// `{"light","deep","rem","awake"}`. The displayed-onset stub test (`nightOnsetTs` /
    /// `isPreOnsetAwakeStub`) MUST read asleep minutes format-agnostically: it previously used the
    /// dict-only `decodeStages`, which returns nil for a computed night's segment array, so every
    /// fragment of an on-device night read as 0 asleep minutes — a real ~54-min first sleep tripped the
    /// "essentially sleepless stub" branch and the shown bedtime jumped from the true 12:16 onset to the
    /// 1:29 main block, bypassing the #259 real-sleep-episode floor entirely (the 2026-07-14 night).
    /// `effectiveStartTs` threads the fragment's effective onset into the segment decode's #259
    /// pre-onset trim. Internal (not private) so the golden test pins the DECODE PATH itself, not a
    /// pre-computed minute count. Android twin: SleepScreen's onset stub-test caller needs the same
    /// both-format decode.
    static func decodedAsleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        decodeStages(json)?.asleep
            ?? decodeSegments(json, sessionStart: effectiveStartTs)?.stages.asleep
            ?? 0
    }

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeStages(_ json: String?) -> Stages? {
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
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let rawStart = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let name = seg["stage"] as? String else { continue }
            // #259: trim each segment to the effective onset (`sessionStart`) so a hand-edited bedtime the
            // raw was too sparse to re-stage (WHOOP 4.0) can't sum pre-onset stages past time-in-bed — nor
            // draw bars before the onset. No-op when segments already start at/after it (the common case).
            let start = max(rawStart, sessionStart)
            guard end > start else { continue }
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

/// Original atmospheric night hero — photographic moonlit lake plus lightweight static depth layers.
/// Drawn as ScreenScaffold.topBackground (fixed under the status bar / overscroll); bottom fades into
/// `surfaceBase` before the first card. No TimelineView, no animation loops.
/// Cheap: one Image + static Canvas/shapes.
private struct SleepPerformanceNightScene: View {
    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Double
    }

    /// Dense-enough star field for a readable night sky without particles.
    private let stars: [Star] = [
        .init(x: 0.04, y: 0.06, size: 1.1, opacity: 0.50),
        .init(x: 0.09, y: 0.14, size: 0.8, opacity: 0.36),
        .init(x: 0.15, y: 0.05, size: 1.2, opacity: 0.55),
        .init(x: 0.21, y: 0.18, size: 0.9, opacity: 0.40),
        .init(x: 0.28, y: 0.08, size: 1.0, opacity: 0.46),
        .init(x: 0.34, y: 0.16, size: 0.7, opacity: 0.32),
        .init(x: 0.41, y: 0.04, size: 1.1, opacity: 0.48),
        .init(x: 0.47, y: 0.13, size: 0.8, opacity: 0.38),
        .init(x: 0.54, y: 0.07, size: 1.0, opacity: 0.44),
        .init(x: 0.60, y: 0.19, size: 0.9, opacity: 0.36),
        .init(x: 0.67, y: 0.05, size: 1.2, opacity: 0.52),
        .init(x: 0.73, y: 0.15, size: 0.8, opacity: 0.34),
        .init(x: 0.80, y: 0.09, size: 1.0, opacity: 0.46),
        .init(x: 0.86, y: 0.17, size: 0.7, opacity: 0.30),
        .init(x: 0.92, y: 0.06, size: 1.1, opacity: 0.48),
        .init(x: 0.96, y: 0.14, size: 0.8, opacity: 0.34),
        .init(x: 0.12, y: 0.26, size: 0.7, opacity: 0.26),
        .init(x: 0.38, y: 0.24, size: 0.8, opacity: 0.28),
        .init(x: 0.58, y: 0.28, size: 0.7, opacity: 0.24),
        .init(x: 0.82, y: 0.25, size: 0.8, opacity: 0.28),
        .init(x: 0.25, y: 0.32, size: 0.6, opacity: 0.20),
        .init(x: 0.70, y: 0.31, size: 0.6, opacity: 0.18)
    ]

    /// #1319: honour the Settings "Day-cycle background" toggle on the Sleep tab too. The bundled
    /// moonlit-lake scene used to draw unconditionally here, so an iOS user who turned the toggle off
    /// still saw it on Sleep — while Home/Today (and the Android Sleep screen) already went plain.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true

    var body: some View {
        if showDayCycleBackground { nightScene } else { StrandPalette.surfaceBase }
    }

    /// The bundled night scene (moonlit lake + procedural fallback). Shown only when the day-cycle
    /// background is enabled; off swaps it for the plain surfaceBase canvas, parity with Home/Today.
    private var nightScene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                // Guaranteed atmospheric base (lake / hills / sky) if the photo asset is missing.
                proceduralNightBase(width: w, height: h)

                // Photographic original (moonlit lake). Ships in StrandiOS Assets.xcassets.
                Group {
                    if let img = resolvedNightHeroImage {
                        img
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: w, height: h, alignment: .center)
                .clipped()
                .allowsHitTesting(false)

                // Light readability wash — keep the photo visible, don't flatten to a blue gradient.
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.04),
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                // Soft moonlight bloom (upper-right) — restrained periwinkle, not purple.
                RadialGradient(
                    colors: [
                        StrandPalette.restGlow.opacity(0.12),
                        StrandPalette.restColor.opacity(0.04),
                        .clear
                    ],
                    center: UnitPoint(x: 0.78, y: 0.12),
                    startRadius: 2,
                    endRadius: max(w, h) * 0.42
                )
                .allowsHitTesting(false)

                // Extra star sparkle over the photo sky.
                Canvas { context, size in
                    for star in stars {
                        let rect = CGRect(
                            x: size.width * star.x,
                            y: size.height * star.y,
                            width: star.size,
                            height: star.size
                        )
                        context.fill(Path(ellipseIn: rect),
                                     with: .color(Color.white.opacity(star.opacity)))
                    }
                }
                .allowsHitTesting(false)

                // Near-shore pine silhouettes — original, not Yosemite peaks.
                pineSilhouette(width: w, height: h)
                    .fill(Color.black.opacity(0.34))
                    .allowsHitTesting(false)

                // Soft haze near the waterline / mid-band.
                LinearGradient(
                    colors: [
                        .clear,
                        StrandPalette.restDeep.opacity(0.06),
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: h * 0.30)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

                // Fade into the Sleep tab canvas BEFORE the first card.
                LinearGradient(
                    colors: [
                        .clear,
                        StrandPalette.surfaceBase.opacity(0.25),
                        StrandPalette.surfaceBase.opacity(0.78),
                        StrandPalette.surfaceBase
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(48, h * 0.20))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
    }

    /// Prefer the catalog image; fall back to the bundled HEIC resource if needed.
    private var resolvedNightHeroImage: Image? {
        #if canImport(UIKit)
        if let ui = UIImage(named: "sleepNightHero") {
            return Image(uiImage: ui)
        }
        if let url = Bundle.main.url(forResource: "SleepNightHero", withExtension: "heic"),
           let ui = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: ui)
        }
        return nil
        #else
        return Image("sleepNightHero")
        #endif
    }

    /// Static procedural night environment — calm lake, low hills, pines, moon glow.
    /// Visible when the photo fails to load; also peeks through translucent photo edges.
    @ViewBuilder
    private func proceduralNightBase(width w: CGFloat, height h: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.14),
                    Color(red: 0.06, green: 0.09, blue: 0.18),
                    Color(red: 0.03, green: 0.05, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Moon + soft halo (upper right).
            Circle()
                .fill(Color.white.opacity(0.78))
                .frame(width: 18, height: 18)
                .blur(radius: 0.4)
                .overlay(
                    Circle()
                        .fill(StrandPalette.restGlow.opacity(0.18))
                        .frame(width: 90, height: 90)
                        .blur(radius: 22)
                )
                .position(x: w * 0.78, y: h * 0.14)

            // Distant low hills.
            Path { p in
                let y0 = h * 0.48
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: y0 + 18))
                p.addCurve(to: CGPoint(x: w * 0.28, y: y0 - 6),
                           control1: CGPoint(x: w * 0.10, y: y0 + 6),
                           control2: CGPoint(x: w * 0.18, y: y0 - 14))
                p.addCurve(to: CGPoint(x: w * 0.55, y: y0 + 10),
                           control1: CGPoint(x: w * 0.38, y: y0 + 8),
                           control2: CGPoint(x: w * 0.46, y: y0 + 16))
                p.addCurve(to: CGPoint(x: w * 0.82, y: y0 - 2),
                           control1: CGPoint(x: w * 0.66, y: y0 + 2),
                           control2: CGPoint(x: w * 0.74, y: y0 - 12))
                p.addCurve(to: CGPoint(x: w, y: y0 + 14),
                           control1: CGPoint(x: w * 0.90, y: y0 + 6),
                           control2: CGPoint(x: w * 0.96, y: y0 + 12))
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
            }
            .fill(Color.black.opacity(0.42))

            // Lake band with faint moonlight reflection.
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.16).opacity(0.90),
                    Color(red: 0.08, green: 0.12, blue: 0.22).opacity(0.75),
                    Color(red: 0.03, green: 0.05, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: h * 0.38)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        StrandPalette.restGlow.opacity(0.10),
                        StrandPalette.restGlow.opacity(0.03),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: w * 0.14, height: h * 0.28)
                .offset(x: w * 0.18)
                .blur(radius: 8)
            }

            // Soft cloud / haze wisps.
            Ellipse()
                .fill(Color.white.opacity(0.04))
                .frame(width: w * 0.55, height: 28)
                .blur(radius: 16)
                .position(x: w * 0.35, y: h * 0.22)
            Ellipse()
                .fill(StrandPalette.restColor.opacity(0.05))
                .frame(width: w * 0.45, height: 22)
                .blur(radius: 14)
                .position(x: w * 0.70, y: h * 0.18)
        }
        .allowsHitTesting(false)
    }

    private func pineSilhouette(width w: CGFloat, height h: CGFloat) -> Path {
        Path { p in
            let base = h * 0.72
            // Left shoreline pines.
            p.move(to: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: 0, y: base - 8))
            for i in 0..<7 {
                let x = w * (0.02 + CGFloat(i) * 0.045)
                let tip = base - (18 + CGFloat(i % 3) * 10)
                p.addLine(to: CGPoint(x: x - 6, y: base + 4))
                p.addLine(to: CGPoint(x: x, y: tip))
                p.addLine(to: CGPoint(x: x + 6, y: base + 4))
            }
            p.addLine(to: CGPoint(x: w * 0.38, y: base + 10))
            // Low mid shoreline.
            p.addCurve(to: CGPoint(x: w * 0.72, y: base + 6),
                       control1: CGPoint(x: w * 0.50, y: base + 16),
                       control2: CGPoint(x: w * 0.62, y: base))
            // Right pines.
            for i in 0..<5 {
                let x = w * (0.78 + CGFloat(i) * 0.045)
                let tip = base - (14 + CGFloat((i + 1) % 3) * 9)
                p.addLine(to: CGPoint(x: x - 5, y: base + 4))
                p.addLine(to: CGPoint(x: x, y: tip))
                p.addLine(to: CGPoint(x: x + 5, y: base + 4))
            }
            p.addLine(to: CGPoint(x: w, y: base + 8))
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        }
    }
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
/// The "Sleep marks" tap-to-log card. Lives in the Sleep tab but is also hostable in Today
/// (#today-hosted-cards), so it is `internal` (not `private`) and self-contained — it reads only the
/// shared `repo`/`live` environment objects, both present on Today too.
struct SleepMarkCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons. Drives the SwiftUI haptic landing too. LOGGING-ONLY: a mark never feeds the sleep
    /// detector — it's persisted to the metric series + strap log. (#461)
    @State private var lastMark: SleepMark?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep marks", overline: "Tap to log")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time. It doesn't change tonight's detected sleep.")
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

// SleepModel / Night / Stages and the pure `SleepModel.build(_:)` derivation pipeline now live in
// SleepModel.swift, so the Today host can build the same model without a SleepView instance.

// MARK: - Wake-time editor

/// Identifies the night being edited for `.sheet(item:)`. A night's `startTs` is its stable natural
/// key (wake-time edits never move it), so it doubles as the sheet identity.
/// The transient UNDO banner state after a suppressing delete (#65). `identityStart` is the immutable
/// detected key so a stale auto-dismiss task can tell whether it still owns the current banner;
/// `displayStart` is the effective (shown) onset for the message clock.
private struct SleepUndoBanner {
    let snapshot: SleepDeletionSnapshot
    let identityStart: Int
    let displayStart: Int
    let windowEnd: Int
}

private struct WakeEdit: Identifiable {
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    let stagesJSON: String?
    /// True for a hand-edited / manually-added (nap) night. Such a delete writes NO tombstone (it is
    /// never re-detected), so the editor's delete-confirm copy must NOT promise re-detection suppression
    /// for it. Mirrors the undo-banner branch (#65 banner/confirm honesty).
    let userEdited: Bool
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

/// A small sheet to hand-correct a night's bed (onset) and wake (end) instants. Seeds both pickers with
/// the current values, including each calendar date. Hands the chosen unix-second (bed, wake) back via
/// `onSave`. Pure presentation + a single async save — persistence lives in the repo.
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
    /// The night's RECORDED coverage (detected onset ... current wake, unix seconds) for the #940
    /// guards: a time-only bed roll past the wake auto-decrements the date, and a corrected window
    /// fully outside this range gets an explicit confirm instead of silent acceptance. nil for the
    /// "Add a nap" sheet, whose window deliberately sits outside the night (only the future-bed
    /// guard applies there).
    private let coverage: ClosedRange<Int>?
    /// True when deleting THIS session writes a re-detection tombstone (a DETECTED night). false for a
    /// userEdited/nap row, which is never re-detected, so the delete-confirm copy drops the suppression
    /// promise for it, matching the undo banner. (#65 confirm honesty.)
    private let suppressesReDetection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false
    /// The bed value BEFORE the in-flight picker change, so the #940 auto-correct can tell a
    /// time-only roll (same calendar day: rescue it) from a deliberate date change (respect it).
    @State private var previousBed: Date
    /// True while the #940 "no recorded data there" confirm is up; Save proceeds only on consent.
    @State private var confirmingDisjoint = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller (#508) overrides them. The save logic is identical either way — adding a nap
    /// is just an edit whose "existing" window is a seed. `onDelete` (#68) is the optional destructive
    /// action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync.",
         bedLabel: LocalizedStringKey = "Asleep",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         coverage: ClosedRange<Int>? = nil,
         suppressesReDetection: Bool = true,
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        self.coverage = coverage
        self.suppressesReDetection = suppressesReDetection
        // A bed can never be seeded in the future (#940): the "Add a nap" anchor is wake+1h, which is
        // ahead of the clock right after a morning sync; clamp so the picker opens inside its bound.
        let seedBed = min(bedTs, Int(Date().timeIntervalSince1970))
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _previousBed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The current edit window after the same future/inverted/duration guards used by persistence.
    private var validatedWindow: (start: Int, end: Int)? {
        SleepEditGuard.clampedEditWindow(
            start: Int(bed.timeIntervalSince1970),
            end: Int(wake.timeIntervalSince1970),
            now: Int(Date().timeIntervalSince1970))
    }

    /// The single save funnel: both the direct Save and the #940 disjoint confirm land here.
    private func commit(start: Int, end: Int) {
        saving = true
        Task {
            await onSave(start, end)
            dismiss()
        }
    }

    var body: some View {
        let canSave = validatedWindow != nil

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(blurb)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NoopCard(padding: NoopMetrics.cardPadding, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    // Bed is bounded to the PAST (#940): a sleep can't start in the future, and an
                    // unbounded picker let a cross-midnight time roll land the bed on the coming
                    // evening, creating a future-dated night the tab couldn't render.
                    DatePicker(bedLabel, selection: $bed, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                    Divider().overlay(StrandPalette.hairline)
                    // The wake date and time are both editable so corrections preserve the exact
                    // endpoint selected by the user (#970).
                    DatePicker(wakeLabel, selection: $wake, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
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
                    // #940 guard 2: a corrected window that no longer touches the night's recorded
                    // coverage has no data to stage from. Silently accepting it fabricated an
                    // all-awake phantom night; ask first.
                    guard let window = validatedWindow else { return }
                    if let coverage, SleepEditGuard.isDisjoint(
                        newStart: window.start, newEnd: window.end,
                        coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound) {
                        confirmingDisjoint = true
                    } else {
                        commit(start: window.start, end: window.end)
                    }
                }
                .buttonStyle(.noopPrimary)
                .disabled(saving || !canSave)
                .opacity(canSave ? 1 : 0.55)
            }
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 360)
        .background(NoopChromeSurface())
        // #940 guard 1: a time-only roll that lands the bed in the future, or at/after the night's
        // wake, almost always means the PREVIOUS evening (23:00 "yesterday", not tonight). Snap the
        // date back a day so the picker visibly shows the night the user meant. Pure rule + tests:
        // SleepEditGuard.autoCorrectedBed (Android twin in com.noop.analytics).
        .onChangeCompat(of: bed) { newBed in
            let corrected = SleepEditGuard.autoCorrectedBed(
                previousBed: previousBed, candidateBed: newBed,
                originalWake: coverage.map { Date(timeIntervalSince1970: TimeInterval($0.upperBound)) },
                now: Date())
            previousBed = corrected
            if corrected != newBed { bed = corrected }
        }
        // #940 guard 2's consent step. On-brand role-tagged .alert, same shape as the delete confirm.
        .alert("Move this sleep?", isPresented: $confirmingDisjoint) {
            Button("Cancel", role: .cancel) { }
            Button("Move anyway") {
                guard let window = SleepEditGuard.clampedEditWindow(
                    start: Int(bed.timeIntervalSince1970),
                    end: Int(wake.timeIntervalSince1970),
                    now: Int(Date().timeIntervalSince1970)) else { return }
                commit(start: window.start, end: window.end)
            }
        } message: {
            Text("This moves the night to a time with no recorded data. Stages can't be derived there, so it may show as empty until data covers it.")
        }
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
            // A detected night is tombstoned so it won't re-detect; a userEdited/nap row writes no
            // tombstone, so its copy drops that (false) promise. Mirrors the undo banner. (#65)
            Text(suppressesReDetection
                 ? "Removes this recorded sleep and recomputes the day without it. NOOP won't re-detect sleep in this window. You can undo for a few seconds after."
                 : "Removes this sleep and recomputes the day without it. You can undo for a few seconds after.")
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
