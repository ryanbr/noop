package com.noop.protocol

import com.noop.ble.WhoopBleClient
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [WhoopBleClient.maverickHapticBody] — the WHOOP 5/MG haptic body built from a 4.0-shaped
 * `[patternId, loops, 0, 0, 0]` payload.
 *
 * #926: byte 11 (overallLoop) was hardcoded 0, so the caller's repeat count never reached the wire
 * and every BuzzPattern felt identical on a 5/MG.
 *
 * HARDWARE-CONFIRMED on a real 5/MG: overallLoop counts the repeats AFTER the first pulse — writing
 * 3 produced four buzzes — so it is written as `loops - 1`. That model also explains the old
 * behaviour: the shipped 0 meant "no repeats", i.e. the single buzz every pattern used to give.
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
    fun overallLoopIsTheRepeatCountAfterTheFirstPulse() {
        // The wire value is one LESS than the number of buzzes the wrist feels.
        assertEquals("1 buzz", 0, body(1)[11].toInt())
        assertEquals("2 buzzes", 1, body(2)[11].toInt())
        assertEquals("3 buzzes", 2, body(3)[11].toInt())
        assertEquals("5 buzzes (BuzzPattern.Long)", 4, body(5)[11].toInt())
    }

    @Test
    fun theFourBuzzPatternsAllDiffer() {
        // The whole point of #926: Single/Double/Triple/Long must not collapse to one value.
        val wire = listOf(1, 2, 3, 5).map { body(it)[11].toInt() }
        assertEquals(listOf(0, 1, 2, 4), wire)
        assertEquals("no two patterns share a wire value", 4, wire.toSet().size)
    }

    @Test
    fun loopsAreClampedToTheRangeTheAlarmBodyEvidences() {
        // AlarmPayload ships overallLoop=7, the largest value evidenced, so loops caps at 8.
        assertEquals(7, body(99)[11].toInt())
        assertEquals(7, body(8)[11].toInt())
        assertEquals(0, body(0)[11].toInt())
    }

    @Test
    fun theLoopByteIsReadUnsigned() {
        // A payload byte is a raw wire value, so 0xFD must read as 253 (then clamp), NOT as the signed
        // -3 it would be in Kotlin. Reading it signed would make any count above 127 collapse to the
        // minimum — the opposite of what the clamp is for.
        assertEquals(7, body(0xFD)[11].toInt())
        assertEquals(7, body(0xFF)[11].toInt())
    }

    @Test
    fun singleBuzzReproducesTheOldShippedConstantExactly() {
        // The literal this replaced was [0x01, 47, 152, 0*8, 0]. With overallLoop = loops-1, a
        // single-buzz request rebuilds it byte-for-byte — so the previously shipped, hardware-verified
        // frame is preserved and the change only takes effect when more than one pulse was asked for.
        val old = byteArrayOf(0x01, 47, 152.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0)
        assertArrayEquals(old, body(1))
    }

    @Test
    fun shortPayloadFallsBackToASinglePulse() {
        assertEquals(0, WhoopBleClient.maverickHapticBody(byteArrayOf())[11].toInt())
        assertEquals(0, WhoopBleClient.maverickHapticBody(byteArrayOf(2))[11].toInt())
    }
}
