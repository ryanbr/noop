package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of `SleepReadWindowTests.swift` — the two must agree case for case, since this one bound
 * decides which sleep sessions "today" reads and the platforms may not disagree about a wake time.
 *
 * #500 fixed the sleep-read window for PAST days but left TODAY capped at `dayStart + 18h`, so a
 * day-sleeper (asleep ~12:00, awake ~20:00) — still inside today when they wake — had every wake
 * reported as a flat 18:00 until local midnight, at which point the day became past, the other branch
 * took over, and the same night silently re-scored to the real time.
 */
class SleepReadWindowTest {

    // 2026-08-14 00:00 and 2026-08-15 00:00 in Athens (UTC+3) — the night from the reported capture.
    private val today = 1_786_690_800L          // Fri 14 Aug 00:00 +03
    private val tomorrow = today + 86_400L

    // ── Today ────────────────────────────────────────────────────────────────

    /** The regression. The wearer woke at 20:41; the read must reach it. */
    @Test
    fun todayReadsPastSixPMWhenTheWearerIsStillAwakeLater() {
        val wake = today + 20 * 3_600L + 41 * 60L      // 20:41
        val now = wake + 20 * 60L                      // they check the app at 21:01
        val end = IntelligenceEngine.sleepReadWindowEnd(dayStart = today, nowLocalMidnight = today, now = now)
        assertTrue("read window ends before the wake — it would report a flat 18:00", end >= wake)
        assertTrue("the 18:00 cap is back", end != today + 18 * 3_600L)
    }

    /** Today must never read into the future — the only property the old bound actually secured. */
    @Test
    fun todayNeverReadsPastNow() {
        val now = today + 9 * 3_600L                   // 09:00
        assertEquals(now, IntelligenceEngine.sleepReadWindowEnd(dayStart = today, nowLocalMidnight = today, now = now))
    }

    /** …and never past the day's own end, even if `now` has somehow run on. */
    @Test
    fun todayIsStillBoundedByTheNextLocalMidnight() {
        val now = today + 30 * 3_600L                  // absurd, but the bound must hold
        assertEquals(tomorrow, IntelligenceEngine.sleepReadWindowEnd(dayStart = today, nowLocalMidnight = today, now = now))
    }

    /** Early in the morning the window is still short — nothing here widens it beyond the present. */
    @Test
    fun todayEarlyMorningIsCappedAtNowNotAtSixPM() {
        val now = today + 2 * 3_600L                   // 02:00
        val end = IntelligenceEngine.sleepReadWindowEnd(dayStart = today, nowLocalMidnight = today, now = now)
        assertEquals(now, end)
        assertTrue(end < today + 18 * 3_600L)
    }

    // ── Past days ──────────────────────────────────────────────────────────────

    /** A past day reads the whole day — the half #500 already fixed, pinned so it stays fixed. */
    @Test
    fun aPastDayReadsThroughToTheNextLocalMidnight() {
        val yesterday = today - 86_400L
        val now = today + 21 * 3_600L
        assertEquals(
            "a past day must read to its own next midnight",
            today,
            IntelligenceEngine.sleepReadWindowEnd(dayStart = yesterday, nowLocalMidnight = today, now = now),
        )
    }

    /** A past day's window must NOT be shortened by `now` — that would re-truncate old nights. */
    @Test
    fun aPastDayIsNotClampedByNow() {
        val longAgo = today - 10 * 86_400L
        assertEquals(
            longAgo + 86_400L,
            IntelligenceEngine.sleepReadWindowEnd(dayStart = longAgo, nowLocalMidnight = today, now = today + 60L),
        )
    }

    // ── The rollover itself ─────────────────────────────────────────────────────

    /**
     * The reported symptom, expressed directly: the SAME night must not read differently either side of
     * local midnight. Before the fix the 00:01 reading reached 20:41 and the 23:59 one stopped at 18:00.
     */
    @Test
    fun theSameNightReadsTheSameJustBeforeAndJustAfterMidnight() {
        val wake = today + 20 * 3_600L + 41 * 60L
        // 23:59, still "today"
        val before = IntelligenceEngine.sleepReadWindowEnd(dayStart = today, nowLocalMidnight = today, now = today + 86_340L)
        // 00:01, now a past day
        val after = IntelligenceEngine.sleepReadWindowEnd(dayStart = today, nowLocalMidnight = tomorrow, now = tomorrow + 60L)
        assertTrue("pre-midnight read still truncates the wake", before >= wake)
        assertTrue(after >= wake)
        assertEquals(tomorrow, after)
    }
}
