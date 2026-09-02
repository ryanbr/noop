package com.noop.analytics

// SleepStagerTrace.kt - Kotlin twin of SleepStager+Trace.swift. Pure gate-trace line builders for
// the Sleep & Rest test mode. Byte-aligned with the Swift line shape so the parity test passes.
// No em-dashes. Counts and seconds only.

object SleepStagerTrace {
    enum class Verdict(val tag: String) { KEPT("KEPT"), DROPPED("DROPPED") }

    /**
     * Why the HR-only spine did or did not run (#1801).
     *
     * The funnel line below only exists when the spine is CALLED, so its absence was ambiguous in
     * exactly the way that made the first field report unreadable: it could mean the gate never
     * opened, or that the sink was never wired. This says which, on any day with no motion — the only
     * days where the question arises. A day that HAS motion never prints it, because the motion spine
     * is the answer there and nothing was skipped.
     */
    fun hrOnlyGateLine(attempted: Boolean, reason: String, gravRows: Int, storedNights: Int): String =
        "[sleep] hr-only gate attempted=$attempted reason=$reason grav=$gravRows stored=$storedNights"

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
        anchorBpm: Double?, bandBpm: Double?, hrP50: Double?, hrP90: Double?, epochs: Int,
        runs: Int, mergedRuns: Int, sleepRuns: Int,
        longestSleepMin: Int, staged: Int, kept: Int, minSleepMin: Int,
    ): String =
        "[sleep] hr-only spine anchorBpm=${round1(anchorBpm)} bandBpm=${round1(bandBpm)} " +
            "hrP50=${round1(hrP50)} hrP90=${round1(hrP90)} " +
            "epochs=$epochs runs=$runs merged=$mergedRuns sleepRuns=$sleepRuns " +
            "longestMin=$longestSleepMin staged=$staged kept=$kept minSleepMin=$minSleepMin"

    /**
     * One decimal, by ARITHMETIC rather than `printf`.
     *
     * `String.format("%.1f", …)` is not a twin: Java rounds HALF_UP on the decimal expansion while
     * Swift's `String(format:)` goes through C `printf`, which rounds half-to-even on the actual
     * binary value. A harness caught them disagreeing on 64.05 — Kotlin 64.1, Swift 64.0 — and a band
     * of `anchor * 1.05` produces trailing decimals constantly, so that would have diverged on most
     * real values. Multiplying and rounding is IEEE-deterministic, so both platforms do the same
     * arithmetic to the same bits and cannot disagree, whichever side of .5 the product lands on.
     * Same reasoning as [round2] one line down, which was already arithmetic.
     *
     * NON-NEGATIVE ONLY. `-0.5` would print "0.5", because the integer division truncates toward zero
     * and the sign is then lost to `abs`. Every current caller is a bpm, which cannot be negative;
     * a caller that could be would need the sign carried separately.
     */
    private fun round1(v: Double?): String {
        if (v == null) return "nil"
        val tenths = Math.round(v * 10.0)
        return "${tenths / 10}.${Math.abs(tenths % 10)}"
    }

    fun runLine(index: Int, startTs: Long, endTs: Long, verdict: Verdict, gate: String, detail: String): String {
        val spanS = maxOf(0L, endTs - startTs)
        return "gate run=$index spanS=$spanS ${verdict.tag} gate=$gate $detail"
    }

    fun flipLine(epoch: Int, from: String, to: String, threshold: String): String =
        "epoch=$epoch flip $from->$to threshold=$threshold"

    /** Round to 2 dp for the trace detail fields (AnalyticsEngine.round2 is private). Formatting only. */
    fun round2(v: Double): Double = Math.round(v * 100.0) / 100.0
}
