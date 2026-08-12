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

    /** Edge vectors mutated off the attached golden — the SAME results the Swift twin asserts, byte for
     *  byte, including the non-ASCII-serial case where both must return a null serial (not a garbage one). */
    @Test fun edgeVectorsDecodeIdenticallyToSwift() {
        val base = bytes(attachedHex)
        fun mut(vararg kv: Pair<Int, Int>) = base.copyOf().also { for ((i, v) in kv) it[i] = v.toByte() }
        assertEquals(0.0, BatteryPackInfo.decode(mut(37 to 0, 38 to 0))!!.socPct!!, 1e-9)
        assertEquals(100.0, BatteryPackInfo.decode(mut(37 to 0xe8, 38 to 0x03))!!.socPct!!, 1e-9)
        assertNull(BatteryPackInfo.decode(mut(21 to 0))!!.serial)          // empty serial → null
        val hb = BatteryPackInfo.decode(mut(21 to 0x80))!!                  // non-ASCII byte
        assertEquals(true, hb.present)
        assertNull(hb.serial)                                              // undecodable → null
        assertNull(BatteryPackInfo.decode(mut(10 to 0)))                   // not a 151 response
        assertNull(BatteryPackInfo.decode(mut(12 to 0)))                   // not SUCCESS
    }

    /** WHOOP 4.0 path: pack read via GET_EXTENDED_BATTERY_INFO (98), reporting VOLTAGE not a %. The frame
     *  is the #592 WHOOP4 capture (pay[7..8] = 0x0f82 = 3970 mV); same values the Swift twin asserts. */
    @Test fun whoop4PackReportsVoltageNotPercent() {
        val realFrame = "aa2400fa24c6620d010165006bff820f0c0128000f05e90321120200010100001a0000004675fe58"
        val info = BatteryPackInfo.decodeExtended(bytes(realFrame))!!
        assertEquals(true, info.present)
        assertEquals(3970, info.voltageMv)   // 3.97 V
        assertNull(info.socPct)              // 4.0 has no fuel-gauge %
        assertNull(info.serial)
        assertNull(BatteryPackInfo.decodeExtended(bytes(attachedHex)))   // 151 frame is not a 98 response
        assertNull(BatteryPackInfo.decode(bytes(attachedHex))!!.voltageMv) // 5/MG decode never fills voltage
    }
}
