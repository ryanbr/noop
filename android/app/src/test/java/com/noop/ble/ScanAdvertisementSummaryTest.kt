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
        assertTrue(s.contains("0000fd4b-0000-1000-8000-00805f9b34fb:9B"))
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
        assertTrue(pairing.contains("0000fd4b-0000-1000-8000-00805f9b34fb:4B"))
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

    /**
     * The cross-platform guarantee. CoreBluetooth reports an assigned 16-bit UUID as "180d" while
     * Android always expands it, so without canonicalisation the SAME strap would log two different
     * lines and an iOS capture could not be diffed against an Android one. Both spellings must collapse
     * to one string — the Swift twin asserts this verbatim.
     */
    @Test
    fun `short and long uuid spellings produce the same line`() {
        val short = line(svc = listOf("180d"), svcData = mapOf("fd4b" to 4))
        val long = line(
            svc = listOf("0000180d-0000-1000-8000-00805f9b34fb"),
            svcData = mapOf("0000fd4b-0000-1000-8000-00805f9b34fb" to 4),
        )
        assertEquals(short, long)
        assertTrue(short.contains("svc=0000180d-0000-1000-8000-00805f9b34fb"))
    }

    /** A 32-bit assigned UUID takes the same base, and a 128-bit one is passed through untouched. */
    @Test
    fun `canonicalisation covers 32-bit and leaves full uuids alone`() {
        assertEquals(
            "0000180d-0000-1000-8000-00805f9b34fb",
            ScanAdvertisementSummary.canonicalUuid("0000180d"),
        )
        val full = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        assertEquals(full, ScanAdvertisementSummary.canonicalUuid(full))
    }

    /**
     * The other cross-platform trap in this line, and the reason it is measured in bytes.
     *
     * Java's `String.length` would say 8 for this name and Swift's `String.count` would say 7, so the
     * same strap logged a different size on each platform. The Swift twin asserts the SAME 10.
     */
    @Test
    fun `local name length is utf-8 bytes, not characters`() {
        assertEquals(10, ScanAdvertisementSummary.localNameLength("Whoop \uD83C\uDF89"))
        assertEquals(8, "Whoop \uD83C\uDF89".length)  // guards the premise: length would disagree
        assertEquals(12, ScanAdvertisementSummary.localNameLength("Ryan's Whoop"))
        assertEquals(null, ScanAdvertisementSummary.localNameLength(null))
    }

}
