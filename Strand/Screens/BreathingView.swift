import SwiftUI
import Foundation
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
            case .breathe:   return "Breathe"
            case .resonance: return "Resonance"
            case .calm:      return "Calm me"
            }
        }
    }
    @State private var mode: Mode = .breathe

    // MARK: Pace presets

    private enum Pace: Hashable {
        case relax          // 4s inhale / 6s exhale
        case coherence      // 5.5s / 5.5s
        case box            // 4s / 4s
        case resonance      // the user's locked pace (br/min)

        var label: String {
            switch self {
            case .relax:      return "Relax 4-6"
            case .coherence:  return "Coherence 5.5"
            case .box:        return "Box 4-4"
            case .resonance:  return "Resonance"
            }
        }

        /// Inhale seconds — for `.resonance` it derives from the locked bpm at a 40:60 inhale:exhale split.
        func inhale(lockedBpm: Double?) -> Double {
            switch self {
            case .relax:     return 4.0
            case .coherence: return 5.5
            case .box:       return 4.0
            case .resonance:
                let cycle = 60.0 / (lockedBpm ?? ResonanceEngine.fallbackBpm)
                return cycle * BreathPacer.defaultInhaleFraction
            }
        }

        func exhale(lockedBpm: Double?) -> Double {
            switch self {
            case .relax:     return 6.0
            case .coherence: return 5.5
            case .box:       return 4.0
            case .resonance:
                let cycle = 60.0 / (lockedBpm ?? ResonanceEngine.fallbackBpm)
                return cycle * (1 - BreathPacer.defaultInhaleFraction)
            }
        }

        func cycle(lockedBpm: Double?) -> Double { inhale(lockedBpm: lockedBpm) + exhale(lockedBpm: lockedBpm) }
        func bpm(lockedBpm: Double?) -> Double { 60.0 / cycle(lockedBpm: lockedBpm) }

        func tagline(lockedBpm: Double?) -> String {
            switch self {
            case .relax:     return "Long exhale · downshift to rest"
            case .coherence: return "Equal breath · ~5.5 br/min coherence"
            case .box:       return "Square breath · steady focus"
            case .resonance:
                return String(format: "Your locked pace · %.1f br/min", lockedBpm ?? ResonanceEngine.fallbackBpm)
            }
        }
    }

    private enum Phase { case inhale, exhale }

    // MARK: State (fixed-pace Breathe — unchanged behaviour)

    @State private var pace: Pace = .coherence
    @State private var running = false

    /// 0 = fully contracted, 1 = fully expanded. Drives the orb scale.
    @State private var orbProgress: CGFloat = 0
    @State private var phase: Phase = .inhale
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

    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let rrWindow = 30

    /// The user's locked resonance pace, read fresh each render (set by the sweep).
    private var lockedBpm: Double? { BiofeedbackPrefs.lockedPace }

    var body: some View {
        ScreenScaffold(title: "Breathe",
                       subtitle: "Haptic-paced breathing · find your pace · calm down") {

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
        }
        .onChangeCompat(of: live.rr) { rr in
            ingest(rr)
        }
        .onChangeCompat(of: pace) { _ in
            if running { armPhase(.inhale, from: Date(), buzz: false) }
        }
        .onChangeCompat(of: mode) { _ in
            // Leaving a mode stops any session it owns so two clocks never run at once.
            if running { stop() }
            controller.stop()
        }
        .onAppear { controllerBox.prepare(model: model, live: live) }
        .onDisappear { stop(); controller.stop() }
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
                Text(timeString(sessionSeconds))
                    .font(StrandFont.number(15))
                    .foregroundStyle(StrandPalette.textPrimary)
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
                    Text(String(format: "%.1f br/min", pace.bpm(lockedBpm: lockedBpm)))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                ZStack {
                    ScenicHeroBackground(domain: .rest, starCount: 56)
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                    breathingOrb
                        .padding(.vertical, 6)
                }
                .frame(height: 320)
                .frame(maxWidth: .infinity)

                Text(running ? phaseWord : pace.tagline(lockedBpm: lockedBpm))
                    .font(StrandFont.subhead)
                    .foregroundStyle(running ? StrandPalette.restBright : StrandPalette.textSecondary)
                    .animation(.easeInOut(duration: 0.2), value: phaseWord)
                    .animation(.easeInOut(duration: 0.2), value: running)

                pacePills
            }
        }
    }

    /// Preset pills — the locked-resonance pill only shows once a pace has been locked (it reads the
    /// stored value), so a never-swept user sees the three shipped presets exactly as before.
    private var availablePaces: [Pace] {
        lockedBpm != nil ? [.relax, .coherence, .box, .resonance] : [.relax, .coherence, .box]
    }

    private var pacePills: some View {
        // Up to four pills (incl. locked Resonance) overflow a narrow iPhone — let a
        // horizontal scroll govern the width rather than truncating inside a fixed frame.
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentedPillControl(availablePaces, selection: $pace) { $0.label }
        }
    }

    private var phaseWord: String {
        switch phase {
        case .inhale: return "Breathe in…"
        case .exhale: return "Breathe out…"
        }
    }

    private var breathingOrb: some View {
        GeometryReader { geo in
            let maxDiameter = min(geo.size.width, geo.size.height)
            let minScale: CGFloat = 0.42
            let scale = minScale + (1.0 - minScale) * orbProgress
            let diameter = maxDiameter * scale

            ZStack {
                Circle()
                    .strokeBorder(StrandPalette.restColor.opacity(0.28), lineWidth: 1)
                    .frame(width: maxDiameter, height: maxDiameter)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [StrandPalette.restBright.opacity(0.30),
                                     StrandPalette.restGlow.opacity(0.0)],
                            center: .center,
                            startRadius: diameter * 0.20,
                            endRadius: diameter * 0.70
                        )
                    )
                    .frame(width: diameter * 1.35, height: diameter * 1.35)
                    .blur(radius: 18)
                    .opacity(0.55 + 0.45 * Double(orbProgress))

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [StrandPalette.restBright.opacity(0.90),
                                     StrandPalette.restColor.opacity(0.62),
                                     StrandPalette.restDeep.opacity(0.85)],
                            center: .init(x: 0.4, y: 0.35),
                            startRadius: 2,
                            endRadius: diameter * 0.62
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(StrandPalette.restBright.opacity(0.50), lineWidth: 1)
                    )
                    .frame(width: diameter, height: diameter)
                    .shadow(color: StrandPalette.restGlow.opacity(0.40 * orbProgress), radius: 26)

                VStack(spacing: 2) {
                    Text(model.bpm.map(String.init) ?? "—")
                        .font(StrandFont.number(40))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.bpm)
                    Text("BPM")
                        .font(StrandFont.footnote)
                        .tracking(0.8)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button {
                running ? stop() : start()
            } label: {
                Label(running ? "Stop session" : "Start session",
                      systemImage: running ? "stop.fill" : "play.fill")
                    .font(StrandFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(running ? StrandPalette.statusCritical : StrandPalette.accent)

            Button {
                model.buzz(loops: 1)
            } label: {
                Label("Test buzz", systemImage: "waveform.path")
                    .font(StrandFont.body)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .disabled(!live.bonded)
            .help("Fire a single haptic pulse on the strap (requires a bonded connection)")
        }
    }

    // MARK: - Session outcome

    private var outcomeLine: String? {
        if running { return nil }
        if let endedOutcome {
            return endedOutcome == "—" ? "RMSSD — · not enough R-R data" : "RMSSD \(endedOutcome)"
        }
        if !lastStoredOutcome.isEmpty { return "Last session: \(lastStoredOutcome)" }
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
            readoutTile(label: "Heart rate",
                        value: model.bpm.map { "\($0)" } ?? "—",
                        unit: "bpm",
                        accent: StrandPalette.metricRose,
                        caption: live.worn ? "Live" : "Strap not worn")

            readoutTile(label: "HRV (RMSSD)",
                        value: rmssd.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "ms",
                        accent: StrandPalette.metricPurple,
                        caption: rrBuffer.isEmpty ? "Waiting for R-R" : "Last \(rrBuffer.count) beats")

            readoutTile(label: "Pace",
                        value: String(format: "%.1f", pace.bpm(lockedBpm: lockedBpm)),
                        unit: "br/min",
                        accent: StrandPalette.restBright,
                        caption: String(format: "%.0f / %.0fs",
                                        pace.inhale(lockedBpm: lockedBpm), pace.exhale(lockedBpm: lockedBpm)))
        }
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

                GeometryReader { geo in
                    let frac = coherenceFraction
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [StrandPalette.restDeep,
                                             StrandPalette.restBright],
                                    startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: max(6, geo.size.width * frac))
                            .animation(.easeInOut(duration: 0.5), value: frac)
                    }
                }
                .frame(height: 10)

                Text("Estimate only — a higher RMSSD while paced usually means your parasympathetic \"rest\" branch is engaging. It is not a clinical reading; trends over a session matter more than any single number.")
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
        guard let r = rmssd else { return "No data" }
        switch r {
        case ..<20:  return "Building"
        case ..<45:  return "Settling"
        case ..<80:  return "Coherent"
        default:     return "Deep calm"
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
            Text("Connect your strap for haptic guidance — you'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.")
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

    // MARK: - Session control (fixed-pace Breathe — unchanged)

    private func start() {
        running = true
        ScreenIdle.keepAwake(true)
        sessionSeconds = 0
        breathCount = 0
        endedOutcome = nil
        baselineRmssd = rmssd
        sessionRmssdSum = 0
        sessionRmssdCount = 0
        sessionRmssdPeak = 0
        armPhase(.inhale, from: Date(), buzz: true)
    }

    private func stop() {
        let wasRunning = running
        running = false
        ScreenIdle.keepAwake(false)
        phaseDeadline = .distantFuture
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
        let core = String(format: "%+d%% vs start · peak %.0f ms", pct, sessionRmssdPeak)
        endedOutcome = core
        lastStoredOutcome = core
    }

    private func armPhase(_ newPhase: Phase, from now: Date, buzz: Bool) {
        phase = newPhase
        let duration = (newPhase == .inhale)
            ? pace.inhale(lockedBpm: lockedBpm)
            : pace.exhale(lockedBpm: lockedBpm)
        phaseDeadline = now.addingTimeInterval(duration)

        if reduceMotion {
            orbProgress = reducedSteadyOrb
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                orbProgress = (newPhase == .inhale) ? 1.0 : 0.0
            }
        }

        if buzz {
            model.buzz(loops: newPhase == .inhale ? 1 : 2)
        }
    }

    private func advance(now: Date) {
        guard now >= phaseDeadline else { return }
        switch phase {
        case .inhale:
            armPhase(.exhale, from: now, buzz: true)
        case .exhale:
            breathCount += 1
            armPhase(.inhale, from: now, buzz: true)
        }
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
                Text("Everyone has a breathing pace — usually between 4.5 and 7 breaths a minute — where the heart's rhythm swings the most with each breath. We pace you through a few candidate paces, measure how your HRV responds, and lock the one that resonates best for you.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Estimate from PPG-derived R-R — relaxation guidance, not a clinical reading. Your pace drifts, so we date it and you can re-measure anytime.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startCard: some View {
        StrandCard {
            VStack(spacing: 12) {
                Button {
                    controller.startSweep(quick: false)
                } label: {
                    Label("Full sweep · ~13 min", systemImage: "waveform.path.ecg")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)

                Button {
                    controller.startSweep(quick: true)
                } label: {
                    Label("Quick sweep · ~7 min", systemImage: "bolt")
                        .font(StrandFont.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

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
                    Text(controller.sweepLabel ?? "Sweeping…")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    StatePill("Live", tone: .accent, showsDot: true, pulsing: true)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule()
                            .fill(LinearGradient(colors: [StrandPalette.restDeep, StrandPalette.restBright],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * controller.sweepProgress))
                            .animation(.easeInOut(duration: 0.4), value: controller.sweepProgress)
                    }
                }
                .frame(height: 10)
                .accessibilityLabel("Sweep progress")
                .accessibilityValue("\(Int(controller.sweepProgress * 100)) percent")

                Button {
                    controller.stop()
                } label: {
                    Label("Stop sweep", systemImage: "stop.fill")
                        .font(StrandFont.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(StrandPalette.statusCritical)
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
                    Text(String(format: "%.1f", result.lockedBpm))
                        .font(StrandFont.number(40))
                        .foregroundStyle(StrandPalette.restBright)
                    Text("br/min")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if !result.didLock {
                    Text("Not enough clean beat data to lock a pace today — try again rested, sitting still with the strap snug. For now we'll pace you at 5.5 br/min (coherence).")
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
                    Text(String(format: "%.1f", bpm))
                        .font(StrandFont.number(34))
                        .foregroundStyle(StrandPalette.restBright)
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
                    GeometryReader { geo in
                        let frac = (s.rsaAmplitude ?? 0) / max(maxRsa, 0.0001)
                        ZStack(alignment: .leading) {
                            Capsule().fill(StrandPalette.surfaceInset)
                            Capsule()
                                .fill(StrandPalette.restBright.opacity(s.scored ? 0.9 : 0.25))
                                .frame(width: max(4, geo.size.width * CGFloat(frac)))
                        }
                    }
                    .frame(height: 8)
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
            let v = s.rsaAmplitude.map { String(format: "%.1f", $0) } ?? "unscored"
            return String(format: "%.1f breaths per minute: %@", s.bpm, v)
        }.joined(separator: ", ")
    }

    private var connectHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.statusWarning)
            Text("Connect your strap for the felt cue — the sweep paces you with one buzz on the inhale, two on the exhale.")
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
                Text("The strap buzzes a gentle rhythm just below your current heart rate — a felt metronome to relax toward. It trails your heart down rather than yanking it, and stops on its own.")
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
            VStack(spacing: 10) {
                Button {
                    controller.startCalmMe()
                } label: {
                    Label("Calm me · 3 min", systemImage: "heart.fill")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(!canRun)

                if !controller.canBuzz {
                    Text("Connect your strap — Calm me is a felt rhythm on the wrist, so it needs a bonded connection.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !canRun {
                    Text("Waiting for a resting heart rate — start a live reading first, or come back when you're still.")
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
                    Text(model.bpm.map(String.init) ?? "—")
                        .font(StrandFont.number(48))
                        .foregroundStyle(StrandPalette.metricRose)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.bpm)
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

                Button {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.statusCritical)
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
                    Text("That's normal — a paced breath often settles things when a metronome alone doesn't.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
