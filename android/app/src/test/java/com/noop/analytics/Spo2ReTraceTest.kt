package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Connection-mode SpO2 reverse-engineering dump line (PR #945, reimplemented). Pure JVM. The
 * vectors are byte-identical to the Swift Spo2ReTraceTests so a shared log correlates identically from
 * either platform. Log-only diagnostics: nothing here ever becomes a user-facing SpO2 number.
 */
class Spo2ReTraceTest {

    @Test fun recordLinePinnedExactly() {
        val line = Spo2ReTrace.recordLine(
            frame = byteArrayOf(0x00, 0x0f, 0xff.toByte(), 0x10),
            version = 24, unix = 1_700_000_000, red = 512, ir = 480, skinRaw = 330,
        )
        assertEquals("spo2re v=24 unix=1700000000 red=512 ir=480 skinRaw=330 len=4 raw=000fff10", line)
    }

    @Test fun absentChannelsRenderNull() {
        // A record with no SpO2 channels mapped (e.g. a v25 motion record) must still dump in full -
        // proving "nothing banked" needs the negative case on the record itself.
        val line = Spo2ReTrace.recordLine(
            frame = byteArrayOf(1, 2, 3), version = 25, unix = 42, red = null, ir = null, skinRaw = null,
        )
        assertEquals("spo2re v=25 unix=42 red=null ir=null skinRaw=null len=3 raw=010203", line)
    }

    @Test fun hexRendersUnsignedFullFrame() {
        // 0xFF must render "ff" (unsigned, never a sign-extended "ffffffff"), and the FULL frame ships -
        // the unmapped tail bytes are exactly where a banked SpO2 would sit.
        val line = Spo2ReTrace.recordLine(
            frame = byteArrayOf(0xff.toByte(), 0x00, 0xab.toByte()),
            version = null, unix = null, red = null, ir = null, skinRaw = null,
        )
        assertTrue(line, line.endsWith("raw=ff00ab"))
        assertTrue(line, line.contains("v=null"))
    }

    @Test fun sampleCapBounded() {
        assertEquals(12, Spo2ReTrace.MAX_SAMPLES)
    }

    /** The per-layout cap is what stops one dominant layout spending the whole session budget, and it
     *  only does that if it is strictly smaller than the session cap. */
    @Test fun perVersionCapIsBoundedAndSmallerThanTheSessionCap() {
        assertEquals(3, Spo2ReTrace.MAX_PER_VERSION)
        assertTrue(Spo2ReTrace.MAX_PER_VERSION < Spo2ReTrace.MAX_SAMPLES)
    }

    /** The session cap has to leave room for more than one layout, or stratifying changes nothing:
     *  a 5/MG emits v18 alongside v20/v21/v26 and every one of them needs samples. */
    @Test fun sessionCapCoversSeveralDistinctLayouts() {
        assertTrue(Spo2ReTrace.MAX_SAMPLES / Spo2ReTrace.MAX_PER_VERSION >= 4)
    }

    /**
     * The examine budget is what keeps the search bounded now that a per-version cap can hold dumps back
     * indefinitely. Without it the loop's only stop condition counts dumps, so a single-layout strap
     * re-decodes every frame of every chunk for the whole offload to rediscover a version at cap.
     */
    @Test
    fun `the examine budget bounds the search independently of the dump budget`() {
        assertTrue(Spo2ReTrace.MAX_EXAMINED > Spo2ReTrace.MAX_SAMPLES)
        // Enough frames to sweep several chunks, so a layout at a few percent of traffic is still found.
        assertTrue(Spo2ReTrace.MAX_EXAMINED >= 256)
    }
}
