import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for a running Lift Log session — the minimised session bar, on the Lock Screen and
/// in the Dynamic Island.
///
/// It carries the same four things the in-app bar does, in the same order, because it is answering
/// the same question from further away: what am I doing, on what, with what numbers, and how long.
/// The colour language matches too — green while a set is being worked, amber through the rest.
///
/// THE CLOCK TICKS WITHOUT THE APP. Both timers are `Text(timerInterval:)`, driven by dates in the
/// content state, so the Lock Screen counts on its own between pushes. The app only sends a new
/// state when something actually changes (stage, set, heart rate), never once a second to animate a
/// number.
struct LiftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiftActivityAttributes.self) { context in
            lockScreen(context.state, program: context.attributes.programName)
                .activityBackgroundTint(StrandPalette.surfaceBase)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            let tint = tint(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.exercise, systemImage: "dumbbell.fill")
                        .font(.caption).lineLimit(1)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let bpm = context.state.bpm {
                        Label("\(bpm)", systemImage: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(StrandPalette.metricRose)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail ?? context.state.status)
                            .font(.caption).lineLimit(1)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 8)
                        clock(context.state, tint: tint)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(tint)
            } compactTrailing: {
                clock(context.state, tint: tint)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            } minimal: {
                Image(systemName: "dumbbell.fill").foregroundStyle(tint)
            }
        }
    }

    /// Green while working, amber through the rest — the sheet's and the bar's colour language.
    private func tint(_ state: LiftActivityAttributes.ContentState) -> Color {
        state.isResting ? StrandPalette.metricAmber : StrandPalette.statusPositive
    }

    private func lockScreen(_ state: LiftActivityAttributes.ContentState,
                            program: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint(state))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.exercise)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(state.detail.map { "\(state.status) — \($0)" } ?? state.status)
                    .font(.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                // Two variables in an HStack rather than one interpolated string: the extension has
                // no catalog, so a literal separator here would be untranslatable copy shipped to
                // ten locales. Everything user-facing arrives pre-localized from the app.
                HStack(spacing: 6) {
                    Text(state.progress)
                    Text(program)
                }
                .font(.caption2)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                clock(state, tint: tint(state))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                if let bpm = state.bpm {
                    Label("\(bpm)", systemImage: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(StrandPalette.metricRose)
                }
            }
        }
        .padding()
    }

    /// Counts DOWN through a rest (the number you act on) and UP through a set, both self-ticking.
    ///
    /// Both branches use `Text(timerInterval:)`, which is the API widgets are given for a clock that
    /// advances without the app pushing. `Text(date, style: .timer)` looks equivalent and is not: on
    /// the Lock Screen it rendered "25 minutes" — a rounded, prose duration — where a gym timer has
    /// to read 25:02. Verified in the simulator, which is the only reason it was caught.
    ///
    /// An overrun rest (`restEndsAt` already past) counts UP from when it was due, which is the
    /// honest reading: you are over, and by how much. A zero-length range would render nothing, so
    /// the end is pushed a day out — well beyond any session.
    private func clock(_ state: LiftActivityAttributes.ContentState, tint: Color) -> some View {
        let counter: some View = {
            if let ends = state.restEndsAt, ends > .now {
                return Text(timerInterval: .now...ends, countsDown: true)
            }
            let from = state.restEndsAt ?? state.stageStartedAt
            return Text(timerInterval: from...from.addingTimeInterval(86_400), countsDown: false)
        }()
        return counter
            .monospacedDigit()
            .foregroundStyle(tint)
    }
}
