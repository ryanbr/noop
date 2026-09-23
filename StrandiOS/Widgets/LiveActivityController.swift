#if os(iOS)
import Foundation
import ActivityKit
import UIKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// What the banner was last pushed with, so an unchanged banner is not pushed again
    /// (`LiveHRBannerPushPolicy`). Nil until this controller pushes, and again once it ends the activity.
    private var shownState: NOOPActivityAttributes.ContentState?
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// How long after the last push iOS may keep showing the activity as fresh. An unchanged activity is
    /// re-pushed once half of this has passed, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end (a missed-tick safety net
    /// on top of the connected-driven end below).
    private static let staleAfter: TimeInterval = 120
    /// A banner kept through a dropped link (it shows the dash) is ended if the link stays down this long, so a strap
    /// left behind does not leave a dash on the Lock Screen for hours.
    private static let endAfterLinkDown: TimeInterval = 600
    private var linkDownEnd: DispatchWorkItem?

    /// Drive the activity from the latest live values (`LiveHRBannerLifecycle` decides start / push / end). Starts
    /// only in the foreground, with the strap CONNECTED (the live link, not the sticky "paired" flag) and a heart
    /// rate to show; a running banner shows the dash through a dropped link or a strap that is not measuring, and
    /// ends when its switch is off, another banner takes the screen (`standsAside`), or the link stays down for
    /// `endAfterLinkDown`. Pushed only when what it shows changes (`LiveHRBannerPushPolicy`).
    func update(bpm: Int?, recovery: Int?, connected: Bool, standsAside: Bool, effort: Int? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }

        // The switch (#336) and another banner on screen end it; a dropped link does not (`LiveHRBannerLifecycle`).
        let step = LiveHRBannerLifecycle.step(
            switchOn: UnitPrefs.liveActivityEnabled(), standsAside: standsAside, linkUp: connected, bpm: bpm,
            showing: activity != nil, appActive: UIApplication.shared.applicationState == .active)
        switch step {
        case .nothing: return
        case .end:
            Task { await end() }
            return
        case .start, .push: break
        }

        // Link down: the dash, never the last number (`bonded` stays true across a disconnect, and keying off it once
        // left a fabricated "live" HR standing), and an end if the link does not come back.
        if connected {
            linkDownEnd?.cancel()
            linkDownEnd = nil
        } else if linkDownEnd == nil {
            let item = DispatchWorkItem { [weak self] in Task { @MainActor in await self?.end() } }
            linkDownEnd = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.endAfterLinkDown, execute: item)
        }

        let state = NOOPActivityAttributes.ContentState(bpm: connected ? bpm : nil, recovery: recovery,
                                                        bonded: connected, effort: effort)
        let now = Date()
        let staleDate = now.addingTimeInterval(Self.staleAfter)

        if let activity {
            // The link dropping is pushed at once: no tick follows it, so a push skipped for spacing would leave the
            // last number standing until the link came back.
            let linkJustDropped = !connected && shownState?.bonded == true
            guard linkJustDropped || LiveHRBannerPushPolicy.due(shown: shownState, next: state,
                                                                  sinceLastPush: now.timeIntervalSince(lastPush),
                                                                  staleAfter: Self.staleAfter) else { return }
            lastPush = now
            shownState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. The 2-second throttle above only guards the update path.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = now
                shownState = state
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        shownState = nil
        linkDownEnd?.cancel()
        linkDownEnd = nil
    }
}
#endif
