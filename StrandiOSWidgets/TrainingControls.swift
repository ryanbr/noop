import SwiftUI
import WidgetKit
import StrandDesign

struct TrainingControls: View {
    let training: TrainingDisplay
    let labels: [String: String]
    var compact = false
    var iconsOnly = false
    @Environment(\.widgetRenderingMode) private var renderingMode
    private func label(_ key: String) -> String { labels[key] ?? "" }
    private var textColor: Color { renderingMode == .fullColor ? StrandPalette.textPrimary : StrandPalette.onDarkPrimary }
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            if let error = training.error {
                Text(error).font(StrandFont.footnote).foregroundStyle(StrandPalette.metricAmber).lineLimit(2)
            }
            if training.isConfirming(), let token = training.confirmationToken {
                Text(label("confirm")).font(StrandFont.caption.weight(.semibold)).foregroundStyle(textColor)
                if training.kind == "lift" && !compact {
                    let warning = label("completedOnly")
                    Text(verbatim: warning).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                HStack(spacing: NoopMetrics.space2) {
                    button(.confirmEnd, title: label("yes"), symbol: "checkmark", token: token, destructive: true)
                    button(.cancelEnd, title: label("cancel"), symbol: "xmark")
                }
            } else {
                HStack(spacing: NoopMetrics.space2) {
                    Toggle(isOn: training.pausedAt != nil,
                           intent: TrainingActionIntent(training.pausedAt == nil ? .pause : .resume, sessionID: training.id)) {
                        Text(label(training.pausedAt == nil ? "pause" : "resume"))
                    }
                    .toggleStyle(PauseStyle(controls: self))
                    button(.requestEnd, title: label("end"), symbol: "stop.fill")
                }
            }
        }
        .font(StrandFont.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    private func button(_ action: TrainingAction, title: String, symbol: String, token: String = "",
                        destructive: Bool = false) -> some View {
        Button(intent: TrainingActionIntent(action, sessionID: training.id, token: token)) {
            buttonLabel(title: title, symbol: symbol, destructive: destructive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(action == .confirmEnd && training.kind == "lift" ? label("completedOnly") : "")
    }
    private func buttonLabel(title: String, symbol: String, emphasized: Bool = false, destructive: Bool = false) -> some View {
        let icon = destructive ? StrandPalette.statusCritical : emphasized ? StrandPalette.accent : StrandPalette.textPrimary
        let fill = destructive ? StrandPalette.statusCritical.opacity(0.18) : emphasized ? StrandPalette.accentMuted : StrandPalette.surfaceRaised
        return HStack(spacing: NoopMetrics.space1) {
            if !compact || iconsOnly {
                Image(systemName: symbol)
                    .foregroundStyle(renderingMode == .fullColor ? icon : StrandPalette.onDarkPrimary)
            }
            if !iconsOnly { Text(title) }
        }
        .font(StrandFont.caption.weight(.semibold))
        .padding(.horizontal, NoopMetrics.space2)
        .frame(minWidth: iconsOnly ? NoopButtonMetrics.minHitTarget : nil, maxWidth: .infinity,
               minHeight: compact ? NoopMetrics.compactMetadataMinHeight : NoopButtonMetrics.minHitTarget)
        .foregroundStyle(textColor)
        .background(renderingMode == .fullColor ? fill : StrandPalette.hairlineStrong, in: Capsule())
    }
    private struct PauseStyle: ToggleStyle {
        let controls: TrainingControls
        func makeBody(configuration: Configuration) -> some View {
            let title = controls.label(configuration.isOn ? "resume" : "pause")
            Button { configuration.isOn.toggle() } label: {
                controls.buttonLabel(title: title, symbol: configuration.isOn ? "play.fill" : "pause.fill", emphasized: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }
}

struct TrainingClock: View {
    let training: TrainingDisplay
    @Environment(\.widgetRenderingMode) private var renderingMode
    var body: some View {
        Text(timerInterval: training.clockStart...max(training.clockStart, training.pulseDeadline ?? training.clockStart.addingTimeInterval(7 * 86_400)),
             pauseTime: training.pausedAt, countsDown: false)
            .monospacedDigit()
            .foregroundStyle(renderingMode == .fullColor ? StrandPalette.textPrimary : StrandPalette.onDarkPrimary)
    }
}
