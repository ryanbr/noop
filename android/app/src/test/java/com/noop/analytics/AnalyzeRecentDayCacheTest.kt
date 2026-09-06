package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * [AnalyzeRecentDayCache.cacheKey] — the per-day reuse identity for `analyzeRecent`'s pass-1 loop. Twin of
 * the Swift `AnalyzeRecentDayCacheTests`; keep the two in lockstep on the invalidation rules (the exact key
 * STRING may differ across platforms — the cache is in-memory and per-platform — but the set of changes that
 * must / must not invalidate a reused day is a shared contract).
 */
class AnalyzeRecentDayCacheTest {
    /** A settled night's other-stream witness (`WhoopRepository.dayStreamFingerprint`) — opaque to the key,
     *  so these tests only need two values that differ. */
    private val baseStreams = "s1|p0:0|r120000:1700000000|x0:0|o0:0|g86400:1700000000|z0:0|t0:0|e0:0"


    /**
     * #1575: the day that emits the per-window HRV DETAIL must not be reused as an ordinary night.
     *
     * Trace lines are now recorded and replayed, so the cached "today" carries a detailed HRV trace. After
     * midnight that same night is an ordinary one and a fresh scan would emit only the one-line summary —
     * replaying the detail would break the cache's whole promise, that a reused night is indistinguishable
     * from a freshly-scored one. Folding the flag into the key costs one day's re-score per rollover, and
     * only while a trace mode is on.
     */
    @Test
    fun theHrvDetailDayIsNotReusedAsAnOrdinaryNight() {
        val detail = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0,
                                                    baseStreams, hrvWindowDetail = true)
        val summary = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0,
                                                     baseStreams, hrvWindowDetail = false)
        assertNotEquals("the detail day must invalidate when it stops being today", detail, summary)
    }
    // Unchanged inputs -> identical key -> the day is reused.
    @Test fun stableInputsReuse() {
        val a = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        val b = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        assertEquals(a, b)
    }

    // A new HR row (count moves) OR a later newest-ts must invalidate — the day changed.
    @Test fun hrChangeInvalidates() {
        val base = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        val moreRows = AnalyzeRecentDayCache.cacheKey("dev1", 178_001, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        val laterTs = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_060L, 1290.0, baseStreams, hrvWindowDetail = false)
        assertNotEquals(base, moreRows)
        assertNotEquals(base, laterTs)
    }

    // A shifted window-wide skin anchor (another night's skin changed the 4.0 median) must invalidate even
    // when this night's HR fingerprint is identical — the skin conversion changed.
    @Test fun anchorShiftInvalidates() {
        val a = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        val b = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.5, baseStreams, hrvWindowDetail = false)
        assertNotEquals(a, b)
    }

    // A night with no anchor (null) is a distinct, self-consistent key: null reuses null, and null != a real
    // anchor (so it never aliases to a real-anchor night's scan).
    @Test fun nullAnchorDistinctButStable() {
        val nilA = AnalyzeRecentDayCache.cacheKey("dev1", 5_000, 1_700_000_000L, null, baseStreams, hrvWindowDetail = false)
        val nilB = AnalyzeRecentDayCache.cacheKey("dev1", 5_000, 1_700_000_000L, null, baseStreams, hrvWindowDetail = false)
        val real = AnalyzeRecentDayCache.cacheKey("dev1", 5_000, 1_700_000_000L, 0.0, baseStreams, hrvWindowDetail = false)
        assertEquals(nilA, nilB)
        assertNotEquals(nilA, real)
    }

    // Multi-strap (4.0 + 5/MG): if a day's resolved owner flips between straps, the key must invalidate
    // EXPLICITLY — even in the astronomically-unlikely case that the two straps produced an identical
    // count+maxTs for the same window. The owner id is part of the key, so it never falsely reuses one
    // strap's scan for the other.
    @Test fun differentOwnerInvalidates() {
        val whoop4 = AnalyzeRecentDayCache.cacheKey("whoop4-A", 178_000, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        val whoop5 = AnalyzeRecentDayCache.cacheKey("whoop5-B", 178_000, 1_700_000_000L, 1290.0, baseStreams, hrvWindowDetail = false)
        assertNotEquals(whoop4, whoop5)
    }

    /**
     * #29: a stream that is not HR moving must invalidate, even with the HR fingerprint frozen.
     *
     * A history offload delivers channels independently and ignores offloaded HR rows that duplicate live
     * ones, so a night scored once from HR alone can gain its R-R — or its respiration, SpO2, gravity,
     * steps, skin temp, events, or a PPG-derived HR second — with this night's `hrCount`/`hrMaxTs`
     * completely unmoved. Keyed on HR alone that said "reuse" and re-served the HRV-less scan for the rest
     * of the process, user-initiated refreshes included.
     *
     * Twin of Swift `testAStreamArrivingAfterHrInvalidatesTheReusedNight`.
     */
    @Test fun aStreamArrivingAfterHrInvalidatesTheReusedNight() {
        // Same night, same HR rows, same anchor — only the other-stream witness moved.
        val hrOnly = AnalyzeRecentDayCache.cacheKey(
            "dev1", 178_000, 1_700_000_000L, 1290.0,
            "s1|p0:0|r0:0|x0:0|o0:0|g0:0|z0:0|t0:0|e0:0", hrvWindowDetail = false)
        val rrLanded = AnalyzeRecentDayCache.cacheKey(
            "dev1", 178_000, 1_700_000_000L, 1290.0,
            "s1|p0:0|r120000:1700000000|x0:0|o0:0|g0:0|z0:0|t0:0|e0:0", hrvWindowDetail = false)
        assertNotEquals("the night's R-R arrived — its cached scan has no HRV in it", hrOnly, rrLanded)
    }

    /**
     * The other half of the same contract: a witness that did NOT move must still reuse. #29's fix must not
     * turn every pass into a full re-score — that is the drain #1005 closed.
     */
    @Test fun unchangedStreamWitnessStillReuses() {
        val a = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0, baseStreams,
                                               hrvWindowDetail = false)
        val b = AnalyzeRecentDayCache.cacheKey("dev1", 178_000, 1_700_000_000L, 1290.0, baseStreams,
                                               hrvWindowDetail = false)
        assertEquals(a, b)
    }
}
