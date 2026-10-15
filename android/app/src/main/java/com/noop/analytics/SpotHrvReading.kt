package com.noop.analytics

/**
 * On-demand "take an HRV reading now" — the single-value spot RMSSD path (#537, @sunny-noop).
 *
 * This wraps NOOP's canonical [HrvAnalyzer] for the LIVE, user-triggered HRV snapshot the Live screen
 * captures over ~60 s of beat-to-beat (R-R) intervals. It exists so the spot value, its honesty gate,
 * and its data-quality caveat live in ONE tested place rather than being re-derived in the view.
 *
 * Why delegate to [HrvAnalyzer] (and NOT roll our own RMSSD):
 *  - RMSSD is the textbook root-mean-square of successive R-R differences:
 *        RMSSD = sqrt( mean( (RR[i+1] - RR[i])^2 ) )   in ms.
 *  - NOOP's nightly HRV (`avgHrv`, fed into Vitality / Fitness Age) uses [HrvAnalyzer.rmssdRaw], which
 *    takes the Task Force (1996) SAMPLE denominator (n-1) over the cleaned NN series. To keep a spot
 *    reading COMPARABLE to the overnight number a user sees elsewhere, this path computes RMSSD the
 *    SAME way (same cleaning pipeline, same (n-1) denominator). Using a population (n) denominator —
 *    as a from-scratch port might — would make the same beats read a few percent lower than the
 *    nightly figure, which is misleading. Consistency with the existing scorer is the whole point.
 *
 * Honesty is built in, not bolted on:
 *  - A number is returned ONLY when enough CLEAN beats survive ([HrvAnalyzer.MIN_BEATS]); otherwise the
 *    result is [Insufficient] with the surviving/needed counts so the UI can say so plainly (never a
 *    fabricated value, unknown stays "—").
 *  - The caveat ([caveatFor]) is source-aware: a 60 s spot reading is not the overnight baseline, it
 *    needs enough beats, and R-R derived from a WHOOP strap's optical PPG (4.0, 5.0 or MG) is noisier than
 *    an electrical chest strap's R-R. Pure strings, US-neutral, no em-dashes.
 *
 * Pure arithmetic + small data holders, no I/O — fully unit-testable against a known RR series.
 */
object SpotHrvReading {

    /** Where the live R-R intervals came from — drives the honesty caveat (optical PPG is noisier). */
    enum class Source {
        /** Any WHOOP strap (4.0, 5.0, MG): R-R from the optical PPG via 0x2A37 — beat-to-beat, but noisier. */
        OPTICAL_PPG,

        /** An electrical chest strap (e.g. Polar H10) over the standard 0x2A37 profile — electrical R-R. */
        CHEST_STRAP,

        /** Source not known (generic / unspecified strap). */
        UNKNOWN,
    }

    /** Outcome of an on-demand spot reading. */
    sealed interface Outcome {
        /** A trustworthy spot value: [rmssdMs] (ms), mean [hrBpm] (or null), and the clean-beat [beats]
         *  used. Backed by the full [HrvAnalyzer] result for callers that want SDNN / pNN50 too. */
        data class Reading(
            val rmssdMs: Double,
            val hrBpm: Double?,
            val beats: Int,
            val full: HrvAnalyzer.HrvResult,
        ) : Outcome

        /** Not enough clean beats to report honestly — carries how many survived vs how many are needed
         *  so the UI can guide the user ("sit still and try again"). */
        data class Insufficient(val clean: Int, val needed: Int, val input: Int) : Outcome
    }

    /**
     * Compute a single spot HRV reading from the raw R-R intervals (ms) gathered during the live
     * capture window. Runs NOOP's canonical cleaning + RMSSD (range filter -> Malik ectopic rejection
     * -> (n-1) RMSSD), so the value matches the nightly HRV math. Returns [Outcome.Insufficient] rather
     * than a number when too few clean beats survive — never a fabricated figure.
     *
     * @param rrMs the raw R-R intervals in milliseconds, in capture order (untrusted BLE input — the
     *   analyzer's range filter bounds-checks each to [HrvAnalyzer.RR_MIN_MS]..[HrvAnalyzer.RR_MAX_MS]).
     * @param maxRejectedFraction the spot honesty gate (#585) — refuse the reading when more than this
     *   fraction of beats was dropped as noise (out-of-range / ectopic), even if [HrvAnalyzer.MIN_BEATS]
     *   clean beats survive. Defaults to [HrvAnalyzer.DEFAULT_SPOT_MAX_REJECTED_FRACTION] (0.35). The
     *   nightly windowed path does NOT use this, so overnight HRV is unchanged.
     */
    fun compute(
        rrMs: List<Int>,
        maxRejectedFraction: Double = HrvAnalyzer.DEFAULT_SPOT_MAX_REJECTED_FRACTION,
    ): Outcome {
        val result = HrvAnalyzer.analyzeRaw(rrMs.map { it.toDouble() }, maxRejectedFraction)
        val rmssd = result.rmssd
        return if (rmssd == null) {
            Outcome.Insufficient(clean = result.nClean, needed = HrvAnalyzer.MIN_BEATS, input = result.nInput)
        } else {
            Outcome.Reading(
                rmssdMs = rmssd,
                hrBpm = meanHrFromNN(result.meanNN),
                beats = result.nClean,
                full = result,
            )
        }
    }

    /** Mean heart rate (bpm) from the mean NN interval (ms): 60000 / meanNN. null when missing or <= 0. */
    fun meanHrFromNN(meanNN: Double?): Double? =
        if (meanNN == null || meanNN <= 0.0) null else 60_000.0 / meanNN

    /**
     * Honest, source-aware caveat for a spot reading. Plain text, US-neutral, no em-dashes. Always
     * states the two universal limits (a 60 s spot is not the overnight baseline; it needs enough clean
     * beats) and adds the source-specific noise note for an optical-PPG strap.
     */
    fun caveatFor(source: Source): String {
        val base =
            "This is a spot reading over a short, still capture, not your overnight HRV baseline. " +
                "Take it seated, still, and at a consistent time of day for comparable numbers, and " +
                "only a reading with enough clean beats is shown."
        return when (source) {
            Source.OPTICAL_PPG ->
                base + " On a WHOOP strap (4.0, 5.0 or MG) the intervals come from the optical pulse signal, which is " +
                    "noisier than an electrical chest strap such as a Polar H10, so treat the number as a rough estimate."
            Source.CHEST_STRAP, Source.UNKNOWN -> base
        }
    }
}
