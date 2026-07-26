import SwiftUI

/// Compact strap-battery chrome that morphs into an activity indicator while history is syncing.
///
/// The indicator owns its visual transition so screens only provide honest battery and sync state.
/// Its expanded width participates in the surrounding layout, pushing earlier controls aside instead
/// of painting over them. Reduce Motion replaces the morph and continuous rotation with a static state.
public struct ChargeSyncIndicator: View {
    public enum BatteryState: Equatable {
        case offline
        case pending(charging: Bool)
        case charge(percent: Double, charging: Bool)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let batteryState: BatteryState
    private let syncing: Bool
    private let label: LocalizedStringKey

    @State private var visualProgress = 0.0
    @State private var pillProgress = 0.0
    @State private var endingSync = false
    @State private var animationActive = false
    @State private var showsLabel = false
    @State private var spinStartedAt: Date?
    @State private var exitStartDegrees = 0.0
    @State private var exitStartArc = 0.30
    @State private var announcementTask: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?

    public init(
        batteryState: BatteryState,
        syncing: Bool,
        label: LocalizedStringKey = "Syncing"
    ) {
        self.batteryState = batteryState
        self.syncing = syncing
        self.label = label
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            indicatorContents
                .frame(
                    width: NoopMetrics.compactControlSize,
                    height: NoopMetrics.compactControlSize
                )

            Text(label)
                .font(StrandFont.compactStatus)
                .foregroundStyle(StrandPalette.onDarkPrimary.opacity(0.92))
                .lineLimit(1)
                .fixedSize()
                .offset(
                    x: NoopMetrics.compactControlSize
                        + NoopMetrics.syncIndicatorLabelSpacing
                )
                .opacity(showsLabel ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(
            width: NoopMetrics.compactControlSize
                + (NoopMetrics.syncIndicatorExpandedWidth - NoopMetrics.compactControlSize)
                * CGFloat(pillProgress),
            height: NoopMetrics.compactControlSize,
            alignment: .leading
        )
        .background(
            Capsule(style: .continuous)
                .fill(StrandPalette.liquidControlSurface.opacity(0.72))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(StrandPalette.onDarkPrimary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onAppear { updateSyncState(syncing) }
        .onChangeCompat(of: syncing) { updateSyncState($0) }
        .onDisappear {
            announcementTask?.cancel()
            settleTask?.cancel()
        }
    }

    @ViewBuilder
    private var indicatorContents: some View {
        switch batteryState {
        case .charge(let percent, let charging):
            ChargeSyncMorph(
                progress: visualProgress,
                ending: endingSync,
                active: animationActive,
                reducedMotion: reduceMotion,
                percent: percent,
                charging: charging,
                batteryTint: ringColor(percent),
                spinStartedAt: spinStartedAt,
                exitStartDegrees: exitStartDegrees,
                exitStartArc: exitStartArc
            )
        default:
            ZStack {
                batteryContents.opacity(1 - visualProgress)
                syncingContents.opacity(visualProgress)
            }
        }
    }

    @ViewBuilder
    private var batteryContents: some View {
        switch batteryState {
        case .charge(let percent, let charging):
            Circle()
                .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                .stroke(
                    ringColor(percent),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(2.5)
            Text("\(Int(percent.rounded()))")
                .font(StrandFont.number(9, weight: .bold))
                .foregroundStyle(StrandPalette.onDarkPrimary.opacity(0.9))
            if charging {
                Image(systemName: "bolt.fill")
                    .font(StrandFont.number(7, weight: .bold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .offset(y: -10)
            }
        case .pending(let charging):
            Image(systemName: charging ? "bolt.fill" : "ellipsis")
                .font(StrandFont.number(charging ? 11 : 9, weight: .bold))
                .foregroundStyle(
                    charging
                        ? StrandPalette.chargeColor
                        : StrandPalette.onDarkPrimary.opacity(0.5)
                )
        case .offline:
            Image(systemName: "bolt.slash")
                .font(StrandFont.number(11))
                .foregroundStyle(StrandPalette.onDarkPrimary.opacity(0.5))
        }
    }

    private var syncingContents: some View {
        TimelineView(
            .animation(
                minimumInterval: StrandMotion.syncIndicatorFrameInterval,
                paused: !animationActive || reduceMotion
            )
        ) { timeline in
            let phase = syncPhase(at: timeline.date)
            ZStack {
                Circle()
                    .stroke(StrandPalette.liquidHeart.opacity(0.13), lineWidth: 2.4)
                    .padding(NoopMetrics.syncIndicatorArcInset)
                Circle()
                    .trim(from: 0, to: phase.arc)
                    .stroke(
                        StrandPalette.liquidHeart,
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(phase.degrees - 90))
                    .padding(NoopMetrics.syncIndicatorArcInset)
            }
        }
    }

    private func updateSyncState(_ active: Bool) {
        announcementTask?.cancel()
        settleTask?.cancel()

        if active {
            beginSync()
        } else {
            endSync()
        }
    }

    private func beginSync() {
        endingSync = false

        if !animationActive {
            spinStartedAt = Date()
            animationActive = true
            showsLabel = false
            animate(reduceMotion ? nil : StrandMotion.syncIndicatorVisual) {
                visualProgress = 1
            }
            animate(reduceMotion ? nil : StrandMotion.syncIndicatorMorph) {
                pillProgress = 1
            }
        } else {
            animate(reduceMotion ? nil : StrandMotion.syncIndicatorVisual) {
                visualProgress = 1
            }
        }

        if reduceMotion {
            showsLabel = true
        }

        announcementTask = Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(
                    nanoseconds: StrandMotion.syncIndicatorLabelDelayNanoseconds
                )
                guard !Task.isCancelled else { return }
                animate(StrandMotion.syncIndicatorLabelIn) { showsLabel = true }
            }

            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorLabelVisibilityNanoseconds
            )
            guard !Task.isCancelled else { return }
            animate(reduceMotion ? nil : StrandMotion.syncIndicatorLabelOut) {
                showsLabel = false
            }
            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorCollapseDelayNanoseconds
            )
            guard !Task.isCancelled else { return }
            animate(reduceMotion ? nil : StrandMotion.syncIndicatorMorph) {
                pillProgress = 0
            }
        }
    }

    private func endSync() {
        guard animationActive else {
            visualProgress = 0
            pillProgress = 0
            showsLabel = false
            return
        }

        if reduceMotion {
            visualProgress = 0
            pillProgress = 0
            showsLabel = false
            animationActive = false
            spinStartedAt = nil
            endingSync = false
            return
        }

        let phase = syncPhase(at: Date())
        exitStartDegrees = phase.degrees
        exitStartArc = phase.arc
        endingSync = true
        animate(StrandMotion.syncIndicatorMorph) {
            showsLabel = false
            pillProgress = 0
        }
        animate(StrandMotion.syncIndicatorVisual) {
            visualProgress = 0
        }

        settleTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorSettleNanoseconds
            )
            guard !Task.isCancelled else { return }
            animationActive = false
            spinStartedAt = nil
            endingSync = false
        }
    }

    private func syncPhase(at date: Date) -> (degrees: Double, arc: Double) {
        guard !reduceMotion else { return (0, 0.38) }
        let seconds = max(0, date.timeIntervalSince(spinStartedAt ?? date))
        let degrees = (seconds / StrandMotion.syncIndicatorSpinPeriod) * 360
        let breath = (
            sin(
                seconds * .pi * 2 / StrandMotion.syncIndicatorArcBreathPeriod
                    - .pi / 2
            ) + 1
        ) / 2
        return (degrees, 0.30 + breath * 0.16)
    }

    private func animate(_ animation: Animation?, changes: () -> Void) {
        withAnimation(animation, changes)
    }

    private func ringColor(_ percent: Double) -> Color {
        if percent < 15 { return StrandPalette.statusCritical }
        if percent < 35 { return StrandPalette.statusWarning }
        return StrandPalette.chargeColor
    }
}

private struct ChargeSyncMorph: View, Animatable {
    var progress: Double
    let ending: Bool
    let active: Bool
    let reducedMotion: Bool
    let percent: Double
    let charging: Bool
    let batteryTint: Color
    let spinStartedAt: Date?
    let exitStartDegrees: Double
    let exitStartArc: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: StrandMotion.syncIndicatorFrameInterval,
                paused: !active || reducedMotion
            )
        ) { timeline in
            let p = max(0, min(1, progress))
            let phase = syncPhase(at: timeline.date)
            let batteryArc = max(0.02, min(1, percent / 100))

            if ending {
                exitBody(progress: p, batteryArc: batteryArc)
            } else {
                entryBody(
                    progress: p,
                    batteryArc: batteryArc,
                    spinnerArc: phase.arc,
                    spinDegrees: phase.degrees
                )
            }
        }
    }

    private func exitBody(progress: Double, batteryArc: Double) -> some View {
        let exit = 1 - progress
        let eased = smoothStep(exit)
        let remainder = exitStartDegrees.truncatingRemainder(dividingBy: 360)
        let degreesToTop = remainder == 0 ? 0 : 360 - remainder
        let degrees = exitStartDegrees + degreesToTop * eased
        let arc = exitStartArc + (batteryArc - exitStartArc) * eased
        let inset = CGFloat(5.5 - 3.0 * eased)
        let lineWidth = CGFloat(2.6 + 0.4 * eased)

        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(0.13 * progress),
                    lineWidth: 2.4
                )
                .padding(inset)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    StrandPalette.liquidHeart,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
                .opacity(progress)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    batteryTint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
                .opacity(1 - progress)
            batteryNumber(opacity: 1 - progress)
        }
    }

    private func entryBody(
        progress: Double,
        batteryArc: Double,
        spinnerArc: Double,
        spinDegrees: Double
    ) -> some View {
        let eased = smoothStep(progress)
        let arc = batteryArc + (spinnerArc - batteryArc) * eased
        let degrees = reducedMotion ? 0 : spinDegrees * eased
        let inset = CGFloat(2.5 + 3.0 * eased)
        let lineWidth = CGFloat(3.0 - 0.4 * eased)

        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(0.13 * progress),
                    lineWidth: 2.4
                )
                .padding(inset)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    batteryTint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
                .opacity(1 - progress)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    StrandPalette.liquidHeart,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
                .opacity(progress)
            batteryNumber(opacity: 1 - progress)
        }
    }

    @ViewBuilder
    private func batteryNumber(opacity: Double) -> some View {
        Text("\(Int(percent.rounded()))")
            .font(StrandFont.number(9, weight: .bold))
            .foregroundStyle(StrandPalette.onDarkPrimary.opacity(0.9))
            .scaleEffect(0.92 + 0.08 * opacity)
            .opacity(opacity)
        if charging {
            Image(systemName: "bolt.fill")
                .font(StrandFont.number(7, weight: .bold))
                .foregroundStyle(StrandPalette.chargeColor)
                .offset(y: -10)
                .opacity(opacity)
        }
    }

    private func syncPhase(at date: Date) -> (degrees: Double, arc: Double) {
        guard !reducedMotion else { return (0, 0.38) }
        let seconds = max(0, date.timeIntervalSince(spinStartedAt ?? date))
        let degrees = (seconds / StrandMotion.syncIndicatorSpinPeriod) * 360
        let breath = (
            sin(
                seconds * .pi * 2 / StrandMotion.syncIndicatorArcBreathPeriod
                    - .pi / 2
            ) + 1
        ) / 2
        return (degrees, 0.30 + breath * 0.16)
    }

    private func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}

public extension View {
    /// Fades long header copy underneath a trailing control row while reserving its expanded footprint.
    func headerTrailingControlFadeMask() -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: NoopMetrics.headerTextFadeWidth)
                Color.clear.frame(width: NoopMetrics.headerControlReserveWidth)
            }
        }
    }
}

#if DEBUG
private struct ChargeSyncIndicatorPreview: View {
    @State private var syncing = false
    private let greeting = "Good evening, Maximilian Alexander"
    private var toggleTitle: String {
        syncing ? "Finish sync" : "Start sync"
    }

    var body: some View {
        VStack(spacing: NoopMetrics.space5) {
            HStack(spacing: NoopMetrics.space2) {
                Text(verbatim: greeting)
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                    .lineLimit(2)
                    .headerTrailingControlFadeMask()
                HStack(spacing: NoopMetrics.space2) {
                    Circle()
                        .fill(StrandPalette.onDarkPrimary.opacity(0.16))
                        .frame(
                            width: NoopMetrics.compactControlSize,
                            height: NoopMetrics.compactControlSize
                        )
                    ChargeSyncIndicator(
                        batteryState: .charge(percent: 68, charging: false),
                        syncing: syncing
                    )
                    Circle()
                        .fill(StrandPalette.onDarkPrimary.opacity(0.16))
                        .frame(
                            width: NoopMetrics.compactControlSize,
                            height: NoopMetrics.compactControlSize
                        )
                }
            }

            Button {
                syncing.toggle()
            } label: {
                Text(verbatim: toggleTitle)
            }
            .font(StrandFont.body)
        }
        .padding(NoopMetrics.space5)
        .frame(width: 440, height: 180)
        .background(StrandPalette.accent)
        .preferredColorScheme(.dark)
    }
}

#Preview("Charge to sync morph") {
    ChargeSyncIndicatorPreview()
}

#Preview("Charge sync active") {
    ChargeSyncIndicator(
        batteryState: .charge(percent: 68, charging: false),
        syncing: true
    )
    .padding(NoopMetrics.space5)
    .background(StrandPalette.accent)
    .preferredColorScheme(.dark)
}
#endif
