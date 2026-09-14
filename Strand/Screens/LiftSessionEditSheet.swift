import SwiftUI
import StrandDesign
import WhoopStore

// Correct a finished session: a number missed or mistyped at the gym, a warm-up not marked, or the
// session's RPE. Only the numbers move — which sets were done, when and in what order stays as it
// happened — and every figure on the session screen is recomputed from these rows.
//
// Fields hold plain text and are parsed once, on Save, so a field is never rewritten while it is being
// typed into (the bug that stored 45.5 kg as 455). Only a field whose text changed is written back:
// re-parsing an untouched pound value into kilograms would otherwise nudge it by a rounding error.

struct LiftSessionEditSheet: View {
    let session: LiftSessionRow
    let sets: [LiftSetRow]
    /// Called after the changes are written, so the session screen can reload.
    let onSaved: () async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// The text of every field, by set id, and what it held when the sheet opened.
    @State private var form: [String: SetForm] = [:]
    @State private var original: [String: SetForm] = [:]
    @State private var sessionRpeText = ""
    @State private var originalSessionRpe = ""
    @State private var saving = false

    @FocusState private var focused: Field?
    private enum Field: Hashable { case weight(String), reps(String), rpe(String), sessionRpe }

    /// One set's fields, as typed.
    struct SetForm: Equatable {
        var weight: String
        var reps: String
        var rpe: String
        var isWarmup: Bool
    }

    private var hasChanges: Bool { form != original || sessionRpeText != originalSessionRpe }

    /// Exercises in the order they were first performed.
    private var exercises: [String] {
        var seen = Set<String>()
        return sets.sorted { $0.ord < $1.ord }.map(\.exercise).filter { seen.insert($0).inserted }
    }

    private var weightHeading: LocalizedStringKey {
        unitSystem == .imperial ? "Lb" : "Kg"
    }

    var body: some View {
        ScreenScaffold(title: "Edit sets",
                       subtitle: "Fix a number you missed or mistyped. The session's figures follow when you save.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                sessionRpeCard
                ForEach(exercises, id: \.self) { exerciseCard($0) }
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 780)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
        .onAppear(perform: fill)
    }

    private var sessionRpeCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("How hard was the whole session? (1–10)").strandOverline()
                field(.sessionRpe, text: Binding(
                    get: { sessionRpeText },
                    set: { sessionRpeText = $0.replacingOccurrences(of: ",", with: ".") }))
            }
        }
    }

    private func exerciseCard(_ exercise: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text(exercise)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: 8) {
                    Text("Set").strandOverline()
                        .frame(width: LiftSessionView.setColumnWidth, alignment: .center)
                    Text(weightHeading).strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Reps").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                    Text("RPE").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                ForEach(sets.filter { $0.exercise == exercise }.sorted { $0.ord < $1.ord }, id: \.id) {
                    setRow($0)
                }
            }
        }
    }

    /// The set number toggles a warm-up, as on the session sheet.
    private func setRow(_ row: LiftSetRow) -> some View {
        let warmup = form[row.id]?.isWarmup ?? row.isWarmup
        return HStack(spacing: 8) {
            Button { form[row.id]?.isWarmup.toggle() } label: {
                Text(warmup ? String(localized: "W") : "\(row.setIndex)")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(warmup ? StrandPalette.metricAmber : StrandPalette.textSecondary)
                    .frame(width: LiftSessionView.setColumnWidth, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(warmup
                                ? String(localized: "Warm-up set — tap to make it a working set")
                                : String(localized: "Set \(row.setIndex) — tap to mark it a warm-up"))
            field(.weight(row.id), text: binding(row.id, \.weight))
            field(.reps(row.id), text: binding(row.id, \.reps))
            field(.rpe(row.id), text: binding(row.id, \.rpe))
        }
        .padding(.vertical, 6)
    }

    private func field(_ target: Field, text: Binding<String>) -> some View {
        TextField(Self.empty, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: target)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A typed comma becomes a point, as on the session sheet: iOS labels the decimal key from the
    /// device's region, and the field reads back in the notation the app displays.
    private func binding(_ id: String, _ key: WritableKeyPath<SetForm, String>) -> Binding<String> {
        Binding(get: { form[id]?[keyPath: key] ?? "" },
                set: { form[id]?[keyPath: key] = $0.replacingOccurrences(of: ",", with: ".") })
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Save changes") { Task { await save() } }
                .buttonStyle(.noopPrimary)
                .frame(maxWidth: 180)
                .disabled(saving || !hasChanges)
                .opacity(saving || !hasChanges ? NoopButtonMetrics.disabledOpacity : 1)
        }
    }

    private func fill() {
        guard form.isEmpty else { return }
        for row in sets { form[row.id] = Self.form(for: row, system: unitSystem) }
        original = form
        sessionRpeText = session.sessionRpe.map { LiftFormat.trim($0) } ?? ""
        originalSessionRpe = sessionRpeText
    }

    private func save() async {
        guard !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        let edited = sets.compactMap { row -> LiftSetRow? in
            guard let after = form[row.id], let before = original[row.id], after != before else { return nil }
            return Self.applying(after, over: before, to: row, system: unitSystem)
        }
        if !edited.isEmpty { _ = try? await store.upsertLiftSets(edited) }
        if sessionRpeText != originalSessionRpe {
            var row = session
            row.sessionRpe = LiftFormat.number(sessionRpeText)
            _ = try? await store.upsertLiftSessions([row])
        }
        await onSaved()
        dismiss()
    }

    /// A set's fields as the sheet opens, in the unit the app displays.
    static func form(for row: LiftSetRow, system: UnitSystem) -> SetForm {
        SetForm(weight: row.weightKg.map { LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system)) } ?? "",
                reps: row.reps.map(String.init) ?? "",
                rpe: row.rpe.map { LiftFormat.trim($0) } ?? "",
                isWarmup: row.isWarmup)
    }

    /// `row` with every field that differs between `before` and `after` parsed back in. A blank field
    /// clears its value.
    static func applying(_ after: SetForm, over before: SetForm, to row: LiftSetRow,
                         system: UnitSystem) -> LiftSetRow {
        var edited = row
        if after.weight != before.weight {
            edited.weightKg = LiftFormat.number(after.weight).map {
                LiftFormat.kilograms(fromDisplay: $0, system: system)
            }
        }
        if after.reps != before.reps {
            edited.reps = Int(after.reps.trimmingCharacters(in: .whitespaces))
        }
        if after.rpe != before.rpe {
            edited.rpe = LiftFormat.number(after.rpe)
        }
        edited.isWarmup = after.isWarmup
        return edited
    }

    private static let empty = "—"
}
