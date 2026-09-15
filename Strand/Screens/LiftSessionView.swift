import SwiftUI
import StrandDesign
import WhoopStore

// The workout sheet: every exercise and every set of the session, on one scrollable page.
//
// WHY A SHEET AND NOT A WIZARD. The first version showed one set at a time and walked the plan in
// order. In a real gym that fails twice over: you cannot see what is coming, and you cannot move on
// when a machine is occupied. So every set is a row, any pending row can be started, and finished
// rows stay on screen with what you lifted.
//
// COLOUR CARRIES STATE, so you can find your place at a glance from arm's length:
//   green   the set you are working now
//   amber   the rest that follows it
//   done    a completed set, with a check; numbers nobody typed stay grey
//
// The session itself lives in `LiftSessionController`, ABOVE this view. Swiping this sheet away
// minimises it to the bottom bar; the clock, the strap gesture and the buzzes all keep running,
// because a workout outlives the screen you happen to be looking at.

struct LiftSessionView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var session: LiftSessionController
    @Environment(\.dismiss) private var dismiss

    /// Called once the session has been written, so the hub can reload.
    let onFinished: () async -> Void

    @State private var showingFinish = false
    @State private var confirmingDiscard = false
    @State private var sessionRpeText = ""
    @State private var saving = false
    /// The two questions finishing can ask. Nil until answered: saving waits for an answer rather than
    /// deciding for the user.
    @State private var unfinishedChoice: UnfinishedChoice?
    @State private var programChoice: ProgramChoice?
    /// Program lines whose set count this session changed, read when the finish sheet opens.
    @State private var setCountChanges: [LiftSessionController.SetCountChange] = []

    private enum UnfinishedChoice: Hashable { case complete, discard }
    private enum ProgramChoice: Hashable { case update, keep }

    /// For the live heart rate on the control bar. `AppModel.bpm` is the smoothed, spike-filtered
    /// value every screen is supposed to show — never the raw per-beat number, which swings with HRV.
    @EnvironmentObject private var model: AppModel

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @FocusState private var focused: FocusTarget?
    private enum FocusTarget: Hashable {
        case weight(LiftSlot), reps(LiftSlot), rpe(LiftSlot), sessionRpe
    }

    /// What the user has TYPED into a field, held until they leave it.
    ///
    /// Without this a numeric field cannot accept a decimal at all. Each binding read its text back
    /// out of the engine, so every keystroke round-tripped through `LiftFormat` and was replaced by
    /// the canonical rendering of the parsed value. Typing "45." parsed to 45, re-rendered as "45",
    /// and the point vanished as it was typed — then the next keystroke made "455". A user entering
    /// 45.5 kg silently got 455 kg, which is the shape of bug this feature has to stop having.
    ///
    /// So while a field is focused it shows exactly what was typed; the parsed value still goes to
    /// the engine and to disk on every keystroke, so nothing about durability changes. The draft is
    /// dropped when focus leaves and the row goes back to the canonical formatting.
    @State private var draft: [FocusTarget: String] = [:]

    private var engine: LiftSessionEngine? { session.engine }

    var body: some View {
        Group {
            if let engine {
                VStack(spacing: 0) {
                    sheet(engine)
                    // The control bar never scrolls away: at the rack the clock and the one action have to
                    // be where your thumb already is.
                    controlBar(engine)
                }
            } else {
                ComingSoon(what: "No session running", symbol: "dumbbell")
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 800)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
        .task { await loadLastTime() }
        // Release a field's draft once the user leaves it, so the row returns to the canonical
        // formatting ("45.50" typed becomes "45.5"). The single-argument form on purpose: the
        // two-argument `onChange` is macOS 14+ and this file also builds for macOS 13.
        .onChange(of: focused) { now in
            draft = draft.filter { $0.key == now }
        }
        .sheet(isPresented: $showingFinish) { finishSheet }
    }

    // MARK: - The scrollable sheet

    private func sheet(_ engine: LiftSessionEngine) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    header(engine)
                    ForEach(Array(engine.plan.enumerated()), id: \.offset) { index, item in
                        exerciseCard(engine, index: index, item: item)
                    }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.top, 18)
            }
            .onChange(of: engine.currentSlot) { slot in
                // Follow the session down the sheet, but only when it moves on its own — scrolling
                // back to read an earlier exercise must not be yanked away from.
                guard let slot else { return }
                withAnimation { proxy.scrollTo(slot.exerciseIndex, anchor: .top) }
            }
        }
    }

    private func header(_ engine: LiftSessionEngine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.programName ?? String(localized: "Session"))
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(String(localized: "\(engine.completedWorkingSets) of \(engine.plannedWorkingSets) sets done"))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - One exercise, with all its sets

    private func exerciseCard(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.exercise)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(LiftMuscleSummary.line(primary: item.primaryMuscle,
                                                secondaries: item.secondaryMuscles))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Belt and braces with the entry cap: the sets are what this screen is for,
                        // and a note must never be able to push them off it.
                        .lineLimit(4)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StrandPalette.metricAmber.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                columnHeadings

                ForEach(engine.slots(forExercise: index), id: \.self) { slot in
                    setRow(engine, slot: slot)
                    // The rest belongs BETWEEN two sets, because that is where it happens.
                    if isRestingAfter(engine, slot: slot) { restBand(engine) }
                }

                setCountRow(engine, index: index, item: item)
            }
        }
        .id(index)
    }

    /// Add one more set, or drop the last planned one — at the END of the exercise, because that is
    /// where the question comes up: you have done what was written down and have one more in you, or
    /// you have not. Until this existed the sheet drew exactly `1...targetSets` and the extra set was
    /// performed and then lost.
    ///
    /// The geometry mirrors a set row: the minus sits in the tick column, under the checks it undoes.
    ///
    /// **Both buttons change this session only.** Whether the program keeps the new count is asked
    /// when the session is finished: a program is a plan for next time, and one extra set on a good
    /// day is not always a new plan.
    private func setCountRow(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem) -> some View {
        let canAdd = item.targetSets < LiftSessionEngine.maxSetsPerExercise
        let canRemove = engine.canRemoveSet(fromExercise: index)

        return HStack(spacing: 8) {
            Button {
                session.addSet(toExercise: index)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Add set").font(StrandFont.caption)
                }
                .foregroundStyle(canAdd ? StrandPalette.effortColor : StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel(String(localized: "Add a set to \(item.exercise)"))

            Button {
                session.removeSet(fromExercise: index)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 17, weight: .semibold))
                    // Dimmed rather than gone: the pair reads as one control, and a minus that
                    // disappears once the last set is done looks like a feature that broke.
                    .foregroundStyle(canRemove ? StrandPalette.textSecondary
                                               : StrandPalette.textTertiary.opacity(0.4))
                    .frame(width: Self.tickColumnWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .accessibilityLabel(String(localized: "Remove the last set from \(item.exercise)"))
        }
        .padding(.top, 2)
        .padding(.horizontal, 8)
    }

    /// Width of the set-number column, shared by the heading and every row so the number sits
    /// directly under its label.
    ///
    /// 34, not 26. `strandOverline` renders ALL-CAPS with +1.4 tracking, and at 26 the heading wrapped
    /// mid-word — a real session photographed it reading "SE / T" over two lines. The headings are
    /// also `lineLimit(1)` with a scale floor: this row is four short labels across a phone width in
    /// ten languages, and a wrapped heading breaks the column alignment for every row beneath it.
    static let setColumnWidth: CGFloat = 34

    /// Width of the trailing tick column. Mirrored by a clear spacer in the heading row so the four
    /// labels sit over the four things they name.
    private static let tickColumnWidth: CGFloat = 30

    private var columnHeadings: some View {
        HStack(spacing: 8) {
            Text("Set").strandOverline()
                .frame(width: Self.setColumnWidth, alignment: .center)
            Text(weightHeading).strandOverline().frame(maxWidth: .infinity, alignment: .leading)
            Text("Reps").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
            Text("RPE").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Self.tickColumnWidth)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var weightHeading: LocalizedStringKey {
        unitSystem == .imperial ? "Lb" : "Kg"
    }

    // MARK: - One set row

    private func setRow(_ engine: LiftSessionEngine, slot: LiftSlot) -> some View {
        let recorded = engine.recordedSet(for: slot)
        let isWorking = engine.stage == .working(slot)

        return HStack(spacing: 8) {
            // The set number IS the warm-up toggle. Warm-ups are excluded from volume and from the
            // per-muscle counts, so being unable to mark one silently inflates the single figure the
            // whole feature rests on — it has to be reachable in one tap, without leaving the row.
            Button {
                toggleWarmup(slot)
            } label: {
                Text(isWarmup(slot) ? String(localized: "W") : "\(slot.setIndex)")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(isWarmup(slot)
                                     ? StrandPalette.metricAmber
                                     : (isWorking ? StrandPalette.textPrimary
                                                  : StrandPalette.textSecondary))
                    .frame(width: Self.setColumnWidth, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isWarmup(slot)
                                ? String(localized: "Warm-up set — tap to make it a working set")
                                : String(localized: "Set \(slot.setIndex) — tap to mark it a warm-up"))

            numberField(slot: slot, field: .weight(slot),
                        text: weightBinding(slot),
                        ghost: ghostWeight(slot))
            numberField(slot: slot, field: .reps(slot),
                        text: repsBinding(slot),
                        ghost: ghostReps(slot))
            numberField(slot: slot, field: .rpe(slot),
                        text: rpeBinding(slot),
                        ghost: ghostRpe(engine, slot: slot))

            // The tick both REPORTS and ACTS: filled when the set is done, and tappable to start
            // this set when it is not — which is how you jump to a different exercise.
            Button {
                if recorded == nil { session.start(slot) } else { session.start(slot) }
            } label: {
                Image(systemName: recorded == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(recorded == nil
                                     ? StrandPalette.textTertiary
                                     : StrandPalette.statusPositive)
            }
            .buttonStyle(.plain)
            .frame(width: Self.tickColumnWidth)
            .accessibilityLabel(recorded == nil
                                ? String(localized: "Start this set")
                                : String(localized: "Redo this set"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(rowBackground(isWorking: isWorking, done: recorded != nil),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Warm-up state lives in the controller, so a mark survives the sheet being minimised and
    /// applies however the set was closed out — button, strap, or the minimised bar.
    private func isWarmup(_ slot: LiftSlot) -> Bool { session.isWarmup(slot) }

    private func toggleWarmup(_ slot: LiftSlot) {
        session.setWarmup(slot, !session.isWarmup(slot))
    }

    /// Green = working now, faint = done, clear = still to come.
    ///
    /// Deliberately no amber case. Tinting the just-finished SET amber said the wrong thing: the set
    /// is over, and what is running is the gap after it. The rest is drawn as its own band between
    /// the two set rows instead — see `restBand`.
    private func rowBackground(isWorking: Bool, done: Bool) -> Color {
        if isWorking { return StrandPalette.statusPositive.opacity(0.20) }
        if done { return StrandPalette.surfaceRaised.opacity(0.5) }
        return .clear
    }

    private func isRestingAfter(_ engine: LiftSessionEngine, slot: LiftSlot) -> Bool {
        if case .resting(let s, _) = engine.stage { return s == slot }
        return false
    }

    /// The running rest, drawn as an amber band sitting BETWEEN the set that ended and the set that
    /// follows — which is literally where a rest is.
    ///
    /// It replaces tinting the finished set's row amber. That read as "this set is amber" when the
    /// set was already done, and from across a gym floor it was not obvious which gap was running.
    /// A band in the gap is unambiguous at a glance, which is the whole requirement: you are looking
    /// at this from a bench, not reading it.
    ///
    /// It carries the countdown as well as the colour. The control bar has the same number, but the
    /// control bar is pinned to the bottom and this is where your eyes already are — and once the
    /// sheet is scrolled to a later exercise, the band is the only thing that says which rest.
    private func restBand(_ engine: LiftSessionEngine) -> some View {
        let remaining = engine.restRemaining(now: session.now) ?? 0
        return HStack(spacing: 8) {
            Text("Rest period").strandOverline()
                .foregroundStyle(StrandPalette.metricAmber)
            Spacer(minLength: 0)
            Text(LiftFormat.duration(remaining))
                .font(StrandFont.captionNumber)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.metricAmber)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.metricAmber.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private func numberField(slot: LiftSlot, field: FocusTarget,
                             text: Binding<String>, ghost: String) -> some View {
        TextField(ghost, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: field)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ghost values
    //
    // The grey numbers come from ONE chain, `LiftSessionController.carry(for:)`: this exercise earlier
    // in the session (set 2 almost always mirrors set 1), then the same set last session, then the
    // program's target. The minimised bar and the Lock Screen read the same chain.
    //
    // A set keeps its grey numbers after it is done, until something is typed over them — grey means
    // "not entered". What they are worth is decided when the session is finished: every set without
    // typed numbers is completed with them, or discarded, in one choice.

    private func ghostWeight(_ slot: LiftSlot) -> String {
        session.carry(for: slot).weightKg.map { display($0) } ?? "—"
    }

    private func ghostReps(_ slot: LiftSlot) -> String {
        session.carry(for: slot).reps.map(String.init) ?? "—"
    }

    /// RPE is never carried, so its ghost is only the previous set's own rating — a reminder, never a
    /// value any set will save.
    private func ghostRpe(_ engine: LiftSessionEngine, slot: LiftSlot) -> String {
        engine.previousSetInSession(for: slot)?.rpe.map { LiftFormat.trim($0) } ?? "—"
    }

    private func display(_ kg: Double) -> String {
        LiftFormat.trim(LiftFormat.display(fromKilograms: kg, system: unitSystem))
    }

    // MARK: - Field bindings
    //
    // Each field reads and writes THROUGH the controller, so a keystroke lands in the engine and on
    // disk immediately.
    //
    // TYPING INTO ANY SET, AT ANY TIME. A set that has already been performed is edited in place; one
    // that has not is held in `LiftSessionController.pendingValues` and applied the moment it is
    // recorded. The two are indistinguishable from the row, which is the requirement: being mid-set
    // on one machine is no reason to refuse a correction to another row you are looking at.
    //
    // This used to be a claim rather than a behaviour — the comment here said the value was "held
    // until the set is recorded" while `write` silently dropped it — and a real session found it:
    // "when I type something during an active set to other sets it refreshes to the empty".

    /// A text binding that does not fight the user while they type: reads the draft if there is one,
    /// otherwise the canonical rendering of what is stored.
    ///
    /// A typed comma becomes a point on the way in. iOS's `.decimalPad` labels its separator key
    /// from the DEVICE's region — a German or French phone offers "," and the app cannot relabel it
    /// — so the two would otherwise disagree with the "." this screen displays everywhere else.
    /// Normalising here means the field always reads back in the notation it shows, whichever key
    /// the keyboard happened to offer.
    private func fieldBinding(_ field: FocusTarget,
                              formatted: @escaping () -> String,
                              store: @escaping (String) -> Void) -> Binding<String> {
        Binding(
            get: { draft[field] ?? formatted() },
            set: { typed in
                let text = typed.replacingOccurrences(of: ",", with: ".")
                draft[field] = text
                store(text)
            })
    }

    private func weightBinding(_ slot: LiftSlot) -> Binding<String> {
        fieldBinding(.weight(slot),
                     formatted: { session.enteredValues(for: slot).weightKg.map { display($0) } ?? "" },
                     store: { text in
                         let kg = LiftFormat.number(text).map {
                             LiftFormat.kilograms(fromDisplay: $0, system: unitSystem)
                         }
                         write(slot) { $0.weightKg = kg }
                     })
    }

    private func repsBinding(_ slot: LiftSlot) -> Binding<String> {
        fieldBinding(.reps(slot),
                     formatted: { session.enteredValues(for: slot).reps.map(String.init) ?? "" },
                     store: { text in
                         write(slot) { $0.reps = Int(text.trimmingCharacters(in: .whitespaces)) }
                     })
    }

    private func rpeBinding(_ slot: LiftSlot) -> Binding<String> {
        fieldBinding(.rpe(slot),
                     formatted: { session.enteredValues(for: slot).rpe.map { LiftFormat.trim($0) } ?? "" },
                     store: { text in write(slot) { $0.rpe = LiftFormat.number(text) } })
    }

    /// Apply one field change to a set, leaving its other fields as they were.
    ///
    /// Works whether or not the set has been performed — the controller decides where the value
    /// lands. It reads the CURRENT entered values first, so editing the reps cannot blank a weight
    /// that was typed a moment ago into the same pending row.
    private func write(_ slot: LiftSlot, _ mutate: (inout LiftRecordedSet) -> Void) {
        let entered = session.enteredValues(for: slot)
        var row = LiftRecordedSet(exerciseIndex: slot.exerciseIndex, setIndex: slot.setIndex,
                                  weightKg: entered.weightKg, reps: entered.reps, rpe: entered.rpe,
                                  isWarmup: session.isWarmup(slot), startTs: 0, endTs: 0, restSec: nil)
        mutate(&row)
        session.updateSet(slot, weightKg: row.weightKg, reps: row.reps,
                          rpe: row.rpe, isWarmup: row.isWarmup)
    }

    // MARK: - The control bar

    private func controlBar(_ engine: LiftSessionEngine) -> some View {
        VStack(spacing: NoopMetrics.rowSpacing) {
            HStack(spacing: 14) {
                clock(String(localized: "Session"),
                      LiftFormat.duration(max(0, session.now - engine.startTs)),
                      tint: StrandPalette.textPrimary)
                stageClock(engine)
                heartRate()
                Spacer(minLength: 0)
                Button { session.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(engine.canUndo ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .disabled(!engine.canUndo)
                .accessibilityLabel("Undo")
            }

            HStack(spacing: NoopMetrics.rowSpacing) {
                Button { session.advance() } label: {
                    Text(actionLabel(engine)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.noopPrimary)

                Button {
                    unfinishedChoice = nil
                    programChoice = nil
                    setCountChanges = []
                    showingFinish = true
                } label: {
                    Text("Finish")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
            }
        }
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(StrandPalette.textTertiary.opacity(0.15)).frame(height: 0.5)
        }
    }

    /// Live heart rate, beside the clocks that are already pinned above the action button.
    ///
    /// It belongs here and not in the scrolling sheet: this strip is the part that never scrolls
    /// away, and a glance mid-set is the whole use — you are holding a bar, not browsing. Asked for
    /// after a real session.
    ///
    /// Shown even when there is no value, as "—", the same way `LiveView` reports it. A row that
    /// disappears when the strap stops streaming would shift the clocks beside it and leave the user
    /// wondering whether the reading is missing or the feature is; a dash says which.
    ///
    /// This is display only. Nothing here feeds a score — Effort stays HR-derived from what the
    /// strap MEASURED over the session window, computed by the analytics engine, not by this view.
    private func heartRate() -> some View {
        clock(String(localized: "HR"),
              model.bpm.map(String.init) ?? "—",
              tint: model.bpm == nil ? StrandPalette.textTertiary : StrandPalette.metricRose)
    }

    private func clock(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).strandOverline()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func stageClock(_ engine: LiftSessionEngine) -> some View {
        switch engine.stage {
        case .working:
            clock(String(localized: "This set"),
                  LiftFormat.duration(max(0, session.now - engine.stageStartedAt)),
                  tint: StrandPalette.statusPositive)
        case .resting:
            // "Rest period", never "Rest": the catalog's "Rest" key is NOOP's SLEEP metric, so this
            // label rendered as "Erholung" (recovery) in German — the exact collision CLAUDE.md and
            // the handover brief both warn about. Reintroduced by the workout-sheet rewrite.
            clock(String(localized: "Rest period"),
                  LiftFormat.duration(engine.restRemaining(now: session.now) ?? 0),
                  tint: StrandPalette.metricAmber)
        case .warmup, .finished:
            clock(String(localized: "Warm-up"),
                  LiftFormat.duration(max(0, session.now - engine.stageStartedAt)),
                  tint: StrandPalette.textSecondary)
        }
    }

    private func actionLabel(_ engine: LiftSessionEngine) -> LocalizedStringKey {
        switch engine.stage {
        case .warmup:   return "Start first set"
        case .working:  return "Set done"
        case .resting:  return engine.allCompleted ? "All sets done" : "Start next set"
        case .finished: return "Saving…"
        }
    }

    // MARK: - Finish

    private var finishSheet: some View {
        let unfinished = session.unfinishedSlots.count
        let answered = (unfinished == 0 || unfinishedChoice != nil)
            && (setCountChanges.isEmpty || programChoice != nil)
        return ScreenScaffold(title: "Finish session",
                              subtitle: "One number for the whole session, so a leg day can be compared with a run.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Text("How hard was the whole session? (1–10)").strandOverline()
                        TextField("7", text: $sessionRpeText)
                            .textFieldStyle(.plain)
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .numericKeyboard()
                            .focused($focused, equals: .sessionRpe)
                        Text("This is session RPE. Multiplied by the session's length it gives session load — the one figure that compares across completely different training.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if unfinished > 0 { unfinishedCard(count: unfinished) }
                if !setCountChanges.isEmpty { programCard }

                HStack {
                    Button("Skip") { Task { await save() } }
                        .buttonStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .disabled(saving || !answered)
                    Spacer()
                    Button("Save session") { Task { await save() } }
                        .buttonStyle(.noopPrimary)
                        .frame(maxWidth: 180)
                        .disabled(saving || !answered)
                        .opacity(saving || !answered ? NoopButtonMetrics.disabledOpacity : 1)
                }
                if !answered {
                    Text("Choose an option above to save.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                // A way OUT that records nothing. Until this existed, every route off this screen
                // saved: "Skip" skips the RPE question, not the session. A session started by a
                // mis-tap, or to try something out, had to be saved and then lived in the history
                // and in that day's Effort for good.
                Button(role: .destructive) {
                    confirmingDiscard = true
                } label: {
                    Label("Discard session", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
                .padding(.top, 4)
                .disabled(saving)
                .confirmationDialog("Discard this session?",
                                    isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) {
                        session.discard()
                        showingFinish = false
                    }
                    Button("Keep going", role: .cancel) { }
                } message: {
                    Text("\(engine?.completedWorkingSets ?? 0) recorded sets will be thrown away. Nothing is saved and no workout is created.")
                }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 460, height: 420)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .task { await loadSetCountChanges() }
    }

    /// Sets nobody typed a number into. One choice covers all of them, because what matters at the end
    /// of a session is simply whether they happened: complete them with the numbers the sheet showed,
    /// or leave them out.
    private func unfinishedCard(count: Int) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Unfinished sets").strandOverline()
                Text("\(count) sets have no numbers typed in — sets you did not start, or finished without typing.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Unfinished sets", selection: $unfinishedChoice) {
                    Text("Complete them").tag(UnfinishedChoice?.some(.complete))
                    Text("Discard them").tag(UnfinishedChoice?.some(.discard))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Completing saves them with the grey numbers shown. Discarding leaves them out of the session.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Set counts changed with ⊕/⊖ during the session. The program keeps them only if asked to.
    private var programCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Program").strandOverline()
                Text("You changed the number of sets. Keep the new counts in the program for next time?")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(setCountChanges, id: \.itemId) { change in
                    Text("\(change.exercise): \(change.from) → \(change.to) sets")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Picker("Program", selection: $programChoice) {
                    Text("Update program").tag(ProgramChoice?.some(.update))
                    Text("Keep as it was").tag(ProgramChoice?.some(.keep))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Loading and saving

    /// What was lifted for each of this session's exercises LAST time, by set number — the middle
    /// layer of the grey numbers, handed to the controller that owns the chain.
    private func loadLastTime() async {
        guard let engine, let store = await repo.storeHandle() else { return }
        var out: [String: [Int: LiftSetCarry]] = [:]
        // One query per DISTINCT exercise, not per plan line. A program that programs the same
        // movement twice — or an imported one with many lines — would otherwise re-ask the store the
        // same question, and this runs when the sheet opens.
        for exercise in NSOrderedSet(array: engine.plan.map(\.exercise)).compactMap({ $0 as? String }) {
            let rows = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                      exercise: exercise,
                                                      before: engine.startTs)) ?? []
            var bySet: [Int: LiftSetCarry] = [:]
            for r in rows where !r.isWarmup {
                bySet[r.setIndex] = LiftSetCarry(weightKg: r.weightKg, reps: r.reps)
            }
            out[exercise] = bySet
        }
        session.setLastSession(out)
    }

    private func save() async {
        guard !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        session.finish()
        guard let engine = session.engine else { return }
        let endTs = Int(Date().timeIntervalSince1970)
        let sessionId = UUID().uuidString
        // After `finish`, which closes out the running rest: that set's measured rest belongs to it.
        let finished = session.setsToSave(completingUnfinished: unfinishedChoice == .complete)

        // Nothing to file, so file nothing. Discarding can empty a session completely: a session run
        // face-down and advanced entirely on the strap has nothing typed, so every slot is unentered
        // and "Discard them" leaves no set behind. Filing it anyway wrote a session row with no sets
        // AND a manual workout, and the engine fills that workout's strain from the heart rate the
        // strap measured — so an hour that recorded nothing still read back as a workout. The
        // program's set counts are a separate thing the user chose explicitly, so those still apply.
        guard !finished.isEmpty else {
            if programChoice == .update {
                await writeSetCountsToProgram(store: store, plan: engine.plan)
            }
            await finishAndDismiss()
            return
        }

        let row = LiftSessionRow(
            id: sessionId, deviceId: repo.deviceId,
            startTs: engine.startTs, endTs: endTs, sport: LiftSessionView.sport,
            programId: session.programId,
            // Snapshot the name: renaming or deleting the program never rewrites this session.
            programName: session.programName,
            sessionRpe: LiftFormat.number(sessionRpeText),
            note: session.programName)
        _ = try? await store.upsertLiftSessions([row])

        // `ord` is COMPLETION order, which with out-of-order work is not the plan's order — and it
        // is the order that actually happened, which is what a session should read back as. Sets
        // completed at finish without being started come last.
        let rows = finished.enumerated().map { ord, s -> LiftSetRow in
            let item = engine.planItem(for: s.slot)
            return LiftSetRow(
                id: UUID().uuidString, deviceId: repo.deviceId, sessionId: sessionId,
                ord: ord, exercise: item?.exercise ?? "",
                // Snapshot the classification AS IT WAS, so reclassifying later never rewrites what
                // past weeks were counted as.
                primaryMuscle: item?.primaryMuscle,
                secondaryMuscles: item?.secondaryMuscles ?? [],
                setIndex: s.slot.setIndex, weightKg: s.weightKg, reps: s.reps, rpe: s.rpe,
                isWarmup: s.isWarmup, startTs: s.startTs, endTs: s.endTs,
                restSec: s.restSec, note: nil)
        }
        _ = try? await store.upsertLiftSets(rows)
        if programChoice == .update {
            await writeSetCountsToProgram(store: store, plan: engine.plan)
        }

        // Through the SAME path a manual workout takes, so it inherits overlap dedup, the engine's
        // HR-derived strain fill and delete/merge. `strain` stays nil deliberately: the engine fills
        // it from the heart rate the strap MEASURED, never from typed sets and reps.
        let workout = WorkoutRow(
            startTs: engine.startTs, endTs: endTs, sport: LiftSessionView.sport,
            source: "manual", durationS: Double(max(0, endTs - engine.startTs)),
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: session.programName, steps: nil)
        await repo.saveManualWorkout(workout)

        await finishAndDismiss()
    }

    /// Close the session down and leave the sheet. Shared by the normal save and the nothing-to-file
    /// path above, so the two cannot drift about what ending a session means.
    private func finishAndDismiss() async {
        session.finishedSaving()
        await repo.refresh()
        await onFinished()
        showingFinish = false
        dismiss()
    }

    /// The program lines whose set count this session changed, for the finish sheet to ask about.
    private func loadSetCountChanges() async {
        guard let programId = session.programId, let plan = session.engine?.plan,
              let store = await repo.storeHandle(),
              let rows = try? await store.liftProgramItems(programId: programId) else { return }
        setCountChanges = LiftSessionController.setCountChanges(plan: plan, program: rows)
    }

    /// Save this session's set counts onto its program — only when the user chose to.
    ///
    /// Re-reads the lines and moves only `targetSets`, so a program edited elsewhere while the session
    /// ran keeps every other change and a line deleted since is not resurrected. The store call
    /// replaces the lines wholesale, so nothing is written when no count differs.
    private func writeSetCountsToProgram(store: WhoopStore, plan: [LiftPlanItem]) async {
        guard let programId = session.programId,
              let rows = try? await store.liftProgramItems(programId: programId) else { return }
        let changes = LiftSessionController.setCountChanges(plan: plan, program: rows)
        guard !changes.isEmpty else { return }
        _ = try? await store.replaceLiftProgramItems(
            programId: programId, items: LiftSessionController.applying(changes, to: rows))
    }

    /// The sport every logged session is filed under — the same token the Hevy/Liftosaur importer
    /// uses, so a typed session and an imported one land in one bucket with one icon.
    static let sport = "Strength Training"
}
