import SwiftUI
import Foundation
import AVFoundation
import StrandDesign
import StrandAnalytics

/// HRV haptic breathing biofeedback trainer — Strand's flagship novel feature, now a closed-loop
/// biofeedback instrument with three layers (v5 "the strap that breathes you down").
///
/// The strap both *measures* HRV (via R-R intervals) and *buzzes* (haptic strap motor), so we can pace
/// the user's breath with a felt cue and watch their HRV respond in real time — and now also *find* the
/// user's personal resonance pace (L1) and offer a below-HR "Calm me" metronome (L2). A passive stress
/// check-in card (L3) surfaces when the shipped StressOnsetDetector fires. All layers are opt-in,
/// user-stoppable, and quiet-hours-aware.
///
/// Mode switch:
///  • **Breathe** — the shipped fixed-pace trainer (presets + the locked resonance pill), unchanged.
///  • **Resonance** — the one-time "find your pace" sweep + the dated result card.
///  • **Calm me** — the L2 below-HR relaxation metronome.
///
/// Public entry point keeps its zero-arg init (every existing call site — RootView, RootTabView,
/// StressView — constructs `BreathingView()`), then defers to `BreathingContent` once the environment's
/// `AppModel`/`LiveState` are available so the `BiofeedbackController` `@StateObject` can be built from
/// them. The L3 `StressNudgeCenter` is OPTIONAL via the environment: Wave 3 injects a shared instance;
/// absent that we fall back to a local one, so the view always compiles + the card surface always exists.
struct BreathingView: View {
    var body: some View { BreathingContent() }
}

private struct BreathingContent: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// When the user has Reduce Motion on, the large repeating inhale/exhale orb zoom is
    /// suppressed — the breath is cued by the phase word + haptics instead. (a11y)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The L1/L2 session controller (walks the engines, fires the buzz path). View-owned, created lazily
    /// from the environment model + live state on first appear (a `@StateObject` can't read the
    /// environment at init, so we build it in `.onAppear`). Self-contained — the spec's view-specific
    /// controller; it never edits the shared AppModel.
    @StateObject private var controllerBox = ControllerBox()
    /// The L3 passive-nudge surface — Wave 3 injects a shared instance; this local fallback keeps the
    /// card surface present whether or not central wiring has landed.
    @StateObject private var fallbackNudge = StressNudgeCenter()
    @Environment(\.stressNudgeCenter) private var injectedNudge

    private var controller: BiofeedbackController { controllerBox.controller(model: model, live: live) }
    private var nudgeCenter: StressNudgeCenter { injectedNudge ?? fallbackNudge }

    // MARK: Mode

    private enum Mode: Hashable, CaseIterable {
        case breathe, resonance, calm
        var label: String {
            switch self {
            case .breathe:   return String(localized: "Breathe")
            case .resonance: return String(localized: "Resonance")
            case .calm:      return String(localized: "Calm me")
            }
        }
    }
    @State private var mode: Mode = .breathe

    // MARK: Pace presets (catalog + locked resonance)

    private enum PaceSelection: Hashable {
        case catalog(String)
        case resonance

        var label: String {
            switch self {
            case .catalog(let id):
                return String(localized: String.LocalizationValue(
                    BreathProtocolCatalog.protocolById(id)?.title ?? id))
            case .resonance:
                return String(localized: "Resonance")
            }
        }
    }

    private enum SessionLength: Hashable, CaseIterable {
        case open, five, ten, fifteen

        var label: String {
            switch self {
            case .open: return String(localized: "Open")
            case .five: return String(localized: "5 min")
            case .ten: return String(localized: "10 min")
            case .fifteen: return String(localized: "15 min")
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

    // MARK: State (fixed-pace Breathe — catalog-driven)

    @State private var pace: PaceSelection = .catalog("coherence_5_5")
    @State private var sessionLength: SessionLength = .ten
    @State private var showEdu = false
    @State private var running = false

    /// 0 = fully contracted, 1 = fully expanded. Drives the orb scale.
    @State private var orbProgress: CGFloat = 0
    @State private var phase: Phase = .inhale
    @State private var phaseLabel: String? = nil
    @State private var stageIndex: Int = 0
    @State private var phaseDeadline: Date = .distantFuture

    @State private var sessionSeconds: Int = 0
    @State private var breathCount: Int = 0

    /// Rolling buffer of the most recent R-R intervals (ms) for RMSSD.
    @State private var rrBuffer: [Int] = []
    @State private var rmssd: Double? = nil

    @State private var baselineRmssd: Double? = nil
    @State private var sessionRmssdSum: Double = 0
    @State private var sessionRmssdCount: Int = 0
    @State private var sessionRmssdPeak: Double = 0
    @State private var endedOutcome: String? = nil

    @AppStorage("breathe.lastOutcome") private var lastStoredOutcome = ""

    /// Opt-in audio pacer — a soft tone at each phase change (rising on the inhale, falling on the
    /// exhale). Default OFF (manual-first). The tones go through an ambient session category, so the
    /// iOS silent switch mutes them like any other ambient sound. Persists across launches.
    @AppStorage("breathe.audioCues") private var audioCues = false
    /// The on-device tone player. View-owned, lazily wired the first time the pacer is enabled, torn
    /// down on disappear so we never hold the audio session when off-screen.
    @StateObject private var tonePlayer = BreathTonePlayer()

    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let rrWindow = 30

    /// The user's locked resonance pace, read fresh each render (set by the sweep).
    private var lockedBpm: Double? { BiofeedbackPrefs.lockedPace }

    private var selectedProtocol: BreathProtocol? {
        if case .catalog(let id) = pace { return BreathProtocolCatalog.protocolById(id) }
        return nil
    }

    private var isGuided: Bool { selectedProtocol?.mode == .guided }

    private var selectedBpm: Double {
        if case .resonance = pace {
            return lockedBpm ?? ResonanceEngine.fallbackBpm
        }
        guard let proto = selectedProtocol, proto.cycleDurationMs > 0 else { return 0 }
        return 60_000.0 / Double(proto.cycleDurationMs)
    }

    private var selectedTagline: String {
        if case .resonance = pace {
            return String(localized: "Your locked pace · \(String(format: "%.1f", lockedBpm ?? ResonanceEngine.fallbackBpm)) br/min")
        }
        return String(localized: String.LocalizationValue(selectedProtocol?.subtitle ?? ""))
    }

    var body: some View {
        ScreenScaffold(title: "Breathe",
                       subtitle: "Haptic-paced breathing · find your pace · calm down",
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Breathe sits in one atmosphere.
                       topBackground: liquidScaffoldSky()) {

            modeSwitch
            StressCheckInCard(center: nudgeCenter) { startOneMinuteCue() }

            switch mode {
            case .breathe:   breatheMode
            case .resonance: ResonanceModeView(controller: controller, live: live, lockedBpm: lockedBpm)
            case .calm:      CalmModeView(controller: controller, live: live, model: model)
            }
        }
        .onReceive(phaseTimer) { now in
            guard running else { return }
            advance(now: now)
        }
        .onReceive(secondTimer) { _ in
            guard running else { return }
            sessionSeconds += 1
            if let target = sessionLength.targetSeconds, sessionSeconds >= target {
                stop()
            }
        }
        // rrSeq-keyed: equal consecutive packets both count (see RRPacketObserver.swift).
        .onRRPackets(live) { rr in
            ingest(rr)
        }
        .onChangeCompat(of: pace) { newPace in
            if running { stop() }
            if case .catalog(let id) = newPace,
               let proto = BreathProtocolCatalog.protocolById(id) {
                sessionLength = SessionLength.from(recommendedMs: proto.recommendedDurationMs)
            }
        }
        .sheet(isPresented: $showEdu) {
            breathEduSheet
        }
        .onChangeCompat(of: mode) { _ in
            // Leaving a mode stops any session it owns so two clocks never run at once.
            if running { stop() }
            controller.stop()
        }
        .onChangeCompat(of: audioCues) { on in
            // Spin the audio engine up the moment the user opts in (so the first phase tone isn't
            // swallowed by start-up latency); tear it back down when they switch it off.
            on ? tonePlayer.activate() : tonePlayer.deactivate()
        }
        .onAppear {
            controllerBox.prepare(model: model, live: live)
            if audioCues { tonePlayer.activate() }
        }
        .onDisappear { stop(); controller.stop(); tonePlayer.deactivate() }
    }

    // MARK: - Mode switch

    private var modeSwitch: some View {
        SegmentedPillControl(Mode.allCases, selection: $mode) { $0.label }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Breathe mode")
    }

    // MARK: - Breathe mode (the shipped fixed-pace trainer)

    @ViewBuilder private var breatheMode: some View {
        statusRow
        orbCard
        controlRow
        if let line = outcomeLine { outcomeCard(line) }
        readoutRow
        coherenceCard
        if !live.bonded { hapticHint }
    }

    /// Start a one-minute haptic breathing cue at the user's locked resonance pace (or 5.5 fallback) —
    /// the L3 card's "Breathe now" action. Switches to Resonance/Breathe context and runs the controller.
    private func startOneMinuteCue() {
        if running { stop() }
        let bpm = lockedBpm ?? ResonanceEngine.fallbackBpm
        let cycles = max(1, Int((60.0 * bpm / 60.0).rounded()))   // ~1 minute of breaths
        controller.startResonanceSession(bpm: bpm, cycles: cycles)
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatePill(running ? "Session live" : "Ready",
                      tone: running ? .accent : .neutral,
                      pulsing: running)

            if live.bonded {
                StatePill("Haptics on", tone: .positive, showsDot: true)
            } else {
                StatePill("Visual only", tone: .warning, showsDot: true)
            }

            Spacer()

            HStack(spacing: 6) {
                if let target = sessionLength.targetSeconds {
                    Text("\(timeString(sessionSeconds)) / \(timeString(target))")
                        .font(StrandFont.number(15))
                        .foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text(timeString(sessionSeconds))
                        .font(StrandFont.number(15))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("·").foregroundStyle(StrandPalette.textTertiary)
                Text("\(breathCount) breaths")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - The orb

    private var orbCard: some View {
        StrandCard(padding: 24, tint: StrandPalette.restColor) {
            VStack(spacing: 18) {
                HStack {
                    Text(pace.label.uppercased()).strandOverline()
                    Spacer()
                    Button {
                        showEdu = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityLabel(String(localized: "Protocol info"))
                    if selectedBpm > 0 {
                        Text(String(format: "%.1f br/min", selectedBpm))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else if isGuided {
                        Text(String(localized: "Guided"))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                ZStack {
                    ScenicHeroBackground(domain: .rest, starCount: 56)
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                    breathingOrb
                        .padding(.vertical, 6)
                }
                .frame(height: 320)
                .frame(maxWidth: .infinity)

                Text(running ? phaseWord : selectedTagline)
                    .font(StrandFont.subhead)
                    .foregroundStyle(running ? StrandPalette.restBright : StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.2), value: phaseWord)
                    .animation(.easeInOut(duration: 0.2), value: running)

                pacePills
                durationPills
                audioCueToggle
            }
        }
    }

    /// Opt-in audio pacer toggle, sitting on the orb card so it reads as part of the breathing setup.
    /// Default off; flipping it primes/tears down the tone engine via the onChange hook above.
    private var audioCueToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: audioCues ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(audioCues ? StrandPalette.restBright : StrandPalette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audio cues")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Soft tone on each phase · respects silent mode")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $audioCues)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel("Audio cues")
        }
    }

    private var availablePaces: [PaceSelection] {
        var items = BreathProtocolCatalog.pickerProtocols.map { PaceSelection.catalog($0.id) }
        if lockedBpm != nil { items.append(.resonance) }
        return items
    }

    private var pacePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentedPillControl(availablePaces, selection: $pace) { $0.label }
        }
    }

    private var durationPills: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Session length"))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                SegmentedPillControl(SessionLength.allCases, selection: $sessionLength) { $0.label }
            }
            .disabled(running)
        }
    }

    private var phaseWord: String {
        if let phaseLabel, !phaseLabel.isEmpty {
            return String(localized: String.LocalizationValue(phaseLabel))
        }
        switch phase {
        case .inhale: return String(localized: "Breathe in…")
        case .hold: return String(localized: "Hold…")
        case .exhale: return String(localized: "Breathe out…")
        case .textOnly: return String(localized: "Follow the cue…")
        }
    }

    private var breathEduSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let proto = selectedProtocol {
                        Text(String(localized: String.LocalizationValue(proto.title)))
                            .font(StrandFont.title2)
                        Text(String(localized: String.LocalizationValue(proto.subtitle)))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if proto.category == .presence {
                            Text(String(localized: String.LocalizationValue(BreathProtocolCatalog.presenceIntroTitle)))
                                .font(StrandFont.headline)
                            Text(String(localized: String.LocalizationValue(BreathProtocolCatalog.presenceIntroBody)))
                                .font(StrandFont.body)
                        }
                        Text(String(localized: String.LocalizationValue(proto.edu)))
                            .font(StrandFont.body)
                        if let hint = proto.sessionHint {
                            Text(String(localized: String.LocalizationValue(hint)))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        if let caution = proto.caution {
                            Text(String(localized: String.LocalizationValue(caution)))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                        Text(String(localized: "Estimate only — not medical advice. Stop if you feel unwell."))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        Text(String(localized: "Your locked resonance pace from the Resonance sweep."))
                            .font(StrandFont.body)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // #697 parity: this screen builds its OWN ScrollView rather than going through
            // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression and
            // could still rubber-band left-right on a purely vertical scroll. Same modifier, same
            // guard. `.basedOnSize` permits horizontal bounce only when content genuinely overflows
            // the width, so nothing that is meant to scroll sideways is affected. (#1532 follow-up)
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .navigationTitle(String(localized: "About this pace"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { showEdu = false }
                }
            }
        }
    }

    private var breathingOrb: some View {
        GeometryReader { geo in
            let maxDiameter = min(geo.size.width, geo.size.height)
            // The breath ring — the resting track the vessel breathes within. Crisp 1px stroke, no glow.
            ZStack {
                Circle()
                    .strokeBorder(StrandPalette.restColor.opacity(0.28), lineWidth: 1)
                    .frame(width: maxDiameter, height: maxDiameter)

                // The pacer is now the canonical liquid vessel: it FILLS on the inhale and drains on the
                // exhale as `orbProgress` (0 contracted → 1 expanded) drives the level, so the breath is
                // cued by water rising and falling rather than a swelling disc. Rest-tinted to match the
                // world; under Reduce Motion `orbProgress` parks at a steady mid-level (no pulsing), and
                // the phase word + haptics still carry the pace.
                LiquidVessel(value: orbProgress, tint: StrandPalette.restColor, animated: running)
                    .frame(width: maxDiameter, height: maxDiameter)

                VStack(spacing: 2) {
                    if let bpm = model.bpm {
                        CountUpText(value: Double(bpm),
                                    format: { "\(Int($0.rounded()))" },
                                    font: StrandFont.number(40),
                                    color: StrandPalette.textPrimary)
                    } else {
                        Text("—")
                            .font(StrandFont.number(40))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(String(localized: "BPM"))
                        .font(StrandFont.footnote)
                        .tracking(0.8)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .allowsHitTesting(false)   // taps fall through to the vessel → splash
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton(running ? "Stop session" : "Start session",
                       systemImage: running ? "stop.fill" : "play.fill",
                       kind: running ? .destructive : .primary, fullWidth: true) {
                running ? stop() : start()
            }

            NoopButton("Test buzz", systemImage: "waveform.path", kind: .secondary) {
                model.buzz(loops: 1)
            }
            .disabled(!live.bonded)
            .help("Fire a single haptic pulse on the strap (requires a bonded connection)")
        }
    }

    // MARK: - Session outcome

    private var outcomeLine: String? {
        if running { return nil }
        if let endedOutcome {
            return endedOutcome == "—" ? String(localized: "No RMSSD · not enough R-R data")
                                       : String(localized: "RMSSD \(endedOutcome)")
        }
        if !lastStoredOutcome.isEmpty { return String(localized: "Last session: \(lastStoredOutcome)") }
        return nil
    }

    private func outcomeCard(_ line: String) -> some View {
        StrandCard(padding: 14, tint: StrandPalette.restColor) {
            HStack(spacing: 10) {
                Image(systemName: "wind")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.restBright)
                    .accessibilityHidden(true)
                Text(line)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let chip = outcomeTrend {
                    TrendChip(text: chip.text, color: chip.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outcomeTrend: (text: String, color: Color)? {
        guard let source = endedOutcome ?? (lastStoredOutcome.isEmpty ? nil : lastStoredOutcome),
              source != "—",
              let pct = Self.leadingSignedPercent(source) else { return nil }
        let sign = pct >= 0 ? "+" : "−"
        let color = pct >= 0 ? StrandPalette.statusPositive : StrandPalette.textTertiary
        return ("\(sign)\(abs(pct))% HRV", color)
    }

    private static func leadingSignedPercent(_ s: String) -> Int? {
        guard let pctRange = s.range(of: "%") else { return nil }
        let head = s[s.startIndex..<pctRange.lowerBound]
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int(head)
    }

    // MARK: - Readouts

    private var readoutRow: some View {
        HStack(spacing: NoopMetrics.gap) {
            readoutTile(label: String(localized: "Heart rate"),
                        value: model.bpm.map { "\($0)" } ?? "—",
                        unit: "bpm",
                        accent: StrandPalette.metricRose,
                        caption: live.worn ? String(localized: "Live") : String(localized: "Strap not worn"))

            readoutTile(label: String(localized: "HRV (RMSSD)"),
                        value: rmssd.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "ms",
                        accent: StrandPalette.metricPurple,
                        caption: rrBuffer.isEmpty ? String(localized: "Waiting for R-R") : String(localized: "Last \(rrBuffer.count) beats"))

            readoutTile(label: String(localized: "Pace"),
                        value: selectedBpm > 0 ? String(format: "%.1f", selectedBpm) : (isGuided ? "—" : "—"),
                        unit: "br/min",
                        accent: StrandPalette.restBright,
                        caption: paceCaption)
        }
    }

    private var paceCaption: String {
        if case .resonance = pace {
            let cycle = 60.0 / (lockedBpm ?? ResonanceEngine.fallbackBpm)
            let inn = cycle * BreathPacer.defaultInhaleFraction
            let out = cycle * (1 - BreathPacer.defaultInhaleFraction)
            return String(format: "%.0f / %.0fs", inn, out)
        }
        guard let proto = selectedProtocol, !proto.stages.isEmpty else {
            return isGuided ? String(localized: "Guided timer") : "—"
        }
        let parts = proto.stages.map { String(format: "%.1f", Double($0.durationMs) / 1000.0) }
        return parts.joined(separator: " · ") + "s"
    }

    private func readoutTile(label: String, value: String, unit: String,
                             accent: Color, caption: String) -> some View {
        StrandCard(padding: 14, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased()).strandOverline()
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(StrandFont.number(26))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
        .frame(height: NoopMetrics.tileHeight)
    }

    // MARK: - Coherence estimate

    private var coherenceCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Coherence estimate").strandOverline()
                    Spacer()
                    StatePill("\(coherenceLabel)", tone: coherenceTone, showsDot: true)
                }

                // The coherence estimate as a filling liquid tube (the same horizontal vessel Today's Key
                // Metrics use), Rest-tinted, filling to the RMSSD-derived fraction — replaces the flat
                // gradient capsule. Live so it sloshes as the reading updates through a session.
                LiquidTube(frac: coherenceFraction, tint: StrandPalette.restBright, height: 10)
                    .accessibilityLabel("Coherence estimate")
                    .accessibilityValue("\(Int(coherenceFraction * 100)) percent")

                Text("Estimate only: a higher RMSSD while paced usually means your parasympathetic \"rest\" branch is engaging. It is not a clinical reading; trends over a session matter more than any single number.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var coherenceFraction: CGFloat {
        guard let r = rmssd else { return 0 }
        return CGFloat(min(max(r / 120.0, 0), 1))
    }

    private var coherenceLabel: String {
        guard let r = rmssd else { return String(localized: "No data") }
        switch r {
        case ..<20:  return String(localized: "Building")
        case ..<45:  return String(localized: "Settling")
        case ..<80:  return String(localized: "Coherent")
        default:     return String(localized: "Deep calm")
        }
    }

    private var coherenceTone: StrandTone {
        guard let r = rmssd else { return .neutral }
        switch r {
        case ..<20:  return .warning
        case ..<45:  return .neutral
        default:     return .positive
        }
    }

    // MARK: - Haptic hint

    private var hapticHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.statusWarning)
            Text("Connect your strap for haptic guidance. You'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(StrandPalette.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Session control (catalog stages + guided timer)

    private func start() {
        running = true
        ScreenIdle.keepAwake(true)
        sessionSeconds = 0
        breathCount = 0
        stageIndex = 0
        phaseLabel = nil
        endedOutcome = nil
        baselineRmssd = rmssd
        sessionRmssdSum = 0
        sessionRmssdCount = 0
        sessionRmssdPeak = 0
        if isGuided {
            phase = .textOnly
            phaseLabel = selectedProtocol?.title
            phaseDeadline = .distantFuture
            if !reduceMotion { orbProgress = reducedSteadyOrb }
        } else {
            armCurrentStage(from: Date(), buzz: true)
        }
    }

    private func stop() {
        let wasRunning = running
        running = false
        ScreenIdle.keepAwake(false)
        phaseDeadline = .distantFuture
        phaseLabel = nil
        // #769: this trainer fires per-phase buzzes (armPhase -> model.buzz). Stopping halts NEW pulses but
        // can't recall one the strap is mid-pattern on, which could wedge the strap if the link drops. Tell
        // the strap to stop haptics too (best-effort; no-op when unbonded / on a 5/MG). Only when we were
        // actually buzzing, so a stop on an idle trainer stays silent.
        if wasRunning { model.stopHaptics() }
        if wasRunning { captureOutcome() }
        if reduceMotion {
            orbProgress = 0
        } else {
            withAnimation(.easeInOut(duration: 0.8)) {
                orbProgress = 0
            }
        }
    }

    private let reducedSteadyOrb: CGFloat = 0.5

    private func captureOutcome() {
        guard sessionSeconds >= 120 else { return }
        guard let base = baselineRmssd, base > 0, sessionRmssdCount > 0 else {
            endedOutcome = "—"
            return
        }
        let mean = sessionRmssdSum / Double(sessionRmssdCount)
        let pct = Int(((mean - base) / base * 100).rounded())
        let pctStr = String(format: "%+d%%", pct)
        let peakStr = String(format: "%.0f", sessionRmssdPeak)
        let core = String(localized: "\(pctStr) vs start · peak \(peakStr) ms")
        endedOutcome = core
        lastStoredOutcome = core
    }

    private func resonanceStages() -> [BreathStage] {
        let bpm = lockedBpm ?? ResonanceEngine.fallbackBpm
        let cycleMs = Int((60_000.0 / bpm).rounded())
        let inhaleMs = Int((Double(cycleMs) * BreathPacer.defaultInhaleFraction).rounded())
        let exhaleMs = max(1, cycleMs - inhaleMs)
        return [
            BreathStage(type: .inhale, durationMs: inhaleMs),
            BreathStage(type: .exhale, durationMs: exhaleMs),
        ]
    }

    private func currentStages() -> [BreathStage] {
        if case .resonance = pace { return resonanceStages() }
        return selectedProtocol?.stages.filter { $0.durationMs > 0 } ?? []
    }

    private func armCurrentStage(from now: Date, buzz: Bool) {
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let stage = stages[stageIndex % stages.count]
        let mapped: Phase
        switch stage.type {
        case .inhale: mapped = .inhale
        case .hold: mapped = .hold
        case .exhale: mapped = .exhale
        case .textOnly: mapped = .textOnly
        }
        phase = mapped
        phaseLabel = stage.label
        let duration = Double(stage.durationMs) / 1000.0
        phaseDeadline = now.addingTimeInterval(duration)

        if reduceMotion {
            orbProgress = reducedSteadyOrb
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                switch mapped {
                case .inhale: orbProgress = 1.0
                case .exhale: orbProgress = 0.0
                case .hold, .textOnly: break // keep current fill
                }
            }
        }

        if buzz {
            let loops = BreathProtocolPlayer.loops(for: stage.type)
            if loops > 0 {
                model.buzz(loops: UInt8(clamping: loops), gate: HapticPrefs.breathing)
            }
            if audioCues {
                switch mapped {
                case .inhale: tonePlayer.play(.inhale)
                case .exhale: tonePlayer.play(.exhale)
                case .hold, .textOnly: break
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
        if completed.type == .exhale {
            breathCount += 1
        }
        armCurrentStage(from: now, buzz: true)
    }

    // MARK: - HRV (RMSSD)

    private func ingest(_ rr: [Int]) {
        guard !rr.isEmpty else { return }
        rrBuffer.append(contentsOf: rr)
        if rrBuffer.count > rrWindow {
            rrBuffer.removeFirst(rrBuffer.count - rrWindow)
        }
        rmssd = computeRMSSD(rrBuffer)
        if running, let r = rmssd {
            if baselineRmssd == nil && sessionSeconds <= 60 { baselineRmssd = r }
            sessionRmssdSum += r
            sessionRmssdCount += 1
            sessionRmssdPeak = max(sessionRmssdPeak, r)
        }
    }

    private func computeRMSSD(_ intervals: [Int]) -> Double? {
        guard intervals.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<intervals.count {
            let d = Double(intervals[i] - intervals[i - 1])
            sumSq += d * d
        }
        let meanSq = sumSq / Double(intervals.count - 1)
        return meanSq.squareRoot()
    }

    // MARK: - Formatting

    private func timeString(_ total: Int) -> String {
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Lazy controller holder

/// Holds the `BiofeedbackController` so it can be created from the environment model/live on first
/// appear (a `@StateObject`'s value can't read the environment at init). `prepare` is idempotent.
@MainActor
private final class ControllerBox: ObservableObject {
    private var made: BiofeedbackController?
    func prepare(model: AppModel, live: LiveState) {
        if made == nil { made = BiofeedbackController(model: model, live: live) }
    }
    func controller(model: AppModel, live: LiveState) -> BiofeedbackController {
        if let made { return made }
        let c = BiofeedbackController(model: model, live: live)
        made = c
        return c
    }
}

// MARK: - Audio pacer (opt-in soft phase tones)

/// A tiny on-device tone player for the opt-in audio pacer. It synthesises a short, soft sine "ding"
/// for each phase (a higher note on the inhale, a lower one on the exhale) and plays it through an
/// **ambient** audio session, so the iOS silent switch mutes it like any other ambient sound and it
/// never interrupts other audio. No bundled assets — the buffers are generated once and reused.
///
/// Self-contained and view-owned: `activate()` spins the engine up when the user opts in, `deactivate()`
/// tears it down when they switch off or leave the screen, so we hold the audio session only while it's
/// actually wanted.
@MainActor
final class BreathTonePlayer: ObservableObject {

    enum Tone { case inhale, exhale }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var inhaleBuffer: AVAudioPCMBuffer?
    private var exhaleBuffer: AVAudioPCMBuffer?
    private var active = false

    /// Phase tone frequencies (Hz). A gentle rising/falling pair — a soft cue, not a chime.
    private let inhaleHz: Double = 440   // A4, brighter for "in"
    private let exhaleHz: Double = 330   // E4, lower for "out"
    private let toneSeconds: Double = 0.45
    private let sampleRate: Double = 44_100

    /// Bring the engine and audio session up. Idempotent — safe to call on every appear.
    func activate() {
        guard !active else { return }
#if os(iOS)
        // Ambient: obeys the silent switch and mixes politely with anything else playing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
#endif
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format else { return }

        if inhaleBuffer == nil { inhaleBuffer = makeTone(frequency: inhaleHz, format: format) }
        if exhaleBuffer == nil { exhaleBuffer = makeTone(frequency: exhaleHz, format: format) }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            active = true
        } catch {
            // Audio is a nicety, never load-bearing — if it can't start we just stay silent.
            active = false
        }
    }

    /// Stop and release the engine + session so nothing lingers when the pacer is off.
    func deactivate() {
        guard active else { return }
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
        active = false
    }

    /// Play the phase tone. No-op if the engine isn't up (e.g. start-up race) — the haptic + visual cues
    /// still carry the pace, so a missed tone is harmless.
    func play(_ tone: Tone) {
        guard active else { return }
        let buffer = (tone == .inhale) ? inhaleBuffer : exhaleBuffer
        guard let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Generate a single soft sine tone with a short attack/decay envelope so it fades in and out rather
    /// than clicking. Built once per frequency and reused.
    private func makeTone(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(toneSeconds * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let total = Int(frameCount)
        let attack = Int(0.02 * sampleRate)
        let release = Int(0.18 * sampleRate)
        let peak: Float = 0.28   // kept quiet — a gentle cue, not a beep

        for i in 0..<total {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * Double.pi * frequency * t))
            // Linear attack, sustain, then a longer linear release so the tail is soft.
            var env: Float = 1.0
            if i < attack {
                env = Float(i) / Float(max(attack, 1))
            } else if i > total - release {
                env = Float(total - i) / Float(max(release, 1))
            }
            channel[i] = sample * env * peak
        }
        return buffer
    }
}

// MARK: - L3 nudge-center environment key (optional injection point for Wave 3)

private struct StressNudgeCenterKey: EnvironmentKey {
    static let defaultValue: StressNudgeCenter? = nil
}
extension EnvironmentValues {
    /// The shared L3 nudge center. Wave 3 sets this (`.environment(\.stressNudgeCenter, model.stressNudge)`)
    /// from the same instance its BLEManager hook posts to; nil → BreathingView uses a local fallback.
    var stressNudgeCenter: StressNudgeCenter? {
        get { self[StressNudgeCenterKey.self] }
        set { self[StressNudgeCenterKey.self] = newValue }
    }
}

// MARK: - L1: Resonance mode (the "find my pace" sweep + result)

/// The L1 surface: an explainer, the full/quick sweep start, a live "Testing 5.5 br/min…" label + RSA
/// progress while sweeping, and the dated result card (locked pace + per-pace RSA curve, or the honest
/// "couldn't lock today" fallback). Self-contained — drives the shared `BiofeedbackController`.
private struct ResonanceModeView: View {
    @ObservedObject var controller: BiofeedbackController
    @ObservedObject var live: LiveState
    let lockedBpm: Double?

    private var sweeping: Bool {
        if case .resonanceSweep = controller.session { return true }
        return false
    }

    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            explainerCard
            if sweeping { sweepProgressCard } else { startCard }
            if let result = controller.lastSweep { resultCard(result) }
            else if let bpm = lockedBpm { lockedCard(bpm) }
            if !live.bonded { connectHint }
        }
    }

    private var explainerCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Find your resonance pace").strandOverline()
                    Spacer()
                    StatePill(live.bonded ? "Haptics on" : "Visual only",
                              tone: live.bonded ? .positive : .warning, showsDot: true)
                }
                Text("Everyone has a breathing pace (usually between 4.5 and 7 breaths a minute) where the heart's rhythm swings the most with each breath. We pace you through a few candidate paces, measure how your HRV responds, and lock the one that resonates best for you.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Estimate from PPG-derived R-R: relaxation guidance, not a clinical reading. Your pace drifts, so we date it and you can re-measure anytime.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startCard: some View {
        StrandCard {
            VStack(spacing: NoopMetrics.space3) {
                NoopButton("Full sweep · ~13 min", systemImage: "waveform.path.ecg",
                           kind: .primary, fullWidth: true) {
                    controller.startSweep(quick: false)
                }

                NoopButton("Quick sweep · ~7 min", systemImage: "bolt",
                           kind: .secondary, fullWidth: true) {
                    controller.startSweep(quick: true)
                }

                Text("Sit still and breathe with the buzz. You can stop anytime; a stopped sweep won't lock a pace.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sweepProgressCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(controller.sweepLabel ?? String(localized: "Sweeping…"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    StatePill("Live", tone: .accent, showsDot: true, pulsing: true)
                }

                // Sweep progress as a filling liquid tube (the liquid idiom used across the redesign),
                // Rest-tinted so it reads as one with the breathe world.
                LiquidTube(frac: controller.sweepProgress, tint: StrandPalette.restColor, height: 10)
                    .accessibilityLabel("Sweep progress")
                    .accessibilityValue("\(Int(controller.sweepProgress * 100)) percent")

                NoopButton("Stop sweep", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
                    controller.stop()
                }
            }
        }
    }

    private func resultCard(_ result: ResonanceEngine.SweepResult) -> some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(result.didLock ? "Your resonance pace" : "Couldn't lock today").strandOverline()
                    Spacer()
                    StatePill(result.didLock ? "Locked" : "Fallback",
                              tone: result.didLock ? .positive : .neutral, showsDot: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CountUpText(value: result.lockedBpm,
                                format: { String(format: "%.1f", $0) },
                                font: StrandFont.number(40),
                                color: StrandPalette.restBright)
                    Text("br/min")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if !result.didLock {
                    Text("Not enough clean beat data to lock a pace today. Try again rested, sitting still with the strap snug. For now we'll pace you at 5.5 br/min (coherence).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                rsaCurve(result.scores)

                if let date = BiofeedbackPrefs.lockedPaceDate, result.didLock {
                    Text("Locked \(date.formatted(date: .abbreviated, time: .omitted)) · paces drift, re-measure anytime.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func lockedCard(_ bpm: Double) -> some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your locked pace").strandOverline()
                    Spacer()
                    StatePill("Locked", tone: .positive, showsDot: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CountUpText(value: bpm,
                                format: { String(format: "%.1f", $0) },
                                font: StrandFont.number(34),
                                color: StrandPalette.restBright)
                    Text("br/min")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let date = BiofeedbackPrefs.lockedPaceDate {
                    Text("Locked \(date.formatted(date: .abbreviated, time: .omitted)). Switch to Breathe to use it, or re-measure above.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A compact text + bar summary of the RSA-amplitude per pace (the resonance curve). The text summary
    /// is the a11y win; the bars are decorative. Unscored paces read "—".
    private func rsaCurve(_ scores: [ResonanceEngine.PaceScore]) -> some View {
        let maxRsa = scores.compactMap(\.rsaAmplitude).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            Text("RSA RESPONSE BY PACE").strandOverline()
            ForEach(scores, id: \.bpm) { s in
                HStack(spacing: 8) {
                    Text(String(format: "%.1f", s.bpm))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    // Each pace's RSA amplitude as a static liquid tube — the same horizontal vessel used
                    // across the redesign. An unscored pace reads muted via a dimmed Rest tint.
                    LiquidTube(frac: (s.rsaAmplitude ?? 0) / max(maxRsa, 0.0001),
                               tint: StrandPalette.restBright.opacity(s.scored ? 1 : 0.35),
                               height: 8, animated: false)
                    Text(s.rsaAmplitude.map { String(format: "%.1f", $0) } ?? "—")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(s.scored ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RSA response by pace")
        .accessibilityValue(rsaTextSummary(scores))
    }

    private func rsaTextSummary(_ scores: [ResonanceEngine.PaceScore]) -> String {
        scores.map { s in
            let v = s.rsaAmplitude.map { String(format: "%.1f", $0) } ?? String(localized: "unscored")
            return String(localized: "\(String(format: "%.1f", s.bpm)) breaths per minute: \(v)")
        }.joined(separator: ", ")
    }

    private var connectHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.statusWarning)
            Text("Connect your strap for the felt cue. The sweep paces you with one buzz on the inhale, two on the exhale.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(StrandPalette.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }
}

// MARK: - L2: "Calm me" mode (below-HR relaxation metronome)

/// The L2 surface: a "Calm me · 3 min" button that runs `HRDownPacer`, a minimal live "HR 78 → settling"
/// readout, a stop control, and an honest outcome line. Haptic-first → disabled (not faked) when the
/// encrypted channel isn't up. Self-contained — drives the shared `BiofeedbackController`.
private struct CalmModeView: View {
    @ObservedObject var controller: BiofeedbackController
    @ObservedObject var live: LiveState
    @ObservedObject var model: AppModel

    private var running: Bool {
        if case .calmMe = controller.session { return true }
        return false
    }

    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            explainerCard
            if running { liveCard } else { startCard }
            if let outcome = controller.calmOutcome, !running { outcomeCard(outcome) }
        }
    }

    private var explainerCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Calm me").strandOverline()
                    Spacer()
                    StatePill(canRun ? "Ready" : "Strap needed",
                              tone: canRun ? .neutral : .warning, showsDot: true)
                }
                Text("The strap buzzes a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it, and stops on its own.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A relaxation rhythm, not cardiac control. It never paces below a safe rate and you can stop anytime. If your heart rate doesn't settle, we'll say so plainly.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// L2 needs the encrypted channel (haptic-first) and a resting-band HR to read H₀.
    private var canRun: Bool { controller.canBuzz && (model.bpm.map { $0 >= 55 && $0 <= 120 } ?? false) }

    private var startCard: some View {
        StrandCard {
            VStack(spacing: NoopMetrics.rowSpacing) {
                NoopButton("Calm me · 3 min", systemImage: "heart.fill",
                           kind: .primary, fullWidth: true) {
                    controller.startCalmMe()
                }
                .disabled(!canRun)

                if !controller.canBuzz {
                    Text("Connect your strap. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !canRun {
                    Text("Waiting for a resting heart rate. Start a live reading first, or come back when you're still.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var liveCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(spacing: 14) {
                HStack {
                    Text("Settling").strandOverline()
                    Spacer()
                    StatePill("Live", tone: .accent, showsDot: true, pulsing: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let bpm = model.bpm {
                        CountUpText(value: Double(bpm),
                                    format: { "\(Int($0.rounded()))" },
                                    font: StrandFont.number(48),
                                    color: StrandPalette.metricRose)
                    } else {
                        Text("—")
                            .font(StrandFont.number(48))
                            .foregroundStyle(StrandPalette.metricRose)
                    }
                    Image(systemName: "arrow.right")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("target")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(controller.calmTargetBpm.map { String(format: "%.0f", $0) } ?? "—")
                            .font(StrandFont.number(22))
                            .foregroundStyle(StrandPalette.restBright)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let h0 = controller.calmStartHR {
                    Text("Started at \(h0) bpm · the rhythm trails your heart down.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                NoopButton("Stop", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
                    controller.stop()
                }
            }
        }
    }

    private func outcomeCard(_ line: String) -> some View {
        StrandCard(padding: 14, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: controller.calmDidNotFall ? "minus.circle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(controller.calmDidNotFall ? StrandPalette.textTertiary : StrandPalette.statusPositive)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if controller.calmDidNotFall {
                    Text("That's normal. A paced breath often settles things when a metronome alone doesn't.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
