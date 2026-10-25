#if os(iOS)
import Foundation
import Combine
import WidgetKit
import ActivityKit
import UIKit
import UserNotifications
import SwiftUI

/// App-owned actions and deadlines. Screens, notifications, widgets and activities use this one path.
@MainActor
final class TrainingCoordinator: ObservableObject {
    @Published var foregroundConfirmation: TrainingDisplay?
    @Published var foregroundPulseLoss: TrainingDisplay?
    @Published var foregroundError: String?
    static let pulseStateKey = "noop.trainingPulseState"
    private let model: AppModel
    private let lift: LiftSessionController
    private let liftActivity: LiftLiveActivityController
    private var guards: [String: TrainingPulseGuard]
    private var confirmations: [String: TrainingEndConfirmation] = [:]
    private var errors: [String: String] = [:]
    private var wasPaused: [String: Bool] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Task<Void, Never>?
    private var armedDeadline: Double?
    private var lastCheckpoint: [String: Int] = [:]
    private var workoutActivity: Activity<WorkoutActivityAttributes>?
    private var lastWorkoutState: WorkoutActivityAttributes.ContentState?
    private var lastWidgetSnapshot: TrainingSnapshot?
    private var workoutUpdate: Task<Void, Never>?
    var isShowingWorkout: Bool { workoutActivity?.activityState == .active || workoutActivity?.activityState == .stale }
    private var canStartFromIntent = false
    private var holdsRealtimeHR = false
    private var connectionAvailable = false

    init(model: AppModel, lift: LiftSessionController, liftActivity: LiftLiveActivityController) {
        self.model = model; self.lift = lift; self.liftActivity = liftActivity
        guards = UserDefaults.standard.data(forKey: Self.pulseStateKey)
            .flatMap { try? JSONDecoder().decode([String: TrainingPulseGuard].self, from: $0) } ?? [:]
        for session in TrainingSnapshot.load().sessions {
            if let confirmation = TrainingEndConfirmation(restoring: session) { confirmations[session.id] = confirmation }
        }
        // Install before any scene; receipt precedes biometric publication, including after a long suspension.
        model.live.onReadableHeartRate = { [weak self] date in self?.receivedPulse(at: date) }
        TrainingIntentHandler.perform = { [weak self] action, id, favorite, token in
            guard let self else { throw CocoaError(.featureUnsupported) }
            let started = ProcessInfo.processInfo.systemUptime
            let sessionMatched = self.ids.contains(id)
            self.canStartFromIntent = true
            defer {
                self.canStartFromIntent = false
                if TestCentre.active(.display) {
                    let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    DisplayPerformanceMonitor.shared.emit?("trainingIntent action=\(action) handlerMs=\(String(format: "%.1f", ms)) sessionMatched=\(sessionMatched) confirming=\(self.confirmations[id] != nil) activeSessions=\(self.ids.count)")
                }
            }
            do { try await self.perform(action, id: id, favorite: favorite, token: token) }
            catch {
                await self.flushActivityUpdates()
                throw error
            }
            await self.flushActivityUpdates()
        }
        model.$activeWorkout.dropFirst().debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }.store(in: &subscriptions)
        lift.changesSettled.sink { [weak self] _ in self?.reconcile() }.store(in: &subscriptions)
        lift.strapStepTaken.sink { [weak self] _ in self?.publish(alert: true) }.store(in: &subscriptions)
        model.live.$heartRate.sink { [weak model, weak liftActivity] bpm in
            liftActivity?.updateHeartRate(model?.live.connected == true ? (model?.bpm ?? bpm) : nil)
        }.store(in: &subscriptions)
        model.live.$connected.removeDuplicates().sink { [weak self] connected in
            self?.connectionAvailable = connected
            self?.reconcile()
        }.store(in: &subscriptions)
        NotificationPresenter.shared.onTrainingAction = { [weak self] action, id, completion in
            Task {
                defer { completion() }
                do {
                    try await self?.perform(action, id: id)
                    if action == "requestEnd" {
                        self?.foregroundConfirmation = TrainingSnapshot.load().sessions.first { $0.id == id }
                    }
                } catch { self?.foregroundError = error.localizedDescription }
            }
        }
        registerNotifications()
        reconcile()
        Task { await lift.loadLastSession(repo: model.repo) }
    }

    private var ids: [String] {
        var ids: [String] = []
        if let workout = model.activeWorkout { ids.append(workout.sessionID) }
        if lift.isActive { ids.append(lift.sessionID) }
        return ids
    }
    private func isPaused(_ id: String) -> Bool {
        if let workout = model.activeWorkout, workout.sessionID == id { return workout.isPaused }
        return lift.sessionID == id && lift.engine?.isPaused == true
    }

    private func receivedPulse(at date: Date) {
        let now = Int(date.timeIntervalSince1970)
        // An accepted live packet proves a link even if its connection publication arrives later.
        connectionAvailable = true
        reconcile(at: date, publish: false)
        for id in ids where !isPaused(id) {
            var guardState = guards[id] ?? TrainingPulseGuard()
            let first = guardState.lastSampleSec == nil
            guardState.receive(at: now)
            guards[id] = guardState
            if first || now - (lastCheckpoint[id] ?? 0) >= TrainingPulseGuard.checkpointSeconds {
                lastCheckpoint[id] = now
                persistGuards()
                scheduleNotification(id: id, at: date.addingTimeInterval(630))
                // One publication per checkpoint, never one per raw realtime frame.
                publish()
            }
        }
        armTimer()
    }

    func reconcile(at date: Date = Date(), publish shouldPublish: Bool = true) {
        let now = Int(date.timeIntervalSince1970)
        let active = Set(ids)
        var pulseLossID: String?
        let wantsRealtimeHR = !active.isEmpty
        if wantsRealtimeHR != holdsRealtimeHR {
            holdsRealtimeHR = wantsRealtimeHR
            if wantsRealtimeHR { model.startRealtimeHR() } else { model.stopRealtimeHR() }
        }
        for id in Array(guards.keys) where !active.contains(id) {
            guards.removeValue(forKey: id); confirmations.removeValue(forKey: id)
            lastCheckpoint.removeValue(forKey: id); errors.removeValue(forKey: id); wasPaused.removeValue(forKey: id)
            cancelNotification(id)
        }
        for id in ids {
            let paused = isPaused(id)
            if var state = guards[id] {
                state.setConnected(connectionAvailable, at: now)
                if state != guards[id] {
                    guards[id] = state
                    lastCheckpoint.removeValue(forKey: id)
                    cancelNotification(id)
                    if !paused, let deadline = state.deadline {
                        scheduleNotification(id: id, at: Date(timeIntervalSince1970: Double(deadline + 30)))
                    }
                    persistGuards()
                }
            }
            if wasPaused[id] == true && !paused {
                guards[id]?.resume(at: now)
                lastCheckpoint.removeValue(forKey: id)
                cancelNotification(id)
                if let deadline = guards[id]?.deadline {
                    scheduleNotification(id: id, at: Date(timeIntervalSince1970: Double(deadline + 30)))
                }
                persistGuards()
            }
            if paused && wasPaused[id] != true { cancelNotification(id) }
            if paused && wasPaused[id] == nil && (model.activeWorkout?.sessionID == id
                ? model.activeWorkout?.pausedForPulseLoss == true : lift.pausedForPulseLoss) { pulseLossID = id }
            if !paused, let guardState = guards[id], guardState.isDue(at: now), let deadline = guardState.deadline {
                pause(id, at: Date(timeIntervalSince1970: Double(deadline)), pulseLoss: true)
                cancelNotification(id)
                scheduleNotification(id: id, at: date.addingTimeInterval(1))
                persistGuards()
                pulseLossID = id
            }
            wasPaused[id] = isPaused(id)
        }
        confirmations = confirmations.filter { active.contains($0.key) && $0.value.until > date }
        if let prompt = foregroundPulseLoss, !active.contains(prompt.id) || !isPaused(prompt.id) { foregroundPulseLoss = nil }
        if shouldPublish || pulseLossID != nil { publish() }
        if let pulseLossID { foregroundPulseLoss = TrainingSnapshot.load().sessions.first { $0.id == pulseLossID } }
        armTimer()
    }

    private func pause(_ id: String, at date: Date = Date(), pulseLoss: Bool = false) {
        if model.activeWorkout?.sessionID == id { model.pauseWorkout(at: date, pulseLoss: pulseLoss) }
        else if lift.sessionID == id { lift.pause(at: Int(date.timeIntervalSince1970), pulseLoss: pulseLoss) }
    }

    func perform(_ action: String, id: String = "", favorite: Int = -1, token: String = "") async throws {
        reconcile(publish: false)
        defer { reconcile(); persistGuards() }
        if action == "start" {
            guard UserDefaults.standard.bool(forKey: "noop.onboarded"),
                  UserDefaults.standard.string(forKey: "noop.acceptedTermsVersion") == Terms.currentVersion else { throw CocoaError(.userCancelled) }
            let favorites = TrainingFavorite.load()
            guard favorites.indices.contains(favorite) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let selected = favorites[favorite]
            if let programID = selected.programID {
                guard !lift.isActive, !lift.isSaving else { return }
                guard let store = await model.repo.storeHandle(),
                      let program = try await store.liftPrograms(deviceId: model.repo.deviceId).first(where: { $0.id == programID }) else { throw CocoaError(.fileReadNoSuchFile) }
                try await lift.start(program: program, repo: model.repo, present: false)
            } else if let sport = selected.sport, WorkoutCatalog.sport(named: sport) != nil {
                model.startWorkout(sport: sport)
            } else { throw CocoaError(.fileReadNoSuchFile) }
            // Permission is requested only by explicit settings, never by a background intent.
        } else {
            guard ids.contains(id), !model.isFinishingWorkout, !lift.isSaving else { return }
            switch action {
            case "pause": pause(id)
            case "resume":
                if model.activeWorkout?.sessionID == id { model.resumeWorkout() }
                else { lift.resume() }
            case "requestEnd":
                confirmations[id] = TrainingEndConfirmation(sessionID: id)
            case "cancelEnd": confirmations.removeValue(forKey: id)
            case "confirmEnd":
                guard let confirmation = confirmations[id], confirmation.accepts(sessionID: id, token: token) else { return }
                confirmations.removeValue(forKey: id)
                do {
                    if model.activeWorkout?.sessionID == id { try await model.finishWorkout() }
                    else {
                        _ = try await lift.save(repo: model.repo, completingUnfinished: false, sessionRpe: nil)
                        lift.finishedSaving()
                        await model.repo.refresh()
                    }
                    errors.removeValue(forKey: id)
                    cancelNotification(id)
                } catch {
                    errors[id] = String(localized: "Training could not be saved")
                    throw error
                }
            default: throw CocoaError(.validationMissingMandatoryProperty)
            }
        }
    }

    private func persistGuards() {
        if let data = try? JSONEncoder().encode(guards.mapValues(\.checkpoint)) { UserDefaults.standard.set(data, forKey: Self.pulseStateKey) }
    }
    private func flushActivityUpdates() async {
        // User actions finish their ActivityKit update before the intent returns.
        await workoutUpdate?.value
        await liftActivity.pendingUpdate?.value
    }
    private func armTimer() {
        let deadlines = ids.filter { !isPaused($0) }.compactMap { guards[$0]?.deadline }.map(Double.init)
            + confirmations.values.map { $0.until.timeIntervalSince1970 }
        guard let next = deadlines.min() else { timer?.cancel(); timer = nil; armedDeadline = nil; return }
        if timer != nil, let armedDeadline, abs(next - armedDeadline) < 30 { return }
        timer?.cancel()
        armedDeadline = next
        let delay = max(0.01, min(Double(TrainingPulseGuard.timeoutSeconds), next - Date().timeIntervalSince1970))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.armedDeadline = nil
            self?.reconcile()
        }
    }

    static func sportTitle(_ sport: String) -> String {
        switch sport {
        case "Strength": return String(localized: "Strength training")
        case "Running": return String(localized: "Running workout")
        default: return sport
        }
    }

    private var labels: [String: String] { [
        "pause": String(localized: "Pause"), "resume": String(localized: "Resume"),
        "end": String(localized: "End training"), "confirm": String(localized: "Really end training?"),
        "yes": String(localized: "Yes, end training"), "cancel": String(localized: "Cancel"),
        "completedOnly": String(localized: "Only completed sets will be saved."),
        "paused": String(localized: "Paused"), "running": String(localized: "Training"),
        "configure": String(localized: "Configure training favorites in NOOP")
    ] }
    private func display(id: String, kind: String, title: String, start: Date, pausedAt: Date?, pausedDuration: TimeInterval, sport: String? = nil) -> TrainingDisplay {
        TrainingDisplay(id: id, kind: kind, title: title, clockStart: start.addingTimeInterval(pausedDuration), pausedAt: pausedAt,
                        pulseDeadline: guards[id]?.checkpoint.deadline.map { Date(timeIntervalSince1970: Double($0)) },
                        confirmationUntil: confirmations[id]?.until, confirmationToken: confirmations[id]?.token, error: errors[id], sport: sport)
    }
    func publish(alert: Bool = false) {
        var sessions: [TrainingDisplay] = []
        if let w = model.activeWorkout { sessions.append(display(id: w.sessionID, kind: "workout", title: Self.sportTitle(w.sport),
                                                               start: w.start, pausedAt: w.pausedAt, pausedDuration: w.pausedDuration, sport: w.sport)) }
        if let e = lift.engine, !e.isFinished {
            sessions.append(display(id: lift.sessionID, kind: "lift", title: lift.programName ?? String(localized: "Strength training"),
                                    start: Date(timeIntervalSince1970: Double(e.startTs)), pausedAt: e.pausedAt.map { Date(timeIntervalSince1970: Double($0)) },
                                    pausedDuration: Double(e.pausedDuration)))
        }
        var favorites = TrainingFavorite.load()
        for i in favorites.indices where favorites[i].name.isEmpty {
            favorites[i].name = favorites[i].sport.flatMap { Self.sportTitle($0) } ?? labels["configure"] ?? ""
        }
        let snapshot = TrainingSnapshot(favorites: favorites, sessions: sessions, labels: labels)
        if snapshot != lastWidgetSnapshot {
            snapshot.save(); lastWidgetSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: "NOOPTrainingWidget")
        }
        pushWorkout(sessions.first(where: { $0.kind == "workout" }))
        if let p = lift.presentation(system: UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric) {
            var state = LiftActivityAttributes.ContentState(isResting: p.isResting, exercise: p.exercise, status: p.status, detail: p.detail,
                                                           bpm: model.live.connected ? model.bpm : nil, next: p.next, stageStartedAt: p.stageStartedAt, restEndsAt: p.restEndsAt)
            if let engine = lift.engine, engine.isPaused, case .resting(_, let endsAt) = engine.stage {
                state.isResting = true
                state.restEndsAt = Date(timeIntervalSince1970: Double(endsAt))
            }
            state.training = sessions.first(where: { $0.kind == "lift" }); state.trainingLabels = labels
            if let lightUp = liftActivity.update(state: state, alert: alert, allowBackgroundStart: canStartFromIntent) {
                model.live.append(log: AppModel.stamped(lightUp.logLine))
            }
        } else { liftActivity.update(state: nil) }
    }
    private func pushWorkout(_ display: TrainingDisplay?) {
        if let current = workoutActivity, [.ended, .dismissed].contains(current.activityState) { workoutActivity = nil }
        if let current = workoutActivity, let display, current.attributes.sessionID != display.id {
            workoutActivity = nil; lastWorkoutState = nil
            workoutUpdate = Task { await current.end(nil, dismissalPolicy: .immediate) }
        }
        if workoutActivity == nil { workoutActivity = Activity<WorkoutActivityAttributes>.activities.first { $0.attributes.sessionID == display?.id && ![.ended, .dismissed].contains($0.activityState) } }
        guard let display, UserDefaults.standard.object(forKey: "noop.workoutLiveActivity") as? Bool ?? true,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            let old = Activity<WorkoutActivityAttributes>.activities
            workoutActivity = nil; lastWorkoutState = nil
            if !old.isEmpty { workoutUpdate = Task { for activity in old { await activity.end(nil, dismissalPolicy: .immediate) } } }
            return
        }
        let state = WorkoutActivityAttributes.ContentState(training: display, labels: labels)
        guard state != lastWorkoutState else { return }
        let content = ActivityContent(state: state, staleDate: display.pulseDeadline)
        if let activity = workoutActivity {
            workoutUpdate = Task { await activity.update(content) }
        } else if UIApplication.shared.applicationState == .active || canStartFromIntent {
            do { workoutActivity = try Activity.request(attributes: .init(sessionID: display.id), content: content, pushType: nil) }
            catch { model.live.append(log: "Training: Live Activity could not start: \(error.localizedDescription)") }
        }
        if workoutActivity != nil { lastWorkoutState = state }
    }

    private func registerNotifications() {
        let center = UNUserNotificationCenter.current()
        let category = UNNotificationCategory(identifier: "noop-training-pulse-loss", actions: [
            UNNotificationAction(identifier: "resume", title: String(localized: "Resume")),
            UNNotificationAction(identifier: "requestEnd", title: String(localized: "End training"), options: [.foreground])
        ], intentIdentifiers: [])
        center.getNotificationCategories { existing in center.setNotificationCategories(existing.union([category])) }
    }
    private func cancelNotification(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["training-\(id)"])
        center.removeDeliveredNotifications(withIdentifiers: ["training-\(id)"])
    }
    private func scheduleNotification(id: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Still training?")
        content.body = String(localized: "No live heart rate for ten minutes. Check your training or resume it.")
        content.sound = .default; content.categoryIdentifier = "noop-training-pulse-loss"; content.userInfo = ["sessionID": id]
        let request = UNNotificationRequest(identifier: "training-\(id)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false))
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
#endif
