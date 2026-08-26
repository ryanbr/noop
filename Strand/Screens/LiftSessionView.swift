import SwiftUI
import StrandDesign
import WhoopStore

// Running a session: the screen you actually use at the rack.
//
// THREE WAYS TO ADVANCE, all doing exactly the same thing:
//   1. A double-tap on the WHOOP strap — the one that works with the phone face-down on a bench.
//   2. Tapping anywhere on the screen.
//   3. The explicit button.
// Both (2) and (3) were asked for by name; shipping only one of them is not the same feature. They
// are ordinary single taps — the double-tap is the STRAP gesture only, because a strap takes knocks
// against bars all session while a phone screen in your hand does not.
//
// The countdown is read from `LiftSessionEngine`, which anchors rest to an absolute instant, so a
// phone that sleeps through a rest still shows the truth when it wakes. Nothing auto-advances: when
// the rest hits zero the screen says so and waits.

struct LiftSessionView: View {
    let programId: String?
    let programName: String?
    /// Called once the session has been written, so the hub can reload.
    let onFinished: () async -> Void

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State var engine: LiftSessionEngine

    /// What the user is entering for the set in progress. Pre-filled from last time.
    @State private var weightText = ""
    @State private var repsText = ""
    @State private var rpeText = ""
    @State private var isWarmup = false

    /// Drives the countdown redraw and the 5-second cue. One second is plenty: the timer is read
    /// from the clock, so the tick only decides how often the label is refreshed.
    @State private var now = Int(Date().timeIntervalSince1970)
    /// The rest period the 5-second cue has already fired for, so it fires once per rest and not
    /// once per tick.
    @State private var buzzedFor: Int?

    @State private var saving = false
    @State private var showingFinish = false
    @State private var sessionRpeText = ""

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// Transition cues, mirrored to the phone's Taptic Engine on iOS.
    private enum Cue { case next, rest, ready, done }
    #if os(iOS)
    @State private var lastCue: Cue = .next
    @State private var cueTick = 0
    #endif

    @FocusState private var focused: Field?
    private enum Field: Hashable { case weight, reps, rpe, sessionRpe }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(plan: [LiftPlanItem], programId: String?, programName: String?,
         onFinished: @escaping () async -> Void) {
        self.programId = programId
        self.programName = programName
        self.onFinished = onFinished
        _engine = State(initialValue: LiftSessionEngine(plan: plan,
                                                        startTs: Int(Date().timeIntervalSince1970)))
    }

    /// Resume an interrupted session.
    init(resuming snapshot: LiftSessionPersistence.Snapshot, onFinished: @escaping () async -> Void) {
        self.programId = snapshot.programId
        self.programName = snapshot.programName
        self.onFinished = onFinished
        _engine = State(initialValue: LiftSessionPersistence.engine(from: snapshot))
    }

    var body: some View {
        ScreenScaffold(title: sessionTitle, subtitle: sessionSubtitle) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                stageCard
                if case .working = engine.stage { entryCard }
                progressCard
                controls
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 760)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        // The whole screen advances the session. `.contentShape` so the empty space between cards
        // counts too — at the rack you should not have to aim.
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        #if os(iOS)
        .sensoryFeedback(trigger: cueTick) { _, _ in
            switch lastCue {
            case .next:  return .impact(weight: .heavy)
            case .rest:  return .impact(weight: .light)
            case .ready: return .success
            case .done:  return .success
            }
        }
        #endif
        .onReceive(tick) { instant in
            now = Int(instant.timeIntervalSince1970)
            fireRestCueIfDue()
        }
        .task {
            // Claim the strap's double-tap for as long as this session is on screen.
            model.strapDoubleTapOverride = { advance() }
            await prefillFromLastTime()
            persist()
        }
        .onDisappear {
            model.strapDoubleTapOverride = nil
        }
        .sheet(isPresented: $showingFinish) { finishSheet }
    }

    // MARK: - Header

    private var sessionTitle: LocalizedStringKey {
        switch engine.stage {
        case .warmup:   return "Warm-up"
        case .working:  return "Working"
        // NOT the bare "Rest": that key already exists in the catalog as NOOP's SLEEP metric
        // ("Erholung", "Riposo", "Odpoczynek"). Reusing it would label a rest between sets with the
        // word for overnight recovery in every non-English locale.
        case .resting:  return "Rest period"
        case .cooldown: return "Cool-down"
        case .finished: return "Done"
        }
    }

    private var sessionSubtitle: LocalizedStringKey {
        switch engine.stage {
        case .warmup:   return "Tap when you start your first set."
        case .working:  return "Tap when the set is done."
        case .resting:  return "Tap when you're ready for the next set."
        case .cooldown: return "Tap to finish and save."
        case .finished: return "Saving…"
        }
    }

    // MARK: - The big stage card

    private var stageCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 10) {
                if let item = engine.currentItem {
                    Text(item.exercise)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LiftMuscleSummary.line(primary: item.primaryMuscle,
                                                secondaries: item.secondaryMuscles))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                switch engine.stage {
                case .working(_, let s):
                    Text(setLabel(s))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.effortColor)
                    if let target = targetLine { Text(target).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary) }
                    if let note = engine.currentItem?.note, !note.isEmpty {
                        Text(note).font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .resting:
                    Text(restLabel)
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(restRemaining == 0
                                         ? StrandPalette.statusPositive : StrandPalette.effortColor)
                    Text(restRemaining == 0 ? "Ready when you are" : "Resting")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)

                case .warmup:
                    Text("Warming up")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Everything before your first set counts as the warm-up. Nothing is being recorded yet.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .cooldown, .finished:
                    Text("That's the last set")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Tap to finish. The session is saved as a workout, so it shows up in Workouts and Today like any other.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Set entry

    private var entryCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    field(weightLabel) { numberInput("0", text: $weightText, field: .weight) }
                    field("Reps") { numberInput("0", text: $repsText, field: .reps) }
                    field("RPE") { numberInput("—", text: $rpeText, field: .rpe) }
                }
                Toggle(isOn: $isWarmup) {
                    Text("Warm-up set")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("Pre-filled with what you did last time. Change anything that's different today.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The entry card must NOT swallow taps into the advance gesture while someone is typing a
        // weight, so it takes its own (empty) tap and stops propagation.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Progress + controls

    private var progressCard: some View {
        NoopCard {
            HStack(spacing: 14) {
                stat(String(localized: "Sets"),
                     "\(engine.completedWorkingSets)/\(engine.plannedWorkingSets)")
                stat(String(localized: "Elapsed"), LiftFormat.duration(max(0, now - engine.startTs)))
                stat(String(localized: "Volume"), LiftFormat.weight(volumeKg, system: unitSystem))
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button { advance() } label: {
                Text(buttonLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopPrimary)
            .accessibilityLabel("Next")

            HStack {
                Button {
                    engine.undo()
                    persist()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .disabled(!engine.canUndo)

                Spacer()

                Button(role: .destructive) {
                    LiftSessionPersistence.clear()
                    model.strapDoubleTapOverride = nil
                    dismiss()
                } label: {
                    Text("Discard")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
            }

            Text("Double-tap your strap to log a set without picking the phone up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var buttonLabel: LocalizedStringKey {
        switch engine.stage {
        case .warmup:   return "Start first set"
        case .working:  return "Set done"
        case .resting:  return "Start next set"
        case .cooldown: return "Finish & save"
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
                        field("How hard was the whole session? (1–10)") {
                            numberInput("7", text: $sessionRpeText, field: .sessionRpe)
                        }
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

    // MARK: - Behaviour

    private func advance() {
        let stamp = Int(Date().timeIntervalSince1970)
        let wasWorking: Bool
        if case .working = engine.stage { wasWorking = true } else { wasWorking = false }

        if case .cooldown = engine.stage {
            showingFinish = true
            return
        }

        engine.advance(now: stamp,
                       weightKg: wasWorking ? enteredWeightKg : nil,
                       reps: wasWorking ? Int(repsText.trimmingCharacters(in: .whitespaces)) : nil,
                       rpe: wasWorking ? LiftFormat.number(rpeText) : nil,
                       isWarmup: wasWorking ? isWarmup : false)

        buzzedFor = nil
        isWarmup = false
        cue(for: engine.stage)
        persist()

        if case .working = engine.stage {
            Task { await prefillFromLastTime() }
        }
    }

    /// The strap buzz five seconds before the rest ends — the cue that reaches you with the phone
    /// face-down. Fires once per rest period, and only while a strap is actually bonded.
    private func fireRestCueIfDue() {
        guard case .resting(_, _, let endsAt) = engine.stage else { return }
        guard buzzedFor != endsAt else { return }
        let remaining = endsAt - now
        guard remaining <= 5 else { return }
        buzzedFor = endsAt
        if live.bonded {
            model.buzz(loops: 2, gate: HapticPrefs.liftRest)
        }
        cue(.ready)
    }

    private func cue(for stage: LiftSessionEngine.Stage) {
        switch stage {
        case .working:  cue(.next)
        case .resting:  cue(.rest)
        case .finished: cue(.done)
        default: break
        }
    }

    /// Fire an iPhone haptic alongside the strap buzz, so the transition is felt even with no strap
    /// bonded. Bumping the token re-triggers `.sensoryFeedback` even when the same cue repeats.
    /// A no-op on macOS, which has no Taptic Engine.
    private func cue(_ c: Cue) {
        #if os(iOS)
        lastCue = c
        cueTick &+= 1
        #endif
    }

    private func persist() {
        LiftSessionPersistence.store(
            LiftSessionPersistence.snapshot(engine: engine,
                                            programId: programId,
                                            programName: programName))
    }

    /// Fill the entry boxes with what was actually lifted for this exercise last time — the read the
    /// whole feature exists for, and the reason sets are stored as rows rather than a blob.
    private func prefillFromLastTime() async {
        guard case .working(_, let setNumber) = engine.stage,
              let item = engine.currentItem,
              let store = await repo.storeHandle() else { return }
        let previous = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                      exercise: item.exercise,
                                                      before: engine.startTs)) ?? []
        // Prefer the matching set number from last time, else the last set performed.
        let match = previous.first { $0.setIndex == setNumber && !$0.isWarmup } ?? previous.last
        guard let match else {
            weightText = ""; repsText = ""; rpeText = ""
            return
        }
        weightText = match.weightKg.map {
            LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: unitSystem))
        } ?? ""
        repsText = match.reps.map(String.init) ?? ""
        rpeText = match.rpe.map { LiftFormat.trim($0) } ?? ""
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }

        var finished = engine
        if !finished.isFinished {
            finished.advance(now: Int(Date().timeIntervalSince1970))
        }
        let endTs = Int(Date().timeIntervalSince1970)

        guard let store = await repo.storeHandle() else { return }
        let sessionId = UUID().uuidString

        // The session row, pinned to its workout row by the workout table's own natural key.
        let session = LiftSessionRow(
            id: sessionId, deviceId: repo.deviceId,
            startTs: finished.startTs, endTs: endTs,
            sport: LiftSessionView.sport,
            programId: programId,
            // Snapshot the name: renaming or deleting the program never rewrites this session.
            programName: programName,
            note: sessionNote)
        _ = try? await store.upsertLiftSessions([session])

        let rows = finished.sets.enumerated().map { ord, s -> LiftSetRow in
            let item = finished.plan.indices.contains(s.exerciseIndex)
                ? finished.plan[s.exerciseIndex] : nil
            return LiftSetRow(
                id: UUID().uuidString, deviceId: repo.deviceId, sessionId: sessionId,
                ord: ord, exercise: item?.exercise ?? "",
                // Snapshot the classification AS IT WAS, so reclassifying later never silently
                // rewrites what past weeks were counted as.
                primaryMuscle: item?.primaryMuscle,
                secondaryMuscles: item?.secondaryMuscles ?? [],
                setIndex: s.setIndex, weightKg: s.weightKg, reps: s.reps, rpe: s.rpe,
                isWarmup: s.isWarmup, startTs: s.startTs, endTs: s.endTs,
                restSec: s.restSec, note: nil)
        }
        _ = try? await store.upsertLiftSets(rows)

        // And the workout row itself, through the SAME path a manual workout takes — so it inherits
        // overlap dedup, the engine's HR-derived strain fill (`rescoreManualWorkouts`), and
        // delete/merge. `strain` is left nil deliberately: the engine fills it from the heart rate
        // the strap actually measured over this window. It is never derived from the typed
        // sets/reps/weight, because there is no validated path from those to a strain equivalent.
        let workout = WorkoutRow(
            startTs: finished.startTs, endTs: endTs, sport: LiftSessionView.sport,
            source: "manual", durationS: Double(max(0, endTs - finished.startTs)),
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: sessionNote, steps: nil)
        await repo.saveManualWorkout(workout)

        LiftSessionPersistence.clear()
        model.strapDoubleTapOverride = nil
        await repo.refresh()
        await onFinished()
        showingFinish = false
        dismiss()
    }

    // MARK: - Derived

    /// The sport every logged session is filed under — the same token the Hevy/Liftosaur importer
    /// uses, so a typed session and an imported one land in one bucket with one icon.
    static let sport = "Strength Training"

    private var sessionNote: String? {
        var parts: [String] = []
        if let programName, !programName.isEmpty { parts.append(programName) }
        if let rpe = LiftFormat.number(sessionRpeText) {
            parts.append(String(localized: "session RPE \(LiftFormat.trim(rpe))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var enteredWeightKg: Double? {
        LiftFormat.number(weightText).map {
            LiftFormat.kilograms(fromDisplay: $0, system: unitSystem)
        }
    }

    private var volumeKg: Double? {
        let total = engine.sets.filter { !$0.isWarmup }.reduce(0.0) { sum, s in
            guard let w = s.weightKg, let r = s.reps else { return sum }
            return sum + w * Double(r)
        }
        return total > 0 ? total : nil
    }

    private var restRemaining: Int { engine.restRemaining(now: now) ?? 0 }

    private var restLabel: String { LiftFormat.duration(restRemaining) }

    private func setLabel(_ s: Int) -> String {
        let total = engine.currentItem?.targetSets ?? s
        return String(localized: "Set \(s) of \(total)")
    }

    private var targetLine: String? {
        guard let item = engine.currentItem else { return nil }
        var parts: [String] = []
        if let lo = item.targetRepsLow, let hi = item.targetRepsHigh, lo != hi {
            parts.append("\(lo)–\(hi) reps")
        } else if let lo = item.targetRepsLow {
            parts.append(String(localized: "\(lo) reps"))
        }
        if let rpe = item.targetRpe { parts.append("RPE \(LiftFormat.trim(rpe))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var weightLabel: LocalizedStringKey {
        unitSystem == .imperial ? "Weight (lb)" : "Weight (kg)"
    }

    // MARK: - Field helpers

    private func field<Content: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: LocalizedStringKey,
                             text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: field)
    }
}
