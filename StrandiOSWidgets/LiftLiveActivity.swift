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
            LiftActivityView(state: context.state)
                .activityBackgroundTint(StrandPalette.surfaceBase)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            let view = LiftActivityView(state: context.state)
            let tint = view.tint
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.exercise, systemImage: "dumbbell.fill")
                        .font(StrandFont.caption).lineLimit(1)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label {
                        Text(context.state.bpm.map(String.init) ?? "—").monospacedDigit()
                    } icon: {
                        Image(systemName: "heart.fill")
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(context.state.bpm == nil
                                     ? StrandPalette.textTertiary
                                     : StrandPalette.metricRose)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        HStack {
                            Text(context.state.detail ?? context.state.status)
                                .font(StrandFont.caption).lineLimit(1)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer(minLength: NoopMetrics.space2)
                            view.clock.font(StrandFont.bodyNumber)
                        }
                        if let training = context.state.training {
                            TrainingControls(training: training, labels: context.state.trainingLabels ?? [:])
                        }
                    }
                }
            } compactLeading: {
                if let bpm = context.state.bpm {
                    HStack(spacing: NoopMetrics.space1) {
                        Image(systemName: "heart.fill")
                            .resizable().scaledToFit()
                            .frame(width: NoopMetrics.space4, height: NoopMetrics.space4)
                        Text(bpm, format: .number).monospacedDigit()
                    }
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.metricRose)
                    .frame(height: NoopMetrics.space6)
                } else {
                    WorkoutTypeIcon(workoutType: .strength, size: NoopMetrics.space4, color: tint)
                        .frame(width: NoopMetrics.space6, height: NoopMetrics.space6)
                }
            } compactTrailing: {
                // Sized like the Lock Screen's clock: a running `Text(timerInterval:)` takes every point it
                // is offered, which stretched the island and left the digits adrift in its middle with blank
                // to their right (Utku, 22 Sep 2026). A hidden "0:00:00" in the same font gives the region the
                // width of the clock itself, and the live one is right-aligned over it.
                Text(verbatim: "0:00:00")
                    .font(StrandFont.captionNumber)
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .trailing) {
                        view.clock
                            .font(StrandFont.captionNumber)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(height: NoopMetrics.space6)
            } minimal: {
                Image(systemName: context.state.training?.pausedAt == nil ? "dumbbell.fill" : "pause.fill")
                    .resizable().scaledToFit()
                    .frame(width: NoopMetrics.space4, height: NoopMetrics.space4)
                    .foregroundStyle(tint)
                    .frame(width: NoopMetrics.space6, height: NoopMetrics.space6)
            }
            .contentMargins(.horizontal, NoopMetrics.space4, for: .expanded)
        }
    }
}

struct LiftActivityView: View {
    let state: LiftActivityAttributes.ContentState
    var tint: Color {
        state.training?.pausedAt != nil || state.isResting ? StrandPalette.metricAmber : StrandPalette.statusPositive
    }
    var body: some View {
        let focused = state.training.map { $0.isConfirming() || $0.error != nil } ?? false
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Label(state.exercise, systemImage: state.training?.pausedAt == nil ? "dumbbell.fill" : "pause.fill")
                    .font(focused ? StrandFont.caption.weight(.semibold) : StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                // Missing HR remains visible as a dash (Utku, 21 Sep 2026).
                Label {
                    Text(state.bpm.map(String.init) ?? "—").monospacedDigit()
                } icon: {
                    Image(systemName: "heart.fill")
                }
                .font(StrandFont.captionNumber)
                .foregroundStyle(state.bpm == nil ? StrandPalette.textTertiary : StrandPalette.metricRose)
                .fixedSize()
            }
            if !focused {
                HStack(spacing: NoopMetrics.space2) {
                    Text(state.training?.pausedAt == nil ? state.status : (state.trainingLabels?["paused"] ?? "") + " · " + state.status)
                        .font(StrandFont.caption).foregroundStyle(tint).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: "00:00").font(StrandFont.title2).hidden()
                        .overlay(alignment: .trailing) {
                            clock.font(StrandFont.title2).multilineTextAlignment(.trailing)
                        }
                }
                HStack(spacing: NoopMetrics.space2) {
                    if let detail = state.detail {
                        Text(detail).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary).fixedSize()
                    }
                    Label(state.next, systemImage: "arrow.turn.down.right")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                }
            }
            if let training = state.training {
                TrainingControls(training: training, labels: state.trainingLabels ?? [:])
            }
        }
        .padding(NoopMetrics.space3)
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
    var clock: some View {
        Group {
            if let ends = state.restEndsAt {
                if ends > state.stageStartedAt {
                    Text(timerInterval: state.stageStartedAt...ends, pauseTime: state.training?.pausedAt, countsDown: true)
                } else {
                    Text(verbatim: "0:00")
                }
            } else {
                Text(timerInterval: state.stageStartedAt...state.stageStartedAt.addingTimeInterval(86_400),
                     pauseTime: state.training?.pausedAt, countsDown: false)
            }
        }
        .monospacedDigit()
        .foregroundStyle(tint)
    }
}
