package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Twin of the Swift `HistoricalLayoutSupportTests`. */
class HistoricalLayoutSupportTest {

    /**
     * No layout this platform's 5/MG decoder dispatches on may be called UNMAPPED, whatever field names its
     * decode happens to produce. This is what #156 needed and did not get, so v25/v26 kept warning. Driven
     * off the dispatch set itself, so a layout added there without a signature field cannot reintroduce it.
     */
    @Test
    fun noMappedWhoop5LayoutIsEverCalledUnmapped() {
        for (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) {
            assertNotEquals(
                "layout v$v is in MAPPED_WHOOP5_HISTORICAL_VERSIONS but reports as unmapped",
                HistoricalLayoutSupport.UNMAPPED,
                historicalLayoutSupport(v, DeviceFamily.WHOOP5, false, false, false),
            )
        }
    }

    /**
     * v20 IS unmapped here, and that is correct rather than a gap in this function: Android's historical
     * dispatch has no v20/v21 branch, so the record genuinely does not decode on this side. Swift answers
     * DECODES_WITHOUT_NAMED_SIGNAL for the same version because its decoder does dispatch it. Pinned so the
     * divergence is deliberate and visible, and so porting the decoder flips this test rather than
     * surprising someone.
     */
    @Test
    fun theOpticalLayoutIsStillUnmappedOnThisPlatform() {
        assertFalse("Android has no v20 historical branch", 20 in MAPPED_WHOOP5_HISTORICAL_VERSIONS)
        assertEquals(
            HistoricalLayoutSupport.UNMAPPED,
            historicalLayoutSupport(20, DeviceFamily.WHOOP5, false, false, false),
        )
    }

    /** A mapped layout that DOES carry a named signal is simply fine, and says nothing at all. */
    @Test
    fun aMappedLayoutCarryingASignalIsSupported() {
        for ((hr, grav, ppg) in listOf(
            Triple(true, false, false), Triple(false, true, false), Triple(false, false, true),
        )) {
            assertEquals(
                HistoricalLayoutSupport.SUPPORTED,
                historicalLayoutSupport(18, DeviceFamily.WHOOP5, hr, grav, ppg),
            )
        }
    }

    /** A decoded field does NOT rescue an unmapped 5/MG version: the dispatch set is the authority. */
    @Test
    fun anUnknownWhoop5LayoutIsUnmappedWhateverItDecoded() {
        val unknown = (1..255).first { it !in MAPPED_WHOOP5_HISTORICAL_VERSIONS }
        assertEquals(
            HistoricalLayoutSupport.UNMAPPED,
            historicalLayoutSupport(unknown, DeviceFamily.WHOOP5, false, false, false),
        )
        assertEquals(
            HistoricalLayoutSupport.UNMAPPED,
            historicalLayoutSupport(unknown, DeviceFamily.WHOOP5, true, true, true),
        )
    }

    /** WHOOP 4.0 is judged by what it decoded, exactly as before. */
    @Test
    fun whoop4IsStillJudgedByWhatItDecoded() {
        assertEquals(
            HistoricalLayoutSupport.UNMAPPED,
            historicalLayoutSupport(19, DeviceFamily.WHOOP4, false, false, false),
        )
        for ((hr, grav, ppg) in listOf(
            Triple(true, false, false), Triple(false, true, false), Triple(false, false, true),
        )) {
            assertEquals(
                HistoricalLayoutSupport.SUPPORTED,
                historicalLayoutSupport(25, DeviceFamily.WHOOP4, hr, grav, ppg),
            )
        }
    }
}
