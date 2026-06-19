import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Workouts
//
// The activity log, instrument-grade and uniform. Built ONLY from the locked Noop
// component system (NoopMetrics / NoopCard / StatTile / SectionHeader /
// SegmentedPillControl / SourceBadge) so every card, tile and row lines up:
//
//  • a range pill (7D / 30D / 90D / 1Y / All) that filters the loaded sessions,
//  • a LazyVGrid of summary StatTiles (count / time / calories / distance / most-active),
//  • an "ACTIVITY BREAKDOWN" LazyVGrid of per-sport NoopCards — identical internal layout,
//  • an "ALL SESSIONS" NoopCard containing fixed-height rows (date · sport · dur · HR · kcal · dist · source).
//
// No custom card heights, paddings, colours or surfaces — uniformity is the bar.

struct WorkoutsView: View {
    @EnvironmentObject var repo: Repository
    /// #459: "Start Workout" used to live ONLY on the Live screen, so a user reaching Workouts (via the
    /// Quick-action FAB or the tab) had no way to begin one from the obvious place. Injected here so the
    /// header/empty-state can start a live session and present the in-exercise view directly.
    @EnvironmentObject var model: AppModel
    @State private var showLiveWorkout = false

    // Imperial/Metric display preference (D#103). Workout distances are stored in metres; the toggle
    // re-labels them to miles/yards. Display-only — nothing on disk changes.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    // Effort display scale (#268) — drives the effort hero's read-out. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// All loaded sessions, newest first. Seedable for previews.
    @State private var allRows: [WorkoutRow]
    @State private var loaded: Bool
    @State private var seededInitialRange = false
    @State private var range: Range = .all
    private let usesPreviewRows: Bool

    // iPhone (.compact) can't fit the labelled "Add workout" button beside the 5-segment range pill —
    // the button got crushed into a tall sliver (#234/#339). Stack them there; iPad/Mac keep one row.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// The add/edit sheet target: `.some(nil)` = add a new workout, `.some(row)` = edit `row`,
    /// `nil` = sheet closed. Wrapped in Identifiable so `.sheet(item:)` can drive presentation.
    @State private var sheet: WorkoutSheetTarget?

    /// The read-only detail screen target — a tapped session. Drives a `.sheet(item:)` separate from
    /// the add/edit sheet so a primary tap (detail) and the ••• menu (edit) never collide. (#410)
    @State private var detail: WorkoutDetailTarget?

    /// A transient one-line note shown after a manual save / relabel for a sport that already has a
    /// solid/building ActivityCost entry — "Sessions like this usually …" (#439). Auto-clears.
    @State private var postLogNote: String?

    /// Wraps the optional edited row so `.sheet(item:)` can present add (editing == nil) or edit.
    private struct WorkoutSheetTarget: Identifiable {
        let editing: WorkoutRow?
        let id = UUID()
    }

    /// Wraps a tapped row so `.sheet(item:)` can present its detail screen.
    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }

    init(previewRows: [WorkoutRow]? = nil) {
        _allRows = State(initialValue: previewRows ?? [])
        _loaded = State(initialValue: previewRows != nil)
        usesPreviewRows = previewRows != nil
    }

    var body: some View {
        ScreenScaffold(title: "Workouts", subtitle: "Every session, threaded together.",
                       onRefresh: { await repo.refresh() }) {
            if allRows.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ComingSoon(what: loaded
                        ? "No workouts yet. They come from your WHOOP and Apple Health history. Import in Data Sources to bring them in — or add one you tracked elsewhere."
                        : "Loading your sessions…")
                    if loaded {
                        HStack(spacing: 10) { startLiveWorkoutButton; addWorkoutButton }
                    }
                }
            } else {
                // Compute the windowed rows and per-sport groups ONCE per body
                // evaluation, then thread them into every section. SwiftUI re-runs
                // `body` on hover/animation/1Hz HR ticks; the previous computed-
                // property fan-out (rows → effectiveRange → sessions(_:), and
                // sportGroups → rows → …) rebuilt the same filters/aggregations
                // several times per render. Same windowing, same results.
                let resolved = effectiveRange
                let windowRows = sessions(for: resolved)
                let groups = sportGroups(from: windowRows)
                let zonesSummary = WorkoutZones.summary(from: windowRows)

                HStack { startLiveWorkoutButton; Spacer() }
                rangeBar(rows: windowRows, effectiveRange: resolved)
                if let postLogNote { postLogBanner(postLogNote) }
                effortHero(rows: windowRows, effectiveRange: resolved, groups: groups)
                summarySection(rows: windowRows, effectiveRange: resolved, groups: groups)
                breakdownSection(groups: groups, rows: windowRows)
                if let z = zonesSummary {
                    zonesSection(z, totalSessions: windowRows.count)
                }
                sessionsSection(rows: windowRows)
            }
        }
        .task(id: repo.refreshSeq) {
            guard !usesPreviewRows else { return }
            let r = await repo.workoutRows()
            allRows = r
            let wasLoaded = loaded
            loaded = true
            if !wasLoaded {
                range = defaultRange(for: r)
                seededInitialRange = true
            }
        }
        .onAppear {
            // Preview-seeded rows skip `.task`; still choose a range that has data.
            if loaded && !seededInitialRange {
                range = defaultRange(for: allRows)
                seededInitialRange = true
            }
        }
        .sheet(item: $sheet) { target in
            ManualWorkoutSheet(editing: target.editing) { row, replacing in
                Task {
                    await repo.saveManualWorkout(row, replacing: replacing)
                    await reload()
                    // Post-log note (#439): if this sport now has a solid/building recovery-cost
                    // entry, surface its personal-pattern sentence as a transient caption.
                    await showPostLogNote(forSport: WorkoutSource.displaySport(row.sport))
                }
            }
        }
        .sheet(item: $detail) { target in
            // These shared screens aren't hosted in a per-screen NavigationStack, so the read-only
            // detail rides its own NavigationStack inside the sheet (the Done toolbar item + iOS
            // grabber give the dismiss affordances). Mirrors HealthView presenting MetricDetailView.
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
        // #459: the in-exercise view, presented when Start Workout is tapped here (same screen LiveView
        // shows). activeWorkout is global on AppModel, so ending it from either surface stays in sync.
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
        }
    }

    /// Present the read-only detail for a tapped row. The primary affordance; the ••• menu stays the
    /// secondary path for edit/relabel/delete.
    private func openDetail(_ row: WorkoutRow) { detail = WorkoutDetailTarget(row: row) }

    /// Re-read every source after a mutation so the screen reflects the new state immediately.
    /// Keeps the user's current range — only the initial load picks a default — and the auto-widen
    /// (`effectiveRange`) still covers a now-empty window.
    private func reload() async {
        allRows = await repo.workoutRows()
    }

    // MARK: - Post-log activity-cost note (#439)

    /// After a manual save / relabel, look up whether `sport` has a solid/building ActivityCost entry
    /// (n ≥ minSessions) and, if so, show its plain-English sentence as a transient caption that
    /// auto-clears. Copy is "usually"/"personal pattern" framed (the engine's own wording) — never a
    /// law. Computes off the freshly reloaded sessions + the merged daily Charge.
    private func showPostLogNote(forSport sport: String) async {
        let costs = InsightsView.computeActivityCosts(workouts: allRows, days: repo.days)
        guard let match = costs.first(where: { $0.sport == sport }) else {
            await MainActor.run { postLogNote = nil }
            return
        }
        let sentence = match.sentence()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { postLogNote = sentence } }
        // Auto-dismiss after a few seconds (transient caption, not a permanent card).
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        await MainActor.run {
            if postLogNote == sentence { withAnimation(.easeOut(duration: 0.2)) { postLogNote = nil } }
        }
    }

    /// The transient "personal pattern" caption — an Effort-tinted frosted strip with a chart glyph.
    private func postLogBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.effortColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.effortColor.opacity(0.22), lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Row actions (edit · relabel · dismiss · delete)

    private func editWorkout(_ row: WorkoutRow) { sheet = WorkoutSheetTarget(editing: row) }

    private func relabel(_ row: WorkoutRow, to sport: String) {
        Task {
            await repo.relabelDetected(row, sport: sport)
            await reload()
            await showPostLogNote(forSport: WorkoutSource.displaySport(sport))
        }
    }

    private func dismiss(_ row: WorkoutRow) {
        Task { await repo.dismissDetected(row); await reload() }
    }

    private func delete(_ row: WorkoutRow) {
        Task { await repo.deleteWorkout(row); await reload() }
    }

    /// Common sports offered when re-labelling a detected bout (keeps the menu short and honest —
    /// the user can fine-tune via Edit afterwards).
    private static let relabelSports = ["Running", "Walking", "Cycling", "Strength Training",
                                        "Swimming", "Rowing", "Yoga", "HIIT",
                                        "CrossFit", "Hiking", "Tennis"]

    // MARK: - Range control

    private func rangeBar(rows: [WorkoutRow], effectiveRange: Range) -> some View {
        let fellBack = effectiveRange != range
        let caption = rangeCaption(rows: rows, effectiveRange: effectiveRange, fellBack: fellBack)
        #if os(iOS)
        let stacked = hSizeClass == .compact
        #else
        let stacked = false
        #endif
        return VStack(alignment: .leading, spacing: 8) {
            if stacked {
                // iPhone: button on its own row, the range pill full-width below — no crushed sliver.
                addWorkoutButton
                SegmentedPillControl(Range.allCases, selection: $range) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    addWorkoutButton
                    Spacer()
                    SegmentedPillControl(Range.allCases, selection: $range) { $0.label }
                }
            }
            Text(caption)
                .font(StrandFont.footnote)
                .foregroundStyle(fellBack ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(caption)
        }
    }

    /// Opens the add sheet (editing == nil). Present on the populated screen and the empty state so a
    /// user with no imports can still log a session.
    private var addWorkoutButton: some View {
        Button {
            sheet = WorkoutSheetTarget(editing: nil)
        } label: {
            Label("Add workout", systemImage: "plus")
                .font(StrandFont.subhead)
        }
        .buttonStyle(.bordered)
        .tint(StrandPalette.accent)
        .accessibilityLabel("Add a workout")
    }

    /// #459: begin (or jump back into) a live, manually-tracked workout straight from Workouts — the
    /// place people instinctively look — instead of only from the Live screen. Starts the session and
    /// presents the in-exercise view directly (no cross-view auto-present race with LiveView's sheet).
    private var startLiveWorkoutButton: some View {
        Button {
            if model.activeWorkout == nil { model.startWorkout() }
            showLiveWorkout = true
        } label: {
            Label(model.activeWorkout == nil ? "Start Workout" : "View active workout",
                  systemImage: model.activeWorkout == nil ? "figure.run" : "timer")
                .font(StrandFont.subhead)
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.accent)
        .accessibilityLabel(model.activeWorkout == nil ? "Start a workout" : "View the active workout")
    }

    /// The latest session start (anchors every window — windows are relative to the
    /// most recent session, not "now", so an old log still resolves).
    private var latestTs: Int? { allRows.map(\.startTs).max() }

    /// Sessions inside a given range, RELATIVE TO THE LATEST session. `.all` = all.
    private func sessions(for r: Range) -> [WorkoutRow] {
        guard let days = r.days else { return allRows }
        guard let last = latestTs else { return [] }
        let cutoff = last - days * 86_400
        return allRows.filter { $0.startTs >= cutoff }
    }

    /// The range actually shown: the SELECTED range when it holds ≥1 session, else
    /// the smallest LARGER range that does — so switching ranges stays visibly
    /// distinct and only an empty window widens.
    private var effectiveRange: Range {
        guard !allRows.isEmpty else { return range }
        for r in range.widening where !sessions(for: r).isEmpty { return r }
        return .all
    }

    /// "N sessions · <range>" near the control, flagging an auto-widen.
    /// Takes the already-resolved range / windowed rows so `body` computes them once.
    private func rangeCaption(rows: [WorkoutRow], effectiveRange: Range, fellBack: Bool) -> String {
        guard loaded, !allRows.isEmpty else { return "—" }
        let n = rows.count
        let unit = n == 1 ? "session" : "sessions"
        if fellBack {
            return "\(n) \(unit) · sparse — widened to \(effectiveRange.caption)"
        }
        return "\(n) \(unit) · \(effectiveRange.caption)"
    }

    /// Pick the tightest range that still holds ≥2 sessions; otherwise show All.
    private func defaultRange(for source: [WorkoutRow]) -> Range {
        guard let last = source.map(\.startTs).max() else { return .all }
        for r in Range.allCases where r.days != nil {
            let cutoff = last - (r.days ?? 0) * 86_400
            if source.filter({ $0.startTs >= cutoff }).count >= 2 { return r }
        }
        return .all
    }

    // MARK: - Effort hero (weekly effort over a scenic Effort backdrop)

    /// A Bevel hero for the windowed range: the typical session Effort on the shared layered StrainGauge,
    /// floated over an Effort-tinted scenic backdrop, with the session count + total time alongside. The
    /// gauge reads the AVERAGE per-session strain (the stored 0–100 Effort axis mapped to the gauge's
    /// 0–21 span, exactly like the Today effort hero); the headline number is shown on the user's scale.
    @ViewBuilder
    private func effortHero(rows: [WorkoutRow], effectiveRange: Range, groups: [SportGroup]) -> some View {
        let strains = rows.compactMap(\.strain)
        let avgStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let totalTimeH = rows.compactMap(\.durationS).reduce(0, +) / 3600.0
        ZStack {
            ScenicHeroBackground(domain: .effort)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            NoopCard(padding: 20, tint: StrandPalette.effortColor) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        effortHeroGauge(avgStrain: avgStrain, hasData: !strains.isEmpty)
                        effortHeroStats(rows: rows, effectiveRange: effectiveRange,
                                        groups: groups, totalTimeH: totalTimeH)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .center, spacing: 16) {
                        effortHeroGauge(avgStrain: avgStrain, hasData: !strains.isEmpty)
                        effortHeroStats(rows: rows, effectiveRange: effectiveRange,
                                        groups: groups, totalTimeH: totalTimeH)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func effortHeroGauge(avgStrain: Double, hasData: Bool) -> some View {
        VStack(spacing: 8) {
            Text("TYPICAL EFFORT")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.effortColor)
            StrainGauge(
                strain: UnitFormatter.effortValue(avgStrain, scale: effortScale),
                outOf: effortScale == .whoop ? 21 : 100,
                diameter: 168, lineWidth: 15,
                showsLabel: hasData, showsHover: false,
                valueFormat: { _ in UnitFormatter.effortDisplay(avgStrain, scale: effortScale) }
            )
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func effortHeroStats(rows: [WorkoutRow], effectiveRange: Range,
                                 groups: [SportGroup], totalTimeH: Double) -> some View {
        let modal = modalSport(from: groups)
        VStack(alignment: .leading, spacing: 12) {
            Text("Effort this \(effectiveRange.heroWord)")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: NoopMetrics.gap) {
                heroStat("Sessions", "\(rows.count)", tint: StrandPalette.effortColor)
                heroStat("Active", oneDecimal(totalTimeH) + "h", tint: StrandPalette.textPrimary)
                heroStat("Top sport", modal.count > 0 ? "\(modal.count)×" : "—",
                         tint: StrandPalette.effortBright)
            }
            Text(modal.count > 0
                 ? "Mostly \(WorkoutSource.displaySport(modal.sport)) — \(effectiveRange.caption)."
                 : "Logged sessions across \(effectiveRange.caption).")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heroStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.number(20))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary tiles (uniform 104pt StatTiles)

    private func summarySection(rows: [WorkoutRow], effectiveRange: Range, groups: [SportGroup]) -> some View {
        let totalCount = rows.count
        let totalTimeH = rows.compactMap(\.durationS).reduce(0, +) / 3600.0
        let totalKcal = rows.compactMap(\.energyKcal).reduce(0, +)
        let totalKmRaw = rows.compactMap(\.distanceM).reduce(0, +) / 1000.0
        let modal = modalSport(from: groups)

        return LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {
            StatTile(label: "Total Workouts",
                     value: "\(totalCount)",
                     caption: effectiveRange.caption,
                     accent: StrandPalette.effortColor)
            StatTile(label: "Total Time",
                     value: oneDecimal(totalTimeH) + "h",
                     caption: "active",
                     accent: StrandPalette.textPrimary)
            StatTile(label: "Total Calories",
                     value: grouped(totalKcal),
                     caption: "kcal",
                     accent: StrandPalette.metricAmber)
            StatTile(label: "Total Distance",
                     value: UnitFormatter.distanceFromKilometers(totalKmRaw, system: unitSystem),
                     caption: "covered",
                     accent: StrandPalette.metricCyan)
            StatTile(label: "Most Active",
                     value: modal.sport,
                     caption: modal.count > 0 ? "\(modal.count) session\(modal.count == 1 ? "" : "s")" : nil,
                     accent: StrandPalette.textPrimary)
        }
    }

    // MARK: - Activity breakdown (per-sport NoopCards, identical layout)

    private func breakdownSection(groups: [SportGroup], rows: [WorkoutRow]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Activity Breakdown",
                          overline: "By sport",
                          trailing: "\(groups.count) sport\(groups.count == 1 ? "" : "s")")
            LazyVGrid(columns: breakdownColumns, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(groups) { g in
                    // This sport's own sessions, so the card can carry an HR-zone mini-bar.
                    sportCard(g, zones: WorkoutZones.summary(from: rows.filter { $0.sport == g.sport }))
                }
            }
        }
    }

    private func sportCard(_ g: SportGroup, zones: WorkoutZones.Summary?) -> some View {
        // Frosted Effort-tinted card with the sport glyph in the Effort world, an HR-zone mini-bar when
        // the sessions carry imported zones, and the bright "now" end-cap on its busiest zone.
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 12) {
                // Identical header for every card.
                HStack(spacing: 10) {
                    Image(systemName: sportIcon(g.sport))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 22, alignment: .center)
                    Text(WorkoutSource.displaySport(g.sport))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(g.count)")
                        .font(StrandFont.number(15))
                        .foregroundStyle(StrandPalette.effortBright)
                }
                if let zones { zoneMiniBar(zones) }
                Divider().overlay(StrandPalette.hairline)
                // Identical 4-up stat strip for every card.
                HStack(spacing: 0) {
                    miniStat("SESSIONS", "\(g.count)")
                    miniStat("TIME", oneDecimal(g.totalTimeH) + "h")
                    miniStat("KCAL", grouped(g.totalKcal), tint: StrandPalette.metricAmber)
                    miniStat("AVG/SESS", "\(Int(g.avgTimePerSessionMin.rounded()))m")
                }
            }
        }
    }

    /// A slim proportional HR-zone bar for one sport's sessions — the zone colours, with the busiest
    /// zone carrying a bright "now" end-cap glow so the card reads as a Bevel chart, not a flat strip.
    private func zoneMiniBar(_ z: WorkoutZones.Summary) -> some View {
        let busiest = z.minutes.indices.max(by: { z.minutes[$0] < z.minutes[$1] }) ?? 0
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(StrandPalette.hrZoneColor(i + 1))
                        .frame(width: max(0, CGFloat(z.minutes[i] / max(z.totalMinutes, 0.001)) * geo.size.width))
                        .overlay {
                            if i == busiest {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(StrandPalette.hrZoneColor(i + 1).opacity(0.9), lineWidth: 1)
                                    .shadow(color: StrandPalette.hrZoneColor(i + 1).opacity(0.7), radius: 4)
                            }
                        }
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart-rate zone split: " + (1...5).map { "zone \($0) \(Int((z.minutes[$0 - 1] / max(z.totalMinutes, 0.001) * 100).rounded())) percent" }.joined(separator: ", "))
    }

    private func miniStat(_ label: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.number(15))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - HR zones (imported per-workout zone split, one card)

    private func zonesSection(_ z: WorkoutZones.Summary, totalSessions: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("HR Zones",
                          overline: "Whoop import",
                          trailing: "\(z.sessionsWithZones) of \(totalSessions) session\(totalSessions == 1 ? "" : "s")")
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: 12) {
                    // Proportional stacked bar — same construction as SleepView's stage bar, with the
                    // busiest zone carrying a bright glowing end-cap so it reads as a Bevel chart.
                    let busiest = z.minutes.indices.max(by: { z.minutes[$0] < z.minutes[$1] }) ?? 0
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { i in
                                Rectangle()
                                    .fill(StrandPalette.hrZoneColor(i + 1))
                                    .frame(width: max(0, CGFloat(z.minutes[i] / z.totalMinutes) * geo.size.width))
                                    .overlay {
                                        if i == busiest {
                                            Rectangle()
                                                .stroke(StrandPalette.hrZoneColor(i + 1), lineWidth: 1.5)
                                                .shadow(color: StrandPalette.hrZoneColor(i + 1).opacity(0.7), radius: 6)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Heart-rate zone split: " + (1...5).map { "zone \($0) \(Int((z.minutes[$0 - 1] / z.totalMinutes * 100).rounded())) percent" }.joined(separator: ", "))
                    Divider().overlay(StrandPalette.hairline)
                    // 5-up stat strip, identical rhythm to the sport cards' miniStat row.
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { i in
                            zoneStat(i + 1, minutes: z.minutes[i], total: z.totalMinutes)
                        }
                    }
                    Text("Share of imported zone time, duration-weighted across sessions — approximate.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text("Z\(zone)" as String).strandOverline()
            }
            Text("\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(durationLabel(minutes * 60))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - All sessions (one NoopCard, uniform fixed-height rows)

    private func sessionsSection(rows: [WorkoutRow]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("All Sessions",
                          overline: "Log",
                          trailing: "\(rows.count) total")
            NoopCard(padding: 0) {
                // The fixed-width columns total ≈612pt — wider than an iPhone — so on iOS the table
                // scrolls horizontally instead of clipping the SPORT / DIST / SOURCE columns (#183).
                // macOS windows are wide enough to show it all, so they keep the full-width layout.
                #if os(iOS)
                ScrollView(.horizontal, showsIndicators: true) {
                    sessionsTable(rows: rows)
                }
                #else
                sessionsTable(rows: rows)
                #endif
            }
            #if os(iOS)
            // Each row now carries a visible "•••" actions button; the long-press contextMenu still
            // works as a secondary path (#183).
            Text("Tap a workout for its detail · tap ••• to re-label, edit or delete it.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 4)
            #endif
        }
    }

    @ViewBuilder
    private func sessionsTable(rows: [WorkoutRow]) -> some View {
        LazyVStack(spacing: 0) {
            sessionHeaderRow
            Divider().overlay(StrandPalette.hairline)
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                sessionRow(row)
                    .background(idx % 2 == 1
                                ? StrandPalette.surfaceInset.opacity(0.4)
                                : Color.clear)
                if idx != rows.count - 1 {
                    Divider().overlay(StrandPalette.hairline.opacity(0.5))
                }
            }
        }
    }

    private var sessionHeaderRow: some View {
        HStack(spacing: 0) {
            colHeader("DATE", width: ColWidth.date, align: .leading)
            colHeader("SPORT", width: ColWidth.sport, align: .leading)
            colHeader("DUR", width: ColWidth.duration, align: .trailing)
            colHeader("AVG HR", width: ColWidth.hr, align: .trailing)
            colHeader("KCAL", width: ColWidth.kcal, align: .trailing)
            colHeader("DIST", width: ColWidth.dist, align: .trailing)
            Spacer(minLength: 0)
            colHeader("SOURCE", width: ColWidth.source, align: .trailing)
            // Empty header over the per-row "•••" actions menu column (keeps SOURCE aligned).
            Color.clear.frame(width: ColWidth.action)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .frame(height: RowMetrics.headerHeight)
    }

    private func colHeader(_ t: String, width: CGFloat, align: Alignment) -> some View {
        Text(t).strandOverline().frame(width: width, alignment: align)
    }

    private func sessionRow(_ row: WorkoutRow) -> some View {
        HStack(spacing: 0) {
            // Date + time
            VStack(alignment: .leading, spacing: 1) {
                Text(dateLabel(row.startTs))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(timeRangeLabel(row.startTs, row.endTs))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(width: ColWidth.date, alignment: .leading)

            // Sport ("detected" reads as "Activity")
            HStack(spacing: 7) {
                Image(systemName: sportIcon(row.sport))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 16)
                Text(WorkoutSource.displaySport(row.sport))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: ColWidth.sport, alignment: .leading)

            cell(durationLabel(row.durationS), width: ColWidth.duration)
            cell(row.avgHr.map { "\($0)" } ?? "–", width: ColWidth.hr,
                 color: row.avgHr != nil ? StrandPalette.metricRose : nil)
            cell(row.energyKcal.map { grouped($0) } ?? "–", width: ColWidth.kcal,
                 color: row.energyKcal != nil ? StrandPalette.metricAmber : nil)
            cell(distanceLabel(row.distanceM), width: ColWidth.dist)

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)
                sourceBadge(row.source)
            }
            .frame(width: ColWidth.source, alignment: .trailing)

            // Visible per-row actions affordance (#1). Mirrors the right-click contextMenu so the
            // relabel/edit/dismiss actions are discoverable without knowing to Control-click.
            rowActionsMenu(row)
                .frame(width: ColWidth.action, alignment: .trailing)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .frame(height: RowMetrics.rowHeight)
        .contentShape(Rectangle())
        // PRIMARY tap → the read-only detail (#410). The trailing ••• Menu button consumes its own
        // tap, so tapping the actions glyph still opens the menu rather than the detail.
        .onTapGesture { openDetail(row) }
        .contextMenu { rowMenu(row) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens workout detail")
    }

    /// The same actions as `rowMenu`, surfaced as a tappable "•••" button so they're discoverable on
    /// both macOS (no right-click needed) and iOS (no long-press needed). Borderless + hidden
    /// indicator keeps it to a bare glyph that fits the row's metric rhythm.
    private func rowActionsMenu(_ row: WorkoutRow) -> some View {
        Menu {
            rowMenu(row)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: ColWidth.action, height: RowMetrics.rowHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Right-click actions per row. A DETECTED bout can be re-labelled (becomes a real manual session
    /// that survives re-detection) or dismissed (durably hidden). A MANUAL session can be edited or
    /// deleted. Imported WHOOP / Apple rows are read-only (we never rewrite imported history).
    @ViewBuilder
    private func rowMenu(_ row: WorkoutRow) -> some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(Self.relabelSports, id: \.self) { sport in
                    Button(sport) { relabel(row, to: sport) }
                }
            }
            Button("Edit details…") { editWorkout(row) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) { dismiss(row) }
        case .manual:
            Button("Edit…") { editWorkout(row) }
            Divider()
            Button("Delete", role: .destructive) { delete(row) }
        case .whoop, .apple, .lifting:
            // Imported history is read-only; offer a copy-to-manual edit path that doesn't touch it.
            Button("Duplicate as manual…") { editWorkout(asManualCopy(row)) }
        }
    }

    /// A manual-source copy of an imported row, so "Duplicate as manual" opens the add sheet pre-filled
    /// without ever mutating the imported original (the sheet saves under the strap source).
    private func asManualCopy(_ row: WorkoutRow) -> WorkoutRow {
        WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: WorkoutSource.displaySport(row.sport),
                   source: "manual", durationS: row.durationS, energyKcal: row.energyKcal,
                   avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain, distanceM: row.distanceM,
                   zonesJSON: row.zonesJSON, notes: row.notes)
    }

    private func cell(_ text: String, width: CGFloat, color: Color? = nil) -> some View {
        Text(text)
            .font(StrandFont.number(13, weight: .regular))
            .foregroundStyle(color ?? (text == "–" ? StrandPalette.textTertiary : StrandPalette.textPrimary))
            .frame(width: width, alignment: .trailing)
    }

    /// Source badge built from the locked SourceBadge component (no custom capsule). Four origins:
    /// Whoop (import), Apple (import), Detected (on-device auto-detector — honestly labelled so a
    /// duplicate is recognisable and removable), Manual (user-logged).
    private func sourceBadge(_ source: String) -> some View {
        let (label, tint, a11y): (String, Color, String) = {
            switch WorkoutSource.classify(source) {
            case .whoop:    return ("Whoop", StrandPalette.accent, "Source Whoop")
            case .apple:    return ("Apple", StrandPalette.metricCyan, "Source Apple Health")
            case .detected: return ("Detected", StrandPalette.metricPurple, "Source on-device detected")
            case .manual:   return ("Manual", StrandPalette.statusWarning, "Source manual entry")
            case .lifting:  return ("Lifting", StrandPalette.zone2, "Source imported lifting log")
            }
        }()
        // String interpolation lifts the computed label into a LocalizedStringKey (SourceBadge's type).
        return SourceBadge("\(label)", tint: tint).accessibilityLabel(a11y)
    }

    // MARK: - Grid columns

    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]
    }
    private var breakdownColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: NoopMetrics.gap, alignment: .top)]
    }

    // MARK: - Aggregation

    private struct SportGroup: Identifiable {
        let sport: String
        let count: Int
        let totalTimeS: Double
        let totalKcal: Double
        var id: String { sport }
        var totalTimeH: Double { totalTimeS / 3600.0 }
        var avgTimePerSessionMin: Double { count > 0 ? (totalTimeS / Double(count)) / 60.0 : 0 }
    }

    /// Sessions grouped by sport, ordered by count (desc), then total time.
    /// Takes the already-windowed rows so `body` builds the groups exactly once.
    private func sportGroups(from rows: [WorkoutRow]) -> [SportGroup] {
        var bySport: [String: (count: Int, time: Double, kcal: Double)] = [:]
        for r in rows {
            var acc = bySport[r.sport] ?? (0, 0, 0)
            acc.count += 1
            acc.time += r.durationS ?? 0
            acc.kcal += r.energyKcal ?? 0
            bySport[r.sport] = acc
        }
        return bySport
            .map { SportGroup(sport: $0.key, count: $0.value.count,
                              totalTimeS: $0.value.time, totalKcal: $0.value.kcal) }
            .sorted { ($0.count, $0.totalTimeS) > ($1.count, $1.totalTimeS) }
    }

    /// The most-frequent sport (modal), derived from the already-built groups.
    private func modalSport(from groups: [SportGroup]) -> (sport: String, count: Int) {
        guard let top = groups.first else { return ("–", 0) }
        return (top.sport, top.count)
    }

    // MARK: - Range model

    private enum Range: CaseIterable, Hashable {
        case week, month, quarter, year, all
        var label: String {
            switch self {
            case .week:    return "7D"
            case .month:   return "30D"
            case .quarter: return "90D"
            case .year:    return "1Y"
            case .all:     return "All"
            }
        }
        var caption: String {
            switch self {
            case .week:    return "last 7 days"
            case .month:   return "last 30 days"
            case .quarter: return "last 90 days"
            case .year:    return "last year"
            case .all:     return "all time"
            }
        }
        /// A short noun for the effort hero's "Effort this …" headline.
        var heroWord: String {
            switch self {
            case .week:    return "week"
            case .month:   return "month"
            case .quarter: return "quarter"
            case .year:    return "year"
            case .all:     return "log"
            }
        }
        /// Trailing-window length in days, or nil for "all".
        var days: Int? {
            switch self {
            case .week:    return 7
            case .month:   return 30
            case .quarter: return 90
            case .year:    return 365
            case .all:     return nil
            }
        }
        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero sessions.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    // MARK: - Formatting

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "4:34 PM" where 12-hour is
    // preferred, "16:34" where 24-hour is — instead of forcing 24-hour on everyone (matches TodayView).
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "HH:mm–HH:mm" when the row carries a real end, start-only otherwise (#157).
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))–\(timeLabel(end))" : timeLabel(start)
    }

    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: unitSystem)
    }

    private func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    // MARK: - Sport icons

    // Sport → SF Symbol now lives in StrandDesign (`sportSymbol`) so the Today HR
    // overview annotates workouts with the same icons. Thin forwarder keeps call sites.
    private func sportIcon(_ sport: String) -> String { sportSymbol(sport) }

    // MARK: - Row + column metrics (uniform)

    private enum RowMetrics {
        static let headerHeight: CGFloat = 34
        static let rowHeight: CGFloat = 46   // every session row is exactly this tall
    }

    private enum ColWidth {
        static let date: CGFloat = 96
        static let sport: CGFloat = 160
        static let duration: CGFloat = 70
        static let hr: CGFloat = 64
        static let kcal: CGFloat = 70
        static let dist: CGFloat = 72
        static let source: CGFloat = 80
        static let action: CGFloat = 36   // trailing "•••" per-row actions menu
    }
}

#if DEBUG
@MainActor
private func previewWorkoutRows() -> [WorkoutRow] {
    let now = Int(Date().timeIntervalSince1970)
    let day = 86_400
    return [
        WorkoutRow(startTs: now - day * 0 - 3600, endTs: now - day * 0,
                   sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
                   avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
                   zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil),
        WorkoutRow(startTs: now - day * 1 - 2700, endTs: now - day * 1,
                   sport: "Strength Training", source: "whoop", durationS: 2700, energyKcal: 388,
                   avgHr: 118, maxHr: 156, strain: 9.4, distanceM: nil,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - day * 2 - 1800, endTs: now - day * 2,
                   sport: "Cycling", source: "apple_health", durationS: 1800, energyKcal: 240,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 12_800,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - day * 3 - 1500, endTs: now - day * 3,
                   sport: "Running", source: "apple_health", durationS: 1500, energyKcal: 310,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 5_100,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - day * 4 - 3300, endTs: now - day * 4,
                   sport: "Cycling", source: "whoop", durationS: 3300, energyKcal: 540,
                   avgHr: 134, maxHr: 162, strain: 11.8, distanceM: 24_600,
                   // Android key shape on purpose — exercises the cross-platform parser.
                   zonesJSON: #"{"zone1":20.0,"zone2":35.0,"zone3":30.0,"zone4":10.0}"#, notes: nil),
        WorkoutRow(startTs: now - day * 6 - 2400, endTs: now - day * 6,
                   sport: "Yoga", source: "whoop", durationS: 2400, energyKcal: 165,
                   avgHr: 92, maxHr: 118, strain: 5.1, distanceM: nil,
                   zonesJSON: nil, notes: nil),
    ]
}

#Preview("Workouts") {
    WorkoutsView(previewRows: previewWorkoutRows())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 1040, height: 940)
        .preferredColorScheme(.dark)
}

#Preview("Workouts — empty") {
    WorkoutsView(previewRows: [])
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 1040, height: 600)
        .preferredColorScheme(.dark)
}
#endif
