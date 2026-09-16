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
            lockScreen(context.state)
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
                    Label {
                        Text(context.state.bpm.map(String.init) ?? "—").monospacedDigit()
                    } icon: {
                        Image(systemName: "heart.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(context.state.bpm == nil
                                     ? StrandPalette.textTertiary
                                     : StrandPalette.metricRose)
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

    private func lockScreen(_ state: LiftActivityAttributes.ContentState) -> some View {
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
                // The set coming up, alone on the line, arriving pre-localized from the app (the
                // extension has no catalog). It puts the set number before the exercise, so the tail
                // truncation a long name needs cuts the name and keeps the number.
                Text(state.next)
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            // Heart rate then clock, side by side — the minimised bar's layout, because this is the
            // same bar seen from the Lock Screen. Stacking them looked misaligned:
            // `Text(timerInterval:)` reserves width for the widest value it could show, so a
            // trailing-aligned timer does not visually line up with the text under it.
            //
            // The heart rate is ALWAYS present, dash and all. A readout that vanishes when the strap
            // stops reading is indistinguishable from a missing feature — which is exactly how it
            // was first reported.
            HStack(spacing: 10) {
                Label {
                    Text(state.bpm.map(String.init) ?? "—").monospacedDigit()
                } icon: {
                    Image(systemName: "heart.fill")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.bpm == nil
                                 ? StrandPalette.textTertiary
                                 : StrandPalette.metricRose)

                clock(state, tint: tint(state))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
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
    /// A rest that is over reads 0:00 and stays there, as the in-app bar does
    /// (`LiftSessionEngine.restRemaining` floors at zero). It used to count UP past the end, and a
    /// clock climbing from zero on the Lock Screen read as a new timer rather than a finished rest
    /// (gym session, 16 Sep 2026). The countdown's range therefore starts at the REST'S start, not at
    /// `.now`: a widget re-rendered after the end — for a heart-rate push, say — still gets a range
    /// that is entirely past, which `Text(timerInterval:)` shows as its end value instead of switching
    /// to a count-up. A rest with no length (the sheet is complete) has no range to count and shows
    /// the same 0:00. A working set counts up from its start; a zero-length range would render
    /// nothing, so that end is pushed a day out — well beyond any session.
    private func clock(_ state: LiftActivityAttributes.ContentState, tint: Color) -> some View {
        Group {
            if let ends = state.restEndsAt {
                if ends > state.stageStartedAt {
                    Text(timerInterval: state.stageStartedAt...ends, countsDown: true)
                } else {
                    Text(verbatim: "0:00")
                }
            } else {
                Text(timerInterval: state.stageStartedAt...state.stageStartedAt.addingTimeInterval(86_400),
                     countsDown: false)
            }
        }
        .monospacedDigit()
        .foregroundStyle(tint)
    }
}
