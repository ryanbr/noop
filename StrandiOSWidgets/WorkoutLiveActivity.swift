import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for a live-tracked workout — on the Lock Screen and in the Dynamic Island.
///
/// The Lock Screen answers what a runner glances down for: how long, how far, how fast, and the heart rate.
/// A workout with no GPS route (strength, yoga) shows time and heart rate only.
///
/// THE CLOCK TICKS WITHOUT THE APP. The timer is `Text(_:style: .timer)` from a date in the content state, so the
/// Lock Screen counts on its own between pushes; the app pushes only when the heart rate, distance or pace moves,
/// or the workout pauses or resumes (`WorkoutLiveActivityController`).
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            lockScreen(context)
                .padding()
                .activityBackgroundTint(StrandPalette.surfaceBase)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(a.sport, systemImage: Self.symbol(a.sport))
                        .font(.caption).lineLimit(1)
                        .foregroundStyle(StrandPalette.effortColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    heartRate(s.bpm).font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .top, spacing: 0) {
                        column(a.durationLabel, size: 20) { timer(s) }
                        if a.tracksRoute {
                            column(a.distanceLabel, size: 20) { Text(s.distance ?? "—") }
                            column(a.paceLabel, size: 20) { Text(s.pace ?? "—") }
                        }
                    }
                }
            } compactLeading: {
                // Sport glyph + the running clock, so the island reads as a workout at a glance.
                HStack(spacing: 4) {
                    Image(systemName: Self.symbol(a.sport)).foregroundStyle(StrandPalette.effortColor)
                    timer(s).monospacedDigit().frame(maxWidth: 56)
                }
            } compactTrailing: {
                // Pace once the GPS has one; the heart rate until then, and for a workout with no route.
                if a.tracksRoute, let pace = s.pace {
                    Text(pace).monospacedDigit().foregroundStyle(StrandPalette.effortColor)
                } else {
                    Text(s.bpm.map(String.init) ?? "—").monospacedDigit().foregroundStyle(StrandPalette.metricRose)
                }
            } minimal: {
                Image(systemName: Self.symbol(a.sport)).foregroundStyle(StrandPalette.effortColor)
            }
        }
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        let a = context.attributes, s = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(a.sport))
                    .font(.headline)
                    .foregroundStyle(StrandPalette.effortColor)
                Text(a.sport)
                    .font(.headline).lineLimit(1)
                    .foregroundStyle(StrandPalette.textPrimary)
                if s.pausedElapsed != nil {
                    Text(a.pausedLabel)
                        .font(.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                heartRate(s.bpm).font(.headline)
            }
            HStack(alignment: .top, spacing: 0) {
                column(a.durationLabel, size: 24) { timer(s) }
                if a.tracksRoute {
                    column(a.distanceLabel, size: 24) { Text(s.distance ?? "—") }
                    column(a.paceLabel, size: 24) { Text(s.pace ?? "—") }
                }
            }
        }
    }

    /// One equal-width column: a small label over a large value.
    private func column<V: View>(_ label: String, size: CGFloat, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(StrandPalette.textSecondary)
            value()
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heartRate(_ bpm: Int?) -> some View {
        Label {
            Text(bpm.map(String.init) ?? "—").monospacedDigit()
        } icon: {
            Image(systemName: "heart.fill")
        }
        .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.metricRose)
    }

    /// Running: iOS counts up by itself from `timerStart`. Paused: the frozen active time.
    @ViewBuilder
    private func timer(_ s: WorkoutActivityAttributes.ContentState) -> some View {
        if let paused = s.pausedElapsed {
            Text(Self.formatElapsed(paused))
        } else {
            Text(s.timerStart, style: .timer)
        }
    }

    /// "m:ss" under an hour, "h:mm:ss" from then on — the same shape as the `.timer` style it stands in for.
    static func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, sec = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// An SF Symbol for the catalogue's distance sports, and a generic one for everything else.
    static func symbol(_ sport: String) -> String {
        let s = sport.lowercased()
        if s.contains("walk") { return "figure.walk" }
        if s.contains("hik") { return "figure.hiking" }
        if s.contains("cycl") || s.contains("bike") || s.contains("ride") { return "figure.outdoor.cycle" }
        if s.contains("swim") { return "figure.open.water.swim" }
        if s.contains("row") { return "figure.rower" }
        if s.contains("run") { return "figure.run" }
        return "figure.mixed.cardio"
    }
}
