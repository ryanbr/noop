package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Twin of Swift BatteryPackInfoTests. GET_BATTERY_PACK_INFO (151) has two answers and the Devices card
 * must behave oppositely on each: a reply naming a pack fills the row, a reply naming none must CLEAR it.
 * Both frames came off one WHOOP 5 strap — pack attached, then physically removed — pinning the decode to
 * real bytes, byte-identical to the Swift twin.
 */
class BatteryPackInfoTest {

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private val attachedHex =
        "aa01280001002de1245c9704010101f7381d2e3161574242354150303132363339" +
            "35000000e5020c01000000be577aee"
    private val absentHex =
        "aa01280001002de1240797040101000000000000000000000000000000000000" +
            "000000000000000000000000cf8e5340"

    @Test fun attachedPackNamesItsChargeAndSerial() {
        val info = BatteryPackInfo.decode(bytes(attachedHex))!!
        assertEquals(true, info.present)
        assertEquals(74.1, info.socPct!!, 1e-9)
        assertEquals("WBB5AP0126395", info.serial)
        assertEquals("f7381d2e3161", info.btAddr)
    }

    @Test fun removedPackReportsAbsenceNotAStaleReading() {
        val info = BatteryPackInfo.decode(bytes(absentHex))!!
        assertEquals(false, info.present)
        assertNull(info.socPct)
        assertNull(info.serial)
        assertNull(info.btAddr)
    }

    @Test fun nonPackOrShortFrameIsNull() {
        assertNull(BatteryPackInfo.decode(bytes("aa0128000100")))
        val f = bytes(attachedHex); f[12] = 0 // result != SUCCESS
        assertNull(BatteryPackInfo.decode(f))
    }
}
