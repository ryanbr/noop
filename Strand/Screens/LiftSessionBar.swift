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

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        // `LiftSessionController.presentation`, the same resolution the Lock Screen renders, so the two
        // cannot word the session differently. Resolved once per render; all three lines read it.
        if let engine = session.engine, let shown = session.presentation(system: unitSystem) {
            Button {
                session.isPresented = true
            } label: {
                // The Lock Screen banner's layout (`LiftLiveActivity`), because this is the same banner
                // seen inside the app: the icon and the numbers sit near the edges and the heart rate
                // stacks over the clock, so the words get the width (Utku, 21 Sep 2026, with a screenshot
                // of the bar: "more place for writings"). Same sizes as before.
                HStack(spacing: 10) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint(engine))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(shown.exercise)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Text(shown.detail.map { "\(shown.status) — \($0)" } ?? shown.status)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                        // The set coming up, on one line that cuts the exercise name before the
                        // set number (`LiftSessionController.nextLine`).
                        Text(shown.next)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)

                    // Heart rate over the clock, both flush right, each its own small view that updates
                    // itself (`LiftLiveReadouts.swift`), so a beat or a tick redraws one number, not the bar.
                    // The clock's width comes from a hidden "00:00" in its font — the widest a set or a rest
                    // shows under an hour — so the words beside it do not shift when it gains a digit.
                    VStack(alignment: .trailing, spacing: 2) {
                        LiftHeartRate(style: .compact)

                        Text(verbatim: "00:00")
                            .font(StrandFont.bodyNumber)
                            .monospacedDigit()
                            .hidden()
                            .overlay(alignment: .trailing) {
                                bigClock(engine)
                                    .font(StrandFont.bodyNumber)
                                    .foregroundStyle(tint(engine))
                                    .fixedSize()
                            }
                    }

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
                .padding(.leading, 12)
                .padding(.trailing, 8)
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

    /// Rest counts DOWN (that is the number you act on); everything else counts up. Written as the Lock
    /// Screen writes the same clock — "0:45", "0:00", "1:05:00" — through NOOP's one running-clock format.
    private func bigClock(_ engine: LiftSessionEngine) -> LiftRunningClock {
        LiftRunningClock { now in engine.restRemaining(now: now) ?? now - engine.stageStartedAt }
    }
}
