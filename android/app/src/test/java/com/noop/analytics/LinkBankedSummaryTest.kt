package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1635: the per-link banked line, split by PATH.
 *
 * The case it exists for: an unbonded 5/MG streams heart rate and R-R over the standard profile while the
 * offload never runs, and the epitaph reports that link as hundreds of healthy inbound frames.
 *
 * The split is by path rather than by stream because the realtime decoder yields only hr/rr/events/battery
 * — gravity, respiratory, skin temperature, SpO2 and steps arrive solely through the offload. An earlier
 * live-only version named those five as "nothing banked live for" on EVERY link, bonded or not, which is a
 * constant rather than a finding. These pin the distinction.
 */
class LinkBankedSummaryTest {

    private fun line(
        liveHr: Int = 0, liveRr: Int = 0, chunks: Int = 0,
        oHr: Int = 0, oRr: Int = 0, oGrav: Int = 0, oResp: Int = 0,
        oSkin: Int = 0, oSpo2: Int = 0, oSteps: Int? = 0,
    ) = ConnectionReadout.linkBankedSummary(
        liveHr = liveHr, liveRr = liveRr, offloadChunks = chunks, offloadHr = oHr, offloadRr = oRr,
        offloadGravity = oGrav, offloadResp = oResp, offloadSkinTemp = oSkin,
        offloadSpo2 = oSpo2, offloadSteps = oSteps,
    )

    @Test
    fun `an unbonded strap reads live traffic with an offload that never ran`() {
        // The whole point: HR flowing while the offload banks nothing is the bond split, in one line.
        assertEquals(
            "banked this link: live hr=12 rr=7 | offload none",
            line(liveHr = 12, liveRr = 7, chunks = 0),
        )
    }

    @Test
    fun `a healthy sync reads completely differently`() {
        // The same shape on a bonded strap must NOT look like the unbonded one. This is the case the
        // live-only version could not express: it printed the same zeros either way.
        val healthy = line(liveHr = 3, liveRr = 2, chunks = 9, oHr = 1200, oRr = 2400, oGrav = 8000,
            oResp = 8000, oSkin = 8000, oSpo2 = 8000, oSteps = 40)
        assertEquals(
            "banked this link: live hr=3 rr=2 | offload hr=1200 rr=2400 gravity=8000 resp=8000" +
                " skinTemp=8000 spo2=8000 steps=40",
            healthy,
        )
        assertTrue("a full sync carries no zero call-out", !healthy.contains("nothing banked"))
    }

    @Test
    fun `a partial offload names only the streams that stayed empty`() {
        val l = line(liveHr = 1, chunks = 4, oHr = 500, oRr = 900, oGrav = 0, oResp = 0, oSkin = 700, oSpo2 = 700)
        assertTrue(l.contains("nothing banked from the offload for: gravity, resp, steps"))
    }

    @Test
    fun `a stream this platform cannot measure is omitted, not reported as zero`() {
        // Apple's store returns no step count. Printing steps=0 there would name it forever.
        val l = line(liveHr = 5, chunks = 1, oHr = 10, oSteps = null)
        assertTrue("an unmeasured stream must not appear", !l.contains("steps"))
    }

    @Test
    fun `battery never appears, on either path`() {
        // It rides the standard 0x2A19 profile, so it banks with or without the bond and answers nothing
        // here. A field log showed 306 battery banks against battery=0 in an earlier version of this line.
        assertTrue(!line(liveHr = 9, chunks = 1, oHr = 9).contains("battery"))
    }

    @Test
    fun `negative counts cannot leak into a diagnostic`() {
        // Runs on the teardown path, where throwing would cost the report it exists to produce.
        val l = line(liveHr = -5, liveRr = 1, chunks = 2, oHr = -3, oGrav = 4)
        assertTrue(l.contains("live hr=0 rr=1"))
        assertTrue(l.contains("hr=0"))
        // NOT `contains("-")`: the sentence separator is a hyphen, so that assertion fails on a correct
        // line. Check the negative VALUES are gone, which is what clamping actually promises.
        assertEquals(false, l.contains("-5"))
        assertEquals(false, l.contains("-3"))
    }

    @Test
    fun `an offload that ran with nothing new is not the same finding as one that never ran`() {
        // Rows are ACCEPTED counts, so a reconnect re-offloading already-stored records banks zero while
        // the strap plainly handed its history over. classifyCompletedOffload already treats that as
        // bankedSensorRecords rather than a fault, and this line must not contradict it.
        assertEquals(
            "banked this link: live hr=1 rr=1 | offload ran 6 chunk(s), no new rows",
            line(liveHr = 1, liveRr = 1, chunks = 6),
        )
        // And the bond signal stays distinct.
        assertTrue(line(liveHr = 1, liveRr = 1, chunks = 0).contains("offload none"))
    }
}
