#if os(iOS)
import Foundation
import ActivityKit
import UIKit

/// Starts, updates and ends the Lift Log session Live Activity.
///
/// Modelled on `LiveActivityController` (live HR) and deliberately separate from it: the two answer
/// different questions and have different lifetimes. While a gym session is open this one is the
/// useful banner — it carries the heart rate too — so the app suppresses the HR activity rather than
/// stacking two on the Lock Screen.
///
/// PUSHES ARE CONTENT-DRIVEN, NOT CLOCK-DRIVEN. The widget's timers tick on their own from dates in
/// the content state, so this only sends an update when something a person would notice changes:
/// the stage, the exercise, the set, the numbers, or the heart rate. Without that, an activity that
/// merely shows a running clock would push once a second for a whole workout and be throttled by
/// ActivityKit for it.
@MainActor
final class LiftLiveActivityController {
    private var activity: Activity<LiftActivityAttributes>?
    /// A Lift Log banner is on screen — what NOOP's live heart rate banner makes room for (`LiveHRBannerLifecycle`).
    var isShowing: Bool { activity != nil }
    /// Writes to NOOP's strap log — only when the banner's situation CHANGES (picked up after a restart,
    /// or waiting for NOOP to be opened), never per push.
    private let log: (String) -> Void
    /// Set while a session runs with no banner that NOOP may start, so the reason is logged once.
    private var waitingForForeground = false
    private var lastPush: Date = .distantPast
    private var lastSignature: String?
    /// The state the banner is showing, so a heart-rate tick can push a copy of it without the app
    /// building a whole presentation again (`updateHeartRate`).
    private var lastState: LiftActivityAttributes.ContentState?
    /// Cached for the controller's lifetime — the same reasoning as `LiveActivityController`: this is
    /// consulted on every push and its value only changes via Settings.
    private let authInfo = ActivityAuthorizationInfo()
    /// Guards against two pushes both firing `Activity.request` before the first has returned.
    private var isStarting = false
    /// How long iOS may keep showing the activity as fresh without a push. Generous, because a long
    /// rest legitimately produces no content change at all — the clock is ticking client-side.
    private static let staleAfter: TimeInterval = 15 * 60

    /// A bundled sound file of silence. ActivityKit offers an alert only the default sound or a named
    /// file, and a chime from a phone on a bench every set is not what the lifter asked for; the strap
    /// has already buzzed.
    static let silentAlertSound = "lift-step-silence.caf"

    /// What the push for a strap step did about lighting the screen — one strap-log line per step, so a
    /// step that did not light can be told apart: NOOP was on screen, no banner was running, or the alert
    /// went to iOS and iOS chose (a face-down phone, a Focus, its own limits).
    enum LightUp {
        case askedIOS, appOnScreen, noBanner

        var logLine: String {
            switch self {
            case .askedIOS:    return "Lift Log: strap step sent to the Lock Screen with a light-up alert"
            case .appOnScreen: return "Lift Log: strap step not lighting the Lock Screen — NOOP is open on screen"
            case .noBanner:    return "Lift Log: strap step not lighting the Lock Screen — no Lift Log banner is running"
            }
        }
    }

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    /// Drive the activity from the session's current state. `state` nil means no session is running,
    /// which ends any activity that is showing.
    ///
    /// `alert` is set for the push a strap double-tap causes. It lights a dark Lock Screen on the new
    /// step, so a lifter sees what they are on, and the screen goes dark again on the phone's own timer
    /// (Utku, 16–17 Sep 2026: "just light up", nothing else). It is an ActivityKit alert, the only way iOS
    /// lets an app light the screen, carried on the update the step needs anyway, and it is sent whenever
    /// NOOP is not the app on screen. It used to wait for the phone to report itself LOCKED (protected
    /// data unavailable), but iOS reports that only about 10 s after the screen goes dark, so a tap soon
    /// after it dimmed — right after checking the rest timer, say — lit nothing (gym session, 17 Sep
    /// 2026: "sometimes it lights up and sometimes not"). With another app open, iOS shows the step in the
    /// Dynamic Island instead. ActivityKit offers no setting for vibration; the sound is silence.
    /// Returns what happened about lighting when `alert` was asked for; nil otherwise.
    @discardableResult
    func update(state: LiftActivityAttributes.ContentState?, alert: Bool = false) -> LightUp? {
        guard authInfo.areActivitiesEnabled else { return alert ? .noBanner : nil }

        // A banner the lifter swiped off the Lock Screen, or one iOS ended, takes no more updates: let it
        // go, so the session is not left pushing to — and trying to light — a banner nobody can see.
        if let current = activity, !Self.isShowing(current) { activity = nil }
        // Re-adopt an activity that outlived a previous app session — ActivityKit keeps them alive
        // across relaunches, and a fresh controller starts with `activity == nil`. Without this we
        // could neither update nor END one already on the Lock Screen, and could spawn a duplicate.
        let adopted = activity == nil
            ? Activity<LiftActivityAttributes>.activities.first(where: Self.isShowing) : nil
        if let adopted { activity = adopted }

        // Its own switch (`UnitPrefs.liftLiveActivityEnabled`), so the everyday heart-rate banner can be off while
        // the gym banner stays; turning this one off also ends a banner already showing.
        guard UnitPrefs.liftLiveActivityEnabled(), let state else {
            if activity != nil { Task { await end() } }
            return alert ? .noBanner : nil
        }
        if adopted != nil {
            log("Lift Log: Lock Screen banner picked up again after NOOP restarted")
            waitingForForeground = false
        }

        // Everything a person would notice, EXCLUDING the clocks (which tick client-side) and the
        // heart rate (handled by its own interval below).
        let signature = [
            state.isResting ? "rest" : "work", state.exercise, state.status,
            state.detail ?? "", state.next,
            "\(state.stageStartedAt.timeIntervalSince1970)",
            "\(state.restEndsAt?.timeIntervalSince1970 ?? 0)",
        ].joined(separator: "|")

        let contentChanged = signature != lastSignature
        let heartRateDue = LiftBannerPushPolicy.heartRateDue(
            shown: lastState?.bpm, latest: state.bpm, sinceLastPush: Date().timeIntervalSince(lastPush))
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))

        if let activity {
            let appOnScreen = UIApplication.shared.applicationState == .active
            let lightsScreen = alert && !appOnScreen
            guard contentChanged || heartRateDue || lightsScreen else { return alert ? .appOnScreen : nil }
            lastSignature = signature
            lastState = state
            lastPush = Date()
            if lightsScreen {
                let stepAlert = AlertConfiguration(
                    title: LocalizedStringResource(stringLiteral: state.exercise),
                    body: LocalizedStringResource(stringLiteral: state.detail.map { "\(state.status) — \($0)" }
                                                  ?? state.status),
                    sound: .named(Self.silentAlertSound))
                Task { await activity.update(content, alertConfiguration: stepAlert) }
            } else {
                Task { await activity.update(content) }
            }
            return alert ? (lightsScreen ? .askedIOS : .appOnScreen) : nil
        } else {
            // iOS starts a Live Activity only for the app on screen; asked from the background it throws,
            // and this runs several times a second. The banner comes back the next time NOOP is opened.
            guard UIApplication.shared.applicationState == .active else {
                if !waitingForForeground {
                    waitingForForeground = true
                    log("Lift Log: no Lock Screen banner — iOS starts one only while NOOP is open, so it "
                        + "comes back the next time NOOP is opened")
                }
                return alert ? .noBanner : nil
            }
            waitingForForeground = false
            // Set synchronously before any await, so a second push arriving while `Activity.request`
            // is still in flight bails here instead of creating a duplicate activity.
            guard !isStarting else { return alert ? .noBanner : nil }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: LiftActivityAttributes(),
                    content: content,
                    pushType: nil)
                lastSignature = signature
                lastState = state
                lastPush = Date()
            } catch {
                activity = nil
            }
            isStarting = false
            // A banner requested just now carries no alert: there was nothing on the Lock Screen to light.
            return alert ? .noBanner : nil
        }
    }

    /// A new live heart rate, straight from the HR stream: the cheap path, called once a second.
    ///
    /// It never builds a presentation and never starts a banner — only a banner already on the Lock Screen
    /// takes a heart-rate push, and only when `LiftBannerPushPolicy` says the number is worth one. Everything
    /// else the banner shows comes from `update(state:alert:)`.
    func updateHeartRate(_ bpm: Int?) {
        guard let activity, let state = lastState, state.bpm != bpm else { return }
        guard LiftBannerPushPolicy.heartRateDue(shown: state.bpm, latest: bpm,
                                                sinceLastPush: Date().timeIntervalSince(lastPush)) else { return }
        var next = state
        next.bpm = bpm
        lastState = next
        lastPush = Date()
        let content = ActivityContent(state: next, staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    func end() async {
        // End every lift activity, not just the cached handle — covers a straggler from a previous
        // app session that was never re-adopted, and any rare duplicate.
        for act in Activity<LiftActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastSignature = nil
        lastState = nil
        waitingForForeground = false
    }

    /// Still on the Lock Screen and taking updates: not ended by the app or iOS, not swiped away.
    private static func isShowing(_ activity: Activity<LiftActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .ended, .dismissed: return false
        default: return true
        }
    }
}
#endif
