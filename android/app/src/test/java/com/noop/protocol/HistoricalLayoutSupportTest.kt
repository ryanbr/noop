package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
     * v20 now decodes here as it does on Swift, so this says what Swift's twin says: the layout is
     * understood, and it still cannot stage a night, because the optical channels map to no
     * physiological value on either platform. The previous version of this test asserted the opposite
     * and was written to flip exactly here when the decoder landed.
     */
    @Test
    fun theOpticalLayoutDecodesButStillCannotStageANight() {
        assertTrue("v20 dispatches on this platform now", 20 in MAPPED_WHOOP5_HISTORICAL_VERSIONS)
        assertEquals(
            HistoricalLayoutSupport.DECODES_WITHOUT_NAMED_SIGNAL,
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
