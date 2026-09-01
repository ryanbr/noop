import SwiftUI
import StrandDesign

// The running session, condensed to a bar that sits above the tab bar wherever you are in the app.
//
// WHY IT EXISTS. Swiping the workout sheet down used to dismiss the session outright: the screen
// went away and took the strap handler and the tick with it, so taps and buzzes silently stopped
// working. Now swiping down MINIMISES to this bar. The session is still running — same clock, same
// strap gesture, same buzzes — and tapping the bar brings the full sheet back.
//
// It is deliberately a bar and not a badge: it has to show the one thing you need mid-workout
// without opening anything, which is how long is left of your rest.
//
// COLOUR MATCHES THE SHEET so the two read as one thing: green while working, amber while resting.

struct LiftSessionBar: View {
    @EnvironmentObject var session: LiftSessionController

    var body: some View {
        if let engine = session.engine, !engine.isFinished {
            Button {
                session.isPresented = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint(engine))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(engine))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Text(subtitle(engine))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Text(bigClock(engine))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(tint(engine))
                        .monospacedDigit()

                    // The same action the sheet's button performs, so a set can be closed out
                    // without opening anything.
                    Button { session.advance() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(tint(engine))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(tint(engine).opacity(0.35), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the running session")
        }
    }

    private func tint(_ engine: LiftSessionEngine) -> Color {
        switch engine.stage {
        case .working:  return StrandPalette.statusPositive
        case .resting:  return StrandPalette.metricAmber
        default:        return StrandPalette.effortColor
        }
    }

    private func title(_ engine: LiftSessionEngine) -> String {
        guard let slot = engine.currentSlot, let item = engine.planItem(for: slot) else {
            return session.programName ?? String(localized: "Session")
        }
        return item.exercise
    }

    private func subtitle(_ engine: LiftSessionEngine) -> String {
        guard let slot = engine.currentSlot else {
            return String(localized: "\(engine.completedWorkingSets) of \(engine.plannedWorkingSets) sets done")
        }
        switch engine.stage {
        case .working:
            return String(localized: "Set \(slot.setIndex) — working")
        case .resting:
            return (engine.restRemaining(now: session.now) ?? 0) == 0
                ? String(localized: "Ready for the next set")
                : String(localized: "Resting after set \(slot.setIndex)")
        default:
            return String(localized: "\(engine.completedWorkingSets) of \(engine.plannedWorkingSets) sets done")
        }
    }

    /// Rest counts DOWN (that is the number you act on); everything else counts up.
    private func bigClock(_ engine: LiftSessionEngine) -> String {
        if let remaining = engine.restRemaining(now: session.now) {
            return LiftFormat.duration(remaining)
        }
        return LiftFormat.duration(max(0, session.now - engine.stageStartedAt))
    }
}
