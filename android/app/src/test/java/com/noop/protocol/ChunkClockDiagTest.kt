package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1008: the per-chunk clock/packing diag. Twin of the Swift `ChunkClockDiagTests` — the expected
 * strings are asserted VERBATIM on both platforms so the two logs stay byte-identical and one strap-log
 * parser reads either.
 */
class ChunkClockDiagTest {

    @Test
    fun `no rr yields no line`() {
        assertNull(ChunkClockDiag.line(1, 1_000, 1_000, emptyList<Long>()))
    }

    /** One interval per second at a steady rate: `pack` and `dens` both sit at 1.00 — the honest case. */
    @Test
    fun `honest stream packs and densifies at one`() {
        val ts = (1_700_000_000L until 1_700_000_010L).toList()
        assertEquals(
            "Backfill: hist clock chunk=1 offset=+0s staleGate=closed" +
                " rr=10 secs=10 pack=1.00 max=1 span=10s dens=1.00",
            ChunkClockDiag.line(1, 1_000, 1_000, ts),
        )
    }

    /**
     * PACKING — the shape actually observed on 4.0 (`ord` 0..7 on one second). Every interval of a record
     * lands on that record's single stamp, so `pack`/`max` blow up while `dens` stays at the true beat
     * rate. This is what must NOT be misread as re-delivery.
     */
    @Test
    fun `packed record shows high pack but honest density`() {
        // 3 records, 10s apart, 8 intervals each — 24 beats over a 21s span (~1.14 beats/s).
        val ts = (0 until 3).flatMap { record -> List(8) { 1_700_000_000L + record * 10 } }
        assertEquals(
            "Backfill: hist clock chunk=4 offset=+48s staleGate=closed" +
                " rr=24 secs=3 pack=8.00 max=8 span=21s dens=1.14",
            ChunkClockDiag.line(4, 1_000, 1_048, ts),
        )
    }

    /**
     * DUPLICATION — the same seconds delivered twice moves `pack` AND `dens` together (both double),
     * which is how a strap log tells the two apart at a glance.
     */
    @Test
    fun `duplicated delivery moves pack and density together`() {
        val once = (1_700_000_000L until 1_700_000_010L).toList()
        assertEquals(
            "Backfill: hist clock chunk=2 offset=+0s staleGate=closed" +
                " rr=20 secs=10 pack=2.00 max=2 span=10s dens=2.00",
            ChunkClockDiag.line(2, 1_000, 1_000, once + once),
        )
    }

    /**
     * `staleGate` must mirror [extractHistoricalStreams]: an everyday drift of minutes is DISCARDED by the
     * decoder, so it must not read as a correction the stored stamps never received.
     */
    @Test
    fun `stale gate closed below threshold and open above it`() {
        val ts = listOf(1_700_000_000L)
        val below = ChunkClockDiag.line(1, 0, HIST_STALE_CLOCK_THRESHOLD_SEC, ts)!!
        assertTrue("at exactly the threshold the decoder keeps rawTs", below.contains("staleGate=closed"))
        val above = ChunkClockDiag.line(1, 0, HIST_STALE_CLOCK_THRESHOLD_SEC + 1, ts)!!
        assertTrue(above.contains("staleGate=open"))
    }

    /**
     * A strap RTC AHEAD of the phone must render as a negative offset, not an unsigned number — the
     * trajectory across chunks is only readable if the sign survives.
     */
    @Test
    fun `negative offset keeps its sign`() {
        val line = ChunkClockDiag.line(7, 1_200, 1_000, listOf(1_700_000_000L))!!
        assertTrue(line, line.contains("offset=-200s"))
    }

    /**
     * PARITY REGRESSION. `pack` of 9/8 is an exact binary tie (1.125). Java's [String.format] rounds
     * half-UP and would render `1.13`, while Swift's `printf("%.2f")` rounds half-to-EVEN and renders
     * `1.12` — the two strap logs would silently disagree. Both platforms now round half-UP by integer
     * math, so this asserts `1.13` and its Swift twin asserts the identical string.
     */
    @Test
    fun `exact tie rounds half up not half even`() {
        // 9 intervals over 8 stamped seconds: one second carries 2, the rest 1.
        val ts = (1_700_000_000L until 1_700_000_008L).toList() + listOf(1_700_000_000L)
        val line = ChunkClockDiag.line(1, 0, 0, ts)!!
        assertTrue(line, line.contains("pack=1.13"))
    }

    /**
     * Timestamps arrive in emission order, which is not guaranteed sorted across a record boundary; the
     * span must come from the true min/max, not the first/last element.
     */
    @Test
    fun `span uses min and max not first and last`() {
        val line = ChunkClockDiag.line(1, 0, 0, listOf(1_700_000_005L, 1_700_000_000L, 1_700_000_002L))!!
        assertTrue(line, line.contains("span=6s"))
    }
}
