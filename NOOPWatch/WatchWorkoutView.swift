import SwiftUI
import StrandDesign
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - WatchWorkoutView — record a workout ON the wrist (M3)
//
// This is the one ACTIVE feature where the watch is the brain, not the phone. The phone owns SCORES; this
// screen owns a real HKWorkoutSession + HKLiveWorkoutBuilder running on the watch's own sensors, so the
// heart rate here is the higher-fidelity in-workout stream (not the foregrounded anchored-query readout the
// glance uses), and the energy is the watch's own activeEnergyBurned. On End we save the finished workout
// to HealthKit so it shows up in Activity / Fitness like any other.
//
// We deliberately reimplement the phone's LiveWorkoutView rather than link it: that screen reads the strap
// feed and the shared scorers off AppModel, which don't exist on the watch. The framing is kept though —
// a generic "functional" workout (functionalStrengthTraining), a big live HR hero in SF-Rounded, elapsed
// time, and the building Effort idea expressed honestly here as the live calorie burn from the wrist.
//
// Everything is GUARDED. If HealthKit is unavailable or workout authorization is denied, we show a calm
// "Grant Health access" state instead of a dead Start button. StrandHaptic (real WatchKit path now) marks
// the start / pause / resume / end landings so the wrist confirms each state change without looking.
struct WatchWorkoutView: View {
    @StateObject private var workout = WatchWorkoutSession()

    var body: some View {
        // One screen, no scrolling. A GeometryReader hands each state the real space it has to live in so
        // the controls never fall below the fold on any watch size. The recording state in particular sizes
        // its HR hero to whatever height is left after the fixed header and the fixed control row.
        GeometryReader { geo in
            Group {
                switch workout.phase {
                case .unavailable, .denied:
                    grantAccess
                case .idle:
                    idle
                case .requesting:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .active, .paused, .ending:
                    recording(in: geo.size)
                case .saved:
                    saved
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .padding(.horizontal, 4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    // MARK: Pre-flight states

    /// HealthKit unavailable or workout write denied. Honest about it, with a retry that re-asks (or sends
    /// the user to Settings if the system has already remembered a hard "no").
    private var grantAccess: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 24))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Grant Health access")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            // Condensed so the whole panel clears the fold on a 41mm.
            Text("Live heart rate and energy, recorded on your wrist. Stays on device.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            Button("Allow access") { workout.requestAuthorization() }
                .font(StrandFont.subhead)
                .tint(StrandPalette.effortColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    /// Ready to record. A single big Effort-tinted Start.
    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.strengthtraining.functional")
                .font(.system(size: 30))
                .foregroundStyle(StrandPalette.effortColor)
            Text("Workout")
                .font(StrandFont.rounded(22, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Functional strength")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Button {
                workout.start()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(StrandFont.subhead)
                    .frame(maxWidth: .infinity)
            }
            .tint(StrandPalette.effortColor)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Recording

    /// The whole recording layout, sized to fit ONE screen. We reserve fixed heights for the compact header,
    /// the stats row, and the side-by-side control row, then hand whatever is left to the HR hero so End is
    /// always on screen. The hero gets the remaining height (floored so it never collapses), which keeps the
    /// big SF-Rounded BPM the visual anchor on a 41mm and lets it breathe on the bigger watches.
    private func recording(in size: CGSize) -> some View {
        let spacing: CGFloat = 6
        let headerH: CGFloat = 22
        let statsH: CGFloat = 50
        let controlsH: CGFloat = 40
        let reserved = headerH + statsH + controlsH + spacing * 4   // 3 gaps + a little breathing room
        let heroH = max(56, size.height - reserved)

        return VStack(spacing: spacing) {
            header
                .frame(height: headerH)
            heroHeartRate
                .frame(maxHeight: heroH)
            statsRow
                .frame(height: statsH)
            controls
                .frame(height: controlsH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(workout.phase == .paused ? StrandPalette.statusWarning : StrandPalette.statusCritical)
                .frame(width: 7, height: 7)
            Text(workout.phase == .paused ? String(localized: "PAUSED") : String(localized: "RECORDING"))
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(workout.phase == .paused ? StrandPalette.statusWarning : StrandPalette.metricRose)
            Spacer()
            // Elapsed time ticks itself off the session start via a TimelineView, so we never run a manual
            // Timer. While paused we freeze the readout at the accumulated duration the session reports.
            elapsed
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var elapsed: some View {
        if workout.phase == .paused {
            // Frozen while paused: builder.elapsedTime freezes on pause, so liveElapsed() reads the same
            // pause-accurate value the active clock last showed — no reliance on the pause event's timing.
            Text(Self.clock(workout.liveElapsed()))
                .font(StrandFont.rounded(18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.clock(workout.liveElapsed()))
                    .font(StrandFont.rounded(18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// The big live wrist heart rate, SF-Rounded, on a near-black Effort-tinted card. A dash until the
    /// first in-session sample lands.
    private var heroHeartRate: some View {
        VStack(spacing: 1) {
            Text("HEART RATE")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(StrandPalette.statusCritical)
                Text(workout.bpm.map(String.init) ?? "–")
                    .font(StrandFont.rounded(40, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Text("bpm")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Active energy from the watch's own builder, the watch-native stand-in for the phone's building
    /// Effort. Whole kcal, SF-Rounded, never a fabricated number (a dash until the builder reports any).
    private var statsRow: some View {
        HStack(spacing: 6) {
            stat("ENERGY", workout.activeKcal.map { "\($0)" } ?? "–", unit: "kcal",
                 tint: StrandPalette.effortColor)
            stat("AVG HR", workout.avgBpm.map(String.init) ?? "–", unit: "bpm",
                 tint: StrandPalette.metricRose)
        }
    }

    private func stat(_ title: String, _ value: String, unit: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(StrandFont.overlineScaled(9))
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.rounded(24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(StrandFont.overlineScaled(8))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Pause/Resume and End sit SIDE BY SIDE on one row so both are always on screen without scrolling.
    /// Icon-only buttons keep them compact on a 41mm; the role/tint still reads at a glance (Effort-tinted
    /// pause/resume, critical-red End).
    private var controls: some View {
        HStack(spacing: 8) {
            if workout.phase == .paused {
                Button {
                    workout.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .font(StrandFont.subhead)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityLabel("Resume")
                .tint(StrandPalette.effortColor)
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    workout.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                        .font(StrandFont.subhead)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityLabel("Pause")
                .tint(StrandPalette.surfaceRaised)
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                workout.end()
            } label: {
                Label("End", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(StrandFont.subhead)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityLabel("End workout")
            .tint(StrandPalette.statusCritical)
            .buttonStyle(.borderedProminent)
            .disabled(workout.phase == .ending)
        }
    }

    // MARK: Saved

    private var saved: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(StrandPalette.chargeColor)
            Text("Workout saved")
                .font(StrandFont.rounded(20, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            // A small honest recap of what we banked. Whole-phrase per shape (no appended tail)
            // so the kcal variant localizes as one string.
            Text(workout.activeKcal.map { String(localized: "\(Self.clock(workout.elapsed)) · \($0) kcal") }
                 ?? Self.clock(workout.elapsed))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Button("Done") { workout.reset() }
                .font(StrandFont.subhead)
                .tint(StrandPalette.effortColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    /// m:ss for short sessions, h:mm:ss once we cross the hour. Whole seconds, monospaced at the call site.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - WatchWorkoutSession — the HKWorkoutSession + HKLiveWorkoutBuilder engine
//
// Owns the live workout lifecycle on the watch. The view is pure; this object is the only thing that talks
// to HealthKit. Every published value comes from the builder's own statistics (HR / active energy) or the
// session's accumulated duration, so the numbers the wrist shows are the ones HealthKit will save. Nothing
// is invented: a metric stays nil until its first real sample lands and the UI renders a dash for nil.
final class WatchWorkoutSession: NSObject, ObservableObject {

    /// Where we are in the lifecycle. The view switches its whole layout on this.
    enum Phase: Equatable {
        case unavailable   // HealthKit not on this device at all
        case denied        // workout write authorization refused
        case idle          // authorized, ready to start
        case requesting    // auth prompt in flight
        case active        // recording
        case paused        // recording, paused
        case ending        // end() in flight, saving to HealthKit
        case saved         // saved, showing the recap
    }

    @Published private(set) var phase: Phase = .idle
    /// Live wrist heart rate (whole BPM) from the builder, or nil before the first sample.
    @Published private(set) var bpm: Int?
    /// Session-average heart rate so far, or nil before the first sample.
    @Published private(set) var avgBpm: Int?
    /// Active energy burned this session in whole kcal, or nil before the first sample.
    @Published private(set) var activeKcal: Int?
    /// Accumulated session duration. Read live by the view's TimelineView while active.
    @Published private(set) var elapsed: TimeInterval = 0

    #if canImport(HealthKit) && os(watchOS)
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private let hrUnit = HKUnit.count().unitDivided(by: .minute())
    private let kcalUnit = HKUnit.kilocalorie()

    /// What we ask to write: the workout itself plus the two series we surface live. Read-only HR is for the
    /// live readout. Mirrors the phone's "we never invent, we record" stance.
    private var shareTypes: Set<HKSampleType> {
        var set: Set<HKSampleType> = [HKQuantityType.workoutType()]
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { set.insert(e) }
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { set.insert(hr) }
        return set
    }
    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { set.insert(hr) }
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { set.insert(e) }
        return set
    }
    #endif

    override init() {
        super.init()
        refreshAvailability()
    }

    /// Decide the initial phase from HealthKit availability and the write status we already hold. We do not
    /// ask for permission here, only on Start or the explicit "Allow access" button, so opening the tab is
    /// quiet (Apple's guidance: prompt at the point of use).
    private func refreshAvailability() {
        #if canImport(HealthKit) && os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { phase = .unavailable; return }
        let status = store.authorizationStatus(for: HKQuantityType.workoutType())
        phase = (status == .sharingDenied) ? .denied : .idle
        #else
        phase = .unavailable
        #endif
    }

    /// Explicit auth request (the "Allow access" button). Idempotent; HealthKit no-ops if already decided.
    func requestAuthorization(then start: Bool = false) {
        #if canImport(HealthKit) && os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { phase = .unavailable; return }
        phase = .requesting
        store.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // requestAuthorization's `granted` only reports whether the sheet was shown, not the user's
                // choice, so we read the real share status back. Denied write = no workout to save.
                let status = self.store.authorizationStatus(for: HKQuantityType.workoutType())
                if status == .sharingDenied {
                    self.phase = .denied
                } else {
                    self.phase = .idle
                    if start { self.start() }
                }
            }
        }
        #else
        phase = .unavailable
        #endif
    }

    /// Begin recording a generic functional-strength workout indoors. If we have not been authorized yet,
    /// route through the auth prompt first and auto-start on grant.
    func start() {
        #if canImport(HealthKit) && os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { phase = .unavailable; return }
        let status = store.authorizationStatus(for: HKQuantityType.workoutType())
        guard status == .sharingAuthorized else {
            requestAuthorization(then: true)
            return
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .functionalStrengthTraining
        config.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            let begin = Date()
            session.startActivity(with: begin)
            builder.beginCollection(withStart: begin) { [weak self] _, _ in
                // Collection started (or failed silently); the delegate callbacks drive the UI from here.
                DispatchQueue.main.async { self?.phase = .active }
            }
            StrandHaptic.commit.play()  // a firm tap confirms the session is live without looking
        } catch {
            // Could not create the session (rare). Fall back to idle so Start can be tried again.
            phase = .idle
        }
        #else
        phase = .unavailable
        #endif
    }

    func pause() {
        #if canImport(HealthKit) && os(watchOS)
        session?.pause()
        // The session's didChangeTo callback flips us to .paused; haptic there so it matches the real state.
        #endif
    }

    func resume() {
        #if canImport(HealthKit) && os(watchOS)
        session?.resume()
        #endif
    }

    /// Live elapsed time for the ticking clock. `HKLiveWorkoutBuilder.elapsedTime` is pause-aware and
    /// advances continuously while recording — independent of whether samples arrive — so read it live on
    /// each TimelineView tick rather than only in the sample/event callbacks, which left the clock frozen
    /// at 0:00 when no samples landed (loose watch, denied HR-read). Falls back to the last stored value
    /// once the builder is gone (the saved recap, where `elapsed` holds the finalized duration). (@bhelm)
    func liveElapsed() -> TimeInterval {
        #if canImport(HealthKit) && os(watchOS)
        return builder?.elapsedTime ?? elapsed
        #else
        return elapsed
        #endif
    }

    /// Stop the session, finalize collection, and save the workout to HealthKit. The recap appears on save.
    func end() {
        #if canImport(HealthKit) && os(watchOS)
        guard let session, let builder, phase == .active || phase == .paused else { return }
        phase = .ending
        let stop = Date()
        session.stopActivity(with: stop)
        // Freeze the final duration for the recap NOW: the builder is niled below, and the stored `elapsed`
        // was otherwise only ever advanced by sample callbacks — so a sparse-sample session showed a
        // too-short recap. finishWorkout's authoritative HKWorkout.duration overrides it just below. (@bhelm)
        elapsed = builder.elapsedTime
        builder.endCollection(withEnd: stop) { [weak self] _, _ in
            builder.finishWorkout { [weak self] hkWorkout, _ in
                DispatchQueue.main.async {
                    if let duration = hkWorkout?.duration { self?.elapsed = duration }
                    StrandHaptic.success.play()  // milestone: the workout is banked to HealthKit
                    self?.phase = .saved
                    self?.session = nil
                    self?.builder = nil
                }
            }
        }
        #else
        phase = .saved
        #endif
    }

    /// Clear the recap and return to idle so another workout can be started.
    func reset() {
        bpm = nil
        avgBpm = nil
        activeKcal = nil
        elapsed = 0
        refreshAvailability()
    }
}

// MARK: - HealthKit delegates

#if canImport(HealthKit) && os(watchOS)
extension WatchWorkoutSession: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch toState {
            case .running:
                if self.phase != .active { StrandHaptic.selection.play() }
                self.phase = .active
            case .paused:
                self.phase = .paused
                StrandHaptic.light.play()  // soft tap marks the pause landing
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        // The session died on us. Surface idle so the user can retry rather than sitting on a frozen screen.
        DispatchQueue.main.async { [weak self] in
            self?.phase = .idle
            self?.session = nil
            self?.builder = nil
        }
    }
}

extension WatchWorkoutSession: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Pause / resume events update the accumulated duration the elapsed readout shows.
        DispatchQueue.main.async { [weak self] in
            self?.elapsed = workoutBuilder.elapsedTime
        }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // A new batch of samples landed. Pull the latest HR, the running average HR, and total active
        // energy straight from the builder's own statistics so the wrist shows exactly what HealthKit holds.
        var newBpm: Int?
        var newAvg: Int?
        var newKcal: Int?

        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
           collectedTypes.contains(hrType),
           let stats = workoutBuilder.statistics(for: hrType) {
            if let recent = stats.mostRecentQuantity()?.doubleValue(for: hrUnit) {
                newBpm = Int(recent.rounded())
            }
            if let avg = stats.averageQuantity()?.doubleValue(for: hrUnit) {
                newAvg = Int(avg.rounded())
            }
        }

        if let eType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
           collectedTypes.contains(eType),
           let stats = workoutBuilder.statistics(for: eType),
           let total = stats.sumQuantity()?.doubleValue(for: kcalUnit) {
            newKcal = Int(total.rounded())
        }

        let elapsedNow = workoutBuilder.elapsedTime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let newBpm { self.bpm = newBpm }
            if let newAvg { self.avgBpm = newAvg }
            if let newKcal { self.activeKcal = newKcal }
            self.elapsed = elapsedNow
        }
    }
}
#endif
