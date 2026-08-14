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

    /// Guards the destructive End action behind a confirm (#517) — a stray tap on the compact exit
    /// control must not end the workout instantly with no way back.
    @State private var showEndConfirm = false

    private var zoneSet: HRZoneSet { model.profile.hrZoneSet }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                let cards: [AnyView] = [
                    AnyView(header),
                    AnyView(timeBlock),
                    AnyView(heartRateBlock),
                    AnyView(effortGauge),
                    AnyView(zoneSection),
                    AnyView(statsGrid),
                    // Live GPS distance + pace (#1195) — a self-gating leaf owning its own recorder
                    // observation, so a GPS fix re-renders only this card. Renders nothing until the first
                    // accepted fix, so non-GPS / denied sessions leave the stack unchanged.
                    AnyView(DistancePaceRowIfPresent(recorder: model.gpsRecorder)),
                ]
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    card.staggeredAppear(index: index)
                }
                // Live-observing leaf: renders the sensor row (and its entrance stagger) only when a
                // standard fitness sensor is feeding metrics, refreshing on its own packets without
                // re-rendering the HR hero / effort gauge above (scroll-stutter isolation).
                SensorRowIfPresent()
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space6)
            .padding(.bottom, NoopMetrics.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Floating end / elapsed / sport-type controls sit in the bottom safe area so the scroll
        // content never owns the chrome and the timer can stay screen-centered.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControlRow
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
        // Confirm before ending (#517): ending still requires an explicit confirm so a stray tap on the
        // compact exit control cannot discard the in-progress recording with no way back.
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
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Recording workout"))
    }

    /// Centered elapsed-time stack — same TimelineView source as before; card chrome removed so
    /// TIME sits as a free hero metric above heart rate.
    private var timeBlock: some View {
        Group {
            if let start = model.activeWorkout?.start {
                VStack(spacing: NoopMetrics.space1) {
                    Text("TIME")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.elapsed(since: start))
                            .font(StrandFont.number(56)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Centered live HR stack — bpm unit sits under the value; the zone capsule moved to `zoneSection`.
    private var heartRateBlock: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return VStack(spacing: NoopMetrics.space1) {
            Text("HEART RATE")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
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
        .frame(maxWidth: .infinity)
    }

    /// Centered Effort stack — same `liveStrain` / Effort-scale conversion and `StrainGauge` intensity
    /// label as before. Card chrome and side-by-side layout removed so the value sits as a free hero
    /// metric between heart rate and the zone rail. Display-only; captured value stays 0–100.
    private var effortGauge: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        let displayEffort = UnitFormatter.effortValue(strain, scale: effortScale)
        let maxValue = effortScale == .whoop ? 21.0 : 100.0
        let fraction = min(max(displayEffort / maxValue, 0), 1)
        // VoiceOver needs the selected scale maximum (0–21 / 0–100) even though the visible denominator
        // was removed from the glanceable layout. Reuse the same localized "of %@" caption as Today /
        // Week-in-review, and format the spoken value like the on-screen CountUpText.
        let valueText = effortScale == .whoop
            ? String(format: "%.1f", displayEffort)
            : "\(Int(displayEffort.rounded()))"
        let scaleCaption = String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")
        let effortAccessibilityLabel = "\(String(localized: "Effort")) \(valueText) \(scaleCaption)"
        return VStack(spacing: NoopMetrics.space1) {
            CountUpText(value: displayEffort,
                        format: { value in
                            effortScale == .whoop
                                ? String(format: "%.1f", value)
                                : "\(Int(value.rounded()))"
                        },
                        font: StrandFont.rounded(56, weight: .semibold),
                        color: StrandPalette.textPrimary)
            .accessibilityLabel(effortAccessibilityLabel)
            .accessibilityValue(Text(StrainGauge.stateLabel(forFraction: fraction)))

            Text("EFFORT BUILDING")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.effortColor)
            Text(StrainGauge.stateLabel(forFraction: fraction))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Zone status capsule + rail + caption — same zone derivation and copy; capsule sits on the
    /// HR ZONE header row instead of beside the heart-rate value.
    private var zoneSection: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HR ZONE")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(zone >= 1 ? "Zone \(zone) · \(Self.zoneName(zone))" : "Below Zone 1")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, NoopMetrics.space2)
                    .padding(.vertical, NoopMetrics.space1)
                    .background(tint.opacity(0.12), in: Capsule())
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

    // MARK: - Bottom floating controls

    /// Diameter shared by the exit and workout-type Liquid Glass circles so the centered timer stays
    /// optically balanced against equal side chrome.
    private static let bottomControlDiameter: CGFloat = 56
    /// Tight inset so the glass circles nest into the capsule ends (stopwatch-bar proportions).
    private static let bottomBarInset: CGFloat = 4

    /// One shared dark floating capsule: Liquid Glass exit · elapsed · Liquid Glass workout-type.
    /// The timer is centered in the bar via ZStack; the glass circles sit in a separate HStack so
    /// uneven label widths cannot pull the time off-center. The capsule itself is solid elevated
    /// chrome — not Liquid Glass.
    private var bottomControlRow: some View {
        ZStack {
            bottomElapsedTimer
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                endWorkoutGlassButton
                Spacer(minLength: 0)
                workoutTypeGlassButton
            }
        }
        .padding(Self.bottomBarInset)
        .background {
            NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: true)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space3)
    }

    /// Same `activeWorkout.start` + `TimelineView` source as the hero TIME block — plain primary text,
    /// no card / glass / capsule behind it (the shared bar owns the surface).
    private var bottomElapsedTimer: some View {
        Group {
            if let start = model.activeWorkout?.start {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsed(since: start))
                        .font(StrandFont.number(40)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                }
                .accessibilityLabel(Text("Elapsed time"))
                .accessibilityValue(Text(Self.elapsed(since: start)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var endWorkoutGlassButton: some View {
        Button { showEndConfirm = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("End workout"))
        .accessibilityHint(Text("Stops recording and saves what's captured so far"))
    }

    private var activeSportName: String {
        model.activeWorkout?.sport ?? WorkoutCatalog.defaultSportName
    }

    private var workoutTypeGlassButton: some View {
        Button {
            // Placeholder — sport-type picker lands later; chrome and sizing stay put.
        } label: {
            WorkoutTypeIcon(workoutType: activeSportName, size: 22, weight: .semibold)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("\(WorkoutSource.displaySport(activeSportName)) workout"))
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

// MARK: - Native Liquid Glass workout controls

private extension View {
    /// Platform-owned circular chrome for the live-workout bottom controls. iOS 26 uses the interactive
    /// Liquid Glass button material; macOS and older iOS keep the same circular geometry with the
    /// same native-system material fallback the Home header buttons already use.
    @ViewBuilder
    func nativeLiquidGlassWorkoutControl() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .large) {
            self
                .buttonStyle(LiquidPressStyle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
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
/// preserved verbatim (index bumped to 7 — 6 after the glanceable layout split TIME / HR / Effort / zone
/// into separate stagger slots, then 7 after the live distance/pace card #1195 took the slot before it),
/// so the rendered output matches the previous inline code.
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
            .staggeredAppear(index: 7)
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

/// Live GPS distance + average pace on the active-workout screen, for distance sports (#1195). The main
/// gap this closes: the recorder already computes and publishes `distanceM` / `paceSecPerKm` on every
/// accepted fix, but they were only ever shown in the post-workout detail view — never live.
///
/// A standalone leaf that owns its OWN `@ObservedObject` on the recorder (the parent `LiveWorkoutView`
/// does not observe it), so a GPS fix re-renders only this card — not the HR hero / effort gauge above,
/// the same scroll-stutter isolation as `SensorRowIfPresent`. Self-gates to nothing until the first
/// accepted fix, so a denied-permission or GPS-less (Mac) session shows no empty card. Mirrors Android's
/// gated distance/pace row in `LiveWorkoutScreen`.
private struct DistancePaceRowIfPresent: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        // `isRecording` is essential, not just `pointCount > 0`: the recorder is a single long-lived
        // object and `stop()` leaves `pointCount`/`distanceM` intact (only `start()` resets them, and it
        // runs solely for distance sports). Without the `isRecording` guard a non-GPS workout started
        // after a GPS one would show the previous session's stale distance. Together they mean "a GPS
        // recording is live AND has at least one accepted fix" — the Android `gpsEnabled && track` twin.
        if recorder.isRecording, recorder.pointCount > 0 {
            NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
                HStack(spacing: 0) {
                    // "Distance"/"Pace" are already localized (reused from the detail view); uppercased for
                    // the caps stat grid, exactly as the detail route stats do.
                    stat(String(localized: "Distance").uppercased(),
                         UnitFormatter.distanceFromMeters(recorder.distanceM, system: unitSystem))
                    statDivider
                    stat(String(localized: "Pace").uppercased(),
                         UnitFormatter.paceFromSecPerKm(recorder.paceSecPerKm, system: unitSystem))
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(28))
                .foregroundStyle(StrandPalette.effortColor)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 48)
    }
}
