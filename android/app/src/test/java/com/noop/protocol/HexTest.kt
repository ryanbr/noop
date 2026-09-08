package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The fast encoder has to be byte-for-byte identical to the `%02x` join it replaces, because its output
 * goes into capture files and strap logs that existing decode tooling reads.
 */
class HexTest {

    private fun slow(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test
    fun `matches the format-based encoder across the whole byte range`() {
        val all = ByteArray(256) { it.toByte() }
        assertEquals(slow(all), all.toHexLower())
    }

    /** The sign bit is where a hand-rolled encoder usually goes wrong. */
    @Test
    fun `high bytes are unsigned and zero-padded`() {
        assertEquals("00", byteArrayOf(0).toHexLower())
        assertEquals("0f", byteArrayOf(15).toHexLower())
        assertEquals("80", byteArrayOf((-128).toByte()).toHexLower())
        assertEquals("ff", byteArrayOf((-1).toByte()).toHexLower())
    }

    @Test
    fun `empty in, empty out`() {
        assertEquals("", ByteArray(0).toHexLower())
    }

    /** Lowercase, no separator: the shape every existing consumer of these dumps expects. */
    @Test
    fun `output is lowercase and unseparated`() {
        val b = byteArrayOf(0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte())
        assertEquals("abcdef", b.toHexLower())
    }
}
