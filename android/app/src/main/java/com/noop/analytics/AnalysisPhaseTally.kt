package com.noop.analytics

import kotlin.math.roundToLong

/**
 * Where an `analyzeRecent` pass spends the time AFTER its per-day loop. Kotlin twin of the Swift
 * `AnalysisPhaseTally`.
 *
 * #1538 added a cost line, but it brackets the day loop and is emitted the moment that loop returns. Every
 * phase after it — the baseline folds, pass 2, the persist, the weekly metrics, the steps calibration, the
 * sleep writes and heals, the workout rescore — was outside the tally, so a pass whose time went somewhere
 * after the loop reported a small `prep`/`score` and no explanation for the rest. The steps calibration
 * alone re-folded sixty days of gravity per pass under that blind spot.
 *
 * This is the same idea at the other end of the pass: stamp each phase as it completes and print them in
 * order, so the dominant phase names itself instead of being inferred from what the day-loop line does not
 * account for.
 */
object AnalysisPhaseTally {
    /**
     * Render ordered `(name, seconds)` phases as one line, each in milliseconds.
     *
     * Phases print in the order given, which is execution order — reading the line top to bottom is reading
     * the pass front to back. The total is included because the phases deliberately do NOT have to sum to
     * the pass: anything not bracketed shows up as the difference, which is itself the signal that a phase
     * is still unmeasured.
     *
     * [scope] names WHAT was bracketed, and it is a parameter rather than a constant because the two
     * platforms can afford to measure different amounts — see the class note. A line that said `postLoop`
     * while timing only part of the post-loop would misreport its own total, which is the one thing a cost
     * line must not do. Byte-identical to the Swift `AnalysisPhaseTally.logLine`.
     */
    fun logLine(scope: String, phases: List<Pair<String, Double>>): String {
        val parts = phases.map { "${it.first}=${millis(it.second)}ms" }
        val total = phases.sumOf { it.second }
        return "analyzeRecent $scope total=${millis(total)}ms " +
            if (parts.isEmpty()) "(no phases)" else parts.joinToString(" ")
    }

    /**
     * Seconds to whole milliseconds, floored at zero.
     *
     * The clamp is the parity contract, not defensive habit. These are wall-clock differences, and a clock
     * that steps backwards mid-pass (an NTP correction is enough) yields a negative interval — the one
     * input where Swift's round-half-away-from-zero and Kotlin's round-half-up disagree, at exactly
     * -0.5 ms. Clamping first makes both sides provably identical instead of identical only while the
     * clock behaves. A phase cannot take less than no time, so nothing true is lost.
     */
    private fun millis(seconds: Double): Long =
        if (!seconds.isFinite() || seconds <= 0.0) 0L else (seconds * 1000).roundToLong()
}

/**
 * Ordered phase stopwatch for one `analyzeRecent` pass, rendered by [AnalysisPhaseTally.logLine].
 *
 * A collector rather than the local closure the Swift side uses, and — unlike Swift — it brackets only
 * `persistFitnessVitalityAndSteps` rather than the whole post-loop. That is a JVM constraint, not a choice:
 * `analyzeRecentOnCpu` sits 210 bytes under the JaCoCo method-size ratchet that `IntelligenceEngineJacocoBudgetTest`
 * holds, and marking its phases costs about 467. The ratchet's own note says to extract rather than raise it,
 * and an extraction is a larger change than this one should carry, so Android measures the phase the cost was
 * actually found in and names its scope honestly. Extending it to the rest of the post-loop needs that
 * extraction first.
 *
 * Monotonic (`System.nanoTime`), matching the clock the day-loop tally beside it already uses.
 */
class AnalysisPhaseMarks {
    private val collected = ArrayList<Pair<String, Double>>()
    private var last = System.nanoTime()

    /** Close the phase that ends here and name it. */
    fun mark(name: String) {
        val now = System.nanoTime()
        collected.add(name to (now - last) / 1_000_000_000.0)
        last = now
    }

    val phases: List<Pair<String, Double>> get() = collected
}
