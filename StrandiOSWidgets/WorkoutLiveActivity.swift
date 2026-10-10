import SwiftUI
import WidgetKit
import ActivityKit
import StrandDesign

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutActivityView(training: context.state.training, labels: context.state.labels)
                .activityBackgroundTint(StrandPalette.surfaceBase)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.training.title)
                    } icon: {
                        WorkoutTypeIcon(workoutType: context.state.training.sport ?? KnownWorkoutType.other.rawValue,
                                        size: NoopMetrics.space4, color: StrandPalette.accent)
                    }
                        .font(StrandFont.caption.weight(.semibold)).lineLimit(1).foregroundStyle(StrandPalette.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrainingClock(training: context.state.training).font(StrandFont.bodyNumber)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TrainingControls(training: context.state.training, labels: context.state.labels)
                }
            } compactLeading: {
                WorkoutTypeIcon(workoutType: context.state.training.sport ?? KnownWorkoutType.other.rawValue,
                                size: NoopMetrics.space4, color: StrandPalette.accent)
                    .frame(width: NoopMetrics.space6, height: NoopMetrics.space6)
            } compactTrailing: {
                Text(verbatim: "0:00:00").font(StrandFont.captionNumber).hidden()
                    .overlay(alignment: .trailing) {
                        TrainingClock(training: context.state.training).font(StrandFont.captionNumber)
                            .multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(height: NoopMetrics.space6)
            } minimal: {
                WorkoutTypeIcon(workoutType: context.state.training.sport ?? KnownWorkoutType.other.rawValue,
                                size: NoopMetrics.space4, color: StrandPalette.accent)
                    .frame(width: NoopMetrics.space6, height: NoopMetrics.space6)
            }
            .contentMargins(.horizontal, NoopMetrics.space4, for: .expanded)
        }
    }
}

struct WorkoutActivityView: View {
    let training: TrainingDisplay
    let labels: [String: String]
    var body: some View {
        let focused = training.isConfirming() || training.error != nil
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space3) {
                if !focused {
                    WorkoutTypeIcon(workoutType: training.sport ?? KnownWorkoutType.other.rawValue,
                                    size: NoopMetrics.space6, color: StrandPalette.accent)
                        .frame(width: NoopButtonMetrics.minHitTarget, height: NoopButtonMetrics.minHitTarget)
                        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(training.title).font(focused ? StrandFont.caption.weight(.semibold) : StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(focused ? 1 : 2)
                    if !focused {
                        Text(labels[training.pausedAt == nil ? "running" : "paused"] ?? "")
                            .font(StrandFont.caption).foregroundStyle(training.pausedAt == nil ? StrandPalette.textSecondary : StrandPalette.metricAmber)
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: "0:00:00").font(focused ? StrandFont.bodyNumber : StrandFont.title1).hidden()
                    .overlay(alignment: .trailing) {
                        TrainingClock(training: training).font(focused ? StrandFont.bodyNumber : StrandFont.title1).multilineTextAlignment(.trailing)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
            }
            TrainingControls(training: training, labels: labels)
        }
        .padding(NoopMetrics.space4)
    }
}
