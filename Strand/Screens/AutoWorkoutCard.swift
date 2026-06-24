import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Auto-detected workout prompt (Today screen)
//
// A single, dismissible Today card that appears ONLY when the opt-in "Auto-detect workouts"
// toggle is on and `Repository.autoDetectCandidate()` finds a recent sustained-elevated HR
// window that isn't already saved and wasn't previously dismissed.
//
// It only ever SUGGESTS: tapping Save creates a manual-style "Workout" for the window (via the
// same manual-save path the edit sheet uses); the X dismisses it durably so it never re-prompts.
// Nothing is created automatically. Design-Reset compliant — a flat NoopCard using NoopMetrics /
// StrandPalette / StrandFont, no gold, matching the other Today cards (mirrors DonationNudgeCard).

struct AutoWorkoutCard: View {

    @EnvironmentObject var repo: Repository

    /// Whether the toggle is on. Read here too so the card disappears the instant it's switched off.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false

    /// The current suggestion, loaded in `.task`. nil → nothing to show.
    @State private var candidate: DetectedWorkout?
    /// Hide immediately on Save/X without waiting for the next reload (avoids a flash of the old card).
    @State private var handledThisSession = false
    /// Guards the Save button while the write is in flight.
    @State private var saving = false

    var body: some View {
        Group {
            if autoDetectEnabled, !handledThisSession, let w = candidate {
                card(for: w)
            }
        }
        // Re-scan whenever the data refreshes (a sync bumps refreshSeq) or the toggle flips on.
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled)) {
            await reload()
        }
    }

    @ViewBuilder
    private func card(for w: DetectedWorkout) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Looks like a workout")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button {
                        dismiss(w)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.space1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss this workout suggestion")
                }

                Text(promptText(w))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        save(w)
                    } label: {
                        Label("Save it", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(saving)

                    Button("Not a workout") { dismiss(w) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?"
    private func promptText(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        return "Looks like a workout \(Self.dayLabel(startDate))around \(start)–\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?"
    }

    private func reload() async {
        guard autoDetectEnabled else { candidate = nil; return }
        let next = await repo.autoDetectCandidate()
        // A fresh scan resets the session guard so a NEW window can surface after one is handled.
        if next != candidate { handledThisSession = false }
        candidate = next
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        handledThisSession = true
        Task {
            _ = await repo.saveDetectedWorkout(w)
            await repo.refresh()   // surfaces the new workout + drops it from re-suggestion
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        handledThisSession = true
        candidate = nil
    }

    /// HH:mm in the user's locale/timezone.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// A relative LOCAL-day prefix for the prompt (#719): "" when the workout started today, "yesterday "
    /// when yesterday, otherwise "on <date> " — so a time-only prompt can no longer read last night as today.
    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "" }
        if cal.isDateInYesterday(date) { return "yesterday " }
        return "on \(dateFmt.string(from: date)) "
    }

    /// Localized medium date ("Jun 23, 2026") for a workout older than yesterday.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Reload key: a new sync (seq) or a toggle flip re-runs detection.
private struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}
