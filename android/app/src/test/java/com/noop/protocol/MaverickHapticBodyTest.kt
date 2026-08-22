package com.noop.protocol

import com.noop.ble.WhoopBleClient
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [WhoopBleClient.maverickHapticBody] — the WHOOP 5/MG haptic body built from a 4.0-shaped
 * `[patternId, loops, 0, 0, 0]` payload.
 *
 * EXPERIMENT (#926): byte 11 (overallLoop) was hardcoded 0, so the caller's repeat count never
 * reached the wire and every BuzzPattern felt identical on a 5/MG. These cases pin the layout and
 * the clamp; whether the strap ACTUALLY repeats the buzz is a hardware question this cannot answer.
 */
class MaverickHapticBodyTest {

    private fun body(loops: Int) =
        WhoopBleClient.maverickHapticBody(byteArrayOf(2, loops.toByte(), 0, 0, 0))

    @Test
    fun bodyIsTwelveBytesWithTheNotifyPreset() {
        val b = body(1)
        assertEquals(12, b.size)
        assertEquals(0x01, b[0].toInt())            // REVISION_1
        assertEquals(47, b[1].toInt())              // effects[0]
        assertEquals(152, b[2].toInt() and 0xFF)    // effects[1]
        for (i in 3..8) assertEquals("effects[$i] padding", 0, b[i].toInt())
        assertEquals("loopControl lo", 0, b[9].toInt())
        assertEquals("loopControl hi", 0, b[10].toInt())
    }

    @Test
    fun overallLoopCarriesTheRepeatCount() {
        assertEquals(1, body(1)[11].toInt())
        assertEquals(2, body(2)[11].toInt())
        assertEquals(3, body(3)[11].toInt())
        assertEquals(5, body(5)[11].toInt())
    }

    @Test
    fun loopsAreClampedToTheRangeTheAlarmBodyIsKnownToUse() {
        // AlarmPayload ships overallLoop=7; nothing above that is evidenced, and 0 would reproduce
        // the very bug this experiment is testing.
        assertEquals(7, body(99)[11].toInt())
        assertEquals(1, body(0)[11].toInt())
    }

    @Test
    fun theLoopByteIsReadUnsigned() {
        // A payload byte is a raw wire value, so 0xFD must read as 253 (then clamp to 7), NOT as the
        // signed -3 it would be in Kotlin. Reading it signed would make any count above 127 collapse
        // to the minimum — the opposite of what the clamp is for.
        assertEquals(7, body(0xFD)[11].toInt())
        assertEquals(7, body(0xFF)[11].toInt())
    }

    @Test
    fun singleLoopReproducesTheOldShippedConstant() {
        // The literal this replaced was [0x01, 47, 152, 0*8, 0] — i.e. exactly the loops=1 case with
        // overallLoop still 0. Proves the change is additive: nothing but byte 11 moved.
        val old = byteArrayOf(0x01, 47, 152.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0)
        val new = body(1)
        assertArrayEquals(old.copyOfRange(0, 11), new.copyOfRange(0, 11))
        assertEquals("only overallLoop differs", 0, old[11].toInt())
        assertEquals("only overallLoop differs", 1, new[11].toInt())
    }

    @Test
    fun shortPayloadDoesNotCrash() {
        assertEquals(1, WhoopBleClient.maverickHapticBody(byteArrayOf())[11].toInt())
        assertEquals(1, WhoopBleClient.maverickHapticBody(byteArrayOf(2))[11].toInt())
    }
}
