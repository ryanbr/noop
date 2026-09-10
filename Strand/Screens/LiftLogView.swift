import SwiftUI
import StrandDesign
import StrandAnalytics
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
    @State private var importing = false
    /// The live session, owned at the app root so it survives this screen going away.
    @EnvironmentObject private var session: LiftSessionController
    /// Recent finished sessions, newest first.
    @State private var history: [LiftSessionRow] = []
    /// This week's fractional sets per muscle.
    @State private var weekCounts: [LiftMuscle: Double] = [:]
    /// The session whose detail sheet is open.
    @State private var viewing: SessionDetailTarget?

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        ScreenScaffold(
            title: "Lift Log",
            subtitle: "Build a program once, then tap through it at the gym. Kept on \(Platform.deviceNounPhrase).",
            onRefresh: { await load() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                headerCard
                programsSection
                weekSection
                historySection
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .sheet(item: $editing) { target in
            LiftProgramEditorSheet(program: target.program) {
                await load()
            }
        }
        .sheet(isPresented: $importing) {
            LiftProgramImportSheet { await load() }
        }
        .sheet(item: $viewing) { target in
            LiftSessionDetailSheet(session: target.session) { await load() }
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

            HStack(spacing: 10) {
                Button {
                    editing = ProgramEditTarget(id: "new", program: nil)
                } label: {
                    Label("New program", systemImage: "plus")
                }
                .buttonStyle(NoopButtonStyle(.secondary))

                // Filling a dozen exercise lines by hand on a phone is the most tedious thing in the
                // feature; a spreadsheet on a computer does it in a couple of minutes.
                Button {
                    importing = true
                } label: {
                    Label("Import", systemImage: "tablecells")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
            }
        }
    }

    private var emptyState: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No programs yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("A program is a name and an ordered list of exercises with your targets — working sets, reps, weight, rest and your own technique note.")
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
                                .lineLimit(3)
                        }
                        Text("Tap to edit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(session.isActive ? "Running" : "Start") { Task { await start(program) } }
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
        // Refuse to start a second session over a running one: two live sessions would both claim
        // the strap gesture and both write the in-flight snapshot.
        guard !session.isActive else {
            session.isPresented = true
            return
        }
        session.start(plan: plan, programId: program.id, programName: program.name)
    }

    // MARK: - This week, per muscle

    private var weekSection: some View {
        let ordered = LiftMuscle.ordered.filter { (weekCounts[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sets per muscle", overline: "Last 7 days")
            if ordered.isEmpty {
                NoopCard {
                    Text("Once you've logged a session, this shows how many sets each muscle got this week, against what the research associates with growth.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                NoopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ordered, id: \.self) { muscle in
                            muscleBar(muscle, sets: weekCounts[muscle] ?? 0)
                        }
                        // The band is named and sourced, never phrased as a target NOOP sets for
                        // anyone: this is not a medical device and does not prescribe.
                        Text("The tick marks about 4 sets a week — the point below which the research doesn't reliably detect growth. Above it, gains continue with strongly diminishing returns and no clear ceiling, so the bar has no \"full\".")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    /// The span the weekly bar is drawn across.
    ///
    /// A DRAWING choice, not a dose. The evidence puts a floor at about 4 sets a week and identifies
    /// NO ceiling for hypertrophy — gains continue above it with strongly diminishing returns — so
    /// any bar maximum is arbitrary and must never be read as a target. 20 is chosen only because it
    /// comfortably contains the range people actually train in, which puts the floor tick early on
    /// the bar and makes a normal week read as progress rather than as "finished".
    ///
    /// The NUMBER beside the bar is the truth. The bar is context for it, and a count past 20 fills
    /// the bar while the number keeps counting.
    private static let weeklySetsBarSpan = 20.0

    /// One muscle's week: the count, and where it sits relative to the evidence.
    ///
    /// This used to scale the bar 0...4 and turn it FULL and GREEN at four sets — so the screen said
    /// "done" at the exact point the research says growth merely becomes *detectable*. It was telling
    /// the user to stop at the starting line, and it contradicted the caption printed directly below
    /// it. Now four sets is a TICK a fifth of the way along, and nothing on the bar ever reads as
    /// complete, because nothing about the dose is.
    private func muscleBar(_ muscle: LiftMuscle, sets: Double) -> some View {
        let floor = LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek
        let atOrAboveFloor = sets >= floor
        let fill = min(1.0, sets / Self.weeklySetsBarSpan)
        let tick = min(1.0, floor / Self.weeklySetsBarSpan)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(muscle.displayName)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                // Deliberately NOT a success colour. There is no success point to signal, and a
                // green number is exactly what made four sets read as an achievement.
                Text(LiftFormat.trim(sets))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceRaised)
                    Capsule()
                        // Muted below the floor — below it growth is not reliably detectable, which
                        // is worth showing — and the ordinary accent above it. Never a "done" colour.
                        .fill(StrandPalette.effortColor.opacity(atOrAboveFloor ? 1.0 : 0.45))
                        .frame(width: max(2, geo.size.width * fill))
                    // The floor, marked where it actually falls.
                    Capsule()
                        .fill(StrandPalette.textPrimary.opacity(0.45))
                        .frame(width: 2)
                        .offset(x: max(0, geo.size.width * tick - 1))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(atOrAboveFloor
                                ? String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, at or above the weekly floor of \(LiftFormat.trim(floor))")
                                : String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, below the weekly floor of \(LiftFormat.trim(floor))"))
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sessions", overline: "Recent")
            if history.isEmpty {
                NoopCard {
                    Text("Finished sessions land here, with every set you logged.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else {
                ForEach(history, id: \.id) { session in
                    Button {
                        viewing = SessionDetailTarget(id: session.id, session: session)
                    } label: {
                        historyRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func historyRow(_ session: LiftSessionRow) -> some View {
        NoopCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.programName ?? String(localized: "Session"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(Date(timeIntervalSince1970: TimeInterval(session.startTs))
                            .formatted(date: .abbreviated, time: .shortened))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Load

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []

        let now = Int(Date().timeIntervalSince1970)
        history = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                  fromTs: now - 180 * 86_400,
                                                  toTs: now)) ?? [])
            .filter { $0.endTs != nil }                 // an abandoned session is not history
            .sorted { $0.startTs > $1.startTs }
        weekCounts = (try? await store.liftSetCounts(deviceId: repo.deviceId,
                                                      fromTs: now - 7 * 86_400,
                                                      toTs: now).fractional) ?? [:]
        loaded = true
    }
}

/// The session whose detail is being read back. A wrapper rather than a retroactive `Identifiable`
/// on `LiftSessionRow`, keeping the store's row types free of app-layer conformances.
private struct SessionDetailTarget: Identifiable {
    let id: String
    let session: LiftSessionRow
}


/// Identifies what the editor sheet is editing. A wrapper rather than a retroactive `Identifiable`
/// on `LiftProgramRow`, so the store's row types stay free of app-layer conformances — and so
/// "new program" has an identity of its own to present on.
private struct ProgramEditTarget: Identifiable {
    let id: String
    let program: LiftProgramRow?
}
