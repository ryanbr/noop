import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Runs a backgrounded re-score somewhere it can actually finish, and records honestly when one did not.
///
/// See `RescoreBackgroundPolicy` for the problem (#1538) and the decision rules. This is the plumbing:
/// the durable "a re-score is owed" mark, the measured duration the policy reads, the iOS
/// execution assertion, and the `BGProcessingTask` that work is escalated to.
///
/// `BGProcessingTask` rather than `BGAppRefreshTask` — the two the app already uses (the scheduled debug
/// export, the Health write-back) are refresh tasks, which are metered for short work. Processing tasks are
/// the long, deferrable kind, which is what an eight-minute pass needs. iOS decides when one runs and
/// favours idle and charging, so this is an "eventually, without needing the user to hold the app open"
/// guarantee, NOT a promise that a score appears moments after a sync. Nothing here claims otherwise, and
/// the honest limit is worth stating: on an install where the pass takes minutes, the score still normally
/// appears when the app is next opened. What changes is that the phone stops paying for a full doomed pass
/// on every single offload to get there.
///
/// HONEST about platform limits, in the shape of `ScheduledDebugExport`:
/// - **macOS** — the app is a normal foreground app with no suspension deadline. Every entry point here is
///   a no-op that reports `.run`, so the existing behaviour is exactly preserved.
/// - **iOS** — needs the `processing` background mode AND the identifier listed in
///   `BGTaskSchedulerPermittedIdentifiers` AND `register()` called before launch finishes. If any of those
///   is missing, `submit` fails gracefully and the foreground path still scores normally.
@MainActor
enum RescoreBackgroundScheduler {

    /// A re-score is OWED: either a pass marked itself started and never marked itself finished (it was
    /// killed), or a trigger deferred one to a background task. Survives process death, which is the
    /// entire point — the process being killed is the event we are trying to observe, and it is not an
    /// event the killed process gets any chance to write down.
    static let owedKey = "noop.rescoreOwed"
    /// Seconds the last COMPLETED pass took. Only ever written by a pass that reached the end.
    static let lastPassSecondsKey = "noop.rescoreLastPassSeconds"

    /// Identifies the MOST RECENT debt, so a pass can tell its own from someone else's (#1681).
    ///
    /// A token rather than a counter, deliberately. A counter needs read-modify-write, and two triggers
    /// marking a debt at the same moment could both read N and both write N+1 — losing an increment, and
    /// with it exactly the debt this is meant to protect. A fresh token is a single write: concurrent
    /// marks each produce a distinct one, the last wins, and it cannot equal any pass's captured token.
    static let owedTokenKey = "noop.rescoreOwedToken"

    static var isRescoreOwed: Bool { UserDefaults.standard.bool(forKey: owedKey) }

    static var currentOwedToken: String? { UserDefaults.standard.string(forKey: owedTokenKey) }

    static var lastCompletedPassSeconds: Double? {
        guard UserDefaults.standard.object(forKey: lastPassSecondsKey) != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: lastPassSecondsKey)
        return value.isFinite && value > 0 ? value : nil
    }

    /// Mark a re-score as owed. Called by `IntelligenceEngine` once a pass is past every gate and is
    /// definitely about to work — so that a kill leaves the debt behind — and by the deferral path, where
    /// no pass is attempted at all but the work is just as outstanding.
    /// Returns the token stamped on this debt. A pass keeps it and hands it back at completion; every
    /// other caller (the deferral path) can ignore it, since it is not the one that will settle up.
    @discardableResult
    static func markRescoreOwed() -> String {
        let token = UUID().uuidString
        UserDefaults.standard.set(true, forKey: owedKey)
        UserDefaults.standard.set(token, forKey: owedTokenKey)
        return token
    }

    /// May a pass holding [capturedToken] settle the debt?
    ///
    /// Only if nothing newer was recorded while it ran. The bug in #1681 is that this question was never
    /// asked: completion cleared one global boolean unconditionally, so a trigger firing mid-pass — for
    /// data that arrived AFTER the pass had already read its inputs — had its debt erased before the
    /// correction it was recorded for ever ran. The scoring loop starts at today, so the night most
    /// likely to still be syncing is the first thing read and the likeliest to be caught mid-write.
    ///
    /// A pass with NO token never settles. That errs toward one extra pass, which costs battery; the
    /// other direction costs a night's scores until something unrelated happens to re-score it, which is
    /// the failure being fixed.
    ///
    /// Pure, so the rule is pinned without UserDefaults or a background task.
    static func maySettleDebt(capturedToken: String?, currentToken: String?) -> Bool {
        guard let capturedToken, !capturedToken.isEmpty else { return false }
        return capturedToken == currentToken
    }

    /// Settle the debt at the end of a completed pass, beside the watermark advance. A pass that is
    /// killed never reaches this, which is what leaves the mark set for the next launch to find.
    /// [owedToken] is the token this pass received from its own `markRescoreOwed()`. The debt is settled
    /// only if it is still the current one — see `maySettleDebt`. The pass duration is recorded either
    /// way: it is telemetry about THIS pass, and true regardless of whose debt is now outstanding.
    /// Returns whether the debt was actually settled, so the caller can SAY when it was not. Declining
    /// is the interesting outcome and it must not be silent: #1538 cost three nights because the log
    /// recorded that scoring had not happened without ever recording why, and a pass that completes
    /// while leaving the mark set looks identical to one that cleared it unless something says so.
    @discardableResult
    static func markRescoreCompleted(seconds: Double, owedToken: String?) -> Bool {
        let settled = maySettleDebt(capturedToken: owedToken, currentToken: currentOwedToken)
        if settled {
            UserDefaults.standard.set(false, forKey: owedKey)
        }
        if seconds.isFinite, seconds > 0 {
            UserDefaults.standard.set(seconds, forKey: lastPassSecondsKey)
        }
        return settled
    }

    /// Whether the app is somewhere a long pass might not survive. Always false on macOS — see the type doc.
    ///
    /// Anything that is not `.active` counts, `.inactive` included, which is the conservative direction on
    /// purpose. `.inactive` is the state on the way to suspension, so reading it as "foreground" is the
    /// error that loses work; reading it as "background" costs at most a deferral that the very next
    /// `.active` transition drains. The transient `.inactive` cases — app switcher, notification centre,
    /// an incoming call — therefore self-correct within seconds, and the case that matters is never missed.
    static var isBackgrounded: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }

    /// Decide, then either run `work` under an execution assertion or leave it for `BGProcessingTask`.
    ///
    /// `log` goes to the strap log, always — both the decision and its reason. #1538 cost three nights
    /// because the log recorded that scoring had not happened without ever recording why.
    /// `isBackground` defaults to the real application state and is a parameter only so a test can drive
    /// the deferral branch, which is unreachable on macOS (where `isBackgrounded` is always false) and is
    /// exactly where the work-is-owed bookkeeping lives.
    /// - Parameter owesOnDefer: whether a deferral should record a debt for a background task to settle.
    ///   True for a real update path — a completed offload MUST eventually be scored, so deferring it has
    ///   to leave something behind or the work is dropped rather than moved. FALSE for the steady-state
    ///   backstop tick, which by its own contract is not the thing that must happen: every real update
    ///   forces its own pass, so the tick exists only to catch what those missed. Recording a debt for it
    ///   would conjure a forced full pass for a processing task to run when very likely nothing changed,
    ///   which is the churn #1146 exists to avoid. A debt an earlier real pass already recorded is
    ///   untouched either way.
    static func run(isBackground: Bool? = nil,
                    owesOnDefer: Bool = true,
                    log: @escaping (String) -> Void,
                    work: () async -> Void) async {
        let decision = RescoreBackgroundPolicy.decide(
            isBackground: isBackground ?? isBackgrounded,
            rescoreAlreadyOwed: isRescoreOwed,
            lastCompletedPassSeconds: lastCompletedPassSeconds)

        switch decision {
        case .deferToBackgroundTask(let reason):
            guard owesOnDefer else {
                // Nothing is queued and nothing is owed: the backstop simply does not run here. Said
                // plainly in the log, because "deferred" would promise a background task that is not
                // coming.
                log("re-score: backstop tick skipped while backgrounded — \(reason)")
                return
            }
            // Record the debt BEFORE scheduling. Without this the background task wakes, finds nothing
            // marked owed, and returns having done nothing — the deferral would silently drop the work
            // rather than move it.
            markRescoreOwed()
            log("re-score: deferred to a background task — \(reason)")
            schedule()
        case .run:
            await withAssertion(log: log, work: work)
        }
    }

    /// Hold an execution assertion for the duration of `work` so a SHORT pass is not suspended halfway.
    /// A long one still outlives the grant; the assertion's expiry handler is where that becomes visible
    /// in the log and where the work is escalated, rather than the process simply vanishing.
    private static func withAssertion(log: @escaping (String) -> Void, work: () async -> Void) async {
        #if os(iOS)
        let assertion = BackgroundAssertion()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "noop.rescore") {
            // iOS invokes this on the main thread when it is about to reclaim the assertion. The pass
            // itself cannot be cancelled from here — its heavy loop runs in a detached task, which does
            // not inherit cancellation — so do not pretend to stop it. Record the fact and escalate:
            // the owed mark is still set (only a completed pass clears it) and that is what the next
            // decision reads.
            MainActor.assumeIsolated {
                log("re-score: background time expired before the pass finished — escalating (#1538)")
                schedule()
                assertion.end()
            }
        }
        assertion.store(taskID)
        await work()
        // Idempotent under the box's lock, so the expiry path and this one cannot double-end the task —
        // which UIKit treats as a programmer error — and cannot leak it either.
        assertion.end()
        #else
        await work()
        #endif
    }

    // MARK: - iOS background-processing plumbing

    #if os(iOS)
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".rescore"

    /// Register the handler. MUST be called from `StrandiOSApp.init()` before launch finishes, and the
    /// identifier MUST be listed in `BGTaskSchedulerPermittedIdentifiers`, or iOS never delivers the task.
    /// Safe to leave uncalled: `schedule()` fails gracefully and the foreground path still scores.
    static func register(perform operation: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                await operation()
                guard !Task.isCancelled else { return }
                // Re-arm only while work remains. A processing task is single-shot, and re-submitting
                // unconditionally would ask iOS for a wake on every install forever, including the ones
                // that never have anything to do.
                if isRescoreOwed { schedule() }
                completion.finish(success: !isRescoreOwed)
            }
            task.expirationHandler = {
                worker.cancel()
                // The pass did not finish inside the processing budget either. Ask for another rather
                // than dropping the work, and report the failure so iOS's own scheduling heuristics see
                // it honestly instead of being told this succeeded.
                schedule()
                completion.finish(success: false)
            }
        }
    }

    /// Keep exactly one pending request, so calling this from several places is idempotent and also
    /// repairs a request the system discarded.
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        // Neither is required. Network is irrelevant to an offline app, and demanding external power
        // would strand the work for anyone who does not charge overnight — the exact population most
        // likely to be wearing the strap continuously.
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Holds the background-task identifier so the normal path and the expiry handler can each try to end
    /// it while exactly one of them succeeds. UIKit treats a double `endBackgroundTask` as a programmer
    /// error and a never-ended one as grounds for killing the app, so neither may be left to ordering.
    /// Plain lock rather than actor isolation, matching `TaskCompletionGuard` below.
    private final class BackgroundAssertion: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UIBackgroundTaskIdentifier = .invalid

        func store(_ newID: UIBackgroundTaskIdentifier) {
            lock.lock()
            defer { lock.unlock() }
            id = newID
        }

        @MainActor func end() {
            lock.lock()
            let current = id
            id = .invalid
            lock.unlock()
            guard current != .invalid else { return }
            UIApplication.shared.endBackgroundTask(current)
        }
    }

    /// Guards `setTaskCompleted` against being called twice — once normally and once from the expiration
    /// handler — which `BGTaskScheduler` treats as a programmer error. Plain lock rather than actor
    /// isolation: iOS can invoke the expiration handler on a different queue. Mirrors the guard in
    /// `ScheduledDebugExport`.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
    #else
    /// macOS has no background-task scheduler and no suspension deadline — nothing to schedule.
    static func schedule() {}
    #endif
}
