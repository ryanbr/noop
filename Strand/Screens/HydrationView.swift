import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Hydration detail (MVP, opt-in, local-only)
//
// Liquid finish: water in a vessel is the literal metaphor, so the hero is the canonical `LiquidVessel`
// tinted the action blue, filling to today's fraction of goal with the litre figure counting up over it.
// The day total sits in a filling `LiquidTube` (the same horizontal vessel Today's grid uses), the three
// quick-log buttons (Sip / Cup / Bottle) stay in the secondary NoopButton style, and the 7-day mini bars
// remain. Frosted `card {}` surfaces (rounded 22 + resting hairline), the day-of-sky backdrop, and
// `LiquidPressStyle` on the tappable drink rows line the screen up with the liquid Today + batch-1 tabs.
// BYTE-PARITY twin of the Android `HydrationScreen`: the day total + history come from the local-only
// `HydrationStore` series (additive day total), and the goal is the pure `HydrationGoal` engine (profile
// sex + today's Effort bump). Per-tap rows aren't separately persisted on either platform — the day total
// is the source of truth, so the screen shows the honest day figure.
struct HydrationView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Today's running total (ml) + the 7-day history (oldest→newest), loaded off the gesture path and
    /// refreshed after each log. A reload key the taps bump so the `.task` re-reads the store.
    @State private var totalML: Double = 0
    @State private var history: [(day: String, value: Double)] = []
    @State private var reloadTick = 0
    /// The animated fill the hero vessel + tube drive to on appear and after each log, so the liquid
    /// rises smoothly rather than snapping (the Today HeroScoreCell idiom).
    @State private var heroFraction: Double = 0
    /// #798 - today's individual logged drinks (for swipe-to-delete + tap-to-edit), and the entry being
    /// edited in the amount sheet (nil when the sheet is closed).
    @State private var entries: [HydrationEntry] = []
    /// Water imported from Apple Health for today (#949) — part of `totalML`, surfaced separately so the
    /// drinks card can show it as its own, non-editable line.
    @State private var importedML: Double = 0
    @State private var editingEntry: HydrationEntry?
    /// #798 - the user's custom container size (ml), editable from the custom-size sheet. Persisted local-only.
    @AppStorage(HydrationStore.customSizeKey) private var customSizeML = HydrationGoal.cupML
    @State private var showCustomSizeSheet = false

    /// "Card transparency" (0–100, default 100): fades the hydration cards in lockstep with the frosted
    /// cards; content stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    private var goalML: Int { repo.hydrationGoalML(profileSex: profile.sex) }
    private var fraction: Double { HydrationGoal.fraction(totalML: totalML, goalML: goalML) }
    private var percent: Int { min(100, Int((fraction * 100).rounded(.towardZero))) }

    var body: some View {
        ScreenScaffold(title: "Hydration",
                       subtitle: "Your fluid intake today, on \(Platform.deviceNounPhrase) only.",
                       onRefresh: { await reload() },
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Hydration sits in one atmosphere.
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ringSection
                logSection
                entriesSection
                historySection
                todayTotalSection
                Text("A simple goal that adjusts to your effort. General wellness guidance, not medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Rise the hero vessel + tube to the current fill on appear, and re-draw when a log moves it.
            // macOS-13-safe single-param onChange.
            .onChangeCompat(of: fraction) { newFraction in
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = newFraction }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = fraction }
            }
        }
        .task(id: reloadTick) { await reload() }
        // #798 - edit a logged drink's amount.
        .sheet(item: $editingEntry) { entry in
            HydrationAmountSheet(title: "Edit drink", initialML: entry.amountMl) { newML in
                editingEntry = nil
                Task { await updateEntry(entry, to: newML) }
            } onCancel: { editingEntry = nil }
        }
        // #798 - set the custom container size.
        .sheet(isPresented: $showCustomSizeSheet) {
            HydrationAmountSheet(title: "Custom size", initialML: customSizeML) { newML in
                customSizeML = newML
                showCustomSizeSheet = false
            } onCancel: { showCustomSizeSheet = false }
        }
    }

    // MARK: - Hero (the vessel: water filling toward the goal, in litres)

    private var ringSection: some View {
        card {
            VStack(spacing: NoopMetrics.cardInnerSpacing) {
                // The signature liquid gauge, filling the "of goal" fraction in the action blue. Water in
                // a vessel is the literal metaphor here, so it replaces the old flat progress ring. The
                // litre figure counts up over it; the vessel fills to the SAME animated `heroFraction`
                // driven on appear / after a log, so the fill and the number roll-up land together.
                ZStack {
                    LiquidVessel(value: heroFraction, tint: StrandPalette.accent, animated: true)
                        .frame(width: 184, height: 184)
                    VStack(spacing: 2) {
                        CountUpText(value: HydrationGoal.litres(fromML: totalML),
                                    format: { String(format: "%.1f", $0) },
                                    font: StrandFont.rounded(40, weight: .bold),
                                    color: StrandPalette.textPrimary)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                        Text(String(localized: "of \(String(format: "%.1f", HydrationGoal.litres(fromML: Double(goalML)))) L"))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .allowsHitTesting(false)   // taps fall through to the vessel → splash
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hydration today")
                .accessibilityValue("\(String(format: "%.1f", HydrationGoal.litres(fromML: totalML))) of \(String(format: "%.1f", HydrationGoal.litres(fromML: Double(goalML)))) litres")

                Text("\(percent)% of today's goal")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Frosted card helper (matches LiquidTodayView.card: rounded 22 + resting hairline)

    private func card<V: View>(padding: CGFloat = 16, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .opacity(cardOpacity)
            )
    }

    // MARK: - Quick log (Sip / Cup / Bottle, secondary style)

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(spacing: NoopMetrics.gap) {
                logButton("Sip", systemImage: "drop", ml: HydrationGoal.sipML)
                logButton("Cup", systemImage: "cup.and.saucer.fill", ml: HydrationGoal.cupML)
                logButton("Bottle", systemImage: "drop.fill", ml: HydrationGoal.bottleML)
            }
            // #798 - a custom container the user sizes themselves. Tapping logs it; the pencil opens the
            // size editor so a one-off mug / flask / glass can be set once and reused.
            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Custom \(customSizeML) ml", systemImage: "drop.circle", kind: .secondary, fullWidth: true) {
                    Task { await add(ml: customSizeML) }
                }
                .accessibilityLabel("Log custom \(customSizeML) millilitres")
                Button { showCustomSizeSheet = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                            .fill(StrandPalette.surfaceInset))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set custom container size")
            }
            Text("Sip \(HydrationGoal.sipML) ml · Cup \(HydrationGoal.cupML) ml · Bottle \(HydrationGoal.bottleML) ml")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// One quick-add button using the secondary (no-gold) NoopButton style. Logs the amount and refreshes.
    private func logButton(_ title: LocalizedStringKey, systemImage: String, ml: Int) -> some View {
        NoopButton(title, systemImage: systemImage, kind: .secondary, fullWidth: true) {
            Task { await add(ml: ml) }
        }
        .accessibilityLabel("Log \(title)")
    }

    // MARK: - Today's logged drinks (#798) - swipe to delete, tap to edit

    @ViewBuilder private var entriesSection: some View {
        // Also shown when the only water today came from Apple Health (#949) — otherwise the ring would
        // count drinks the screen never accounts for, and the day would look like it appeared from nowhere.
        if !entries.isEmpty || importedML > 0 {
            card(padding: 18) {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    Text("Today's drinks").strandOverline()
                    if importedML > 0 { importedRow }
                    // #842 — render rows in a plain VStack inside the page ScrollView. The previous nested,
                    // scroll-disabled List with a hardcoded `count * 44 + 8` height clipped every row past
                    // the third (real rows are taller than 44pt) and couldn't be scrolled to. Tap a row to
                    // edit; the trailing trash deletes (a VStack row can't host native swipe-to-delete).
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                            entryRow(entry)
                                .padding(.vertical, 6)
                            if idx < entries.count - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    if !entries.isEmpty {
                        Text("Tap a drink to edit it, or use the trash to delete.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// Water Apple Health already had, from a hydration app or a smart bottle (#949).
    ///
    /// Deliberately not tappable and with no trash: NOOP does not own these drinks, and "deleting" one
    /// here would be a lie — the next sync re-reads the same day from Health and the figure would come
    /// straight back. Removing it for real means removing it in the app that logged it.
    @ViewBuilder private var importedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            Text("From Apple Health")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text("\(Int(importedML.rounded())) ml")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Int(importedML.rounded())) millilitres from Apple Health. Edit it in the app that logged it.")
        if !entries.isEmpty { Divider().opacity(0.4) }
    }

    /// One logged-drink row: the time it was logged + its amount (tap to edit) with a trailing trash.
    private func entryRow(_ entry: HydrationEntry) -> some View {
        HStack(spacing: 10) {
            Button { editingEntry = entry } label: {
                HStack(spacing: 10) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(Self.entryTimeFmt.string(from: entry.loggedAt))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Text("\(entry.amountMl) ml")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            // Liquid tap response: the same physical settle-inward every tappable liquid row gets.
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("Logged \(entry.amountMl) millilitres at \(Self.entryTimeFmt.string(from: entry.loggedAt))")
            .accessibilityHint("Tap to edit the amount")
            Button(role: .destructive) {
                Task { await deleteEntry(entry) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete the \(entry.amountMl) millilitre drink logged at \(Self.entryTimeFmt.string(from: entry.loggedAt))")
        }
    }

    private static let entryTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    // MARK: - 7-day mini history (flat bars, today on the right)

    private var historySection: some View {
        card(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Last 7 days").strandOverline()
                historyBars
            }
        }
    }

    @ViewBuilder private var historyBars: some View {
        if history.isEmpty {
            Text("No history yet.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            // Scale the bars to the LARGER of the goal and the biggest day, so an over-goal day doesn't clip.
            let ceiling = max(Double(max(goalML, 1)), history.map(\.value).max() ?? 0, 1)
            let lastIndex = history.count - 1
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(history.enumerated()), id: \.element.day) { idx, bar in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(StrandPalette.textPrimary.opacity(0.10))
                                .frame(height: 96)
                            let frac = min(1.0, max(0.0, bar.value / ceiling))
                            if frac > 0 {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(idx == lastIndex ? StrandPalette.accent
                                                           : StrandPalette.accent.opacity(0.45))
                                    .frame(height: max(3, 96 * CGFloat(frac)))
                            }
                        }
                        Text(weekdayInitial(bar.day))
                            .font(StrandFont.overline)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(weekdayInitial(bar.day)): \(String(format: "%.1f", HydrationGoal.litres(fromML: bar.value))) litres")
                }
            }
        }
    }

    // MARK: - Today's total (the honest day figure; per-tap rows aren't persisted)

    private var todayTotalSection: some View {
        card(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Today").strandOverline()
                if totalML <= 0 {
                    Text("No drinks logged yet. Tap Sip, Cup or Bottle to start.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Logged today")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 8)
                        Text("\(Int(totalML)) ml")
                            .font(StrandFont.headline.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                    // Progress toward goal as the liquid tube (the same horizontal vessel Today's Key
                    // Metrics use), filling to the animated `heroFraction` so it rises with the hero.
                    LiquidTube(frac: heroFraction, tint: StrandPalette.accent, height: 8, animated: false)
                        .accessibilityLabel("Progress toward today's goal")
                        .accessibilityValue("\(percent) percent")
                }
            }
        }
    }

    // MARK: - Data

    /// The single-letter weekday for a yyyy-MM-dd key (M T W T F S S), or "·" when unparseable. Mirrors
    /// the Android `weekdayInitial` (EEE → first letter, US locale).
    // #perf: fixed-locale formatters, hoisted to static so the history-bar ForEach doesn't allocate two
    // DateFormatters per bar per render (label + a11y both call this). Locale is pinned (en_US_POSIX /
    // en_US), so caching is behaviour-identical — no dependence on the device locale.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let weekdayAbbrev: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"
        return f
    }()
    private func weekdayInitial(_ dayKey: String) -> String {
        guard let date = Self.dayKeyParser.date(from: dayKey) else { return "·" }
        return String(Self.weekdayAbbrev.string(from: date).prefix(1))
    }

    /// Log `ml` (additive day total + a per-entry row, #798) and refresh.
    private func add(ml: Int) async {
        guard ml > 0 else { return }
        _ = await repo.logHydration(amountMl: ml)
        reloadTick &+= 1
    }

    /// #798 - delete a logged drink, re-deriving the day total, then refresh.
    private func deleteEntry(_ entry: HydrationEntry) async {
        _ = await repo.deleteHydrationEntry(id: entry.id)
        reloadTick &+= 1
    }

    /// #798 - set a logged drink's amount, re-deriving the day total, then refresh.
    private func updateEntry(_ entry: HydrationEntry, to ml: Int) async {
        _ = await repo.updateHydrationEntry(id: entry.id, amountMl: ml)
        reloadTick &+= 1
    }

    /// Load today's total + the 7-day history + today's per-entry list from the store.
    private func reload() async {
        totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        history = await repo.hydrationHistory(days: 7)
        entries = repo.hydrationEntries()
        // #949: `totalML` already includes this; read it separately so the drinks card can name where
        // the difference came from instead of leaving an unexplained gap between the ring and the list.
        importedML = await repo.hydrationImportedTotal(day: Repository.localDayKey(Date()))
    }
}

// MARK: - Amount sheet (#798) - edit a drink / set the custom size

/// A small stepper sheet for an ml amount. Reused by the edit-entry and custom-size flows. Tokens only,
/// NoopButton actions, ARIA labels. Clamps to a sane range so the value stays a real container size.
private struct HydrationAmountSheet: View {
    let title: LocalizedStringKey
    let initialML: Int
    let onSave: (Int) -> Void
    let onCancel: () -> Void

    @State private var ml: Int

    /// Bounds for a plausible single container (10 ml up to 3 L), stepping in 10 ml increments.
    private static let minML = 10
    private static let maxML = 3000
    private static let stepML = 10

    init(title: LocalizedStringKey, initialML: Int, onSave: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.initialML = initialML
        self.onSave = onSave
        self.onCancel = onCancel
        _ml = State(initialValue: Self.clamp(initialML))
    }

    static func clamp(_ value: Int) -> Int { min(maxML, max(minML, value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack {
                Text("Amount")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(ml) ml")
                    .font(StrandFont.rounded(28, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
            }
            Stepper(value: $ml, in: Self.minML...Self.maxML, step: Self.stepML) {
                Text("Adjust amount")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .accessibilityLabel("Amount in millilitres")
            .accessibilityValue("\(ml) millilitres")
            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Cancel", kind: .secondary, fullWidth: true) { onCancel() }
                NoopButton("Save", kind: .primary, fullWidth: true) { onSave(Self.clamp(ml)) }
            }
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // iOS-only sheet sizing - macOS sheets are free-floating windows and reject detents (see the
        // shared `noopSheetPresentation` note); the call site stays cross-platform via this guard.
        #if os(iOS)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        #endif
    }
}
