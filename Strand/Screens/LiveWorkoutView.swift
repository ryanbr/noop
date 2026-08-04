import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick — the HR hero, effort
    // gauge, zone rail and stats grid all re-evaluate even though they read from `model` (smoothed bpm +
    // scorers), not `live`. The only region that genuinely needs `live` is the additive sensor readout
    // (speed / cadence / power), so it's extracted into the small `SensorRowIfPresent` leaf below that
    // owns its OWN `@EnvironmentObject live`. A sensor/R-R packet now re-renders just that row, not the
    // hero. (`model.live` is its own ObservableObject, so the leaf's `live` is the one that sees the
    // @Published changes — exactly as the parent's direct observation did before.)
    let onClose: () -> Void

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    /// Guards the destructive End action behind a confirm (#517) — a stray tap on the full-width button
    /// used to end the workout instantly with no way back.
    @State private var showEndConfirm = false

    private var zoneSet: HRZoneSet { HRZones.zones(maxHR: Double(model.profile.hrMax)) }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                let cards: [AnyView] = [
                    AnyView(header),
                    AnyView(heroHeartRate),
                    AnyView(effortGauge),
                    AnyView(statsGrid),
                ]
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    card.staggeredAppear(index: index)
                }
                // Live-observing leaf: renders the sensor row (and its entrance stagger) only when a
                // standard fitness sensor is feeding metrics, refreshing on its own packets without
                // re-rendering the HR hero / effort gauge above (scroll-stutter isolation).
                SensorRowIfPresent()
                Spacer(minLength: NoopMetrics.space3)
                endButton
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A scenic Effort-tinted backdrop behind the whole in-exercise screen, fading to the base — the
        // live workout reads as an Effort-world hero, not a flat panel.
        .background {
            ScenicHeroBackground(domain: .effort)
                .ignoresSafeArea()
        }
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
            model.startRealtimeHR()
            // Hold the display awake for the session only if the user opted in (#703).
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            // Always release on the way out so the system idle timer resumes. Even if the toggle was
            // flipped off mid-workout, this clears any hold we placed.
            ScreenIdle.keepAwake(false)
        }
        // Confirm before ending (#517): a stray tap on "End workout" used to stop the session and
        // discard the in-progress recording with no way back.
        .alert("End this workout?",
               isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End workout", role: .destructive) {
                model.endWorkout()
                onClose()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Workout")
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            HStack(spacing: NoopMetrics.space1) {
                Circle()
                    .fill(StrandPalette.metricRose)
                    .frame(width: 7, height: 7)
                Text("RECORDING WORKOUT")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.metricRose)
            }
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(NoopPanelSurface(tint: StrandPalette.metricRose, cornerRadius: 14))
            .clipShape(Capsule())
        }
    }

    private var heroHeartRate: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return NoopCard(padding: NoopMetrics.space6, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.space5) {
                if let start = model.activeWorkout?.start {
                    VStack(spacing: NoopMetrics.space1) {
                        Text("TIME")
                            .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.elapsed(since: start))
                                .font(StrandFont.number(48)).monospacedDigit()
                                .foregroundStyle(StrandPalette.textPrimary)
                                .contentTransition(.numericText())
                        }
                    }
                }

                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)

                HStack(alignment: .center, spacing: NoopMetrics.space4) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("HEART RATE")
                            .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                            if let bpm = model.bpm {
                                CountUpText(value: Double(bpm),
                                            format: { "\(Int($0.rounded()))" },
                                            font: StrandFont.rounded(72, weight: .semibold),
                                            color: tint)
                            } else {
                                Text("—")
                                    .font(StrandFont.rounded(72, weight: .semibold))
                                    .foregroundStyle(tint)
                            }
                            Text("bpm")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(zone >= 1 ? "Zone \(zone) · \(Self.zoneName(zone))" : "Below Zone 1")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, NoopMetrics.space2)
                        .padding(.vertical, NoopMetrics.space1)
                        .background(tint.opacity(0.12), in: Capsule())
                }

                zoneRail
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The accumulating Effort, on the same layered StrainGauge the rest of the app uses — the live
    /// `liveStrain` is on NOOP's 0–100 Effort axis. The gauge renders on the user's selected Effort
    /// scale (#313): 0–100 native, or rescaled to WHOOP's 0–21, matching the rest of the app's
    /// read-outs (mirrors TodayView's effort hero). Display-only — the captured value stays 0–100.
    private var effortGauge: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        let displayEffort = UnitFormatter.effortValue(strain, scale: effortScale)
        let maxValue = effortScale == .whoop ? 21.0 : 100.0
        let maxLabel = UnitFormatter.effortScaleMax(effortScale)
        let fraction = min(max(displayEffort / maxValue, 0), 1)
        return NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
            HStack(spacing: NoopMetrics.space5) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(StrandPalette.effortColor)
                    Text("EFFORT BUILDING")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(StrainGauge.stateLabel(forFraction: fraction))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
                ZStack {
                    LiquidVessel(value: fraction, tint: StrandPalette.effortColor, animated: true)
                    VStack(spacing: 1) {
                        CountUpText(value: displayEffort,
                                    format: { value in
                                        effortScale == .whoop
                                            ? String(format: "%.1f", value)
                                            : "\(Int(value.rounded()))"
                                    },
                                    font: StrandFont.rounded(30, weight: .semibold),
                                    color: .white)
                        Text(String(localized: "of \(maxLabel)"))
                            .font(StrandFont.footnote)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                    .allowsHitTesting(false)
                }
                .frame(width: 124, height: 124)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(UnitFormatter.effortDisplay(strain, scale: effortScale)))
                .accessibilityValue(Text(StrainGauge.stateLabel(forFraction: fraction)))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var zoneRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HR ZONE")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { z in
                    let active = z == zone
                    let color = StrandPalette.hrZoneColor(z)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? color : color.opacity(0.18))
                        .frame(height: active ? 44 : 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? color : StrandPalette.hairline, lineWidth: 1)
                        )
                        .overlay(
                            Text("Z\(z)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(active ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                        )
                }
            }
            if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                Text("Zone \(zone): \(Int(band.lower))-\(Int(band.upper)) bpm (\(Int(band.lowerPct * 100))-\(Int(band.upperPct * 100))% max HR)")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Warming up. Keep moving to climb into Zone 1.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var statsGrid: some View {
        let w = model.activeWorkout
        return NoopCard(padding: NoopMetrics.cardInnerPadding) {
            HStack(spacing: 0) {
                stat(String(localized: "AVG"), (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : "—",
                     tint: (w?.avgHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
                statDivider
                stat(String(localized: "PEAK"), (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : "—",
                     tint: (w?.peakHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
                statDivider
                stat(String(localized: "EFFORT"), UnitFormatter.effortDisplay(w?.liveStrain ?? 0, scale: effortScale),
                     tint: StrandPalette.strainColor(w?.liveStrain ?? 0))
            }
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(28))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 48)
    }

    private var endButton: some View {
        NoopButton("End workout", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
            showEndConfirm = true
        }
    }

    // MARK: - Helpers

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each metric is dropped when its value is absent, and the WHOLE block (panel + entrance stagger)
/// is hidden when nothing is present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly
/// as before. Honest units: speed km/h, cadence per-minute (steps for running / rpm for cycling), power
/// watts. Tinted with the Effort world so it reads as part of the hero, not a competing accent. Nothing
/// here touches HR / zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// no longer observes `LiveState`), so an incoming sensor / R-R packet re-renders only this row, not the
/// HR hero / effort gauge / zone rail above. The gate, layout and `staggeredAppear(index: 5)` are
/// preserved verbatim, so the rendered output is byte-for-byte the previous inline code.
private struct SensorRowIfPresent: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.hasSensorMetrics {
            let speed = LiveState.formatSpeedKmh(live.sensorSpeedKmh)
            let cadence = LiveState.formatCadence(live.sensorCadence)
            let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
            NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("SENSOR")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: NoopMetrics.gap) {
                        if let speed { stat(String(localized: "SPEED"), "\(speed) km/h", tint: StrandPalette.effortColor) }
                        if let cadence { stat(String(localized: "CADENCE"), "\(cadence)/min", tint: StrandPalette.effortColor) }
                        if let power { stat(String(localized: "POWER"), "\(power) W", tint: StrandPalette.effortColor) }
                    }
                }
            }
            .staggeredAppear(index: 5)
        }
    }

    /// Compact sensor value used inside this leaf's shared panel, keeping its high-frequency updates
    /// isolated from the rest of the workout screen.
    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(26))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
