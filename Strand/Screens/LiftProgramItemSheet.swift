import SwiftUI
import StrandDesign
import WhoopStore

// Edit ONE exercise line of a program: which exercise, and the targets for it.
//
// NOOP SHIPS NO EXERCISE CATALOGUE — deliberately. The user types whatever they call the movement
// and it is remembered in `liftExercise` with the muscle group they gave it, then offered back next
// time. A shipped mapping of common exercises to muscles would be both a permanent maintenance
// burden and a correctness claim NOOP has no business making about someone else's technique.
//
// Classification is therefore a one-time, few-second action per exercise: pick the primary muscle
// (a direct set) and any secondaries (indirect, counted at half). It is asked once, on first use,
// and remembered thereafter. Leaving it unset is allowed — an unclassified exercise still counts
// toward volume and session load, it simply claims no muscle it was never assigned.

struct LiftProgramItemSheet: View {
    /// The line being edited, or nil to add a new one.
    let item: LiftProgramItemRow?
    /// Handed the finished line. The parent owns ordering and persistence.
    let onSave: (LiftProgramItemRow) -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var exercise: String = ""
    @State private var primary: LiftMuscle?
    @State private var secondaries: Set<LiftMuscle> = []

    @State private var setsText: String = ""
    @State private var repsText: String = ""
    @State private var weightText: String = ""
    @State private var restText: String = ""
    @State private var note: String = ""

    /// The user's own exercise vocabulary, for suggestions and for adopting a known classification.
    @State private var vocabulary: [LiftExerciseRow] = []
    @State private var loaded = false

    /// The app's existing metric/imperial preference — the Lift Log never adds a second weight unit
    /// setting of its own, so the plan is typed in the same unit the session records in.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var weightLabel: LocalizedStringKey {
        unitSystem == .imperial ? "Weight (lb)" : "Weight (kg)"
    }

    @FocusState private var focused: Field?
    private enum Field: Hashable { case exercise, sets, reps, weight, rest, note }

    private var trimmedExercise: String {
        exercise.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { !trimmedExercise.isEmpty }

    /// Vocabulary entries matching what has been typed so far, minus an exact match (no point
    /// suggesting the thing already in the box). Capped — this is a hint, not a browser.
    private var suggestions: [LiftExerciseRow] {
        let query = trimmedExercise.lowercased()
        guard !query.isEmpty else { return Array(vocabulary.prefix(6)) }
        return vocabulary
            .filter { $0.name.lowercased().contains(query) && $0.name.lowercased() != query }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        ScreenScaffold(
            title: item == nil ? "Add exercise" : "Edit exercise",
            subtitle: "Type any name you like. NOOP remembers it, with the muscles you give it."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                exerciseSection
                muscleSection
                targetsSection
                noteSection
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .task { await loadIfNeeded() }
    }

    // MARK: - Exercise name + suggestions

    private var exerciseSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercise", overline: "Movement")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Incline dumbbell press", text: $exercise)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .focused($focused, equals: .exercise)

                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Used before").strandOverline()
                            ForEach(suggestions, id: \.id) { row in
                                Button {
                                    adopt(row)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.up.left")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(StrandPalette.textTertiary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.name)
                                                .font(StrandFont.body)
                                                .foregroundStyle(StrandPalette.textPrimary)
                                            Text(LiftMuscleSummary.line(primary: row.primaryMuscle,
                                                                        secondaries: row.secondaryMuscles))
                                                .font(StrandFont.caption)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Muscle classification

    private var muscleSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Muscles", overline: "Counted once per exercise")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Primary").strandOverline()
                        Menu {
                            Button("Not classified") { primary = nil }
                            ForEach(LiftMuscle.Region.allCases, id: \.self) { region in
                                Section(region.displayName) {
                                    ForEach(LiftMuscle.inRegion(region), id: \.self) { muscle in
                                        Button(muscle.displayName) { select(primary: muscle) }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(primary?.displayName ?? String(localized: "Not classified"))
                                    .font(StrandFont.body)
                                    .foregroundStyle(primary == nil
                                                     ? StrandPalette.textTertiary
                                                     : StrandPalette.textPrimary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Primary muscle")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Also works (counted as half a set)").strandOverline()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(LiftMuscle.allCases, id: \.self) { muscle in
                                if muscle != primary {
                                    secondaryChip(muscle)
                                }
                            }
                        }
                    }

                    Text("Direct sets count once, indirect sets count as a half. That split is what makes the weekly per-muscle figures mean anything.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func secondaryChip(_ muscle: LiftMuscle) -> some View {
        let on = secondaries.contains(muscle)
        return Button {
            if on { secondaries.remove(muscle) } else { secondaries.insert(muscle) }
        } label: {
            Text(muscle.displayName)
                .font(StrandFont.caption)
                .foregroundStyle(on ? StrandPalette.effortColor : StrandPalette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? StrandPalette.effortColor.opacity(0.14) : StrandPalette.surfaceRaised)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: - Targets

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Targets", overline: "What you're aiming for")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        field("Working sets") {
                            numberInput("4", text: $setsText, field: .sets)
                        }
                        field("Reps") {
                            numberInput("8", text: $repsText, field: .reps)
                        }
                    }
                    HStack(spacing: 12) {
                        field(weightLabel) {
                            numberInput("60", text: $weightText, field: .weight)
                        }
                        field("Rest (seconds)") {
                            numberInput("120", text: $restText, field: .rest)
                        }
                    }
                    // No target RPE here on purpose. RPE is how hard a set FELT, which you can only
                    // know once you have done it — planning one means guessing at your own effort in
                    // advance and then reading the guess back as if it were data. It is recorded per
                    // set during the session instead.
                    Text("Every target is optional — this is the plan, not the record. What you actually lift is entered set by set during the session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Technique note", overline: "In your words")
            NoopCard {
                TextField("Slow eccentric, pause at the bottom", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1...4)
                    .focused($focused, equals: .note)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Save") { Task { await save() } }
                .buttonStyle(.noopPrimary)
                .frame(maxWidth: 160)
                .disabled(!canSave)
                .accessibilityLabel("Save exercise")
        }
    }

    // MARK: - Field helpers (the house form idiom)

    private func field<Content: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: LocalizedStringKey,
                             text: Binding<String>,
                             field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: field)
    }

    // MARK: - Behaviour

    /// Take a known exercise from the vocabulary, including the classification it already carries —
    /// so a movement is classified once and never asked about again.
    private func adopt(_ row: LiftExerciseRow) {
        exercise = row.name
        primary = row.primaryMuscle
        secondaries = Set(row.secondaryMuscles)
        focused = nil
    }

    /// Setting a primary that is also ticked as a secondary drops it from the secondaries: one
    /// muscle can never be credited twice for the same set.
    private func select(primary muscle: LiftMuscle) {
        primary = muscle
        secondaries.remove(muscle)
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let item {
            exercise = item.exercise
            setsText = item.targetSets.map(String.init) ?? ""
            repsText = item.targetRepsLow.map(String.init) ?? ""
            weightText = item.targetWeightKg.map {
                LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: unitSystem))
            } ?? ""
            restText = item.restSec.map(String.init) ?? ""
            note = item.note ?? ""
        }
        guard let store = await repo.storeHandle() else { return }
        vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
        // An existing line adopts whatever classification its exercise already carries, so editing a
        // line shows the muscles the exercise is known by rather than an empty picker.
        if let item, let known = vocabulary.first(where: { $0.name == item.exercise }) {
            primary = known.primaryMuscle
            secondaries = Set(known.secondaryMuscles)
        }
    }

    private func save() async {
        guard canSave else { return }
        let name = trimmedExercise

        // Remember the exercise (and its classification) in the vocabulary, so it is offered back
        // next time. `upsertLiftExercises` is keyed on (deviceId, name), so re-saving updates rather
        // than duplicating.
        if let store = await repo.storeHandle() {
            let now = Int(Date().timeIntervalSince1970)
            let existing = vocabulary.first { $0.name == name }
            let row = LiftExerciseRow(
                id: existing?.id ?? UUID().uuidString,
                deviceId: repo.deviceId,
                name: name,
                primaryMuscle: primary,
                secondaryMuscles: orderedSecondaries,
                createdAt: existing?.createdAt ?? now,
                lastUsedTs: now
            )
            _ = try? await store.upsertLiftExercises([row])
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(LiftProgramItemRow(
            id: item?.id ?? UUID().uuidString,
            deviceId: repo.deviceId,
            // Assigned properly by the parent on save; a placeholder here would be a second source
            // of truth for ordering.
            programId: item?.programId ?? "",
            ord: item?.ord ?? 0,
            exercise: name,
            targetSets: Int(setsText.trimmingCharacters(in: .whitespaces)),
            // ONE rep count. `targetRepsHigh`/`targetRpe` stay nil: they are v40 columns kept for
            // compatibility, not part of the plan any more.
            targetRepsLow: Int(repsText.trimmingCharacters(in: .whitespaces)),
            targetRepsHigh: nil,
            targetRpe: nil,
            targetWeightKg: LiftFormat.number(weightText).map {
                LiftFormat.kilograms(fromDisplay: $0, system: unitSystem)
            },
            restSec: Int(restText.trimmingCharacters(in: .whitespaces)),
            note: trimmedNote.isEmpty ? nil : trimmedNote
        ))
        dismiss()
    }

    /// Secondaries in the vocabulary's canonical order rather than `Set` iteration order, so the
    /// stored list is stable between saves instead of reshuffling on every edit.
    private var orderedSecondaries: [LiftMuscle] {
        LiftMuscle.ordered.filter { secondaries.contains($0) && $0 != primary }
    }
}
