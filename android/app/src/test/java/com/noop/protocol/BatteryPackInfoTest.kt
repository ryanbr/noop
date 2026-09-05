package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    /**
     * The gauge must be sanity-checked before it is shown. These offsets are an unvalidated candidate
     * re-derived from two captures; a wrong one does not fail, it renders a confident wrong number — the
     * failure this project treats as worse than a blank. A percentage outside 0..100 means the offset
     * moved, so the caller renders nothing.
     */
    @Test
    fun `an out-of-range charge is not displayable`() {
        val absurd = BatteryPackInfo.Info(present = true, socPct = 2488.1, serial = "P", btAddr = "aa")
        assertFalse(absurd.displayable)
        val negative = BatteryPackInfo.Info(present = true, socPct = -1.0, serial = "P", btAddr = "aa")
        assertFalse(negative.displayable)
    }

    /** A plausible gauge on an attached pack is the one case that shows. */
    @Test
    fun `an in-range charge on an attached pack is displayable`() {
        assertTrue(BatteryPackInfo.Info(present = true, socPct = 73.4, serial = "P", btAddr = "aa").displayable)
        assertTrue(BatteryPackInfo.Info(present = true, socPct = 0.0, serial = "P", btAddr = "aa").displayable)
        assertTrue(BatteryPackInfo.Info(present = true, socPct = 100.0, serial = "P", btAddr = "aa").displayable)
    }

    /** A removed pack must clear the card, never hold the last reading. */
    @Test
    fun `an absent pack is never displayable`() {
        assertFalse(BatteryPackInfo.Info(present = false, socPct = null, serial = null, btAddr = null).displayable)
        // Even if a stale charge rides along, absence wins.
        assertFalse(BatteryPackInfo.Info(present = false, socPct = 80.0, serial = null, btAddr = null).displayable)
    }

    /**
     * The router branch that decodes this reply matches on the command NAME
     * (`respCmd.startsWith("GET_BATTERY_PACK_INFO(")`), which comes from this lookup table. A rename or a
     * removal there would not fail to compile — the branch would simply stop matching and the whole
     * feature would go quiet, with the decoder back to having no caller. Pin the string.
     */
    @Test
    fun `command 151 resolves to the name the router matches on`() {
        assertEquals("GET_BATTERY_PACK_INFO", com.noop.protocol.CommandNames.byRaw[151])
        assertTrue(com.noop.protocol.CommandNames.label(151).startsWith("GET_BATTERY_PACK_INFO("))
    }

    /**
     * `displayable` is about a CHARGE percentage, and the 4.0 path carries a voltage instead — so it is
     * always false there, correctly. Pinned because the name is generic enough that a future 4.0 voltage
     * card might reach for this gate and get a permanent no.
     */
    @Test
    fun `the 4-0 voltage path is never displayable`() {
        val v = BatteryPackInfo.Info(present = true, socPct = null, serial = null, btAddr = null,
                                     voltageMv = 3_900)
        assertFalse(v.displayable)
    }
}
