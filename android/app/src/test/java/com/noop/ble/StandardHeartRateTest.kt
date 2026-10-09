package com.noop.ble

import com.noop.protocol.StandardHrContact
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure 0x2A37 parser contract — mirrors the Swift StandardHeartRate parser behaviour. No
 * android.bluetooth: [StandardHeartRate.parse] is a pure function over the raw notification bytes.
 *
 * Byte layout under test (Bluetooth SIG Heart Rate Measurement):
 *   flags bit0 → u16 HR (else u8); bit3 → Energy-Expended field (2 bytes, skipped); bit4 → R-R list.
 */
class StandardHeartRateTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun contactOnlyBufferReachesFlushThreshold() {
        assertTrue(standardHrBufferReachedFlushThreshold(
            hrCount = 0,
            rrCount = 0,
            contactCount = 30,
        ))
    }

    @Test
    fun contactFlagsCoverAllCombinations() {
        val cases = listOf(
            0x00 to StandardHrContact.UNSUPPORTED,
            0x02 to StandardHrContact.UNSUPPORTED,
            0x04 to StandardHrContact.SUPPORTED_NOT_DETECTED,
            0x06 to StandardHrContact.SUPPORTED_DETECTED,
        )

        for ((flags, expected) in cases) {
            assertEquals("flags 0x${flags.toString(16)}", expected,
                StandardHeartRate.parse(bytes(flags, 72))!!.contact)
        }
    }

    @Test
    fun eightBitHrNoRr() {
        // flags=0x00 (8-bit HR, no R-R), HR=72.
        val r = StandardHeartRate.parse(bytes(0x00, 72))!!
        assertEquals(72, r.hr)
        assertTrue(r.rr.isEmpty())
        assertTrue(r.rrRawTicks.isEmpty())
    }

    @Test
    fun sixteenBitHr() {
        // flags=0x01 (16-bit HR), HR = 0x0140 = 320 (little-endian 0x40,0x01).
        val r = StandardHeartRate.parse(bytes(0x01, 0x40, 0x01))!!
        assertEquals(320, r.hr)
        assertTrue(r.rr.isEmpty())
        assertTrue(r.rrRawTicks.isEmpty())
    }

    @Test
    fun rrPresentConvertedToMs() {
        // flags=0x10 (8-bit HR + R-R present), HR=60, one R-R raw=1024 (1/1024 s units) → 1000 ms.
        val r = StandardHeartRate.parse(bytes(0x10, 60, 0x00, 0x04))!!
        assertEquals(60, r.hr)
        assertEquals(listOf(1000), r.rr)
        assertEquals(listOf(1024), r.rrRawTicks)
    }

    @Test
    fun multipleRrIntervals() {
        // flags=0x10, HR=58, two R-R: raw=512 → 500 ms, raw=1024 → 1000 ms.
        val r = StandardHeartRate.parse(bytes(0x10, 58, 0x00, 0x02, 0x00, 0x04))!!
        assertEquals(58, r.hr)
        assertEquals(listOf(500, 1000), r.rr)
        assertEquals(listOf(512, 1024), r.rrRawTicks)
    }

    @Test
    fun energyExpendedFieldIsSkippedBeforeRr() {
        // flags=0x18 (bit3 energy-expended + bit4 R-R), HR=65, EE=0x00FF (2 bytes skipped),
        // then R-R raw=1024 → 1000 ms. Proves the EE bytes don't leak into the R-R parse.
        val r = StandardHeartRate.parse(bytes(0x18, 65, 0xFF, 0x00, 0x00, 0x04))!!
        assertEquals(65, r.hr)
        assertEquals(listOf(1000), r.rr)
        assertEquals(listOf(1024), r.rrRawTicks)
    }

    @Test
    fun emptyOrTruncatedReturnsNull() {
        assertNull(StandardHeartRate.parse(ByteArray(0)))
        // flags claim a 16-bit HR but only one HR byte follows → truncated → null.
        assertNull(StandardHeartRate.parse(bytes(0x01, 0x40)))
    }

    @Test fun incompleteDeclaredEnergyRefusesWholeReading() {
        val heartRates = listOf(bytes(72), bytes(0x40, 1))
        for ((format, hr) in heartRates.withIndex()) {
            for (extraFlags in listOf(0x00, 0x06, 0xe0, 0xe6, 0x10, 0x16, 0xf0, 0xf6)) {
                for (energy in listOf(ByteArray(0), bytes(0xff))) {
                    val frame = bytes(format or 0x08 or extraFlags) + hr + energy
                    assertNull("incomplete energy: ${frame.toList()}", StandardHeartRate.parse(frame))
                }
            }
        }
    }

    @Test fun incompleteRrTailRefusesWholeReading() {
        val heartRates = listOf(bytes(72), bytes(0x40, 1))
        for ((format, hr) in heartRates.withIndex()) {
            for (energy in listOf(ByteArray(0), bytes(0x34, 0x12))) {
                for (extraFlags in listOf(0x00, 0x06, 0xe0, 0xe6)) {
                    for (tail in listOf(bytes(0xff), bytes(0, 4, 0xff), bytes(0, 4, 0xff, 0xff, 0xab))) {
                        val flags = format or 0x10 or extraFlags or (if (energy.isEmpty()) 0 else 0x08)
                        val frame = bytes(flags) + hr + energy + tail
                        assertNull("incomplete R-R: ${frame.toList()}", StandardHeartRate.parse(frame))
                    }
                }
            }
        }
    }

    @Test fun completeReadingsMatchOriginalSwiftOracle() {
        val frames = listOf(
            bytes(0x00, 72),
            bytes(0x02, 0),
            bytes(0x04, 220),
            bytes(0x06, 255),
            bytes(0x01, 0x00, 0x01),
            bytes(0x07, 0xff, 0xff),
            bytes(0x08, 72, 0, 0),
            bytes(0x09, 0x40, 1, 0xff, 0xff),
            bytes(0x10, 60),
            bytes(0x11, 0x40, 1),
            bytes(0x18, 65, 0xff, 0),
            bytes(0x19, 0xff, 0xff, 0xff, 0xff),
            bytes(0x10, 60, 0, 4),
            bytes(0x16, 72, 0, 4),
            bytes(0x18, 65, 0xff, 0, 0, 4),
            bytes(0x19, 0x40, 1, 0x34, 0x12, 0, 4),
            bytes(0x10, 58, 0, 2, 0, 4),
            bytes(0x10, 72, 0, 0, 0x40, 0, 0xc0, 0, 0xff, 0xff),
            bytes(0xe0, 72),
            bytes(0xe0, 72, 0xff),
            bytes(0xf0, 72, 0, 4),
            bytes(0xf6, 72, 0, 2, 0, 4),
            bytes(0xf9, 0x40, 1, 0, 0, 0, 4),
            bytes(0xfe, 72, 0, 0, 0, 4),
            bytes(0xff, 0x40, 1, 0, 0, 1, 0),
            bytes(0x00, 72, 0xff, 0, 4),
            bytes(0x01, 0x40, 1, 0xff)
        )
        val expected = """
            0048|72|||unsupported
            0200|0|||unsupported
            04dc|220|||supported_not_detected
            06ff|255|||supported_detected
            010001|256|||unsupported
            07ffff|65535|||supported_detected
            08480000|72|||unsupported
            094001ffff|320|||unsupported
            103c|60|||unsupported
            114001|320|||unsupported
            1841ff00|65|||unsupported
            19ffffffff|65535|||unsupported
            103c0004|60|1000|1024|unsupported
            16480004|72|1000|1024|supported_detected
            1841ff000004|65|1000|1024|unsupported
            19400134120004|320|1000|1024|unsupported
            103a00020004|58|500,1000|512,1024|unsupported
            104800004000c000ffff|72|0,63,188,63999|0,64,192,65535|unsupported
            e048|72|||unsupported
            e048ff|72|||unsupported
            f0480004|72|1000|1024|unsupported
            f64800020004|72|500,1000|512,1024|supported_detected
            f9400100000004|320|1000|1024|unsupported
            fe4800000004|72|1000|1024|supported_detected
            ff400100000100|320|1|1|supported_detected
            0048ff0004|72|||unsupported
            014001ff|320|||unsupported
        """.trimIndent()
        val actual = frames.joinToString("\n") { data ->
            val hex = data.joinToString("") { java.lang.String.format(java.util.Locale.ROOT, "%02x", it.toInt() and 0xff) }
            val r = StandardHeartRate.parse(data)
            if (r == null) "$hex|nil" else "$hex|${r.hr}|${r.rr.joinToString(",")}|${r.rrRawTicks.joinToString(",")}|${r.contact.storageValue}"
        }
        assertEquals(expected, actual)
    }
}
