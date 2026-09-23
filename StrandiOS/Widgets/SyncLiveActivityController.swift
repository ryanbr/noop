#if os(iOS)
import ActivityKit
import Combine
import Foundation
import UIKit

/// Starts, updates and ends the strap-sync Live Activity.
///
/// Modelled on `LiveActivityController` (live HR) and `LiftLiveActivityController`, and separate from
/// both for the same reason they are separate from each other. Attached once at launch to `LiveState`,
/// rather than as a modifier on `StrandiOSApp.body` (that chain is past the type-checker's budget, and
/// this must also run in a process the Sync Strap shortcut launched with no scene at all).
///
/// WHO MAY START IT. iOS only lets an app start a Live Activity from the foreground, or from an App Intent
/// that adopts `LiveActivityIntent`. So a sync started in the foreground starts it here on the
/// `backfilling` edge; the Sync Strap shortcut starts it itself through `startFromShortcut`, while the
/// link is still coming up; and an automatic background sync (the 15-minute tick) can only update an
/// activity that already exists — it never starts one, and this never pretends otherwise.
///
/// PUSHES ARE CONTENT-DRIVEN. The elapsed clock ticks client-side from `startedAt`; a push goes out only
/// when the chunk count or the phase changes, and chunk pushes no more than every 2 s. The words come
/// from `SyncActivityCopy`, which is where they are tested.
@MainActor
final class SyncLiveActivityController {
    static let shared = SyncLiveActivityController()

    private var activity: Activity<SyncActivityAttributes>?
    private var cancellables: Set<AnyCancellable> = []
    /// For the strap log: a refused `Activity.request` must say so, or "no island" has no evidence.
    private weak var live: LiveState?
    private var startedAt = Date()
    private var lastPush: Date = .distantPast
    private var lastPushedChunks = -1
    private let authInfo = ActivityAuthorizationInfo()
    private var isStarting = false
    /// How long iOS may show the activity as fresh without a push. Generous: a long history recovery can
    /// go minutes between acked chunks, and a shortcut-launched "connecting" run has no pushes at all
    /// until the strap answers. Matches `BLEManager.pendingManualSyncTTL`, after which a parked request
    /// no longer fires, so a connecting island that never syncs greys out at the same moment.
    private static let staleAfter: TimeInterval = 600
    /// How long the final "Synced · N chunks" / "Sync interrupted" state stays before dismissing.
    private static let finalShownFor: TimeInterval = 8
    private static let chunkMinInterval: TimeInterval = 2

    /// Asked before a foreground sync STARTS a banner; true holds it back. The Lift Log sets it for the
    /// length of a gym session, whose own banner is the one on the Lock Screen. A banner the Sync Strap
    /// shortcut started still updates and ends as before.
    var holdsBackNewBanner: () -> Bool = { false }

    private init() {}

    func attach(to live: LiveState) {
        self.live = live
        live.$backfilling
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak live] on in
                guard let self, let live else { return }
                if on {
                    self.syncStarted(live)
                } else {
                    // One hop later, deliberately: `exitBackfilling` clears `backfilling` FIRST and stamps
                    // `lastSyncedAt` / `lastSyncError` further down the same synchronous call, so reading
                    // the outcome on the edge itself would see the previous sync's values.
                    DispatchQueue.main.async { self.syncEnded(live) }
                }
            }
            .store(in: &cancellables)
        live.$syncChunksThisSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak live] chunks in
                guard let self, let live, live.backfilling else { return }
                self.pushProgress(live, chunks: chunks)
            }
            .store(in: &cancellables)
    }

    /// The Sync Strap shortcut's entry: may start the activity from the background because the intent is
    /// a `LiveActivityIntent`. Shows "Connecting…" until the link is up, or the running sync's state if
    /// one is already going.
    func startFromShortcut(live: LiveState) {
        adoptExisting()
        startedAt = Date()
        request(state: live.backfilling ? state(syncing(live)) : state(SyncActivityCopy.connecting()))
    }

    /// The shortcut found no model, or asked and nothing started: do not leave a "Connecting…" island up
    /// for a sync that is not coming.
    func shortcutDidNotStart() {
        guard let activity else { return }
        end(activity, with: state(SyncActivityCopy.notStarted()))
    }

    /// Foreground housekeeping: a "connecting" island from a shortcut whose sync never came is ended here
    /// rather than left greyed on the Lock Screen. Called on the `.active` scene phase.
    func reconcile(live: LiveState) {
        adoptExisting()
        guard let activity, !live.backfilling,
              activity.content.state.phase == .connecting,
              Date().timeIntervalSince(activity.content.state.startedAt) > Self.staleAfter else { return }
        shortcutDidNotStart()
    }

    // MARK: - Edges

    private func syncStarted(_ live: LiveState) {
        adoptExisting()
        if let activity {
            // Started by the shortcut while connecting: move it to syncing on the same clock.
            if activity.content.state.phase == .connecting { startedAt = activity.content.state.startedAt }
            push(activity, state(syncing(live)))
            return
        }
        // Only the foreground may start one. A background automatic sync stays silent, honestly.
        guard UIApplication.shared.applicationState == .active, !holdsBackNewBanner() else { return }
        startedAt = Date()
        request(state: state(syncing(live)))
    }

    private func pushProgress(_ live: LiveState, chunks: Int) {
        guard let activity, chunks != lastPushedChunks,
              Date().timeIntervalSince(lastPush) >= Self.chunkMinInterval else { return }
        push(activity, state(syncing(live)))
    }

    private func syncEnded(_ live: LiveState) {
        guard let activity else { return }
        let chunks = max(lastPushedChunks, live.syncChunksThisSession, 0)
        end(activity, with: state(SyncActivityCopy.final(lastSyncError: live.lastSyncError, chunks: chunks)))
    }

    // MARK: - Helpers

    private func syncing(_ live: LiveState) -> SyncActivityCopy.Line {
        SyncActivityCopy.syncing(chunks: live.syncChunksThisSession, pagesBehind: live.pagesBehindAtConnect)
    }

    private func state(_ line: SyncActivityCopy.Line) -> SyncActivityAttributes.ContentState {
        .init(phase: SyncActivityAttributes.Phase(rawValue: line.phase.rawValue) ?? .syncing,
              chunks: line.chunks, startedAt: startedAt, status: line.status, detail: line.detail)
    }

    /// Re-adopt an activity that outlived a previous process — the shortcut's "connecting" island can
    /// easily be older than the process that finishes the sync.
    private func adoptExisting() {
        if activity == nil { activity = Activity<SyncActivityAttributes>.activities.first }
    }

    private func request(state: SyncActivityAttributes.ContentState) {
        // Each refusal names its gate. These are rare-event lines (one per attempted start), so they stay
        // always-on rather than behind a Test Centre domain.
        guard authInfo.areActivitiesEnabled else {
            live?.append(log: "Sync activity: not started — Live Activities are off for NOOP in iOS Settings")
            return
        }
        guard UnitPrefs.syncLiveActivityEnabled() else {
            live?.append(log: "Sync activity: not started — \"Strap sync\" is off in NOOP Settings → Live notifications")
            return
        }
        if let activity { push(activity, state); return }
        guard !isStarting else { return }
        isStarting = true
        do {
            activity = try Activity.request(
                attributes: SyncActivityAttributes(title: String(localized: "Strap sync")),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: nil)
            lastPush = Date()
            lastPushedChunks = state.chunks
            live?.append(log: "Sync activity: started (\(state.phase.rawValue), app state \(UIApplication.shared.applicationState.rawValue))")
        } catch {
            activity = nil
            live?.append(log: "Sync activity: request refused — \(error) (app state \(UIApplication.shared.applicationState.rawValue))")
        }
        isStarting = false
    }

    private func push(_ activity: Activity<SyncActivityAttributes>, _ state: SyncActivityAttributes.ContentState) {
        lastPush = Date()
        lastPushedChunks = state.chunks
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    private func end(_ activity: Activity<SyncActivityAttributes>, with state: SyncActivityAttributes.ContentState) {
        Task { await activity.end(ActivityContent(state: state, staleDate: nil),
                                  dismissalPolicy: .after(Date().addingTimeInterval(Self.finalShownFor))) }
        self.activity = nil
        lastPushedChunks = -1
    }
}
#endif
