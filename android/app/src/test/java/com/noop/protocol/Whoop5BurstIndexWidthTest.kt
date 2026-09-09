package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #2019 follow-up: the per-burst counter is a u16, not a u8. Twin of the Swift
 * `Whoop5BurstIndexWidthTests` against the same synthetic frames.
 */
class Whoop5BurstIndexWidthTest {

    /**
     * A counter past 255 is the whole reason for the width. Read as a u8 this frame reports 0, which is
     * the sentinel meaning "absent", so a wrapped counter would not merely be wrong, it would vanish.
     */
    @Test
    fun aCounterPastAByteSurvives() {
        assertEquals(256, burstIndexOf(v26Frame(0x00, 0x01)))
    }

    /**
     * And the two readings agree exactly below 256, which is why every fixture we hold is unmoved: our
     * captures carry byte 22 = 0, so they cannot tell a u16 from a u8 beside a constant zero.
     */
    @Test
    fun theTwoReadingsAgreeBelow256() {
        for (low in listOf(1, 2, 65, 255)) {
            assertEquals("index $low must be unchanged", low, burstIndexOf(v26Frame(low, 0)))
        }
    }

    /** Zero stays the absent sentinel across both bytes, so a widened read cannot invent a burst. */
    @Test
    fun zeroIsStillAbsent() {
        assertNull(burstIndexOf(v26Frame(0, 0)))
    }

    /**
     * The case where the two readings DISAGREE, pinned so the choice is deliberate rather than
     * incidental. A low byte of 0 with a high byte set reads as absent under a u8 and as 1280 under a
     * u16. If the high byte really is the counter's, 1280 is right and the u8 lost the burst entirely.
     * If it is a separate field, this is where a fabricated index would come from, which is why the
     * falsifiable prediction is a persisted index jumping by a multiple of 256.
     */
    @Test
    fun theDivergentCaseIsPinned() {
        assertEquals(1280, burstIndexOf(v26Frame(0, 5)))
    }

    /**
     * v26 does NOT go through [decodeHistorical] on this platform: that function returns null for it, and
     * the layout is decoded by `decodeWhoop5HistoricalV26` from [extractHistoricalStreams] instead. The
     * burst index is only observable on the row that comes out, which is also where it is persisted from,
     * so this is the honest entry point to assert against. Swift routes v26 through its interpreter and
     * its twin reads `parsed["burst_index"]` directly.
     */
    private fun burstIndexOf(frame: ByteArray): Int? =
        extractHistoricalStreams(
            listOf(frame),
            deviceClockRef = 1_780_917_232,
            wallClockRef = 1_780_917_232,
            family = DeviceFamily.WHOOP5,
        ).ppgWaveform.single().burstIndex

    /** A v26 frame with the counter bytes planted, sealed exactly as a strap seals one. */
    private fun v26Frame(burstLow: Int, burstHigh: Int): ByteArray {
        val f = bytes(V26_HEX)
        f[21] = burstLow.toByte()
        f[22] = burstHigh.toByte()
        val payloadEnd = f.size - 4
        val c = Crc.crc32(f, 8, payloadEnd)
        for (b in 0 until 4) f[payloadEnd + b] = ((c shr (8 * b)) and 0xFF).toByte()
        return f
    }

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte() }

    private companion object {
        const val V26_HEX =
            "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
                "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
                "5fb33c50080101006cb67c17"
    }
}
