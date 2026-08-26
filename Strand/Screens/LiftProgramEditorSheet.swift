import SwiftUI
import StrandDesign
import WhoopStore

// Build or edit a program: a name and an ordered list of exercise lines carrying the TARGETS —
// working sets, rep range, target RPE, rest and the user's own technique note.
//
// Lines are edited as local drafts and written in one go on Save, through
// `replaceLiftProgramItems`, which swaps the whole list transactionally. Editing a program never
// rewrites history: a session snapshots the program's NAME when it runs, so renaming "Upper A" or
// deleting it entirely leaves every past session reading exactly as it did.

struct LiftProgramEditorSheet: View {
    /// The program being edited, or nil to create a new one.
    let program: LiftProgramRow?
    /// Called after a successful save or delete, so the caller can reload.
    let onSaved: () async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var note: String = ""
    /// The exercise lines, in display order. `ord` is assigned from the array index on save, so
    /// reordering is just moving an element.
    @State private var items: [LiftProgramItemRow] = []
    @State private var loaded = false
    @State private var saving = false

    /// The line being added or edited (nil = that sheet is closed).
    @State private var editingItem: ItemEditTarget?
    @State private var confirmingDelete = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, note }

    private var isNew: Bool { program == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        ScreenScaffold(
            title: isNew ? "New program" : "Edit program",
            subtitle: "Your targets for each exercise. What you actually lift is recorded when you run it."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                detailsSection
                exercisesSection
                if !isNew { deleteSection }
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        // A fixed frame, for the reason the other editor sheets document: a macOS sheet hosting a
        // ScrollView needs a definite height or every row collapses to the top.
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .task { await loadIfNeeded() }
        .sheet(item: $editingItem) { target in
            LiftProgramItemSheet(item: target.item) { saved in
                apply(saved, replacing: target.item)
            }
        }
    }

    // MARK: - Name + note

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Program", overline: "Details")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name") {
                        TextField("Upper A", text: $name)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .focused($focused, equals: .name)
                    }
                    field("Note (optional)") {
                        TextField("Anything you want to remember", text: $note)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .focused($focused, equals: .note)
                    }
                }
            }
        }
    }

    // MARK: - Exercise lines

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercises", overline: "In order")

            if items.isEmpty {
                NoopCard {
                    Text("No exercises yet. Add the first one below — you can type any name you like; NOOP remembers it for next time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    itemRow(item, index: index)
                }
            }

            Button {
                editingItem = ItemEditTarget(id: "new", item: nil)
            } label: {
                Label("Add exercise", systemImage: "plus")
            }
            .buttonStyle(NoopButtonStyle(.secondary))
        }
    }

    private func itemRow(_ item: LiftProgramItemRow, index: Int) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    editingItem = ItemEditTarget(id: item.id, item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.exercise)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(targetSummary(item))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if let note = item.note, !note.isEmpty {
                            Text(note)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(spacing: 10) {
                    Button {
                        move(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Move up")

                    Button {
                        move(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == items.count - 1)
                    .accessibilityLabel("Move down")

                    Button(role: .destructive) {
                        items.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove exercise")
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    /// "4 × 8 · 60 kg · 2:00 rest" — only the parts that were actually filled in.
    private func targetSummary(_ item: LiftProgramItemRow) -> String {
        var parts: [String] = []
        if let sets = item.targetSets {
            if let reps = item.targetRepsLow {
                parts.append("\(sets) × \(reps)")
            } else {
                parts.append(String(localized: "\(sets) sets"))
            }
        }
        if let kg = item.targetWeightKg {
            parts.append(LiftFormat.weight(kg, system: unitSystem))
        }
        if let rest = item.restSec {
            parts.append(String(localized: "\(LiftFormat.duration(rest)) rest"))
        }
        return parts.isEmpty ? String(localized: "No targets set") : parts.joined(separator: " · ")
    }

    // MARK: - Delete

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete program", systemImage: "trash")
            }
            .buttonStyle(NoopButtonStyle(.secondary))
            .confirmationDialog("Delete this program?",
                                isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await deleteProgram() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Sessions you already logged from it are kept.")
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
                .accessibilityLabel("Save program")
        }
    }

    // MARK: - Helpers

    private func field<Content: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    /// Insert a new line, or replace an edited one in place so its position is kept.
    private func apply(_ saved: LiftProgramItemRow, replacing old: LiftProgramItemRow?) {
        guard let old, let index = items.firstIndex(where: { $0.id == old.id }) else {
            items.append(saved)
            return
        }
        items[index] = saved
    }

    // MARK: - Load / save

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let program else { return }
        name = program.name
        note = program.note ?? ""
        guard let store = await repo.storeHandle() else { return }
        items = (try? await store.liftProgramItems(programId: program.id)) ?? []
    }

    private func save() async {
        guard canSave, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        let now = Int(Date().timeIntervalSince1970)
        let id = program?.id ?? UUID().uuidString
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        let row = LiftProgramRow(
            id: id,
            deviceId: repo.deviceId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            createdAt: program?.createdAt ?? now,
            updatedAt: now,
            archived: program?.archived ?? false
        )
        _ = try? await store.upsertLiftPrograms([row])

        // `ord` is the array index: reordering the list is all it takes to reorder the program.
        let ordered = items.enumerated().map { index, item in
            LiftProgramItemRow(
                id: item.id,
                deviceId: repo.deviceId,
                programId: id,
                ord: index,
                exercise: item.exercise,
                targetSets: item.targetSets,
                targetRepsLow: item.targetRepsLow,
                targetRepsHigh: item.targetRepsHigh,
                targetRpe: item.targetRpe,
                targetWeightKg: item.targetWeightKg,
                restSec: item.restSec,
                note: item.note
            )
        }
        _ = try? await store.replaceLiftProgramItems(programId: id, items: ordered)

        await onSaved()
        dismiss()
    }

    private func deleteProgram() async {
        guard let program, let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLiftProgram(id: program.id)
        await onSaved()
        dismiss()
    }
}

/// What the line editor is editing — a wrapper so "new line" has an identity to present on.
private struct ItemEditTarget: Identifiable {
    let id: String
    let item: LiftProgramItemRow?
}
