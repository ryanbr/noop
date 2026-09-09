package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Swift `HistoricalLayoutSupportTests`. */
class HistoricalLayoutSupportTest {

    /**
     * Every layout this platform's 5/MG decoder dispatches on must be reported as MAPPED, whatever field
     * names its decode happens to produce. This is what #156 needed and did not get, so v25/v26 kept
     * warning. Driven off the dispatch set itself, so a layout added there without a signature field
     * cannot reintroduce the bug.
     */
    @Test
    fun everyMappedWhoop5LayoutIsReportedAsDecodable() {
        for (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) {
            assertFalse(
                "layout v$v is in MAPPED_WHOOP5_HISTORICAL_VERSIONS but reports as undecodable",
                historicalLayoutIsUnmapped(v, DeviceFamily.WHOOP5, false, false, false),
            )
        }
    }

    /**
     * v20 IS reported here, and that is correct rather than a gap in this function: Android's historical
     * dispatch has no v20/v21 branch, so the record genuinely does not decode on this side. Swift answers
     * the opposite for the same version because its decoder does dispatch it. Pinned so the divergence is
     * deliberate and visible, and so porting the decoder flips this test rather than surprising someone.
     */
    @Test
    fun theOpticalLayoutIsStillUndecodableOnThisPlatform() {
        assertFalse("Android has no v20 historical branch", 20 in MAPPED_WHOOP5_HISTORICAL_VERSIONS)
        assertTrue(historicalLayoutIsUnmapped(20, DeviceFamily.WHOOP5, false, false, false))
    }

    /** A decoded field does NOT rescue an unmapped 5/MG version: the dispatch set is the authority. */
    @Test
    fun anUnknownWhoop5LayoutIsStillReportedEvenIfSomethingDecoded() {
        val unknown = (1..255).first { it !in MAPPED_WHOOP5_HISTORICAL_VERSIONS }
        assertTrue(historicalLayoutIsUnmapped(unknown, DeviceFamily.WHOOP5, false, false, false))
        assertTrue(historicalLayoutIsUnmapped(unknown, DeviceFamily.WHOOP5, true, true, true))
    }

    /** WHOOP 4.0 is judged by what it decoded: any one of the three names means the layout mapped. */
    @Test
    fun whoop4IsJudgedByWhatItDecoded() {
        assertTrue(historicalLayoutIsUnmapped(19, DeviceFamily.WHOOP4, false, false, false))
        for ((hr, grav, ppg) in listOf(
            Triple(true, false, false), Triple(false, true, false), Triple(false, false, true),
        )) {
            assertFalse(historicalLayoutIsUnmapped(25, DeviceFamily.WHOOP4, hr, grav, ppg))
        }
    }

    /**
     * The safety claim: the consumed marker can only ever CLOSE a gap. Whichever of the two is later wins,
     * so a strap with genuine backlog keeps its gap and a strap whose tail merely failed to decode loses it.
     */
    @Test
    fun theFrontierTakesTheLaterOfTheTwoAndNeverGoesBackwards() {
        assertEquals(2_000L, offloadFrontier(1_000L, 2_000L))
        assertEquals(2_000L, offloadFrontier(2_000L, 1_000L))
        assertEquals(2_000L, offloadFrontier(2_000L, 2_000L))
    }

    /**
     * Either half absent is the other half's answer, and both absent stays "unknown" rather than becoming a
     * fabricated zero. A zero frontier against a real strap newest would read as an enormous backlog.
     */
    @Test
    fun anAbsentHalfDoesNotBecomeZero() {
        assertEquals(1_700_000_000L, offloadFrontier(null, 1_700_000_000L))
        assertEquals(1_700_000_000L, offloadFrontier(1_700_000_000L, null))
        assertNull(offloadFrontier(null, null))
    }
}
