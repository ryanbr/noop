package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1008/#1118/#1331: HrvAnalyzer.collapseOverCount — the SHADOW de-dup of the WHOOP 4.0 R-R over-count.
 * Pins that a synthetic over-count (each real beat emitted three times — an exact duplicate plus a
 * two-optical-channel twin ~34 ms off, the #1008 signature) collapses back to ~one beat per real
 * interval, so coverage drops from ~3x toward ~1.0 and the stream becomes beat-accurate again (which is
 * what would let it pass #1127's RSA gate — the #1331 fix). Mirrors the macOS HrvCollapseOverCountTests.
 */
class HrvCollapseOverCountTest {

    /** 60 real beats, one per second at 1000 ms, each emitted 3x in its second: exact dup + a ~34 ms twin. */
    private fun overCounted(): Pair<List<Long>, List<Double>> {
        val ts = ArrayList<Long>()
        val rr = ArrayList<Double>()
        for (s in 0 until 60) {
            val base = 1000.0
            // channel A (green): the beat + an exact duplicate of it
            ts.add(s.toLong()); rr.add(base)
            ts.add(s.toLong()); rr.add(base)
            // channel B (spo2): the SAME beat reported ~34 ms different, same second
            ts.add(s.toLong()); rr.add(base + 34.0)
        }
        return Pair(ts, rr)
    }

    @Test
    fun collapseOverCount_recoversOneBeatPerInterval() {
        val (ts, rr) = overCounted()
        assertEquals("fixture is 3x over-counted", 180, rr.size)
        // Raw coverage ~3x (180 beats * ~1000 ms / 59 s span).
        val rawCov = HrvAnalyzer.rrCoverage(ts, rr)
        assertTrue("raw over-counted coverage should be ~3x, was $rawCov", rawCov > 2.5)

        val (ddTs, ddRr) = HrvAnalyzer.collapseOverCount(ts, rr)
        // Exact dup + the 34 ms twin (< 40 ms tol) both collapse → one beat per second.
        assertEquals("deduped to one beat per real interval", 60, ddRr.size)
        assertEquals("ts and rr stay in lockstep", 60, ddTs.size)
        val ddCov = HrvAnalyzer.rrCoverage(ddTs, ddRr)
        assertEquals("deduped coverage collapses toward 1.0", 1.0, ddCov, 0.1)
    }

    @Test
    fun collapseOverCount_exactDupOnlyKeepsTheChannelTwin() {
        // rrTolMs=0 collapses ONLY exact same-second duplicates (the safe floor — no real-beat loss). The
        // ~34 ms channel twin survives, so 180 (=60x[beat + exact-dup + twin]) → 120 (=60x[beat + twin])
        // and coverage stays ~2x, not 1.0. This is the reference line the shadow logs beside the ~40 ms one.
        val (ts, rr) = overCounted()
        val (exTs, exRr) = HrvAnalyzer.collapseOverCount(ts, rr, 0.0)
        assertEquals("exact-dup removed, channel twin kept", 120, exRr.size)
        assertEquals(120, exTs.size)
        assertTrue("exact-dup coverage stays ~2x (twins remain)", HrvAnalyzer.rrCoverage(exTs, exRr) > 1.8)
    }

    @Test
    fun collapseOverCount_leavesACleanStreamUntouched() {
        // A beat-accurate stream (one beat per second, no same-second duplicates) must pass through as-is.
        val ts = (0 until 60).map { it.toLong() }
        val rr = (0 until 60).map { 1000.0 }
        val (ddTs, ddRr) = HrvAnalyzer.collapseOverCount(ts, rr)
        assertEquals(60, ddRr.size)
        assertEquals(ts, ddTs)
    }

    @Test
    fun collapseOverCount_windowSecCrossSecondIsAnAggressiveUpperBound() {
        // #1331: the cross-second window (windowSec > 0) catches boundary-straddling twins a same-second
        // collapse can't reach — but it is a strict UPPER BOUND, not a shippable de-dup: it also over-merges
        // a STEADY real HR whose intervals repeat one second apart. Shadow-instrumentation only. Twin of Swift.
        val steadyTs = (0L until 10L).toList()
        val steadyRr = List(10) { 1000.0 }
        assertEquals("windowSec 0 leaves a steady stream untouched (safe default)",
            10, HrvAnalyzer.collapseOverCount(steadyTs, steadyRr, 40.0, 0L).second.size)
        assertEquals("windowSec 1 over-merges every other real beat — upper bound, not shippable",
            5, HrvAnalyzer.collapseOverCount(steadyTs, steadyRr, 40.0, 1L).second.size)

        // Boundary-straddling duplicate (the crossSecondOverCount signature): same 500 ms beat at second 0
        // AND second 1. Same-second keeps both; the 1-second window drops the twin.
        assertEquals(2, HrvAnalyzer.collapseOverCount(listOf(0L, 1L), listOf(500.0, 500.0), 40.0, 0L).second.size)
        assertEquals(1, HrvAnalyzer.collapseOverCount(listOf(0L, 1L), listOf(500.0, 500.0), 40.0, 1L).second.size)
        // Distinct values one second apart are real neighbours (|Δ| > tol) — never merged, even cross-second.
        assertEquals(2, HrvAnalyzer.collapseOverCount(listOf(0L, 1L), listOf(500.0, 900.0), 40.0, 1L).second.size)
    }
}
