import SwiftUI
import StrandDesign
import WhoopStore

// The Lift Log: build a program once, then run it in the gym by tapping through it.
//
// This screen is the front door — it lists the saved programs and (from a later phase) the sessions
// run from them. It lives in the Effort colour world, like Workouts, because a finished session
// lands in the `workout` table beside every other workout.
//
// EFFORT IS NEVER MODIFIED HERE (load-bearing). NOOP's Effort is computed from heart rate alone
// (Karvonen %HRR → Edwards TRIMP, `StrainScorer`), and there is no validated public path from typed
// sets/reps/weight to a cardiovascular-strain equivalent — WHOOP's own muscular load runs
// velocity-based algorithms over strap accelerometer/gyroscope data under an unpublished model.
// So the lifting figures are shown BESIDE Effort and never folded into it, matching the choice the
// imported-lifting path already made (`strain: nil, // never a fabricated cardiovascular strain`).

struct LiftLogView: View {
    @EnvironmentObject var repo: Repository

    /// Saved programs, most-recently-touched first. Loaded off the store on appear/refresh.
    @State private var programs: [LiftProgramRow] = []
    @State private var loaded = false

    /// The program being created or edited (nil = the editor is closed).
    @State private var editing: ProgramEditTarget?
    /// The session being run (nil = not in a session).
    @State private var running: SessionStart?
    /// An interrupted session found on disk, offered for resume.
    @State private var interrupted: LiftSessionPersistence.Snapshot?

    var body: some View {
        ScreenScaffold(
            title: "Lift Log",
            subtitle: "Build a program once, then tap through it at the gym. Kept on \(Platform.deviceNounPhrase).",
            onRefresh: { await load() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                headerCard
                if interrupted != nil { resumeCard }
                programsSection
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .sheet(item: $editing) { target in
            LiftProgramEditorSheet(program: target.program) {
                await load()
            }
        }
        .sheet(item: $running) { start in
            if let snapshot = start.resuming {
                LiftSessionView(resuming: snapshot) { await load() }
            } else {
                LiftSessionView(plan: start.plan,
                                programId: start.programId,
                                programName: start.programName) { await load() }
            }
        }
    }

    // MARK: - Resume an interrupted session

    private var resumeCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Session in progress")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("You left a session running. Nothing was lost — pick it up where you stopped.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Resume") {
                        if let interrupted {
                            running = SessionStart(id: "resume", plan: [], programId: nil,
                                                   programName: nil, resuming: interrupted)
                        }
                    }
                    .buttonStyle(.noopPrimary)
                    .frame(maxWidth: 160)
                    Spacer()
                    Button(role: .destructive) {
                        LiftSessionPersistence.clear()
                        interrupted = nil
                    } label: {
                        Text("Discard")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.effortColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your log book")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Programs, sessions and per-set history")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                Text("Lifting adds volume and set counts. It never changes your Effort, which stays measured from heart rate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Programs

    private var programsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Programs", overline: "Saved")

            if !loaded {
                ComingSoon(what: "Reading your programs…", symbol: "dumbbell")
            } else if programs.isEmpty {
                emptyState
            } else {
                ForEach(programs, id: \.id) { program in
                    programRow(program)
                }
            }

            Button {
                editing = ProgramEditTarget(id: "new", program: nil)
            } label: {
                Label("New program", systemImage: "plus")
            }
            .buttonStyle(NoopButtonStyle(.secondary))
        }
    }

    private var emptyState: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No programs yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("A program is a name and an ordered list of exercises with your targets — working sets, rep range, target RPE, rest and your own technique note.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func programRow(_ program: LiftProgramRow) -> some View {
        NoopCard {
            HStack(spacing: 12) {
                Button {
                    editing = ProgramEditTarget(id: program.id, program: program)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(program.name)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let note = program.note, !note.isEmpty {
                            Text(note)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(2)
                        }
                        Text("Tap to edit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button("Start") { Task { await start(program) } }
                    .buttonStyle(.noopPrimary)
                    .frame(maxWidth: 110)
                    .accessibilityLabel("Start this program")
            }
        }
    }

    // MARK: - Start a session

    /// Flatten a program into the plan the session runs. The plan is SNAPSHOT at start: editing or
    /// deleting the program mid-session cannot change what is being tapped through.
    private func start(_ program: LiftProgramRow) async {
        guard let store = await repo.storeHandle() else { return }
        let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        guard !items.isEmpty else { return }
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []

        let plan = items.map { item -> LiftPlanItem in
            // The classification comes from the exercise vocabulary, which is the one place that owns
            // it — the program line deliberately stores no muscle of its own to drift from.
            let known = vocabulary.first { $0.name == item.exercise }
            return LiftPlanItem(exercise: item.exercise,
                                primaryMuscle: known?.primaryMuscle,
                                secondaryMuscles: known?.secondaryMuscles ?? [],
                                targetSets: item.targetSets,
                                restSec: item.restSec,
                                targetRepsLow: item.targetRepsLow,
                                targetRepsHigh: item.targetRepsHigh,
                                targetRpe: item.targetRpe,
                                targetWeightKg: item.targetWeightKg,
                                note: item.note)
        }
        running = SessionStart(id: program.id, plan: plan,
                               programId: program.id, programName: program.name, resuming: nil)
    }

    // MARK: - Load

    private func load() async {
        interrupted = LiftSessionPersistence.load()
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []
        loaded = true
    }
}

/// What the session sheet is presenting — a fresh run of a program, or a resumed snapshot.
private struct SessionStart: Identifiable {
    let id: String
    let plan: [LiftPlanItem]
    let programId: String?
    let programName: String?
    let resuming: LiftSessionPersistence.Snapshot?
}

/// Identifies what the editor sheet is editing. A wrapper rather than a retroactive `Identifiable`
/// on `LiftProgramRow`, so the store's row types stay free of app-layer conformances — and so
/// "new program" has an identity of its own to present on.
private struct ProgramEditTarget: Identifiable {
    let id: String
    let program: LiftProgramRow?
}
