import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Skin-temperature suite cards (v5 pillar)
//
// Three self-contained, reusable cards built on the underused nightly skin-temperature
// signal, each driven entirely by a pure StrandAnalytics engine RESULT passed in via init
// (Wave 3 runs the engines in the analytics pass and mounts these in the Health hub):
//
//   • CycleAwarenessCard   — CyclePhaseEngine.Result. OPT-IN (period/cycle tracking is the
//                            most sensitive health category). Awareness only — NOT
//                            contraception, NOT a fertility/ovulation predictor, NOT a
//                            diagnosis. Phase + cycle-day RANGE + probabilistic next-period
//                            WINDOW (never a hard date).
//   • BodyClockCard        — CircadianEngine.PhaseEstimate (+ optional JetLagPlan). Estimated
//                            body-clock phase + a jet-lag / shift plan that is LIGHT + SLEEP
//                            TIMING only (never a supplement/drug).
//   • HeadsUpCard          — IllnessSignalEngine.Result. The confounder-suppressed illness
//                            "heads-up". On-device estimate — not a diagnosis.
//
// DESIGN-SYSTEM ONLY: NoopCard + DomainTheme/StrandPalette tokens, StrandFont, NoopMetrics,
// ScoreStatePill, the house buttons. No raw hex, no ad-hoc cards. Privacy-forward copy:
// there is no upload or sync path, and every sensitive surface names the user-exported
// backup exception.
//
// The cards take VALUES, not stores — so a slip here stays local and can't take Health down,
// and the engines stay testable + I/O-free upstream. Wave 3 wiring is documented at the foot.

// MARK: - Shared chrome

/// The standing privacy promise repeated on every sensitive skin-temp surface (the single
/// biggest competitive wedge vs cloud cycle trackers, and the ethical stance).
private let skinTempPrivacyLine =
    String(localized: "This never leaves your device unless you export a backup yourself.")

/// A small, footnote-styled privacy row with a lock glyph — dropped at the foot of each
/// sensitive card so the promise is impossible to miss without shouting.
private struct PrivacyNote: View {
    var text: String = skinTempPrivacyLine
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 1. Cycle awareness card (OPT-IN)

/// Cycle phase awareness from the nightly skin-temperature shift, corroborated by the luteal
/// RHR rise + HRV drop. OPT-IN by design — the host shows this only after the user enables
/// cycle awareness (default OFF). Awareness only; never contraception/fertility/diagnosis.
struct CycleAwarenessCard: View {
    /// The classified result from `CyclePhaseEngine.classify(...)`, computed in the analytics pass.
    let result: CyclePhaseEngine.Result
    /// The nightly fused-index (or temp-deviation) series, oldest→newest, for the sparkline.
    /// Optional — the card is honest with or without a curve.
    var curve: [Double] = []
    /// Called when the user taps "Log period start" (opt-in logged-period mode). nil hides it.
    var onLogPeriod: (() -> Void)? = nil
    /// Called when the user opens the cycle detail screen. nil makes the card non-navigating.
    var onOpenDetail: (() -> Void)? = nil
    /// Called when the user turns cycle awareness OFF from here (#801). nil hides the off control.
    /// Provided so the feature can be turned off in-place exactly where it was turned on (the opt-in
    /// card's "Turn on" lives in the same Health spot), rather than only from Automations.
    var onTurnOff: (() -> Void)? = nil

    // Cycle awareness reads in the calm, NON-VALENCED Rest indigo world (mirroring Mind): a
    // phase is just information, never framed good/bad. No red, ever.
    private var hue: Color { StrandPalette.restColor }

    var body: some View {
        NoopCard(tint: hue) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header

                // The headline phase line + cycle-day range.
                phaseHeadline

                if !curve.isEmpty, curve.count > 1 {
                    Sparkline(values: curve,
                              gradient: Gradient(colors: [hue.opacity(0.4), StrandPalette.restBright]),
                              showsHover: false)
                        .frame(height: 30)
                        .accessibilityHidden(true)
                }

                // Honest one-line status / next-period window.
                Text(statusLine)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let window = result.nextPeriodWindow {
                    nextPeriodRow(window)
                }

                actions

                Divider().overlay(StrandPalette.hairline)

                // The standing awareness-only legal line (verbatim from the engine) + privacy promise.
                Text(CyclePhaseEngine.awarenessLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                PrivacyNote()

                // In-place off control (#801): the toggle is now symmetric, it can be turned off
                // right where it was turned on, not only from Automations. A quiet ghost button so it
                // sits below the awareness/privacy lines without competing with the primary actions.
                if let onTurnOff {
                    Button("Turn off cycle awareness", action: onTurnOff)
                        .buttonStyle(.noopGhost)
                        .accessibilityHint("Stops reading a cycle phase from your nightly temperature. You can turn it back on here any time.")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cycle awareness").strandOverline()
                Text("From your nightly temperature")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ScoreStatePill(scoreState, text: confidenceLabel)
        }
    }

    private var phaseHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(phaseTitle)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if let dayText = cycleDayText {
                Text(dayText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeadline)
    }

    private func nextPeriodRow(_ window: CyclePhaseEngine.NextPeriodWindow) -> some View {
        // A probabilistic WINDOW, never a single confident date — the copy reflects that.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hue)
                .accessibilityHidden(true)
            Text("A period is likely between \(prettyDay(window.earliestDay)) and \(prettyDay(window.latestDay)) (a window, not a fixed date).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: NoopMetrics.gap) {
            if let onLogPeriod {
                Button("Log period start", action: onLogPeriod)
                    .buttonStyle(.noopSecondary)
                    .accessibilityHint("Optional. Stored only on this device.")
            }
            if let onOpenDetail {
                Button("View detail", action: onOpenDetail)
                    .buttonStyle(.noopGhost)
            }
        }
    }

    // MARK: derived copy

    private var phaseTitle: String {
        switch result.phase {
        case .follicular:   return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:       return String(localized: "Luteal")
        case .unknown:      return String(localized: "No clear pattern")
        case .learning:     return String(localized: "Learning your pattern")
        }
    }

    /// "~day 18–22" — always a RANGE, never a single point.
    private var cycleDayText: String? {
        guard let lo = result.cycleDayLow, let hi = result.cycleDayHigh else { return nil }
        // En-dash in the range so the key matches the catalog entry `· ~day %lld–%lld` (a hyphen here
        // missed it and fell back to the English literal on every locale).
        return lo == hi ? String(localized: "· ~day \(lo)") : String(localized: "· ~day \(lo)–\(hi)")
    }

    private var statusLine: String { result.note }

    private var confidenceLabel: LocalizedStringKey {
        switch result.confidence {
        case .learning: return "Learning"
        case .building: return "Building"
        case .solid:    return "Solid"
        }
    }

    private var scoreState: ScoreState {
        switch result.confidence {
        case .learning: return .calibrating
        case .building: return .building
        case .solid:    return .solid
        }
    }

    private var accessibilityHeadline: String {
        if let lo = result.cycleDayLow, let hi = result.cycleDayHigh {
            return lo == hi
                ? String(localized: "Cycle phase: \(phaseTitle). About day \(lo).")
                : String(localized: "Cycle phase: \(phaseTitle). About day \(lo) to \(hi).")
        }
        return String(localized: "Cycle phase: \(phaseTitle).")
    }
}

// MARK: - Cycle awareness opt-in (empty / disabled states)

/// Shown in place of `CycleAwarenessCard` when the user has NOT opted in. A single calm
/// opt-in card restating the privacy promise at the point of consent (manual-first; default OFF).
struct CycleAwarenessOptInCard: View {
    /// Toggles cycle awareness ON (the host persists the preference, default OFF).
    var onEnable: () -> Void

    var body: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(spacing: 8) {
                    Image(systemName: "drop.degreesign")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.restColor)
                        .accessibilityHidden(true)
                    Text("Cycle awareness")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }
                Text("NOOP can read a coarse menstrual-cycle phase from your nightly skin temperature, entirely on your device. It is awareness only: not contraception, not a fertility predictor, not a medical service.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrivacyNote()
                Button("Turn on cycle awareness", action: onEnable)
                    .buttonStyle(.noopSecondary)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Menstrual cycle Home card

/// Compact Home entry point for the local period-start tracker. The card deliberately stays focused on
/// dates the user entered and the existing awareness-only estimate: no fertility, ovulation, safe-day,
/// or medical claims. It is shown only on Today and only when the profile is eligible, tracking is already
/// enabled, or local history exists.
struct MenstrualCycleHomeCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profile: ProfileStore

    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    /// The user's "not for me" opt-out (#hide-cycle): when set, the card is suppressed entirely,
    /// reversibly from Automations. USER-controlled, never age-based.
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false
    @State private var starts: [String] = []
    @State private var showingTracker = false

    private var shouldShow: Bool {
        !cycleHidden && (profile.cycleAwarenessApplies || cycleEnabled || !starts.isEmpty)
    }

    var body: some View {
        Group {
            if shouldShow {
                NoopCard(tint: StrandPalette.restColor) {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        HStack(spacing: NoopMetrics.space2) {
                            Image(systemName: "drop.degreesign")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(StrandPalette.restColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Menstrual Cycle")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("Private, on-device tracking")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                        }

                        if cycleEnabled {
                            HStack(alignment: .firstTextBaseline) {
                                Text(model.cyclePhase.map { phaseTitle($0.phase) }
                                     ?? String(localized: "Learning your pattern"))
                                    .font(StrandFont.title2)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                if let result = model.cyclePhase,
                                   let lo = result.cycleDayLow,
                                   let hi = result.cycleDayHigh {
                                    // Return `Text` from each branch so the literal is a LocalizedStringKey
                                    // (`~day %lld` / `~day %lld-%lld`); a ternary of Strings would take the
                                    // verbatim `Text(_:)` init and ship English regardless of locale.
                                    (lo == hi ? Text("~day \(lo)") : Text("~day \(lo)-\(hi)"))
                                        .font(StrandFont.bodyNumber)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        } else {
                            Text("Log period starts locally and use them to anchor optional cycle estimates.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack {
                            Text("Latest period start")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Text(starts.last.map(prettyDay) ?? String(localized: "No period starts logged yet."))
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(starts.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }

                        HStack(spacing: NoopMetrics.space2) {
                            Button(cycleEnabled ? "Open tracker" : "Set up cycle tracking") {
                                openTracker()
                            }
                            .buttonStyle(.noopSecondary)

                            if cycleEnabled {
                                Button(starts.contains(Repository.localDayKey(Date())) ? "Logged today" : "Log today") {
                                    logToday()
                                }
                                .buttonStyle(.noopGhost)
                                .disabled(starts.contains(Repository.localDayKey(Date())))
                            }
                        }

                        PrivacyNote()
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .task(id: repo.cycleTrackingSeq) {
            starts = await repo.periodStarts()
            if cycleEnabled, model.cyclePhase == nil { await model.refreshV5Signals() }
        }
        .sheet(isPresented: $showingTracker) {
            Group {
                if let result = model.cyclePhase {
                    CycleTrackerView(result: result, curve: model.cycleCurve)
                } else {
                    ProgressView("Preparing cycle tracker…")
                        .task { await model.refreshV5Signals() }
                        .padding(NoopMetrics.screenPadding)
                }
            }
        }
    }

    private func openTracker() {
        cycleEnabled = true
        model.cycleAwarenessEnabled = true
        Task {
            await model.refreshV5Signals()
            showingTracker = true
        }
    }

    private func logToday() {
        let today = Repository.localDayKey(Date())
        guard !starts.contains(today) else { return }
        Task {
            await repo.logPeriodStart(day: today)
            await model.refreshV5Signals()
        }
    }

    private func phaseTitle(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular:    return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:        return String(localized: "Luteal")
        case .unknown:       return String(localized: "No clear pattern")
        case .learning:      return String(localized: "Learning your pattern")
        }
    }

    private func prettyDay(_ day: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Cycle tracker detail

/// Local-only logged-period detail. It deliberately records only cycle day 1: the engine needs an
/// anchor, while avoiding fabricated flow/fertility claims. Dates are editable through a real delete
/// and re-log path, and every sensitive surface repeats the privacy + wellness-only contract.
struct CycleTrackerView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let result: CyclePhaseEngine.Result
    var curve: [Double] = []

    @State private var selectedDate = Date()
    @State private var starts: [String] = []
    @State private var confirmDeleteAll = false

    private var selectedDay: String { Repository.localDayKey(selectedDate) }
    private var alreadyLogged: Bool { starts.contains(selectedDay) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    SectionHeader("Cycle tracker", overline: "Period-start history")
                    statusCard
                    logCard
                    historyCard
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Text(CyclePhaseEngine.awarenessLine)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        PrivacyNote()
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Cycle tracker")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: repo.cycleTrackingSeq) { starts = await repo.periodStarts() }
            .confirmationDialog("Delete all logged period starts?",
                                isPresented: $confirmDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete all period history", role: .destructive) {
                    Task {
                        await repo.deleteAllPeriodStarts()
                        await model.refreshV5Signals()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the on-device period-start history. Sensor history is not changed.")
            }
        }
        #if os(macOS)
        .frame(minWidth: NoopMetrics.detailSheetMinWidth,
               minHeight: NoopMetrics.detailSheetMinHeight)
        #endif
    }

    private var statusCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Current estimate").strandOverline()
                HStack(alignment: .firstTextBaseline) {
                    Text(phaseTitle)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let lo = result.cycleDayLow, let hi = result.cycleDayHigh {
                        // `Text` per branch → localized (`~day %lld` / `~day %lld-%lld`); a String ternary
                        // would take the verbatim init and never localize.
                        (lo == hi ? Text("~day \(lo)") : Text("~day \(lo)-\(hi)"))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if curve.count > 1 {
                    Sparkline(values: curve,
                              gradient: Gradient(colors: [StrandPalette.restColor.opacity(0.4),
                                                          StrandPalette.restBright]),
                              showsHover: false)
                        .frame(height: NoopMetrics.space10)
                        .accessibilityHidden(true)
                }
                Text(result.note)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let window = result.nextPeriodWindow {
                    Text("Likely period window: \(prettyDay(window.earliestDay))-\(prettyDay(window.latestDay)). This is a range, not a fixed date.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var logCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Log a period start").strandOverline()
                DatePicker("Period started on", selection: $selectedDate, in: ...Date(),
                           displayedComponents: .date)
                    .font(StrandFont.body)
                Button(alreadyLogged ? "Already logged" : "Log period start") {
                    Task {
                        await repo.logPeriodStart(day: selectedDay)
                        await model.refreshV5Signals()
                    }
                }
                .buttonStyle(.noopSecondary)
                .disabled(alreadyLogged)
                Text("This optional date anchors cycle day 1 and is checked against your nightly temperature pattern.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var historyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text("Logged starts").strandOverline()
                    Spacer()
                    if !starts.isEmpty {
                        Button("Delete all") { confirmDeleteAll = true }
                            .buttonStyle(.noopGhost)
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }
                if starts.isEmpty {
                    Text("No period starts logged yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(starts.reversed(), id: \.self) { day in
                        HStack {
                            Image(systemName: "drop.fill")
                                .foregroundStyle(StrandPalette.restColor)
                                .accessibilityHidden(true)
                            Text(prettyDay(day))
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Button {
                                Task {
                                    await repo.deletePeriodStart(day: day)
                                    await model.refreshV5Signals()
                                }
                            } label: {
                                Label("Delete \(prettyDay(day))", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.noopGhost)
                            .foregroundStyle(StrandPalette.statusCritical)
                        }
                        if day != starts.first { Divider().overlay(StrandPalette.hairline) }
                    }
                }
            }
        }
    }

    private var phaseTitle: String {
        switch result.phase {
        case .follicular: return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal: return String(localized: "Luteal")
        case .unknown: return String(localized: "No clear pattern")
        case .learning: return String(localized: "Learning your pattern")
        }
    }
}

// MARK: - 2. Body Clock card

/// Estimated body-clock phase + an optional jet-lag / shift plan. The plan is LIGHT + SLEEP
/// TIMING only — never a supplement. Behavioural awareness, approximate.
struct BodyClockCard: View {
    /// The phase estimate from `CircadianEngine.estimatePhase(...)`, computed in the analytics pass.
    let estimate: CircadianEngine.PhaseEstimate
    /// Optional active re-entrainment plan (jet-lag / shift). nil = no plan running.
    var plan: CircadianEngine.JetLagPlan? = nil
    /// Opens the body-clock detail / jet-lag planner. nil makes the card non-navigating.
    var onOpenPlanner: (() -> Void)? = nil

    // The body clock reads in the cool Rest world — calm, sleep-adjacent, non-valenced.
    private var hue: Color { StrandPalette.restColor }

    var body: some View {
        NoopCard(tint: hue) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header

                offsetHeadline

                Text(estimate.note)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The estimated temperature-minimum clock time — the canonical phase marker.
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hue)
                        .accessibilityHidden(true)
                    Text("Estimated body-clock low around \(clockString(estimate.tempMinHour))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityElement(children: .combine)

                if let plan, plan.direction != .none, let firstDay = plan.days.first {
                    Divider().overlay(StrandPalette.hairline)
                    planSummary(plan, firstDay: firstDay)
                }

                if let onOpenPlanner {
                    Button(plan == nil ? "Plan a trip or shift" : "View the full plan", action: onOpenPlanner)
                        .buttonStyle(.noopGhost)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Body clock").strandOverline()
                Text("Light + sleep timing only")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ScoreStatePill(scoreState, text: confidenceLabel)
        }
    }

    private var offsetHeadline: some View {
        Text(offsetTitle)
            .font(StrandFont.title2)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(offsetTitle)
    }

    private func planSummary(_ plan: CircadianEngine.JetLagPlan, firstDay: CircadianEngine.DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan · \(plan.estimatedDays)-day shift")
                .strandOverline()
            // Day 1's concrete light + lights-out cue — light + sleep timing only.
            Text("Day 1: bright light \(clockString(firstDay.brightLightStartHour))-\(clockString(firstDay.brightLightEndHour)), lights-out around \(clockString(firstDay.targetSleepHour)).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(plan.note)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: derived copy

    /// "About 25 min later than your schedule" — a plain, skimmable headline.
    private var offsetTitle: String {
        let mins = Int(abs(estimate.offsetVsScheduleMinutes).rounded())
        if estimate.confidence == .unreadable {
            return String(localized: "Hard to read right now")
        }
        if mins <= 20 {
            return String(localized: "About in sync with your schedule")
        }
        return estimate.offsetVsScheduleMinutes > 0
            ? String(localized: "About \(mins) min later than your schedule")
            : String(localized: "About \(mins) min earlier than your schedule")
    }

    private var confidenceLabel: LocalizedStringKey {
        switch estimate.confidence {
        case .unreadable: return "Calibrating"
        case .wide:       return "Building"
        case .solid:      return "Solid"
        }
    }

    private var scoreState: ScoreState {
        switch estimate.confidence {
        case .unreadable: return .calibrating
        case .wide:       return .building
        case .solid:      return .solid
        }
    }

    /// Render a fractional clock hour as "HH:MM" (locale-free, matching the engine's own helper).
    private func clockString(_ hour: Double) -> String {
        var h = hour.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}

// MARK: - 3. Heads-Up card (illness early-warning, confounder-suppressed)

/// The confounder-suppressed illness "heads-up". Renders the engine's already-decided level +
/// copy; the host only mounts it when the engine returns a non-quiet level. On-device estimate
/// — not a diagnosis. Mirrors the existing amber HealthAlertBanner treatment.
struct HeadsUpCard: View {
    /// The decision from `IllnessSignalEngine.evaluate(...)`, computed in the analytics pass.
    let result: IllnessSignalEngine.Result
    /// Optional parallel Mahalanobis distance (IllnessDistance), computed on the SAME z-vector. It does
    /// NOT gate this card (the engine's level already did); when the level is raised and a distance is
    /// present we append a subtle "Confidence" line so the user can gauge how strong the signal is.
    var distance: IllnessDistance.Result? = nil

    var body: some View {
        NoopCard(padding: 14, tint: hue) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: glyph)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hue)
                        .frame(width: 30, height: 30)
                        .background(hue.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(result.copy)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                // The visible "why": which signals fired. Explainability is what earns trust.
                if !result.firedSignals.isEmpty {
                    whyRow(label: "Signals up", values: result.firedSignals, tint: hue)
                }
                // ...and what was ruled out (the differentiating part vs a black-box warning).
                if !result.suppressedBy.isEmpty {
                    whyRow(label: "Explained by", values: result.suppressedBy, tint: StrandPalette.textTertiary)
                }
                // Optional confidence read from the parallel Mahalanobis distance, only when the level is
                // raised. Subtle by design: it augments, never gates (the engine already decided to raise).
                if let confidence = confidenceLine {
                    Text(confidence)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(result.copy)")
    }

    private func whyRow(label: LocalizedStringKey, values: [String], tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).strandOverline()
            // Each fired signal / confounder as a quiet chip.
            FlowChips(values: values, tint: tint)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: derived presentation

    /// The card hue follows the level: raised/already-unwell = amber warning (matches the
    /// shipped banner); suppressed/mild = a calmer neutral so it never scares.
    private var hue: Color {
        switch result.level {
        case .raised, .alreadyUnwell: return StrandPalette.statusWarning
        case .suppressed, .mild:      return StrandPalette.restColor
        case .quiet:                  return StrandPalette.restColor
        }
    }

    private var glyph: String {
        switch result.level {
        case .raised:        return "exclamationmark.triangle.fill"
        case .alreadyUnwell: return "bed.double.fill"
        case .suppressed:    return "info.circle.fill"
        case .mild:          return "waveform.path"
        case .quiet:         return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch result.level {
        case .raised:        return String(localized: "Heads-up")
        case .alreadyUnwell: return String(localized: "Rest up")
        case .suppressed:    return String(localized: "Probably not illness")
        case .mild:          return String(localized: "A few signals are up")
        case .quiet:         return String(localized: "Nothing notable")
        }
    }

    /// A subtle confidence read from the parallel Mahalanobis distance, surfaced ONLY on the RAISED state
    /// (and when a distance is present). nil otherwise. The already-unwell state is driven purely by the
    /// user's own log and can have a near-zero distance (0-1 present features), giving a misleading
    /// "Confidence: slight (distance 0.0)", so it's excluded. The raised path always has >= 2 present
    /// features, so its distance is meaningful. The band mirrors Android exactly. (Augment-only, never gates.)
    private var confidenceLine: String? {
        guard result.level == .raised,
              let d = distance else { return nil }
        return String(localized: "Confidence: \(IllnessConfidence.band(d.distance)) (distance \(IllnessConfidence.formatted(d.distance)))")
    }
}

// MARK: - Illness confidence band (shared wording, mirrored byte-for-byte on Android)

/// Maps the parallel Mahalanobis distance to a plain confidence word + a one-decimal display value.
/// This is presentation-only: it NEVER decides whether the Heads-Up card shows (the engine's level
/// already did). Bands: >= 3.5 strong, >= 2.5 moderate, else slight. Identical to the Kotlin twin.
enum IllnessConfidence {
    static func band(_ distance: Double) -> String {
        if distance >= 3.5 { return String(localized: "strong") }
        if distance >= 2.5 { return String(localized: "moderate") }
        return String(localized: "slight")
    }
    static func formatted(_ distance: Double) -> String {
        String(format: "%.1f", distance)
    }
}

// MARK: - Small chip flow (shared by Heads-Up)

/// A wrapping row of small tinted chips. Used for fired signals / confounders so a long list
/// never clips. Decorative wrapping; the parent combines it into one VoiceOver stop.
private struct FlowChips: View {
    let values: [String]
    var tint: Color = StrandPalette.textTertiary
    var body: some View {
        // A simple wrapping HStack via a flexible layout; for the small counts here a plain
        // HStack with wrapping fallback is enough and avoids a custom Layout dependency.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        ForEach(values, id: \.self) { v in
            Text(v)
                .font(StrandFont.captionNumber)
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        }
    }
}

// MARK: - Day formatting

/// "12 Jun" from a "yyyy-MM-dd" key (locale-aware for display only; the engine math stays UTC).
private func prettyDay(_ key: String) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m) else { return key }
    let months = [String(localized: "Jan"), String(localized: "Feb"), String(localized: "Mar"),
                  String(localized: "Apr"), String(localized: "May"), String(localized: "Jun"),
                  String(localized: "Jul"), String(localized: "Aug"), String(localized: "Sep"),
                  String(localized: "Oct"), String(localized: "Nov"), String(localized: "Dec")]
    return "\(d) \(months[m - 1])"
}

#if DEBUG
#Preview("Skin-temp cards") {
    ScrollView {
        VStack(spacing: NoopMetrics.sectionGap) {
            CycleAwarenessCard(
                result: CyclePhaseEngine.Result(
                    phase: .luteal, confidence: .solid,
                    cycleDayLow: 20, cycleDayHigh: 24, cycleLengthDays: 28,
                    nextPeriodWindow: .init(earliestDay: "2026-06-24", latestDay: "2026-06-28"),
                    shiftMarkers: [], note: "Luteal range — temperature is running above your baseline."),
                curve: (0..<60).map { 0.1 * sin(Double($0) / 9) + 0.05 },
                onLogPeriod: {}, onOpenDetail: {})

            CycleAwarenessOptInCard(onEnable: {})

            BodyClockCard(
                estimate: CircadianEngine.PhaseEstimate(
                    tempMinHour: 5.2, acrophaseHours: 16.0, offsetVsScheduleMinutes: 38,
                    confidence: .solid, note: "Your body clock looks later (a night-owl lean)."),
                plan: CircadianEngine.JetLagPlan(
                    direction: .advance, totalShiftHours: 3, estimatedDays: 3,
                    days: [.init(dayIndex: 1, brightLightStartHour: 7, brightLightEndHour: 9,
                                 dimFromHour: 21, targetSleepHour: 22.75, targetWakeHour: 6.5,
                                 guidance: "")],
                    note: "Shifting your clock 3.0 h earlier, about an hour a day. Light and sleep timing only."),
                onOpenPlanner: {})

            HeadsUpCard(result: IllnessSignalEngine.Result(
                score: 64, level: .raised,
                firedSignals: ["RHR +6", "HRV −22%", "skin temp +0.7 °C"],
                suppressedBy: [], signalCount: 3,
                copy: "Heads-up — your body looks strained. RHR +6, HRV −22%, skin temp +0.7 °C. With no alcohol or travel logged, consider taking it easy. On-device estimate — not a diagnosis."))

            HeadsUpCard(result: IllnessSignalEngine.Result(
                score: 28, level: .suppressed,
                firedSignals: ["RHR +5", "skin temp +0.6 °C"],
                suppressedBy: ["alcohol"], signalCount: 2,
                copy: "Some signals are up (RHR +5, skin temp +0.6 °C), but you logged alcohol — likely that, not illness. On-device estimate — not a diagnosis."))
        }
        .padding(NoopMetrics.screenPadding)
    }
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
