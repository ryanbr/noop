package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The advertisement summary (#1635) — the ORACLE for the Swift twin.
 *
 * Its job is to make two advertising modes distinguishable in a strap log without carrying anything
 * that identifies a person or a device. WHOOP names a strap "<Name>'s Whoop" by default, so the local
 * name is the one field that must never appear.
 */
class ScanAdvertisementSummaryTest {

    private fun line(
        flags: Int? = 0x06,
        svc: List<String> = listOf("61080001-8d6d-82b8-614a-1c8cb0f8dcc6"),
        svcData: Map<String, Int> = emptyMap(),
        mfg: Map<Int, Int> = emptyMap(),
        tx: Int? = null,
        nameLen: Int? = 12,
        connectable: Boolean = true,
    ) = ScanAdvertisementSummary.line(flags, svc, svcData, mfg, tx, nameLen, connectable)

    /** The headline guarantee: shape is reported, payload never is. */
    @Test
    fun `the summary carries no payload bytes and no name`() {
        val s = line(svcData = mapOf("fd4b" to 9), mfg = mapOf(0x01D9 to 14), nameLen = 13)
        // Lengths and ids, yes. Contents, no.
        assertTrue(s.contains("fd4b:9B"))
        assertTrue(s.contains("0x01d9:14B"))
        assertTrue(s.contains("nameLen=13"))
        // Nothing that could be a name or a serial.
        assertFalse(s.contains("Whoop"))
        assertFalse(s.contains("'s"))
    }

    /**
     * The point of the line: two advertising modes must produce different text. If a strap in pairing
     * mode advertises an extra service-data block, or flips a flag, the log has to show it — otherwise
     * the #1635 question stays unanswerable.
     */
    @Test
    fun `a different advertising mode reads differently`() {
        val normal = line(flags = 0x06, svcData = emptyMap())
        val pairing = line(flags = 0x05, svcData = mapOf("fd4b" to 4))
        assertFalse(normal == pairing)
        assertTrue(normal.contains("flags=0x06"))
        assertTrue(pairing.contains("flags=0x05"))
        assertTrue(normal.contains("svcData=none"))
        assertTrue(pairing.contains("fd4b:4B"))
    }

    /** Absent fields say so rather than vanishing, so two logs stay comparable field by field. */
    @Test
    fun `absent fields are named, not omitted`() {
        val s = line(flags = null, svc = emptyList(), tx = null, nameLen = null)
        assertTrue(s.contains("flags=none"))
        assertTrue(s.contains("svc=none"))
        assertTrue(s.contains("tx=none"))
        assertTrue(s.contains("nameLen=none"))
    }

    /** Deterministic ordering, so two captures diff cleanly instead of by map iteration order. */
    @Test
    fun `output is stable regardless of input order`() {
        val a = ScanAdvertisementSummary.line(6, listOf("b", "a"), mapOf("y" to 1, "x" to 2), mapOf(2 to 1, 1 to 2), null, 4, true)
        val b = ScanAdvertisementSummary.line(6, listOf("a", "b"), mapOf("x" to 2, "y" to 1), mapOf(1 to 2, 2 to 1), null, 4, true)
        assertEquals(a, b)
    }

    /** Connectability separates a pairing-ready strap from a beacon-only one. */
    @Test
    fun `connectability is reported`() {
        assertTrue(line(connectable = true).contains("connectable=true"))
        assertTrue(line(connectable = false).contains("connectable=false"))
    }
}
