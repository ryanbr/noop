package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1001 — the single Effort figure every read-out on Today resolves through. Twin of the Swift
 * `EffectiveEffortTests`; the same cases in the same order, because the two platforms must resolve
 * Effort identically.
 *
 * The bug: Effort was resolved independently in three places. Only the hero ring knew about the live
 * in-progress recompute; the Key Metrics tile and the HR chart's edge badge read the stored daily row,
 * which is rewritten only when the heavy daily pass runs. On a morning with a real HR climb the ring
 * showed 2.3 while the other two still showed 0.5.
 *
 * These pin the resolution rule itself, and in particular the MAX — which is not a tie-break but the
 * never-drop floor from #489/#506, where a sparse-HR live under-read replaced a real 38.3 with 0.
 */
class EffectiveEffortTest {

    /** The reported case: a live value ahead of a stale row wins, so every read-out moves together. */
    @Test fun liveAheadOfAStaleRowWins() {
        assertEquals(2.3, StrainScorer.effectiveEffort(live = 2.3, stored = 0.5)!!, 1e-9)
    }

    /** The #489/#506 floor: a live UNDER-read must never pull a read-out below what today already earned. */
    @Test fun aStoredValueFloorsALiveUnderRead() {
        assertEquals(38.3, StrainScorer.effectiveEffort(live = 0.0, stored = 38.3)!!, 1e-9)
    }

    /** Past days carry no live value and use the row unchanged. */
    @Test fun noLiveValueUsesTheStoredRow() {
        assertEquals(12.5, StrainScorer.effectiveEffort(live = null, stored = 12.5)!!, 1e-9)
    }

    /** Before the day has enough HR to score there is no row yet, so the live value stands alone. */
    @Test fun noStoredRowUsesTheLiveValue() {
        assertEquals(4.0, StrainScorer.effectiveEffort(live = 4.0, stored = null)!!, 1e-9)
    }

    /** Neither source is "No Data" — the read-outs must not invent a zero. */
    @Test fun neitherSourceIsNull() {
        assertNull(StrainScorer.effectiveEffort(live = null, stored = null))
    }

    /** A genuine zero is a value, not an absence: a still day scores 0 and must render as 0, not "—". */
    @Test fun aGenuineZeroIsKept() {
        assertEquals(0.0, StrainScorer.effectiveEffort(live = 0.0, stored = 0.0)!!, 1e-9)
        assertEquals(0.0, StrainScorer.effectiveEffort(live = null, stored = 0.0)!!, 1e-9)
    }

    /** Equal sources are stable — resolving twice cannot make a read-out flicker. */
    @Test fun equalSourcesResolveToThatValue() {
        assertEquals(7.25, StrainScorer.effectiveEffort(live = 7.25, stored = 7.25)!!, 1e-9)
    }
}
