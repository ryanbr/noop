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
    @State private var sessionRpeText = ""
    @State private var saving = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @FocusState private var focused: FocusTarget?
    private enum FocusTarget: Hashable {
        case weight(LiftSlot), reps(LiftSlot), rpe(LiftSlot), sessionRpe
    }

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
        .task { await loadLastTime() }
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
            VStack(alignment: .leading, spacing: 10) {
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
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StrandPalette.metricAmber.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                columnHeadings

                ForEach(engine.slots(forExercise: index), id: \.self) { slot in
                    setRow(engine, slot: slot, item: item)
                }
            }
        }
        .id(index)
    }

    private var columnHeadings: some View {
        HStack(spacing: 8) {
            Text("Set").strandOverline().frame(width: 26, alignment: .leading)
            Text(weightHeading).strandOverline().frame(maxWidth: .infinity, alignment: .leading)
            Text("Reps").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
            Text("RPE").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 30)
        }
    }

    private var weightHeading: LocalizedStringKey {
        unitSystem == .imperial ? "Lb" : "Kg"
    }

    // MARK: - One set row

    private func setRow(_ engine: LiftSessionEngine, slot: LiftSlot, item: LiftPlanItem) -> some View {
        let recorded = engine.recordedSet(for: slot)
        let isWorking = engine.stage == .working(slot)
        let isResting: Bool = {
            if case .resting(let s, _) = engine.stage { return s == slot }
            return false
        }()

        return HStack(spacing: 8) {
            Text("\(slot.setIndex)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(isWorking ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(width: 26, alignment: .leading)

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
            .frame(width: 30)
            .accessibilityLabel(recorded == nil
                                ? String(localized: "Start this set")
                                : String(localized: "Redo this set"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(rowBackground(isWorking: isWorking, isResting: isResting, done: recorded != nil),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Green = working now, amber = the rest that follows it, faint = done, clear = still to come.
    private func rowBackground(isWorking: Bool, isResting: Bool, done: Bool) -> Color {
        if isWorking { return StrandPalette.statusPositive.opacity(0.20) }
        if isResting { return StrandPalette.metricAmber.opacity(0.20) }
        if done { return StrandPalette.surfaceRaised.opacity(0.5) }
        return .clear
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
    // number last session, then the program's target. It stays a placeholder — grey, and not
    // recorded unless the user types — because a number nobody entered must never become data.

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
    // disk immediately. Typing into a set that has not been completed yet is allowed — you may want
    // to plan the next one — and is held until the set is recorded.

    private func weightBinding(_ slot: LiftSlot) -> Binding<String> {
        Binding(
            get: {
                guard let kg = engine?.recordedSet(for: slot)?.weightKg else { return "" }
                return display(kg)
            },
            set: { new in
                let kg = LiftFormat.number(new).map {
                    LiftFormat.kilograms(fromDisplay: $0, system: unitSystem)
                }
                write(slot) { $0.weightKg = kg }
            })
    }

    private func repsBinding(_ slot: LiftSlot) -> Binding<String> {
        Binding(
            get: { engine?.recordedSet(for: slot)?.reps.map(String.init) ?? "" },
            set: { new in write(slot) { $0.reps = Int(new.trimmingCharacters(in: .whitespaces)) } })
    }

    private func rpeBinding(_ slot: LiftSlot) -> Binding<String> {
        Binding(
            get: { engine?.recordedSet(for: slot)?.rpe.map { LiftFormat.trim($0) } ?? "" },
            set: { new in write(slot) { $0.rpe = LiftFormat.number(new) } })
    }

    /// Apply one field change to a recorded set, leaving the others as they were.
    private func write(_ slot: LiftSlot, _ mutate: (inout LiftRecordedSet) -> Void) {
        guard var row = engine?.recordedSet(for: slot) else { return }
        mutate(&row)
        session.updateSet(slot, weightKg: row.weightKg, reps: row.reps,
                          rpe: row.rpe, isWarmup: row.isWarmup)
    }

    // MARK: - The control bar

    private func controlBar(_ engine: LiftSessionEngine) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                clock(String(localized: "Session"),
                      LiftFormat.duration(max(0, session.now - engine.startTs)),
                      tint: StrandPalette.textPrimary)
                stageClock(engine)
                Spacer(minLength: 0)
                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(engine.canUndo ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .disabled(!engine.canUndo)
                .accessibilityLabel("Undo")
            }

            HStack(spacing: 10) {
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

    private func clock(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).strandOverline()
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
            clock(String(localized: "Rest"),
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
                    VStack(alignment: .leading, spacing: 12) {
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
        for item in engine.plan {
            let rows = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                      exercise: item.exercise,
                                                      before: engine.startTs)) ?? []
            var bySet: [Int: LiftRecordedSet] = [:]
            for r in rows where !r.isWarmup {
                bySet[r.setIndex] = LiftRecordedSet(
                    exerciseIndex: 0, setIndex: r.setIndex, weightKg: r.weightKg, reps: r.reps,
                    rpe: r.rpe, isWarmup: r.isWarmup, startTs: r.startTs ?? 0,
                    endTs: r.endTs ?? 0, restSec: r.restSec)
            }
            out[item.exercise] = bySet
        }
        lastTime = out
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
