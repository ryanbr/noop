package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The periodic stress refresh's decision (#2185), which is the only part of a widget worker a JVM test
 * can reach. Same discipline as `StressWidgetBackgroundScoringTest`: the conditions are what can be
 * wrong, so they are a pure function and this pins them.
 */
class StressWidgetRefreshTest {

    private val interval = 15L * 60L * 1000L
    private val now = 1_700_000_000_000L

    /** No widget left to draw it: the schedule retires rather than waking every quarter hour forever. */
    @Test
    fun `a definite no retires the schedule`() {
        assertEquals(
            StressWidgetRefresh.Action.Retire,
            StressWidgetRefresh.action(placed = false, nowMs = now, lastScoredAtMs = 0L, intervalMs = interval),
        )
    }

    /**
     * A FAILED lookup is not a no. Retiring on it would cancel the schedule over a transient failure
     * with nothing left to restart it before the next app launch, so an unknown placement still scores.
     */
    @Test
    fun `an unknown placement scores rather than retiring`() {
        assertEquals(
            StressWidgetRefresh.Action.Score,
            StressWidgetRefresh.action(placed = null, nowMs = now, lastScoredAtMs = 0L, intervalMs = interval),
        )
    }

    /** Someone else scored a moment ago, so this pass would read a day of rows for a curve already shown. */
    @Test
    fun `a recent score defers`() {
        assertEquals(
            StressWidgetRefresh.Action.Skip,
            StressWidgetRefresh.action(
                placed = true, nowMs = now, lastScoredAtMs = now - (interval - 1), intervalMs = interval,
            ),
        )
    }

    /** The interval having elapsed is the whole point: the service has stopped and nothing else will. */
    @Test
    fun `a stale score scores`() {
        assertEquals(
            StressWidgetRefresh.Action.Score,
            StressWidgetRefresh.action(
                placed = true, nowMs = now, lastScoredAtMs = now - interval, intervalMs = interval,
            ),
        )
    }

    /** Never scored in this install: far enough in the past to admit the first pass rather than wait one out. */
    @Test
    fun `a never-scored install scores immediately`() {
        assertEquals(
            StressWidgetRefresh.Action.Score,
            StressWidgetRefresh.action(placed = true, nowMs = now, lastScoredAtMs = 0L, intervalMs = interval),
        )
    }

    /** Retiring wins over deferring: a removed widget must stop the schedule even mid-interval. */
    @Test
    fun `no widget retires even when a score is recent`() {
        assertEquals(
            StressWidgetRefresh.Action.Retire,
            StressWidgetRefresh.action(
                placed = false, nowMs = now, lastScoredAtMs = now - 1_000L, intervalMs = interval,
            ),
        )
    }
}
