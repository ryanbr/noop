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
//   done    a completed set, with a check and the numbers you entered
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

    /// What the user did for each exercise LAST session — the fallback ghost values, loaded once.
    @State private var lastTime: [String: [Int: LiftRecordedSet]] = [:]
    @State private var showingFinish = false
    @State private var confirmingDiscard = false
    @State private var sessionRpeText = ""
    @State private var saving = false

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
                    setRow(engine, slot: slot, item: item)
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
    /// **Both buttons also rewrite the program**, which is the point rather than a side effect — a
    /// program is a plan for NEXT time, and the sets you actually chose are the better plan. The
    /// running session is unaffected either way; the write-back only changes what the program offers
    /// when it is started again.
    private func setCountRow(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem) -> some View {
        let canAdd = item.targetSets < LiftSessionEngine.maxSetsPerExercise
        let canRemove = engine.canRemoveSet(fromExercise: index)

        return HStack(spacing: 8) {
            Button {
                changeSetCount { session.addSet(toExercise: index) }
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
                changeSetCount { session.removeSet(fromExercise: index) }
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

    /// Run a change to the set count, then make the program match.
    ///
    /// One funnel for every path that can move a count — the two buttons and the undo — so the
    /// program cannot be left behind by a route someone forgot about.
    private func changeSetCount(_ change: () -> Bool) {
        guard change() else { return }
        Task { await writeSetCountsToProgram() }
    }

    /// Write the session's set counts back onto the program behind it.
    ///
    /// Re-reads the lines first and edits only `targetSets`, so a program edited elsewhere while the
    /// session runs keeps every other change, and a line that has since been deleted is skipped
    /// rather than resurrected. Writes nothing at all when no count actually differs — the store
    /// call replaces the program's lines wholesale, and that is not something to do on every tap.
    private func writeSetCountsToProgram() async {
        guard let programId = session.programId, let plan = session.engine?.plan,
              let store = await repo.storeHandle() else { return }
        var wanted: [String: Int] = [:]
        for line in plan {
            if let id = line.programItemId { wanted[id] = line.targetSets }
        }
        guard !wanted.isEmpty,
              let rows = try? await store.liftProgramItems(programId: programId) else { return }

        var changed = false
        let rewritten = rows.map { row -> LiftProgramItemRow in
            guard let sets = wanted[row.id], row.targetSets != sets else { return row }
            var edited = row
            edited.targetSets = sets
            changed = true
            return edited
        }
        guard changed else { return }
        _ = try? await store.replaceLiftProgramItems(programId: programId, items: rewritten)
    }

    /// Width of the set-number column, shared by the heading and every row so the number sits
    /// directly under its label.
    ///
    /// 34, not 26. `strandOverline` renders ALL-CAPS with +1.4 tracking, and at 26 the heading wrapped
    /// mid-word — a real session photographed it reading "SE / T" over two lines. The headings are
    /// also `lineLimit(1)` with a scale floor: this row is four short labels across a phone width in
    /// ten languages, and a wrapped heading breaks the column alignment for every row beneath it.
    private static let setColumnWidth: CGFloat = 34

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

    private func setRow(_ engine: LiftSessionEngine, slot: LiftSlot, item: LiftPlanItem) -> some View {
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
                        ghost: ghostWeight(engine, slot: slot, item: item))
            numberField(slot: slot, field: .reps(slot),
                        text: repsBinding(slot),
                        ghost: ghostReps(engine, slot: slot, item: item))
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
    // The placeholder shows what you'd most likely repeat, in priority order: the PREVIOUS SET OF
    // THIS EXERCISE IN THIS SESSION first (set 2 almost always mirrors set 1), then the same set
    // number last session, then the program's target — the same order, from the same source, as
    // `LiftSessionEngine.carry(for:lastSession:)`.
    //
    // These are shown only for a set that has NOT been completed yet: a plan, not a record. Once the
    // set is completed the carried numbers become a real entry and the binding below returns them,
    // so the row shows what was actually logged rather than a grey suggestion of it. Keep the two
    // chains in step — a ghost that does not match what completing the set records is worse than no
    // ghost at all.

    private func ghostWeight(_ engine: LiftSessionEngine, slot: LiftSlot, item: LiftPlanItem) -> String {
        if let prev = engine.previousSetInSession(for: slot)?.weightKg { return display(prev) }
        if let last = lastTime[item.exercise]?[slot.setIndex]?.weightKg { return display(last) }
        if let target = item.targetWeightKg { return display(target) }
        return "—"
    }

    private func ghostReps(_ engine: LiftSessionEngine, slot: LiftSlot, item: LiftPlanItem) -> String {
        if let prev = engine.previousSetInSession(for: slot)?.reps { return String(prev) }
        if let last = lastTime[item.exercise]?[slot.setIndex]?.reps { return String(last) }
        if let target = item.targetRepsLow { return String(target) }
        return "—"
    }

    private func ghostRpe(_ engine: LiftSessionEngine, slot: LiftSlot) -> String {
        if let prev = engine.previousSetInSession(for: slot)?.rpe { return LiftFormat.trim(prev) }
        return "—"
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
                Button {
                    // Through the funnel: undo restores the plan as well as the sets, so taking back
                    // an added set has to take it back off the program too.
                    changeSetCount { session.undo(); return true }
                } label: {
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

                Button { showingFinish = true } label: {
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
        ScreenScaffold(title: "Finish session",
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
                HStack {
                    Button("Skip") { Task { await save() } }
                        .buttonStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Save session") { Task { await save() } }
                        .buttonStyle(.noopPrimary)
                        .frame(maxWidth: 180)
                        .disabled(saving)
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
    }

    // MARK: - Loading and saving

    /// What was lifted for each of this session's exercises LAST time, indexed by set number.
    private func loadLastTime() async {
        guard let engine, let store = await repo.storeHandle() else { return }
        var out: [String: [Int: LiftRecordedSet]] = [:]
        // One query per DISTINCT exercise, not per plan line. A program that programs the same
        // movement twice — or an imported one with many lines — would otherwise re-ask the store the
        // same question, and this runs when the sheet opens.
        for exercise in NSOrderedSet(array: engine.plan.map(\.exercise)).compactMap({ $0 as? String }) {
            let rows = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                      exercise: exercise,
                                                      before: engine.startTs)) ?? []
            var bySet: [Int: LiftRecordedSet] = [:]
            for r in rows where !r.isWarmup {
                bySet[r.setIndex] = LiftRecordedSet(
                    exerciseIndex: 0, setIndex: r.setIndex, weightKg: r.weightKg, reps: r.reps,
                    rpe: r.rpe, isWarmup: r.isWarmup, startTs: r.startTs ?? 0,
                    endTs: r.endTs ?? 0, restSec: r.restSec)
            }
            out[exercise] = bySet
        }
        lastTime = out
        // The controller needs this too: the strap can complete a set while this sheet is minimised,
        // and a set recorded that way must carry the same numbers the sheet was showing.
        session.setLastSession(out.mapValues { bySet in
            bySet.mapValues { LiftSetCarry(weightKg: $0.weightKg, reps: $0.reps) }
        })
    }

    private func save() async {
        guard !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        session.finish()
        guard let engine = session.engine else { return }
        let endTs = Int(Date().timeIntervalSince1970)
        let sessionId = UUID().uuidString

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
        // is the order that actually happened, which is what a session should read back as.
        let rows = engine.sets.enumerated().map { ord, s -> LiftSetRow in
            let item = engine.planItem(for: s.slot)
            return LiftSetRow(
                id: UUID().uuidString, deviceId: repo.deviceId, sessionId: sessionId,
                ord: ord, exercise: item?.exercise ?? "",
                // Snapshot the classification AS IT WAS, so reclassifying later never rewrites what
                // past weeks were counted as.
                primaryMuscle: item?.primaryMuscle,
                secondaryMuscles: item?.secondaryMuscles ?? [],
                setIndex: s.setIndex, weightKg: s.weightKg, reps: s.reps, rpe: s.rpe,
                isWarmup: s.isWarmup, startTs: s.startTs, endTs: s.endTs,
                restSec: s.restSec, note: nil)
        }
        _ = try? await store.upsertLiftSets(rows)

        // Through the SAME path a manual workout takes, so it inherits overlap dedup, the engine's
        // HR-derived strain fill and delete/merge. `strain` stays nil deliberately: the engine fills
        // it from the heart rate the strap MEASURED, never from typed sets and reps.
        let workout = WorkoutRow(
            startTs: engine.startTs, endTs: endTs, sport: LiftSessionView.sport,
            source: "manual", durationS: Double(max(0, endTs - engine.startTs)),
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: session.programName, steps: nil)
        await repo.saveManualWorkout(workout)

        session.finishedSaving()
        await repo.refresh()
        await onFinished()
        showingFinish = false
        dismiss()
    }

    /// The sport every logged session is filed under — the same token the Hevy/Liftosaur importer
    /// uses, so a typed session and an imported one land in one bucket with one icon.
    static let sport = "Strength Training"
}
