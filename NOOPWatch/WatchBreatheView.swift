import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// MARK: - WatchBreatheView — wrist-native catalog-driven breathing
//
// Reimplements the phone Breathe trainer on-watch: [BreathProtocolCatalog.watchSubset] protocols,
// stage-accurate inhale/hold/exhale pacing, session length Open/5/10/15 with auto-stop, and Taptic cues
// (one tap inhale, double exhale; holds silent). Zero-arg init; nav lane wires it by name.

struct WatchBreatheView: View {

    private enum SessionLength: Hashable, CaseIterable {
        case open, five, ten, fifteen

        var label: String {
            switch self {
            case .open: return String(localized: "Open")
            case .five: return String(localized: "5m")
            case .ten: return String(localized: "10m")
            case .fifteen: return String(localized: "15m")
            }
        }

        var targetSeconds: Int? {
            switch self {
            case .open: return nil
            case .five: return 5 * 60
            case .ten: return 10 * 60
            case .fifteen: return 15 * 60
            }
        }

        static func from(recommendedMs: Int) -> SessionLength {
            switch recommendedMs {
            case ..<(7 * 60_000): return .five
            case ..<(12 * 60_000): return .ten
            default: return .fifteen
            }
        }
    }

    private enum Phase { case inhale, hold, exhale, textOnly }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var protocolId: String = "coherence_5_5"
    @State private var sessionLength: SessionLength = .ten
    @State private var running = false

    @State private var ringProgress: CGFloat = 0
    @State private var phase: Phase = .inhale
    @State private var phaseLabel: String? = nil
    @State private var stageIndex: Int = 0
    @State private var phaseDeadline: Date = .distantFuture
    @State private var phaseStart: Date = Date()
    @State private var phaseRemaining: Int = 0

    @State private var breathCount = 0
    @State private var sessionSeconds = 0

    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let reducedSteadyRing: CGFloat = 0.5

    private var protocols: [BreathProtocol] { BreathProtocolCatalog.watchSubset }

    private var selectedProtocol: BreathProtocol? {
        BreathProtocolCatalog.protocolById(protocolId)
    }

    private var isGuided: Bool { selectedProtocol?.mode == .guided }

    private var selectedBpm: Double {
        guard let proto = selectedProtocol, proto.cycleDurationMs > 0 else { return 0 }
        return 60_000.0 / Double(proto.cycleDurationMs)
    }

    var body: some View {
        GeometryReader { geo in
            let totalH = geo.size.height
            let totalW = geo.size.width
            let vSpacing: CGFloat = 4

            let headerH: CGFloat = 14
            let lengthH: CGFloat = 26
            let pillsH: CGFloat = 28
            let controlH: CGFloat = 36
            let reserved = headerH + lengthH + pillsH + controlH + vSpacing * 4

            let remaining = max(totalH - reserved, 36)
            let ringSide = min(min(totalW, remaining), 140)

            VStack(spacing: vSpacing) {
                paceLine
                    .frame(height: headerH)
                sessionLengthPicker
                    .frame(height: lengthH)
                ring(side: ringSide)
                Spacer(minLength: 0)
                pacePicker
                    .frame(height: pillsH)
                control
                    .frame(height: controlH)
            }
            .frame(width: totalW, height: totalH)
            .padding(.horizontal, 4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onReceive(phaseTimer) { now in
            guard running else { return }
            advance(now: now)
            updateCountdown(now: now)
        }
        .onReceive(secondTimer) { _ in
            guard running else { return }
            sessionSeconds += 1
            if let target = sessionLength.targetSeconds, sessionSeconds >= target {
                stop()
            }
        }
        .onChange(of: protocolId) { newId in
            if running { stop() }
            if let proto = BreathProtocolCatalog.protocolById(newId) {
                sessionLength = SessionLength.from(recommendedMs: proto.recommendedDurationMs)
            }
        }
        .onDisappear { stop() }
    }

    // MARK: - Ring

    private func ring(side: CGFloat) -> some View {
        let maxDiameter = side
        let minScale: CGFloat = 0.46
        let scale = minScale + (1.0 - minScale) * ringProgress
        let guideDiameter = maxDiameter * scale

        return ZStack {
            Circle()
                .strokeBorder(StrandPalette.restColor.opacity(0.26), lineWidth: 1)
                .frame(width: maxDiameter, height: maxDiameter)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [StrandPalette.restBright.opacity(0.85),
                                 StrandPalette.restColor.opacity(0.55),
                                 StrandPalette.restDeep.opacity(0.80)],
                        center: .init(x: 0.4, y: 0.35),
                        startRadius: 1,
                        endRadius: guideDiameter * 0.62
                    )
                )
                .frame(width: guideDiameter, height: guideDiameter)

            Circle()
                .strokeBorder(StrandPalette.restBright.opacity(running ? 0.70 : 0.40), lineWidth: 2)
                .frame(width: guideDiameter, height: guideDiameter)

            centerLabel
        }
        .frame(width: maxDiameter, height: maxDiameter)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var centerLabel: some View {
        VStack(spacing: 2) {
            if running {
                Text(phaseWord)
                    .font(StrandFont.rounded(14, weight: .semibold))
                    .foregroundStyle(StrandPalette.restBright)
                    .animation(.easeInOut(duration: 0.2), value: phase)
                if !isGuided {
                    Text("\(max(phaseRemaining, 0))")
                        .font(StrandFont.number(26))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else {
                Text("Breathe")
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if selectedBpm > 0 {
                    Text(String(format: String(localized: "%@ br/min"), String(format: "%.1f", selectedBpm)))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else if isGuided {
                    Text(String(localized: "Guided"))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running ? phaseAccessibilityLabel : String(localized: "Ready to breathe"))
    }

    private var phaseWord: String {
        if let phaseLabel, !phaseLabel.isEmpty {
            return phaseLabel
        }
        switch phase {
        case .inhale: return String(localized: "Breathe in")
        case .hold: return String(localized: "Hold")
        case .exhale: return String(localized: "Breathe out")
        case .textOnly: return String(localized: "Follow cue")
        }
    }

    private var phaseAccessibilityLabel: String {
        let secs = max(phaseRemaining, 0)
        switch phase {
        case .inhale: return String(localized: "Breathe in for \(secs) seconds")
        case .hold: return String(localized: "Hold for \(secs) seconds")
        case .exhale: return String(localized: "Breathe out for \(secs) seconds")
        case .textOnly: return String(localized: "Follow the guided cue")
        }
    }

    // MARK: - Pickers

    private var paceLine: some View {
        Text(running ? sessionReadout : idlePaceLine)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }

    private var sessionReadout: String {
        if let target = sessionLength.targetSeconds {
            return String(localized: "\(breathCount) breaths · \(timeString(sessionSeconds))/\(timeString(target))")
        }
        return String(localized: "\(breathCount) breaths · \(timeString(sessionSeconds))")
    }

    private var idlePaceLine: String {
        let title = selectedProtocol.map { watchLabel(for: $0) } ?? protocolId
        if isGuided {
            return String(localized: "\(title) · guided")
        }
        return String(localized: "\(title) · \(sessionLength.label)")
    }

    private var sessionLengthPicker: some View {
        HStack(spacing: 4) {
            ForEach(SessionLength.allCases, id: \.self) { len in
                Button {
                    StrandHaptic.selection.play()
                    sessionLength = len
                } label: {
                    Text(len.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(len == sessionLength ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(len == sessionLength ? StrandPalette.restColor.opacity(0.22) : StrandPalette.surfaceRaised)
                        )
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
        }
    }

    private var pacePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(protocols, id: \.id) { proto in
                    Button {
                        StrandHaptic.selection.play()
                        protocolId = proto.id
                    } label: {
                        Text(watchLabel(for: proto))
                            .font(StrandFont.caption)
                            .foregroundStyle(proto.id == protocolId ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(proto.id == protocolId ? StrandPalette.restColor.opacity(0.22) : StrandPalette.surfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(proto.id == protocolId ? StrandPalette.restBright.opacity(0.6) : Color.clear,
                                                  lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func watchLabel(for proto: BreathProtocol) -> String {
        switch proto.id {
        case "relax_4_6": return String(localized: "Relax")
        case "coherence_5_5": return String(localized: "Coherence")
        case "box_4_4_4_4": return String(localized: "Box")
        case "deep_4_2_6": return String(localized: "Deep")
        case "four_seven_eight": return String(localized: "4-7-8")
        case "coherent_6_6": return String(localized: "6-6")
        case "presence_regular": return String(localized: "Regular")
        case "presence_mid": return String(localized: "Mid")
        case "presence_punching": return String(localized: "Push")
        default:
            return String(proto.title.split(separator: " ").first ?? Substring(proto.title))
        }
    }

    // MARK: - Control

    private var control: some View {
        Button {
            running ? stop() : start()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(running ? String(localized: "Stop") : String(localized: "Start"))
                    .font(StrandFont.rounded(14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(running ? StrandPalette.statusCritical.opacity(0.22)
                                  : StrandPalette.restColor.opacity(0.28))
            )
            .foregroundStyle(running ? StrandPalette.statusCritical : StrandPalette.restBright)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? String(localized: "Stop session") : String(localized: "Start session"))
    }

    // MARK: - Session engine

    private func currentStages() -> [BreathStage] {
        selectedProtocol?.stages.filter { $0.durationMs > 0 } ?? []
    }

    private func start() {
        running = true
        sessionSeconds = 0
        breathCount = 0
        stageIndex = 0
        phaseLabel = nil
        StrandHaptic.success.play()
        if isGuided {
            phase = .textOnly
            phaseLabel = selectedProtocol?.title
            phaseDeadline = .distantFuture
            if reduceMotion { ringProgress = reducedSteadyRing } else { ringProgress = reducedSteadyRing }
        } else {
            armCurrentStage(from: Date(), buzz: true)
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        phaseDeadline = .distantFuture
        phaseLabel = nil
        StrandHaptic.commit.play()
        if reduceMotion {
            ringProgress = 0
        } else {
            withAnimation(.easeInOut(duration: 0.7)) { ringProgress = 0 }
        }
    }

    private func armCurrentStage(from now: Date, buzz: Bool) {
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let stage = stages[stageIndex % stages.count]
        switch stage.type {
        case .inhale: phase = .inhale
        case .hold: phase = .hold
        case .exhale: phase = .exhale
        case .textOnly: phase = .textOnly
        }
        phaseLabel = stage.label
        let duration = Double(stage.durationMs) / 1000.0
        phaseStart = now
        phaseDeadline = now.addingTimeInterval(duration)
        phaseRemaining = Int(duration.rounded(.up))

        if reduceMotion {
            ringProgress = reducedSteadyRing
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                switch phase {
                case .inhale: ringProgress = 1.0
                case .exhale: ringProgress = 0.0
                case .hold, .textOnly: break
                }
            }
        }

        if buzz {
            let loops = BreathProtocolPlayer.loops(for: stage.type)
            if loops > 0 {
                StrandHaptic.light.play()
                if loops >= 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        StrandHaptic.light.play()
                    }
                }
            }
        }
    }

    private func advance(now: Date) {
        guard !isGuided else { return }
        guard now >= phaseDeadline else { return }
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let completed = stages[stageIndex % stages.count]
        stageIndex += 1
        if completed.type == .exhale { breathCount += 1 }
        armCurrentStage(from: now, buzz: true)
    }

    private func updateCountdown(now: Date) {
        let left = phaseDeadline.timeIntervalSince(now)
        phaseRemaining = max(0, Int(left.rounded(.up)))
    }

    private func timeString(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
    }
}
