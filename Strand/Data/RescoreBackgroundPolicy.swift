import Foundation

/// Whether a re-score triggered while the app is BACKGROUNDED should start now or be handed to a
/// background-processing task that has time to finish it.
///
/// #1538: a completed offload rescores immediately, and on iOS that routinely happens while the app is
/// backgrounded — it stays alive as a `bluetooth-central` to receive the offload in the first place. But
/// `analyzeRecent` is all-or-nothing: pass 1 writes nothing, every store write happens after both loops,
/// and the watermark advances only at the very end so an interrupted run can never mark unscored data as
/// scored. On a heavy install the pass measured **474,778 ms** — nearly eight minutes. iOS ends the
/// process long before that, so the work is lost in full.
///
/// The lost work is not the worst of it. Because the watermark never advanced, the NEXT trigger still saw
/// `newData=yes` and started another full pass, which was killed in turn. The reporter's log shows exactly
/// that: every offload after 05:40:31 reported `caught up` with nothing new to fetch, yet two later ticks
/// still read `newData=yes`. It is a livelock — the pass cannot finish, and failing to finish is what
/// guarantees it will be attempted again. The score appeared 1 h 57 m after the data was complete, and only
/// because the app happened to stay foregrounded for eight unbroken minutes.
///
/// What ends those passes is the background CPU limit, not suspension (see `backgroundRestPerWorkSecond`):
/// a suspended pass resumes on the next wake, a killed one does not. A backgrounded pass therefore paces
/// itself under that limit, and this decides only whether one should start here at all.
///
/// Deliberately NOT a fix for how long the pass takes. A cold process still re-scores every night in the
/// window, because the per-day reuse cache is in-memory and starts empty (`IntelligenceEngine.dayScanCache`).
/// This changes only WHERE the work runs and how often a doomed attempt is paid for. Making the pass itself
/// cheap across a process restart is the other half of #1538 and is not attempted here.
enum RescoreBackgroundPolicy {

    /// What a background-initiated re-score should do.
    enum Decision: Equatable {
        /// Start the pass now, under an execution assertion.
        case run
        /// Do not start it; leave the work marked pending and let a background-processing task (or the
        /// next foreground) run it. The reason is logged verbatim to the strap log — #1538 was three
        /// nights of chasing BLE precisely because the log did not say why scoring had not happened.
        case deferToBackgroundTask(reason: String)
    }

    /// How long a backgrounded pass rests per second of work it just did.
    ///
    /// What actually killed the background passes was CPU, not time: iOS terminates a background process
    /// that holds more than 80% CPU over 60 s (`cpu_resource_fatal`). A cold pass is roughly 144 s of
    /// near-continuous CPU on a large install, so every overnight attempt was killed about 52 s in — 26 kills
    /// on one phone in five nights, each leaving the debt for the next attempt to be killed on. Resting as
    /// long as it worked holds the pass near 50%. A suspension between rests is harmless: the pass is not
    /// killed by it, it resumes on the next wake, so a pass longer than any single wake still completes.
    static let backgroundRestPerWorkSecond: Double = 1.0

    /// The longest single rest. Work measured on the uptime clock can include a suspension the process
    /// spent mid-unit; resting for all of it would stall a pass that has already been idle.
    static let maxBackgroundRestSeconds: Double = 30

    /// Seconds to rest after `workSeconds` of re-score work. Zero in the foreground, where no CPU limit
    /// applies and the user is waiting on the result. A non-finite or non-positive measurement rests zero.
    static func restSeconds(afterWorkSeconds workSeconds: Double, isBackground: Bool) -> Double {
        guard isBackground, workSeconds.isFinite, workSeconds > 0 else { return 0 }
        return min(workSeconds * backgroundRestPerWorkSecond, maxBackgroundRestSeconds)
    }

    /// - Parameters:
    ///   - isBackground: whether the app is currently backgrounded. A foregrounded app is never deferred:
    ///     the user is looking at the screen, there is no suspension deadline, and the existing behaviour
    ///     is correct.
    ///   - isRealUpdate: the trigger carries new data that must be scored (an offload), as opposed to the
    ///     steady-state backstop tick. A backgrounded backstop does not run: a paced pass costs minutes,
    ///     the tick cannot tell live HR from a real change, and every real update already runs its own.
    ///   - rescoreAlreadyOwed: a re-score is outstanding — either a pass marked itself started and never
    ///     marked itself finished (it was killed; the mark survives process death, which is the point,
    ///     because the killed process gets no chance to record anything) or an earlier trigger already
    ///     deferred one. The work is spoken for by the processing task this escalated to.
    ///   - passInProgress: a pass is running in THIS process. Its own started-mark is what reads as owed, so
    ///     it is not evidence of a killed pass; the engine re-arms one follow-up pass for a trigger that
    ///     lands mid-run. Deferring instead recorded a newer debt, the running pass then finished without
    ///     settling it (#1681), and every offload after that deferred on it.
    static func decide(isBackground: Bool,
                       isRealUpdate: Bool = true,
                       rescoreAlreadyOwed: Bool,
                       passInProgress: Bool = false) -> Decision {
        guard isBackground else { return .run }

        guard isRealUpdate else {
            return .deferToBackgroundTask(
                reason: "the backstop tick does not re-score while backgrounded; offloads run their own")
        }

        if rescoreAlreadyOwed, !passInProgress {
            return .deferToBackgroundTask(
                reason: "a re-score is already outstanding from an earlier trigger")
        }

        return .run
    }
}
