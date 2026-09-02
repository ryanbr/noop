package com.noop.analytics

// SleepStagerTrace.kt - Kotlin twin of SleepStager+Trace.swift. Pure gate-trace line builders for
// the Sleep & Rest test mode. Byte-aligned with the Swift line shape so the parity test passes.
// No em-dashes. Counts and seconds only.

object SleepStagerTrace {
    enum class Verdict(val tag: String) { KEPT("KEPT"), DROPPED("DROPPED") }

    /**
     * The HR-only spine's own funnel line (#1801).
     *
     * The path shipped silent, and a field log then showed `reason=no-motion` with no way to tell
     * whether the spine had run and found nothing or never ran at all — in a file whose entire sleep
     * story is a funnel. Every number here exists to separate the two failures that actually happen:
     * a band too tight (`sleepRuns` near zero) from a duration gate eating real runs (`sleepRuns` high,
     * `longestMin` under `minSleepMin`).
     *
     * `anchorBpm` and `bandBpm` are printed because they are derived, not configured: the anchor is a
     * percentile of THIS window, so the same code gives a different threshold to every wearer, and a
     * complaint is unreadable without knowing which one they got.
     */
    fun hrOnlyLine(
        anchorBpm: Double?, bandBpm: Double?, epochs: Int,
        runs: Int, mergedRuns: Int, sleepRuns: Int,
        longestSleepMin: Int, staged: Int, kept: Int, minSleepMin: Int,
    ): String =
        "[sleep] hr-only spine anchorBpm=${round1(anchorBpm)} bandBpm=${round1(bandBpm)} " +
            "epochs=$epochs runs=$runs merged=$mergedRuns sleepRuns=$sleepRuns " +
            "longestMin=$longestSleepMin staged=$staged kept=$kept minSleepMin=$minSleepMin"

    private fun round1(v: Double?): String =
        if (v == null) "nil" else String.format(java.util.Locale.US, "%.1f", v)

    fun runLine(index: Int, startTs: Long, endTs: Long, verdict: Verdict, gate: String, detail: String): String {
        val spanS = maxOf(0L, endTs - startTs)
        return "gate run=$index spanS=$spanS ${verdict.tag} gate=$gate $detail"
    }

    fun flipLine(epoch: Int, from: String, to: String, threshold: String): String =
        "epoch=$epoch flip $from->$to threshold=$threshold"

    /** Round to 2 dp for the trace detail fields (AnalyticsEngine.round2 is private). Formatting only. */
    fun round2(v: Double): Double = Math.round(v * 100.0) / 100.0
}
