import Foundation

/// Where an `analyzeRecent` pass spends the time AFTER its per-day loop.
///
/// #1538 added a cost line, but it brackets the day loop and is emitted the moment that loop returns. Every
/// phase after it — the baseline folds, pass 2, the persist, the weekly metrics, the steps calibration, the
/// sleep writes and heals, the workout rescore — was outside the tally, so a pass whose time went somewhere
/// after the loop reported a small `prep`/`score` and no explanation for the rest. The steps calibration
/// alone re-folded sixty days of gravity per pass under that blind spot.
///
/// This is the same idea at the other end of the pass: stamp each phase as it completes and print them in
/// order, so the dominant phase names itself instead of being inferred from what the day-loop line does not
/// account for.
public enum AnalysisPhaseTally {
    /// Render ordered `(name, seconds)` phases as one line, each in milliseconds.
    ///
    /// Phases print in the order given, which is execution order — reading the line top to bottom is reading
    /// the pass front to back. The total is included because the phases deliberately do NOT have to sum to
    /// the pass: anything not bracketed shows up as the difference, which is itself the signal that a phase
    /// is still unmeasured.
    ///
    /// `scope` names WHAT was bracketed, and it is a parameter rather than a constant because the two
    /// platforms can afford to measure different amounts: Android's `analyzeRecentOnCpu` sits under a
    /// JaCoCo method-size ratchet that leaves no room for the marks, so it brackets only its persist
    /// helper. A line that said `postLoop` while timing part of the post-loop would misreport its own
    /// total, which is the one thing a cost line must not do. Byte-identical to the Kotlin
    /// `AnalysisPhaseTally.logLine`.
    public static func logLine(scope: String, _ phases: [(name: String, seconds: Double)]) -> String {
        let parts = phases.map { "\($0.name)=\(millis($0.seconds))ms" }
        let total = phases.reduce(0.0) { $0 + $1.seconds }
        return "analyzeRecent \(scope) total=\(millis(total))ms "
            + (parts.isEmpty ? "(no phases)" : parts.joined(separator: " "))
    }

    /// Seconds to whole milliseconds, floored at zero.
    ///
    /// The clamp is the parity contract, not defensive habit. These are `Date()` differences, and a wall
    /// clock that steps backwards mid-pass (an NTP correction is enough) yields a negative interval — the
    /// one input where Swift's round-half-away-from-zero and Kotlin's round-half-up disagree, at exactly
    /// -0.5 ms. Clamping first makes both sides provably identical instead of identical only while the
    /// clock behaves. A phase cannot take less than no time, so nothing true is lost.
    private static func millis(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}
