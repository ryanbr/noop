package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1635: the per-link banked-rows line, the database-side companion to `linkEpitaph`.
 *
 * The case it exists for: an unbonded WHOOP 5/MG streams heart rate and R-R over the standard profile
 * while every bond-gated stream banks nothing. The epitaph reports that link as hundreds of healthy
 * inbound frames, which is true and misleading. Establishing the split took two exports hours apart and
 * a manual diff of stored row counts; these pin the one line that states it outright.
 */
class LinkBankedSummaryTest {

    @Test
    fun `names the streams that banked nothing when others did`() {
        val line = ConnectionReadout.linkBankedSummary(
            hr = 456, rr = 187, gravity = 0, resp = 0, skinTemp = 0, spo2 = 0, steps = 0, battery = 2,
        )
        assertTrue(line.contains("hr=456"))
        assertTrue(line.contains("gravity=0"))
        // The whole point: a reader must not have to spot which of eight numbers are zero.
        assertTrue(line.contains("nothing banked for: gravity, resp, skinTemp, spo2, steps"))
    }

    @Test
    fun `a fully healthy link gets no call-out`() {
        val line = ConnectionReadout.linkBankedSummary(
            hr = 400, rr = 380, gravity = 900, resp = 900, skinTemp = 900, spo2 = 900, steps = 12, battery = 3,
        )
        assertTrue(line.startsWith("banked this link:"))
        assertTrue("a link where every stream banked must not carry a zero call-out",
            !line.contains("nothing banked for"))
    }

    @Test
    fun `a link that stored nothing at all says so once, not eight times`() {
        val line = ConnectionReadout.linkBankedSummary(0, 0, 0, 0, 0, 0, 0, 0)
        assertTrue(line.contains("NOTHING was stored on this link"))
        // Not also the per-stream list: "nothing banked for: <all eight>" is noise when the total is zero.
        assertTrue(!line.contains("nothing banked for"))
    }

    @Test
    fun `negative counts cannot leak into a diagnostic`() {
        // Pure and total on purpose: this runs on the teardown path, where throwing would cost the very
        // report it exists to produce.
        val line = ConnectionReadout.linkBankedSummary(-5, 1, 0, 0, 0, 0, 0, 0)
        assertTrue(line.contains("hr=0"))
        assertEquals(false, line.contains("-5"))
    }

    @Test
    fun `the exact sentence for the field case, pinned against the Swift twin`() {
        assertEquals(
            "banked this link: hr=456 rr=187 gravity=0 resp=0 skinTemp=0 spo2=0 steps=0 battery=2" +
                " - nothing banked for: gravity, resp, skinTemp, spo2, steps",
            ConnectionReadout.linkBankedSummary(
                hr = 456, rr = 187, gravity = 0, resp = 0, skinTemp = 0, spo2 = 0, steps = 0, battery = 2,
            ),
        )
    }
}
