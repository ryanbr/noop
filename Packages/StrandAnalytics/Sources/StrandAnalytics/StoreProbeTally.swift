import Foundation

/// How much of an `analyzeRecent` pass goes into its per-day PROBE queries, as calls and milliseconds.
///
/// The blind spot this closes: with the steps-calibration fold now reused rather than recomputed, a warm
/// pass still reported ~3.3 s in the steps phase with `stepsMotion reused=60/60` beside it, so the fold was
/// provably not the cost and nothing said what was. The phase is bracketed as one number and sits outside
/// the `#1538` day-loop tally, so the remaining candidates — the sixty per-day probe queries, the one
/// `appleDaily` read, and the in-memory calibration fit — were indistinguishable from each other.
///
/// Two probes are worth counting because each has exactly ONE call site, so the counts attribute themselves
/// with no bookkeeping at the call site and no way to drift:
/// - `ownerHr`: `hasHrInWindow`, the day-owner resolver's per-candidate presence probe. Runs in BOTH the
///   scoring loop and the sixty-day steps loop, and is skipped entirely on a default single-strap install
///   (#970), so a two-strap library is the only one that pays it.
/// - `gravityFp`: `gravityFingerprint`, the steps loop's per-day motion witness. Steps-only.
///
/// Read with the `stepsMotion reused=N/M` line, this is decisive rather than suggestive: a warm pass that
/// folded nothing and still spent its time here means the round trips ARE the cost and batching them into a
/// grouped query is worth building; one that does not means the cost is the `appleDaily` read or the fit,
/// and batching would have bought nothing. Measured, not guessed — the same reason the day-loop split and
/// the day-cache duration are measured rather than reasoned about.
///
/// Instrumentation only: nothing reads these counts but the log line.
public enum StoreProbeTally {
    /// Render ordered `(name, calls, seconds)` probes as one line.
    ///
    /// `calls` is printed beside the time because the two answer different questions: the time says whether
    /// this is where the pass went, and the count says whether the loop issued the number of round trips it
    /// was believed to (sixty per steps pass, one per day). A count that is right with a time that is large
    /// is a slow query; a count that is wrong is a different bug entirely, and one line should not be able
    /// to hide either. Byte-identical to the Kotlin `StoreProbeTally.logLine`.
    public static func logLine(_ probes: [(name: String, calls: Int, seconds: Double)]) -> String {
        let parts = probes.map { "\($0.name)=\($0.calls)/\(millis($0.seconds))ms" }
        let total = probes.reduce(0.0) { $0 + $1.seconds }
        return "analyzeRecent storeProbes total=\(millis(total))ms "
            + (parts.isEmpty ? "(no probes)" : parts.joined(separator: " "))
    }

    /// Seconds to whole milliseconds, floored at zero. The clamp is the parity contract, not defensive
    /// habit: a negative or non-finite input is where Swift's round-half-away-from-zero and Kotlin's
    /// round-half-up disagree, at exactly -0.5 ms, and both sides render into one shared strap log. The
    /// callers here cannot produce one (they count monotonic nanoseconds), which makes this a guarantee
    /// about the renderer rather than a repair of its inputs.
    private static func millis(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}
