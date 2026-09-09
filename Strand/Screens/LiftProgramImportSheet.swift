import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import WhoopStore

// Build a program from a spreadsheet filled in on a computer.
//
// WHY. A program is a name plus an ordered list of exercise lines, each carrying an exercise, a
// muscle classification, sets, reps, a weight, a rest period and a technique note. Typing that for a
// dozen exercises on a phone is the most tedious thing in the feature, and it is exactly the work a
// keyboard and a spreadsheet are good at. `docs/lift-log-program-template.xlsx` is the sheet to fill.
//
// NOTHING IS WRITTEN UNTIL THE USER SAYS SO. The file is parsed, then shown back as what it WILL
// create — programs, their exercises, and every warning — and only then imported. A file picked by
// mistake, or a sheet with the wrong columns, costs a glance rather than a mess to undo.
struct LiftProgramImportSheet: View {
    /// Called after programs have been written, so the hub can reload.
    var onImported: () async -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    @State private var parsed: LiftProgramImportResult?
    @State private var failure: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if let parsed {
                        preview(parsed)
                    } else {
                        intro
                    }
                    if let failure {
                        NoopCard {
                            Text(failure)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusCritical)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Import a program")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let parsed, !parsed.programs.isEmpty {
                        Button("Import") { Task { await performImport(parsed) } }
                            .disabled(importing)
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: Self.acceptedTypes,
                      allowsMultipleSelection: false) { result in
            handle(result)
        }
    }

    /// What the picker will accept. `.spreadsheet` covers .xlsx and .numbers; CSV and plain text are
    /// listed separately because a file exported from a spreadsheet often arrives typed as text.
    private static let acceptedTypes: [UTType] = {
        var types: [UTType] = [.spreadsheet, .commaSeparatedText, .plainText, .data]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.insert(xlsx, at: 0) }
        return types
    }()

    private var intro: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fill it in on a computer")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Download the template from the NOOP repository, fill in one row per exercise, then bring the file here. Excel, Numbers, Google Sheets and LibreOffice all work — .xlsx or .csv.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only the exercise name is required. Anything you leave blank can be filled in later, or during the session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                failure = nil
                picking = true
            } label: {
                Label("Choose a file", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopPrimary)
        }
    }

    private func preview(_ result: LiftProgramImportResult) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ForEach(Array(result.programs.enumerated()), id: \.offset) { _, program in
                NoopCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(program.name)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(program.lines.count) exercises")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        ForEach(Array(program.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.exercise)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Spacer(minLength: 8)
                                Text(summary(line))
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }

            if !result.warnings.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: 6) {
                        // No count in the heading: the warnings are listed directly beneath it, so
                        // the number adds nothing — and it dodges plural agreement in ten languages.
                        Text("Worth checking")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.metricAmber)
                        // Shown in full rather than summarised: each one names a row the user can go
                        // and fix, and a count alone would send them hunting.
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, w in
                            Text(w)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("These lines still import — anything unclassified can be set in the app.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button {
                failure = nil
                parsed = nil
                picking = true
            } label: {
                Label("Choose a different file", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(NoopButtonStyle(.secondary))
        }
    }

    /// "3 x 10 · 50 kg · 90s", skipping whatever the sheet left blank.
    private func summary(_ line: ImportedProgramLine) -> String {
        var parts: [String] = []
        if let sets = line.targetSets, let reps = line.targetReps { parts.append("\(sets) x \(reps)") }
        else if let sets = line.targetSets { parts.append("\(sets) x") }
        if let kg = line.targetWeightKg { parts.append(LiftFormat.trim(kg) + " kg") }
        if let rest = line.restSec { parts.append("\(rest)s") }
        return parts.joined(separator: " · ")
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            failure = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // A file picked from Files/iCloud is security-scoped; without this the read fails with a
            // permissions error that looks like a corrupt file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Check the size BEFORE reading. `Data(contentsOf:)` on a picked file would otherwise
                // pull the whole thing into memory first, which is exactly what the limit exists to
                // prevent — and a phone is where that matters.
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard bytes <= LiftProgramSheetImporter.maxFileBytes else {
                    parsed = nil
                    failure = message(for: .tooLarge)
                    return
                }
                let data = try Data(contentsOf: url)
                parsed = try LiftProgramSheetImporter.parse(data: data)
                failure = nil
            } catch let error as LiftProgramSheetImporter.ImportError {
                parsed = nil
                failure = message(for: error)
            } catch {
                parsed = nil
                failure = String(localized: "That file could not be read.")
            }
        }
    }

    private func message(for error: LiftProgramSheetImporter.ImportError) -> String {
        switch error {
        case .unreadable:
            return String(localized: "That does not look like a spreadsheet. Use the template, saved as .xlsx or .csv.")
        case .missingColumns:
            return String(localized: "That sheet has no Exercise column. Use the template — the import matches on the header names.")
        case .empty:
            return String(localized: "That sheet has no exercises in it yet.")
        case .tooLarge:
            return String(localized: "That file is too big to be a program sheet.")
        }
    }

    private func performImport(_ result: LiftProgramImportResult) async {
        guard !importing, let store = await repo.storeHandle() else { return }
        importing = true
        defer { importing = false }

        let now = Int(Date().timeIntervalSince1970)
        for program in result.programs {
            let programId = UUID().uuidString
            _ = try? await store.upsertLiftPrograms([LiftProgramRow(
                id: programId, deviceId: repo.deviceId, name: program.name, note: program.note,
                createdAt: now, updatedAt: now, archived: false)])

            let items = program.lines.enumerated().map { index, line in
                LiftProgramItemRow(
                    id: UUID().uuidString, deviceId: repo.deviceId, programId: programId,
                    ord: index, exercise: line.exercise,
                    targetSets: line.targetSets,
                    // The sheet plans ONE rep count, which is what the editor plans too; the range's
                    // high end stays nil rather than inventing a spread nobody typed.
                    targetRepsLow: line.targetReps, targetRepsHigh: nil, targetRpe: nil,
                    targetWeightKg: line.targetWeightKg,
                    restSec: line.restSec, note: line.note)
            }
            _ = try? await store.replaceLiftProgramItems(programId: programId, items: items)

            // Remember the exercises too, with the classification the sheet gave them, so the
            // picker offers them next time and the per-muscle rollup resolves the same name the
            // same way. Best-effort: the vocabulary is capped, and hitting the cap must not fail
            // an import of the programs themselves.
            let exercises = program.lines.map { line in
                LiftExerciseRow(
                    id: UUID().uuidString, deviceId: repo.deviceId, name: line.exercise,
                    primaryMuscle: line.primaryMuscle,
                    secondaryMuscles: line.secondaryMuscles,
                    createdAt: now, lastUsedTs: nil)
            }
            _ = try? await store.upsertLiftExercises(exercises)
        }

        await onImported()
        dismiss()
    }
}
