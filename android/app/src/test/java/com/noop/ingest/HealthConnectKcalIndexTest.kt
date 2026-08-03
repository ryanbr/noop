package com.noop.ingest

import com.noop.ingest.HealthConnectImporter.KcalIndex
import com.noop.ingest.HealthConnectImporter.KcalRecord
import com.noop.ingest.HealthConnectImporter.sumKcalInWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #835 follow-up — [KcalIndex] range-scans instead of walking every record per workout.
 *
 * The post-pass called `sumKcalInWindow` twice per workout and each call scanned the whole import
 * window. At `WINDOW_YEARS = 10` with ~15-minute provider buckets that is hundreds of thousands of
 * rows, per workout, on a first import.
 *
 * The optimisation is only worth having if it is INDISTINGUISHABLE from the scan it replaces, so these
 * assert equality against the original function rather than against hand-computed figures. The scan is
 * the oracle; the index is the thing on trial.
 */
class HealthConnectKcalIndexTest {

    /** Deterministic, overlapping, multi-source records — no randomness, so a failure reproduces. */
    private fun corpus(): List<KcalRecord> {
        val out = ArrayList<KcalRecord>()
        var t = 0L
        var i = 0
        while (t < 40_000L) {
            val src = if (i % 3 == 0) "phone" else "watch"          // two sources, so the MAX-source rule bites
            val len = when (i % 4) { 0 -> 900L; 1 -> 300L; 2 -> 1_200L; else -> 60L }
            out.add(KcalRecord(startS = t, endS = t + len, kcal = 10.0 + (i % 7), source = src))
            t += 450L                                               // deliberate overlap between neighbours
            i += 1
        }
        return out
    }

    /**
     * The equivalence proof. Every window, against the full-scan oracle. Windows are swept across the
     * corpus at several widths so partial overlaps, full containment and empty regions are all covered.
     */
    @Test fun indexMatchesTheFullScanOnEveryWindow() {
        val recs = corpus()
        val index = KcalIndex(recs)
        var checked = 0
        for (width in listOf(1L, 60L, 900L, 3_600L, 10_000L)) {
            var start = -5_000L
            while (start < 45_000L) {
                val expected = sumKcalInWindow(recs, start, start + width)
                val actual = index.sumInWindow(start, start + width)
                if (expected == null) {
                    assertNull("window [$start, ${start + width}) width=$width", actual)
                } else {
                    // delta 0.0 — bit-exact, not merely close. See bitExactnessSurvivesUnsortedInput.
                    assertEquals("window [$start, ${start + width}) width=$width", expected, actual!!, 0.0)
                }
                checked += 1
                start += 137L                                        // prime-ish stride, avoids aligning with record starts
            }
        }
        // Guard against a future edit silently emptying the sweep and leaving this green on zero windows.
        assert(checked > 1_000) { "expected a broad sweep, checked only $checked" }
    }

    /**
     * The bound the index rests on: a record far LONGER than its neighbours must still be found from a
     * window that starts well after it began. This is what `maxLenS` exists for — with a naive
     * "start >= windowStart" search it would be missed entirely.
     */
    @Test fun aLongRecordIsFoundFromAWindowStartingInsideIt() {
        val recs = listOf(
            KcalRecord(startS = 0, endS = 86_400, kcal = 864.0, source = "phone"),   // a whole-day record
            KcalRecord(startS = 80_000, endS = 80_600, kcal = 10.0, source = "watch"),
        )
        val index = KcalIndex(recs)
        val expected = sumKcalInWindow(recs, 80_000, 80_600)
        assertEquals(expected!!, index.sumInWindow(80_000, 80_600)!!, 0.0)
    }

    /** Degenerate inputs must behave exactly as the scan does, including the null cases. */
    @Test fun emptyAndDegenerateWindowsMatchTheScan() {
        val empty = KcalIndex(emptyList())
        assertNull(empty.sumInWindow(0, 100))
        assertNull(sumKcalInWindow(emptyList(), 0, 100))

        val recs = corpus()
        val index = KcalIndex(recs)
        assertNull("zero-width window", index.sumInWindow(500, 500))
        assertNull("inverted window", index.sumInWindow(900, 500))
        assertNull("entirely before the corpus", index.sumInWindow(-9_000, -8_000))
        assertNull("entirely after the corpus", index.sumInWindow(500_000, 510_000))
    }

    /**
     * Bit-exactness, on input whose insertion order is deliberately NOT its sorted order.
     *
     * `sumKcalInWindow` accumulates each source with `+`, and floating-point addition is not
     * associative — so a slice summed in start-sorted order rather than as-read drifts by an ULP or
     * two. Before [KcalIndex] restored the original order within its slice, 104 of 595 windows on this
     * corpus differed by up to 1.8e-15. `round1` downstream would have swallowed every one of them,
     * which is exactly why it needs a test: nothing else in the app would ever have noticed the index
     * quietly ceasing to be equivalent.
     */
    @Test fun bitExactnessSurvivesUnsortedInput() {
        val recs = ArrayList<KcalRecord>()
        var t = 30_000L
        for (i in 0 until 4_000) {
            recs.add(
                KcalRecord(
                    startS = t,
                    endS = t + 700 + (i % 5) * 130L,
                    kcal = 0.1 + (i % 9) * 0.037,          // not representable in binary
                    source = if (i % 2 == 0) "a" else "b", // two sources, so the MAX-source rule bites
                ),
            )
            t -= 7L * (i % 11 + 1)                          // descending: insertion order != sorted order
            if (i % 3 == 0) t += 900
        }
        val index = KcalIndex(recs)
        var compared = 0
        var s = 0L
        while (s < 40_000L) {
            for (w in listOf(600L, 3_600L, 20_000L)) {
                val expected = sumKcalInWindow(recs, s, s + w)
                val actual = index.sumInWindow(s, s + w)
                if (expected == null) {
                    assertNull("window [$s, ${s + w})", actual)
                } else {
                    assertEquals("window [$s, ${s + w})", expected, actual!!, 0.0)  // exact
                    compared += 1
                }
            }
            s += 91L
        }
        assert(compared > 400) { "expected a broad sweep, compared only $compared" }
    }

    /**
     * The guard against the index being SLOWER than the scan it replaces.
     *
     * The lower bound reaches back by the longest record's span, so one record covering the whole
     * corpus — a weekly or lifetime aggregate row, which providers do write — makes every slice the
     * entire list. Sorting that per query measured **931 ms against the scan's 113 ms** before the
     * guard existed: an eightfold regression from an optimisation.
     *
     * `KcalIndex` now declines to build itself in that case and routes every query to the scan, which
     * benchmarks at parity. This test pins the CORRECTNESS of that route — the results must still be
     * bit-identical, because it is a different code path through the same class.
     */
    @Test fun aCorpusSpanningRecordFallsBackWithoutChangingResults() {
        val recs = ArrayList<KcalRecord>()
        var t = 0L
        for (i in 0 until 2_000) { recs.add(KcalRecord(t, t + 900, 12.0, "watch")); t += 900 }
        recs.add(KcalRecord(0, t, 100.0, "phone"))   // spans the entire corpus
        val index = KcalIndex(recs)
        var compared = 0
        var s = 0L
        while (s < t) {
            val expected = sumKcalInWindow(recs, s, s + 3_600)
            val actual = index.sumInWindow(s, s + 3_600)
            if (expected == null) assertNull(actual) else {
                assertEquals("window [$s, ${s + 3_600})", expected, actual!!, 0.0)   // exact
                compared += 1
            }
            s += 45_000L
        }
        assert(compared > 20) { "expected a real sweep, compared only $compared" }
    }

    /** A record that ends exactly where the window begins does not overlap it — on both paths. */
    @Test fun touchingBoundariesDoNotOverlap() {
        val recs = listOf(KcalRecord(startS = 0, endS = 100, kcal = 50.0, source = "phone"))
        val index = KcalIndex(recs)
        assertNull(sumKcalInWindow(recs, 100, 200))
        assertNull(index.sumInWindow(100, 200))
    }
}
