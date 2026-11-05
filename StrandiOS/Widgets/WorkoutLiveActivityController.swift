#if os(iOS)
import Foundation
import ActivityKit
import Combine
import UIKit

/// Starts, updates and ends the live-tracked workout Live Activity (`WorkoutActivityAttributes`).
///
/// Modelled on `LiftLiveActivityController` and separate from the live-HR banner, with its own switch
/// (`UnitPrefs.workoutLiveActivityEnabled`), so a runner can keep this one with the everyday heart-rate banner off.
/// It follows `AppModel.activeWorkout` from process start (`follow`): a banner appears when a workout starts with
/// NOOP on screen, and ends when the workout ends or is deleted, or the switch is turned off.
///
/// PUSHES ARE CONTENT-DRIVEN, NOT CLOCK-DRIVEN. The clock ticks in the widget from `timerStart`, so a push is sent
/// at once only for a pause / resume, and otherwise when the heart rate, distance or pace has moved and at least
/// `numbersInterval` has passed: a GPS fix lands about once a second, and pushing each one would be throttled.
@MainActor
final class WorkoutLiveActivityController {
    private var activity: Activity<WorkoutActivityAttributes>?
    /// A workout banner is on screen — what NOOP's live heart rate banner makes room for, since this one carries
    /// the heart rate itself.
    var isShowing: Bool { activity != nil }
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var lastPush: Date = .distantPast
    private var shownState: WorkoutActivityAttributes.ContentState?
    /// Cached for the controller's lifetime, as in the other controllers: its value changes only via Settings.
    private let authInfo = ActivityAuthorizationInfo()
    /// Guards against two refreshes both firing `Activity.request` before the first has returned.
    private var isStarting = false
    /// An end is in flight, so ticks meanwhile neither end it again nor start a new one for the same workout.
    private var isEnding = false
    /// Set while a workout runs with no banner that NOOP may start, so the reason is logged once.
    private var waitingForForeground = false
    /// iOS refused a start and it was logged: once, not on every tick while NOOP is on screen.
    private var refusalLogged = false
    /// Minimum spacing between pushes for changed numbers (heart rate, distance, pace).
    static let numbersInterval: TimeInterval = 5
    /// Generous, because the clock ticks client-side; the heart rate is cleared app-side when the strap drops.
    private static let staleAfter: TimeInterval = 15 * 60

    /// Follow the workout from process start, like the live-HR banner: a banner a previous run left on the Lock
    /// Screen is picked up and fed, or ended if that workout is gone. Called once, from the app's `init`.
    func follow(_ model: AppModel) {
        self.model = model
        LiveHRBannerInputs.settled([
            model.$activeWorkout.map { _ in () }.eraseToAnyPublisher(),
            model.gpsRecorder.$distanceM.map { _ in () }.eraseToAnyPublisher(),
            model.gpsRecorder.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            model.live.$heartRate.map { _ in () }.eraseToAnyPublisher(),
            model.live.$connected.map { _ in () }.eraseToAnyPublisher(),
            model.$bpm.map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)
        // The switch acts at once, not at the next tick.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UnitPrefs.workoutLiveActivityEnabled() }
            .prepend(UnitPrefs.workoutLiveActivityEnabled())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// NOOP came on screen, the only time iOS lets it start a banner: a workout that began while iOS refused one
    /// (or before the switch was turned on) gets its banner now.
    func appBecameActive() {
        refresh(appActive: true)
    }

    private func refresh(appActive: Bool? = nil) {
        guard let model, authInfo.areActivitiesEnabled else { return }

        // A banner swiped off the Lock Screen, or ended by iOS, takes no more updates: let it go.
        if !isEnding, let current = activity, !Self.isShowing(current) {
            activity = nil
            shownState = nil
        }
        // Re-adopt a banner that outlived a previous app session (ActivityKit keeps them across relaunches).
        if activity == nil, !isEnding,
           let adopted = Activity<WorkoutActivityAttributes>.activities.first(where: Self.isShowing) {
            activity = adopted
            log("picked up the one already on the Lock Screen")
        }

        guard UnitPrefs.workoutLiveActivityEnabled(), let workout = model.activeWorkout else {
            if activity != nil, !isEnding {
                isEnding = true
                log(UnitPrefs.workoutLiveActivityEnabled() ? "ended with the workout" : "ended: its switch is off")
                Task { await end() }
            }
            waitingForForeground = false
            return
        }
        guard !isEnding else { return }

        let state = contentState(model, workout)
        let now = Date()
        if let activity {
            guard pushDue(state, now: now) else { return }
            lastPush = now
            shownState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))) }
            return
        }

        // iOS starts a Live Activity only for the app on screen; asked from the background it throws.
        guard appActive ?? (UIApplication.shared.applicationState == .active) else {
            if !waitingForForeground {
                waitingForForeground = true
                log("no Lock Screen banner yet — iOS starts one only while NOOP is open")
            }
            return
        }
        waitingForForeground = false
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            activity = try Activity.request(
                attributes: WorkoutActivityAttributes(
                    sport: workout.sport,
                    tracksRoute: model.activeWorkoutIsGps,
                    durationLabel: String(localized: "Duration"),
                    distanceLabel: String(localized: "Distance"),
                    paceLabel: String(localized: "Pace"),
                    pausedLabel: String(localized: "Paused")),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil)
            lastPush = now
            shownState = state
            refusalLogged = false
            log("started")
        } catch {
            activity = nil
            if !refusalLogged {
                refusalLogged = true
                log("iOS did not start it: \(error.localizedDescription)")
            }
        }
    }

    /// A pause / resume (the clock) is pushed at once; the numbers when they moved and `numbersInterval` has passed.
    private func pushDue(_ next: WorkoutActivityAttributes.ContentState, now: Date) -> Bool {
        guard let shown = shownState else { return true }
        if shown.timerStart != next.timerStart || shown.pausedElapsed != next.pausedElapsed {
            return true
        }
        guard shown != next else { return false }
        return now.timeIntervalSince(lastPush) >= Self.numbersInterval
    }

    /// The banner's figures from the live workout. Distance and pace come from the GPS recorder only for a GPS
    /// session with at least one accepted fix, the same gate as the live workout screen's distance/pace row; while
    /// paused the recorder is not recording, so the workout's pause decides then.
    private func contentState(_ model: AppModel, _ w: AppModel.ActiveWorkout) -> WorkoutActivityAttributes.ContentState {
        let gps = model.gpsRecorder
        let hasRoute = model.activeWorkoutIsGps && gps.pointCount > 0 && (gps.isRecording || w.isPaused)
        let defaults = UserDefaults.standard
        let units = UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: defaults.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric,
            override: defaults.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        let connected = model.live.connected
        return WorkoutActivityAttributes.ContentState(
            bpm: connected ? (model.bpm ?? model.live.heartRate) : nil,
            timerStart: w.start.addingTimeInterval(w.pausedDuration),
            pausedElapsed: w.isPaused ? Int(w.elapsed().rounded(.down)) : nil,
            distance: hasRoute ? UnitFormatter.distanceFromMeters(gps.distanceM, system: units) : nil,
            pace: hasRoute && gps.paceSecPerKm != nil
                ? UnitFormatter.paceFromSecPerKm(gps.paceSecPerKm, system: units) : nil)
    }

    private func end() async {
        // Every workout banner, not just the cached handle: covers a straggler from a previous app session.
        for act in Activity<WorkoutActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        shownState = nil
        isEnding = false
    }

    /// One strap-log line per thing that happens to the banner (started, picked up, ended). Rare, so always on.
    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped("Workout banner: " + line))
    }

    /// Still on the Lock Screen and taking updates: not ended by the app or iOS, not swiped away.
    private static func isShowing(_ activity: Activity<WorkoutActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale: return true
        default: return false
        }
    }
}
#endif
