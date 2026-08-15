package com.noop.oura

import com.noop.oura.OuraSessionReconciler.Decision
import com.noop.oura.OuraSessionReconciler.SessionWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1284 residual 3 — the reconciler on @pipiche38's four measured nights. Byte-identical twin of the
 * Swift `OuraSessionReconcilerTests`. Every fixture reproduces the STRUCTURE she measured (overlap /
 * gap / completeness ordering / noon-vs-midnight day), not exact wall-clock, so the assertions are the
 * design claims: option (2) collapses all four nights to one row, the nap stays separate.
 */
class OuraSessionReconcilerTest {

    private val tz = 7200 // CEST, the corpus timezone (Europe/Paris, summer)
    // A UTC instant that is a LOCAL midnight (utc + tz is a multiple of 86400), so localTs() reads cleanly.
    private val localMidnightUtc = 86_400L * 20_670 - tz

    /** Unix seconds for a local wall-clock time on day `d` (days after the reference local midnight). */
    private fun localTs(d: Int, h: Int, m: Int, s: Int): Long =
        localMidnightUtc + d * 86_400L + h * 3600 + m * 60 + s

    /** codeCount ~ 30-s epochs, the completeness signal (a fuller drain of the same night has more). */
    private fun win(start: Long, end: Long): SessionWindow =
        SessionWindow(startTs = start, endTs = end, codeCount = ((end - start) / 30).toInt())

    /** Replay a persist ORDER through the reconciler against the growing DB; return the final rows. */
    private fun simulate(order: List<SessionWindow>): List<SessionWindow> {
        val db = mutableListOf<SessionWindow>()
        for (s in order) {
            when (val d = OuraSessionReconciler.reconcile(s, db.toList())) {
                is Decision.Insert -> db.add(s)
                is Decision.Skip -> {}
                is Decision.Replace -> {
                    db.removeAll { it.startTs in d.supersededStartTs }
                    db.add(s)
                }
            }
        }
        return db
    }

    // ── Night 08-12/13 — mode 1 (re-anchor): same hypnogram at 3 onsets, all overlapping ──────────────
    @Test
    fun mode1_reAnchor_collapsesToOneRow() {
        val row1 = win(localTs(0, 4, 40, 55), localTs(0, 6, 50, 55)) // 130 min, fullest
        val row2 = win(localTs(0, 4, 50, 9), localTs(0, 6, 48, 9))  // 118 min
        val row3 = win(localTs(0, 6, 34, 9), localTs(0, 6, 48, 9))  // 14 min
        assertEquals(day(row1.startTs), day(row2.startTs))
        assertEquals(day(row1.startTs), day(row3.startTs))
        val db = simulate(listOf(row3, row2, row1)) // arrive shortest-first, worst case
        assertEquals("mode-1 must collapse to one row", 1, db.size)
        assertEquals("the fullest decode survives", row1.startTs, db[0].startTs)
    }

    // ── Night 08-13/14 — mode 2 (partial drain): B nested in A, A genuinely fuller ────────────────────
    @Test
    fun mode2_partialDrain_completenessGuardKeepsFuller() {
        val rowA = win(1786657310L, 1786657310L + 494 * 60) // 494 min / 988 codes
        val rowB = win(1786657552L, 1786657552L + 234 * 60) // 234 min / 468 codes, inside A
        assertTrue("B is inside A", rowB.startTs >= rowA.startTs - 3600 && rowB.endTs <= rowA.endTs)
        assertEquals(rowA.startTs, simulate(listOf(rowB, rowA)).single().startTs)
        assertEquals(rowA.startTs, simulate(listOf(rowA, rowB)).single().startTs)
        assertEquals(Decision.Skip, OuraSessionReconciler.reconcile(rowB, listOf(rowA)))
        assertEquals(Decision.Replace(listOf(rowB.startTs)), OuraSessionReconciler.reconcile(rowA, listOf(rowB)))
    }

    // ── Night 08-11/12 — the case against a 30-min grid (starts 6¼ min apart straddle 22:30) ─────────
    @Test
    fun gridStraddle_stillCollapsesUnderProximity() {
        val real = win(localTs(0, 22, 26, 14), localTs(1, 7, 6, 14))   // the real session, fuller
        val nested = win(localTs(0, 22, 32, 30), localTs(0, 23, 50, 30)) // 78 min, nested
        assertTrue(nested.startTs - real.startTs in 1L..3600L)
        assertEquals(1, simulate(listOf(nested, real)).size)
    }

    // ── Night 08-10/11 — fragment ENDS before midnight: noon-anchor groups it, wake-day would not ────
    @Test
    fun fragmentEndingBeforeMidnight_sharesNoonSleepDayNotWakeDay() {
        val fragment = win(localTs(0, 22, 9, 40), localTs(0, 22, 49, 40)) // ends 22:49, before midnight
        val main = win(localTs(0, 22, 50, 49), localTs(1, 7, 30, 49))
        assertEquals(day(fragment.startTs), day(main.startTs))
        // The WAKE-day (the day each session ENDS) differs: the fragment ends before midnight (Aug 10),
        // the main night ends next morning (Aug 11) — the wake-day bug the noon anchor fixes.
        assertNotEquals(midnightDay(fragment.endTs), midnightDay(main.endTs))
        assertEquals(1, simulate(listOf(fragment, main)).size)
        assertEquals(main.startTs, simulate(listOf(fragment, main)).single().startTs)
    }

    // ── Night 08-09 — a real afternoon nap shares the sleep-day with the night but must stay separate ─
    @Test
    fun nap_sharesSleepDay_butStaysDistinct() {
        val nap = win(localTs(0, 14, 24, 4), localTs(0, 14, 46, 4))    // 22 min afternoon nap
        val night = win(localTs(0, 22, 23, 7), localTs(1, 6, 30, 0))
        assertEquals("nap and night share the noon-anchored sleep-day", day(nap.startTs), day(night.startTs))
        assertEquals(2, simulate(listOf(nap, night)).size)
        assertEquals(Decision.Insert, OuraSessionReconciler.reconcile(night, listOf(nap)))
    }

    @Test
    fun sameConnectionRepeatOfIdenticalWindowIsIdempotent() {
        val s = win(localTs(0, 23, 0, 0), localTs(1, 7, 0, 0))
        assertEquals("re-persisting the exact same window keeps one row", 1, simulate(listOf(s, s, s)).size)
    }

    private fun day(ts: Long) = OuraSessionReconciler.noonAnchoredSleepDay(ts, tz)
    private fun midnightDay(ts: Long) = Math.floorDiv(ts + tz, 86_400L)
}
