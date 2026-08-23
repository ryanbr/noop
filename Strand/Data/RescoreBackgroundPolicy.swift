import Foundation

/// Whether a re-score triggered while the app is BACKGROUNDED should start now or be handed to a
/// background-processing task that has time to finish it.
///
/// #1538: a completed offload rescores immediately, and on iOS that routinely happens while the app is
/// backgrounded — it stays alive as a `bluetooth-central` to receive the offload in the first place. But
/// `analyzeRecent` is all-or-nothing: pass 1 writes nothing, every store write happens after both loops,
/// and the watermark advances only at the very end so an interrupted run can never mark unscored data as
/// scored. On a heavy install the pass measured **474,778 ms** — nearly eight minutes. iOS suspends the
/// process long before that, so the work is lost in full.
///
/// The lost work is not the worst of it. Because the watermark never advanced, the NEXT trigger still saw
/// `newData=yes` and started another full pass, which was killed in turn. The reporter's log shows exactly
/// that: every offload after 05:40:31 reported `caught up` with nothing new to fetch, yet two later ticks
/// still read `newData=yes`. It is a livelock — the pass cannot finish, and failing to finish is what
/// guarantees it will be attempted again. The score appeared 1 h 57 m after the data was complete, and only
/// because the app happened to stay foregrounded for eight unbroken minutes.
///
/// So this decides, before spending anything: is this a pass that can plausibly finish here?
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

    /// What a background execution assertion is worth relying on, in seconds.
    ///
    /// `beginBackgroundTask` buys roughly 30 s on current iOS, and that figure is a courtesy rather than a
    /// contract — it shrinks under memory pressure and in Low Power Mode. 20 s leaves headroom for the
    /// assertion to be granted late and for the pass's own store writes to land, since being killed
    /// mid-write is the one outcome worth spending real caution to avoid.
    static let backgroundBudgetSeconds: Double = 20

    /// - Parameters:
    ///   - isBackground: whether the app is currently backgrounded. A foregrounded app is never deferred:
    ///     the user is looking at the screen, there is no suspension deadline, and the existing behaviour
    ///     is correct.
    ///   - rescoreAlreadyOwed: a re-score is outstanding — either a pass marked itself started and never
    ///     marked itself finished (it was killed; the mark survives process death, which is the point,
    ///     because the killed process gets no chance to record anything) or an earlier trigger already
    ///     deferred one. Both mean the same operationally: the work is spoken for, and starting it here
    ///     would duplicate a pass that something better placed is going to run. This is the
    ///     self-correcting part — the FIRST background attempt on an install we know nothing about is
    ///     allowed to run, and from then on the work escalates instead of being re-killed on every
    ///     offload.
    ///   - lastCompletedPassSeconds: how long the last pass that ran to completion took, or nil if none
    ///     has. Measured rather than assumed — the cost varies by more than an order of magnitude with
    ///     history size, and a fixed guess would either defer installs that finish comfortably or wave
    ///     through ones that never could.
    ///   - budgetSeconds: see `backgroundBudgetSeconds`; a parameter so the tests can state the boundary
    ///     rather than inherit it.
    static func decide(isBackground: Bool,
                       rescoreAlreadyOwed: Bool,
                       lastCompletedPassSeconds: Double?,
                       budgetSeconds: Double = backgroundBudgetSeconds) -> Decision {
        guard isBackground else { return .run }

        if rescoreAlreadyOwed {
            return .deferToBackgroundTask(
                reason: "a re-score is already outstanding from an earlier trigger")
        }

        // Only a FINITE, positive measurement can justify deferring. A nil (nothing has ever completed),
        // a zero, or a NaN/infinity from a corrupted default all mean "unknown", and unknown must fall
        // through to running: refusing to score on the strength of a value we cannot read would be a far
        // worse failure than one wasted pass.
        if budgetSeconds > 0,
           let measured = lastCompletedPassSeconds,
           measured.isFinite, measured > 0,
           measured > budgetSeconds {
            return .deferToBackgroundTask(
                reason: "last completed pass took \(Int(measured.rounded()))s, over the "
                        + "\(Int(budgetSeconds.rounded()))s a background wake can be relied on for")
        }

        return .run
    }
}
