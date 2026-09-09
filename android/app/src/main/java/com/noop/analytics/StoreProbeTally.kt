package com.noop.analytics

import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToLong

/**
 * How much of an `analyzeRecent` pass goes into its per-day PROBE queries, as calls and milliseconds.
 * Kotlin twin of the Swift `StoreProbeTally`.
 *
 * The blind spot this closes: with the steps-calibration fold now reused rather than recomputed, a warm
 * pass still reported ~3.3 s in the steps phase with `stepsMotion reused=60/60` beside it, so the fold was
 * provably not the cost and nothing said what was. The phase is bracketed as one number and sits outside
 * the #1538 day-loop tally, so the remaining candidates — the sixty per-day probe queries, the one
 * `appleDaily` read, and the in-memory calibration fit — were indistinguishable from each other.
 *
 * Two probes are worth counting because each has exactly ONE call site, so the counts attribute themselves
 * with no bookkeeping at the call site and no way to drift:
 * - `ownerHr`: [com.noop.data.WhoopRepository.hasHrInWindow], the day-owner resolver's per-candidate
 *   presence probe. Runs in BOTH the scoring loop and the sixty-day steps loop, and is skipped entirely on
 *   a default single-strap install (#970), so a two-strap library is the only one that pays it.
 * - `gravityFp`: [com.noop.data.WhoopRepository.gravityFingerprintWindow], the steps loop's per-day motion
 *   witness. Steps-only.
 *
 * Read with the `stepsMotion reused=N/M` line, this is decisive rather than suggestive: a warm pass that
 * folded nothing and still spent its time here means the round trips ARE the cost and batching them into a
 * grouped query is worth building; one that does not means the cost is the `appleDaily` read or the fit,
 * and batching would have bought nothing. Measured, not guessed.
 *
 * Counted in the repository rather than at the call site for a mechanical reason: `analyzeRecentOnCpu` sits
 * 210 bytes under the JaCoCo method-size ratchet [IntelligenceEngineJacocoBudgetTest] holds, and the steps
 * loop is inside it. Timing there would cost more than the margin, and the ratchet's own note says to
 * extract rather than raise it. Counting one level down costs the budgeted method nothing at all, and the
 * reset and the emit both live in the unbudgeted `analyzeRecent` wrapper.
 *
 * Instrumentation only: nothing reads these counts but the log line.
 */
object StoreProbeTally {
    private val ownerHrCalls = AtomicLong()
    private val ownerHrNanos = AtomicLong()
    private val gravityFpCalls = AtomicLong()
    private val gravityFpNanos = AtomicLong()

    /** Record one day-owner HR presence probe. Called from the repository, off the pass's hot method. */
    fun recordOwnerHr(nanos: Long) {
        ownerHrCalls.incrementAndGet()
        ownerHrNanos.addAndGet(nanos)
    }

    /** Record one per-day gravity witness read. */
    fun recordGravityFp(nanos: Long) {
        gravityFpCalls.incrementAndGet()
        gravityFpNanos.addAndGet(nanos)
    }

    /** Zero the counters at the start of a pass, so a line describes ONE pass and never accumulates across
     *  the back-to-back passes an offload storm is made of. */
    fun reset() {
        ownerHrCalls.set(0); ownerHrNanos.set(0)
        gravityFpCalls.set(0); gravityFpNanos.set(0)
    }

    /** This pass's line, in the shared format. */
    fun line(): String = logLine(
        listOf(
            Triple("ownerHr", ownerHrCalls.get(), ownerHrNanos.get() / 1_000_000_000.0),
            Triple("gravityFp", gravityFpCalls.get(), gravityFpNanos.get() / 1_000_000_000.0),
        )
    )

    /**
     * Render ordered `(name, calls, seconds)` probes as one line.
     *
     * [calls] is printed beside the time because the two answer different questions: the time says whether
     * this is where the pass went, and the count says whether the loop issued the number of round trips it
     * was believed to (sixty per steps pass, one per day). A count that is right with a time that is large
     * is a slow query; a count that is wrong is a different bug entirely, and one line should not be able
     * to hide either. Byte-identical to the Swift `StoreProbeTally.logLine`.
     */
    fun logLine(probes: List<Triple<String, Long, Double>>): String {
        val parts = probes.map { "${it.first}=${it.second}/${millis(it.third)}ms" }
        val total = probes.sumOf { it.third }
        return "analyzeRecent storeProbes total=${millis(total)}ms " +
            if (parts.isEmpty()) "(no probes)" else parts.joinToString(" ")
    }

    /** Seconds to whole milliseconds, floored at zero. The clamp is the parity contract, not defensive
     *  habit: a negative or non-finite input is where Swift's round-half-away-from-zero and Kotlin's
     *  round-half-up disagree, at exactly -0.5 ms, and both sides render into one shared strap log. The
     *  callers here cannot produce one (they count monotonic nanoseconds), which makes this a guarantee
     *  about the renderer rather than a repair of its inputs. */
    private fun millis(seconds: Double): Long =
        if (!seconds.isFinite() || seconds <= 0.0) 0L else (seconds * 1000).roundToLong()
}
