import SwiftUI
import StrandDesign
import WhoopStore

// Running a session: the screen you actually use at the rack.
//
// EXACTLY TWO WAYS TO ADVANCE, both deliberate:
//   1. A double-tap on the WHOOP strap — the one that works with the phone face-down on a bench.
//   2. The explicit button.
// An earlier build also advanced on a tap ANYWHERE on screen. First real session killed that: it
// fires while you scroll, while you type a weight, while you just hold the phone — and a stray
// advance costs a logged set. Do not reintroduce it.
//
// WHAT YOU LIFTED IS ENTERED DURING THE REST, not during the set. You cannot type a weight with the
// bar in your hands. The set is recorded the instant it ends (timing and all); the numbers are
// filled in while you recover, and the final set — which no rest follows — is filled in during the
// cool-down.
//
// Two buzz patterns, deliberately distinguishable on a wrist that has been knocked about all
// session: ONE pulse confirms a strap double-tap registered; THREE means the rest is nearly up.
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
                // The entry card belongs to the REST, not the set. You cannot type a weight with the
                // bar in your hands; you can while you recover. The final set has no rest after it,
                // so the cool-down is its entry window.
                if engine.setAwaitingEntry != nil { entryCard }
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
        // DELIBERATELY NOT tap-anywhere. An earlier build advanced the session on a tap anywhere on
        // screen; in real use that fires while you are scrolling, typing a weight or just holding the
        // phone, and a stray advance costs a logged set. The session now moves on exactly two
        // deliberate inputs: the button below, or a double-tap on the strap.
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
            model.strapDoubleTapOverride = { advance(fromStrap: true) }
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
        case .working:  return "Press the button, or double-tap your strap, when the set is done."
        case .resting:  return "Enter the set you just did, then start the next one."
        case .cooldown: return "Enter your last set, then finish and save."
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
                Text(entryHeading)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
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
                Text("Pre-filled with your target, or what you did last time. Correct it to what you actually lifted.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Every keystroke goes straight into the engine and to disk, so the numbers survive a crash
        // mid-rest exactly like the rest of the session does.
        // The two-argument closure form deliberately: the zero-argument `onChange(of:)` is
        // macOS 14+, and NOOP still targets macOS 13. iOS compiled it happily — only the Mac build
        // catches this, which is why both targets are built for every change.
        .onChange(of: weightText) { _ in commitEntry() }
        .onChange(of: repsText) { _ in commitEntry() }
        .onChange(of: rpeText) { _ in commitEntry() }
        .onChange(of: isWarmup) { _ in commitEntry() }
    }

    /// Names the set being filled in, so it is never ambiguous which one the numbers belong to.
    private var entryHeading: String {
        guard let s = engine.setAwaitingEntry else { return "" }
        let name = engine.plan.indices.contains(s.exerciseIndex)
            ? engine.plan[s.exerciseIndex].exercise : ""
        return String(localized: "What you just did — \(name), set \(s.setIndex)")
    }

    /// Push the typed values into the engine and persist. Editing, never appending: the set already
    /// exists (it was recorded the moment it ended), so typing can't create a phantom.
    private func commitEntry() {
        engine.updateLastSet(weightKg: enteredWeightKg,
                             reps: Int(repsText.trimmingCharacters(in: .whitespaces)),
                             rpe: LiftFormat.number(rpeText),
                             isWarmup: isWarmup)
        persist()
    }

    // MARK: - Progress + controls

    private var progressCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    stat(String(localized: "Sets"),
                         "\(engine.completedWorkingSets)/\(engine.plannedWorkingSets)")
                    stat(String(localized: "Session"),
                         LiftFormat.duration(max(0, now - engine.startTs)))
                    stat(String(localized: "Volume"), LiftFormat.weight(volumeKg, system: unitSystem))
                }
                // TWO clocks, deliberately. The session total above answers "how long have I been
                // here"; this one answers "how long has THIS set/rest been running", which is the
                // number you actually act on between sets.
                HStack(spacing: 8) {
                    Image(systemName: stageClockSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text(stageClockLabel)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The current stage's own elapsed clock — how long this set has been under way, or how long
    /// you have been resting (which keeps counting past zero, because an overrun rest is worth
    /// seeing rather than hiding).
    private var stageClockLabel: String {
        let elapsed = max(0, now - engine.stageStartedAt)
        switch engine.stage {
        case .working:  return String(localized: "This set \(LiftFormat.duration(elapsed))")
        case .resting:  return String(localized: "Resting \(LiftFormat.duration(elapsed))")
        case .warmup:   return String(localized: "Warming up \(LiftFormat.duration(elapsed))")
        case .cooldown: return String(localized: "Cooling down \(LiftFormat.duration(elapsed))")
        case .finished: return ""
        }
    }

    private var stageClockSymbol: String {
        switch engine.stage {
        case .working:  return "figure.strengthtraining.traditional"
        case .resting:  return "hourglass"
        default:        return "clock"
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

    /// The one action. `fromStrap` is true when a WHOOP double-tap drove it, which earns a single
    /// confirming buzz — with the phone face-down you otherwise have no way to know it registered.
    /// A button press needs no such confirmation: you watched it happen.
    private func advance(fromStrap: Bool = false) {
        // Anything typed during the rest is already in the engine via `commitEntry`, but commit once
        // more here so a value still being typed as the user advances is not lost.
        if engine.setAwaitingEntry != nil { commitEntry() }

        if case .cooldown = engine.stage {
            showingFinish = true
            return
        }

        if fromStrap, live.bonded {
            model.buzz(loops: LiftSessionView.advanceConfirmBuzzes, gate: HapticPrefs.liftRest)
        }

        engine.advance(now: Int(Date().timeIntervalSince1970))

        buzzedFor = nil
        cue(for: engine.stage)
        persist()

        // Entering a rest: seed the boxes for the set just finished, so the common case is a glance
        // and a tap rather than typing three numbers.
        if engine.setAwaitingEntry != nil {
            Task { await seedEntryFields() }
        }
    }

    /// The strap buzz five seconds before the rest ends — the cue that reaches you with the phone
    /// face-down. Fires once per rest period, and only while a strap is actually bonded.
    ///
    /// THREE buzzes, deliberately distinct from the single confirmation buzz an advance gives. On a
    /// wrist that has been knocked around a gym all session, "did it just buzz?" is a real question,
    /// and two cues that feel identical answer it badly — one pulse means "I heard you", three means
    /// "your rest is nearly up".
    private func fireRestCueIfDue() {
        guard case .resting(_, _, let endsAt) = engine.stage else { return }
        guard buzzedFor != endsAt else { return }
        let remaining = endsAt - now
        guard remaining <= 5 else { return }
        buzzedFor = endsAt
        if live.bonded {
            model.buzz(loops: LiftSessionView.restWarningBuzzes, gate: HapticPrefs.liftRest)
        }
        cue(.ready)
    }

    /// Rest is nearly over: three pulses.
    static let restWarningBuzzes: UInt8 = 3
    /// A strap double-tap registered: one pulse, so the gesture is confirmed without ambiguity.
    static let advanceConfirmBuzzes: UInt8 = 1

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

    /// Seed the entry boxes for the set just performed.
    ///
    /// Two sources, in order: what you actually lifted for this exercise LAST TIME (the read the
    /// whole feature exists for, and the reason sets are stored as rows rather than a blob), falling
    /// back to the weight and reps the program PLANNED. Last time beats the plan because the plan is
    /// an intention and last time is evidence.
    private func seedEntryFields() async {
        guard let awaiting = engine.setAwaitingEntry,
              engine.plan.indices.contains(awaiting.exerciseIndex) else { return }
        let item = engine.plan[awaiting.exerciseIndex]
        isWarmup = awaiting.isWarmup

        var seededWeight: Double? = item.targetWeightKg
        var seededReps: Int? = item.targetRepsLow
        var seededRpe: Double?

        if let store = await repo.storeHandle() {
            let previous = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                          exercise: item.exercise,
                                                          before: engine.startTs)) ?? []
            if let match = previous.first(where: { $0.setIndex == awaiting.setIndex && !$0.isWarmup })
                ?? previous.last {
                seededWeight = match.weightKg ?? seededWeight
                seededReps = match.reps ?? seededReps
                seededRpe = match.rpe
            }
        }

        weightText = seededWeight.map {
            LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: unitSystem))
        } ?? ""
        repsText = seededReps.map(String.init) ?? ""
        rpeText = seededRpe.map { LiftFormat.trim($0) } ?? ""
        commitEntry()
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
            // A NUMBER, so session load (sRPE x duration) is computable rather than buried in prose.
            sessionRpe: LiftFormat.number(sessionRpeText),
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

    /// The workout row's human-readable note. The session RPE is NOT repeated here — it has its own
    /// column now, and duplicating it invites the two spellings to disagree.
    private var sessionNote: String? {
        guard let programName, !programName.isEmpty else { return nil }
        return programName
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
