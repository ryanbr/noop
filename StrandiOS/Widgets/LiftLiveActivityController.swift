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
    private var lastPush: Date = .distantPast
    private var lastSignature: String?
    /// Cached for the controller's lifetime — the same reasoning as `LiveActivityController`: this is
    /// consulted on every session tick and its value only changes via Settings.
    private let authInfo = ActivityAuthorizationInfo()
    /// Guards against two ticks both firing `Activity.request` before the first has returned.
    private var isStarting = false
    /// Heart rate moves constantly; everything else does not. A change in HR alone is worth a push,
    /// but not more often than this, or a session becomes one push per second.
    private static let heartRateMinInterval: TimeInterval = 10
    /// How long iOS may keep showing the activity as fresh without a push. Generous, because a long
    /// rest legitimately produces no content change at all — the clock is ticking client-side.
    private static let staleAfter: TimeInterval = 15 * 60

    /// A bundled sound file of silence. ActivityKit offers an alert only the default sound or a named
    /// file, and a chime from a phone on a bench every set is not what the lifter asked for; the strap
    /// has already buzzed.
    static let silentAlertSound = "lift-step-silence.caf"

    /// Drive the activity from the session's current state. `state` nil means no session is running,
    /// which ends any activity that is showing.
    ///
    /// `alert` is set for the push that follows a strap double-tap. It lights the Lock Screen on the
    /// new step, so a lifter who glances at a dark phone sees what they are on (Utku, 16 Sep 2026) —
    /// an ActivityKit alert, not a notification: it wakes the screen without unlocking anything. It is
    /// skipped while the app is on screen, where there is nothing to light and iOS would only vibrate.
    func update(programName: String, state: LiftActivityAttributes.ContentState?, alert: Bool = false) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session — ActivityKit keeps them alive
        // across relaunches, and a fresh controller starts with `activity == nil`. Without this we
        // could neither update nor END one already on the Lock Screen, and could spawn a duplicate.
        if activity == nil { activity = Activity<LiftActivityAttributes>.activities.first }

        // Shares the existing Live Activity opt-out rather than adding a second switch: a user who
        // turned Live Activities off meant all of them.
        guard UnitPrefs.liveActivityEnabled(), let state else {
            if activity != nil { Task { await end() } }
            return
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
        let heartRateDue = Date().timeIntervalSince(lastPush) >= Self.heartRateMinInterval
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))

        if let activity {
            let lightsScreen = alert && UIApplication.shared.applicationState != .active
            guard contentChanged || heartRateDue || lightsScreen else { return }
            lastSignature = signature
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
        } else {
            // Set synchronously before any await, so a second tick arriving while `Activity.request`
            // is still in flight bails here instead of creating a duplicate activity.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: LiftActivityAttributes(programName: programName),
                    content: content,
                    pushType: nil)
                lastSignature = signature
                lastPush = Date()
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        // End every lift activity, not just the cached handle — covers a straggler from a previous
        // app session that was never re-adopted, and any rare duplicate.
        for act in Activity<LiftActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastSignature = nil
    }
}
#endif
