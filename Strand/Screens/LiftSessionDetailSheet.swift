import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// One finished session, read back in full: every set as performed, the six session figures, and how
// each exercise compares with the last time you did it.
//
// This is the screen the whole feature exists to produce. A log book that cannot show you what you
// lifted last week is a diary.
//
// EVERY FIGURE IS ARITHMETIC THE USER CAN REDO BY HAND from the sets listed on the same screen —
// that is the design constraint, and it is why there is no single composite "workout score". The
// maths lives in `LiftMetrics` (pure, unit-tested); this file only lays it out.
//
// Effort is shown BESIDE the lifting figures and is never computed from them: it is whatever NOOP
// measured from heart rate over the session's window, filled in by the engine's own rescore pass.

struct LiftSessionDetailSheet: View {
    let session: LiftSessionRow

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var sets: [LiftSetRow] = []
    /// The `workout` row this session is pinned to, for the HR-measured figures.
    @State private var workout: WorkoutRow?
    /// Previous performance per exercise, for the "vs last time" comparison.
    @State private var previousVolume: [String: Double] = [:]
    @State private var loaded = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    private var durationSec: Int {
        guard let end = session.endTs else { return 0 }
        return max(0, end - session.startTs)
    }

    var body: some View {
        ScreenScaffold(title: "Session", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !loaded {
                    ComingSoon(what: "Reading the session…", symbol: "dumbbell")
                } else {
                    figuresSection
                    exercisesSection
                    muscleSection
                    rpeSection
                    footnote
                }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 780)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await load() }
    }

    private var subtitle: LocalizedStringKey {
        let date = Date(timeIntervalSince1970: TimeInterval(session.startTs))
            .formatted(date: .abbreviated, time: .shortened)
        if let name = session.programName, !name.isEmpty {
            return "\(name) · \(date)"
        }
        return "\(date)"
    }

    // MARK: - The session figures

    private var figuresSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("This session", overline: "Figures")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                tile(String(localized: "Volume"),
                     LiftFormat.weight(LiftMetrics.volumeLoadKg(sets), system: unitSystem),
                     String(localized: "\(workingSetCount) working sets"))

                tile(String(localized: "Session load"),
                     sessionLoadText,
                     sessionLoadCaption)

                tile(String(localized: "Work vs rest"),
                     workRestText,
                     String(localized: "\(LiftFormat.duration(workRest.workSec)) under load"))

                tile(String(localized: "Effort"),
                     workout?.strain.map { LiftFormat.trim($0) } ?? "—",
                     String(localized: "measured from heart rate"))
            }
        }
    }

    private var workRest: LiftMetrics.WorkRest { LiftMetrics.workRest(sets) }
    private var workingSetCount: Int { sets.filter { !$0.isWarmup }.count }

    private var workRestText: String {
        guard let ratio = workRest.restToWorkRatio else { return "—" }
        return String(format: "1 : %.1f", ratio)
    }

    private var sessionLoadText: String {
        guard let load = LiftMetrics.sessionLoad(sessionRpe: session.sessionRpe,
                                                 durationSec: durationSec) else { return "—" }
        return String(Int(load.rounded()))
    }

    /// The caption must show the SAME minutes the load was computed from.
    ///
    /// Showing whole minutes while computing from exact seconds silently breaks the one promise this
    /// screen makes: that every figure is arithmetic you can redo by hand. A 2:40 session captioned
    /// "× 2 min" invites the reader to check 8 × 2 = 16 against a displayed 21 and conclude the app
    /// is making numbers up.
    private var sessionLoadCaption: String {
        guard let rpe = session.sessionRpe else {
            return String(localized: "not rated")
        }
        let minutes = Double(durationSec) / 60.0
        return String(localized: "RPE \(LiftFormat.trim(rpe)) × \(LiftFormat.trim(minutes)) min")
    }

    private func tile(_ label: String, _ value: String, _ caption: String) -> some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).strandOverline()
                Text(value)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Per exercise, with every set

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercises", overline: "As performed")
            ForEach(LiftMetrics.perExercise(sets), id: \.exercise) { summary in
                exerciseCard(summary)
            }
        }
    }

    private func exerciseCard(_ summary: LiftMetrics.ExerciseSummary) -> some View {
        let rows = sets.filter { $0.exercise == summary.exercise }.sorted { $0.ord < $1.ord }
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.exercise)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let first = rows.first {
                    Text(LiftMuscleSummary.line(primary: first.primaryMuscle,
                                                secondaries: first.secondaryMuscles))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                ForEach(rows, id: \.id) { row in setLine(row) }

                Divider().background(StrandPalette.textTertiary.opacity(0.2))

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Best set").strandOverline()
                        Text(bestSetText(summary))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let e1rm = summary.bestEstimatedOneRepMaxKg {
                            // "Estimated" is in the label, not a footnote: it is a formula off one
                            // set, not a measured maximum, and the word has to travel with it.
                            Text(String(localized: "≈ \(LiftFormat.weight(e1rm, system: unitSystem)) estimated 1RM"))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Volume").strandOverline()
                        Text(LiftFormat.weight(summary.volumeKg, system: unitSystem))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let delta = volumeDeltaText(summary) {
                            Text(delta)
                                .font(StrandFont.caption)
                                .foregroundStyle(deltaColor(summary))
                        }
                    }
                }
            }
        }
    }

    private func setLine(_ row: LiftSetRow) -> some View {
        HStack(spacing: 10) {
            Text(row.isWarmup ? String(localized: "W") : "\(row.setIndex)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(row.isWarmup ? StrandPalette.textTertiary : StrandPalette.effortColor)
                .frame(width: 18, alignment: .leading)

            Text(setValueText(row))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(row.isWarmup ? StrandPalette.textSecondary : StrandPalette.textPrimary)

            Spacer(minLength: 0)

            if let rpe = row.rpe {
                Text(String(localized: "RPE \(LiftFormat.trim(rpe))"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let rest = row.restSec {
                Text(LiftFormat.duration(rest))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func setValueText(_ row: LiftSetRow) -> String {
        let reps = row.reps.map(String.init) ?? "—"
        guard let kg = row.weightKg else {
            // Bodyweight work: reps alone, with no fabricated tonnage behind it.
            return String(localized: "\(reps) reps")
        }
        return "\(LiftFormat.weight(kg, system: unitSystem)) × \(reps)"
    }

    private func bestSetText(_ summary: LiftMetrics.ExerciseSummary) -> String {
        guard let reps = summary.bestReps else { return "—" }
        guard let kg = summary.bestWeightKg else { return String(localized: "\(reps) reps") }
        return "\(LiftFormat.weight(kg, system: unitSystem)) × \(reps)"
    }

    /// How this exercise's volume compares with the last session that included it. The single most
    /// useful line in the screen: progression is a comparison, not a number.
    private func volumeDeltaText(_ summary: LiftMetrics.ExerciseSummary) -> String? {
        guard let now = summary.volumeKg, let before = previousVolume[summary.exercise], before > 0
        else { return nil }
        let delta = now - before
        guard abs(delta) >= 0.5 else { return String(localized: "same as last time") }
        let sign = delta > 0 ? "+" : "−"
        return "\(sign)\(LiftFormat.weight(abs(delta), system: unitSystem)) vs last time"
    }

    private func deltaColor(_ summary: LiftMetrics.ExerciseSummary) -> Color {
        guard let now = summary.volumeKg, let before = previousVolume[summary.exercise], before > 0
        else { return StrandPalette.textTertiary }
        if now > before { return StrandPalette.statusPositive }
        if now < before { return StrandPalette.textSecondary }
        return StrandPalette.textTertiary
    }

    // MARK: - Sets per muscle

    private var muscleSection: some View {
        let counts = LiftMetrics.muscleCounts(sets)
        let ordered = LiftMuscle.ordered.filter { (counts.fractional[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sets per muscle", overline: "This session")
            if ordered.isEmpty {
                NoopCard {
                    Text("None of these exercises has a muscle group yet. Add one on the exercise and every future session counts toward it.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                NoopCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ordered, id: \.self) { muscle in
                            HStack(spacing: 10) {
                                Text(muscle.displayName)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer(minLength: 0)
                                Text(LiftFormat.trim(counts.fractional[muscle] ?? 0))
                                    .font(StrandFont.bodyNumber)
                                    .foregroundStyle(StrandPalette.effortColor)
                                Text(componentText(counts, muscle))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Text("Direct sets count once, indirect sets count as a half — the method the reference figures were derived under.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    /// "4 direct · 2 indirect" — so the total above is inspectable rather than asserted.
    private func componentText(_ counts: LiftMetrics.MuscleCounts, _ muscle: LiftMuscle) -> String {
        let d = counts.direct[muscle] ?? 0
        let i = counts.indirect[muscle] ?? 0
        if d > 0 && i > 0 { return String(localized: "\(d) direct · \(i) indirect") }
        if d > 0 { return String(localized: "\(d) direct") }
        return String(localized: "\(i) indirect")
    }

    // MARK: - RPE profile

    private var rpeSection: some View {
        let p = LiftMetrics.rpeProfile(sets)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How hard it felt", overline: "RPE")
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Mean RPE")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 0)
                        Text(p.mean.map { LiftFormat.trim($0) } ?? "—")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    HStack {
                        Text(String(localized: "Sets at RPE \(LiftFormat.trim(p.threshold)) or above"))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 0)
                        Text("\(p.setsAtOrAboveThreshold)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    if p.unratedSets > 0 {
                        Text(String(localized: "\(p.unratedSets) working sets weren't rated, so the mean is drawn from \(p.ratedSets)."))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Text("Lifting figures are worked out from the sets above. Effort stays measured from heart rate and is never derived from weights and reps.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Load

    private func load() async {
        guard let store = await repo.storeHandle() else { loaded = true; return }
        sets = (try? await store.liftSets(sessionId: session.id)) ?? []

        // The workout row this session is pinned to, by that table's own natural key.
        let rows = (try? await store.workouts(deviceId: repo.deviceId,
                                              from: session.startTs - 1,
                                              to: session.startTs + 1, limit: 10)) ?? []
        workout = rows.first { $0.startTs == session.startTs && $0.sport == session.sport }

        // Previous volume per exercise, for the "vs last time" line.
        var previous: [String: Double] = [:]
        for name in Set(sets.map(\.exercise)) {
            let before = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                        exercise: name,
                                                        before: session.startTs)) ?? []
            if let v = LiftMetrics.volumeLoadKg(before) { previous[name] = v }
        }
        previousVolume = previous
        loaded = true
    }
}
