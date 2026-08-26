package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the 5/MG firmware-gate diagnostic. Swift twin: `FirmwareGateDiagnosticTests`.
 *
 * The decoder reads the version at pay[93] behind a `pay[93] == 50` guard, both anchored to a single
 * 50.38.1.0 capture. The guards fail closed, so a strap that does not match reports nothing — and a
 * different generation byte is indistinguishable from a MOVED offset unless the line says which.
 */
class FirmwareGateDiagnosticTest {

    private fun payload(count: Int, at93: Int): ByteArray {
        val p = ByteArray(count) { (it % 256).toByte() }
        if (count > 93) p[93] = at93.toByte()
        return p
    }

    @Test
    fun `reports the byte it actually saw and the expected one`() {
        val line = firmwareGateDiagnostic(payload(128, 51), 27)
        assertTrue(line, line.contains("at93=51 expected=50"))
        assertTrue(line, line.contains("len=128"))
    }

    @Test
    fun `carries the name end because that is what moves the offset`() {
        // The version sits after the name+token region, so where the printable-ASCII name run ended is
        // the number that lets a reader re-derive a shifted offset.
        assertTrue(firmwareGateDiagnostic(payload(128, 51), 31).contains("nameEnd=31"))
    }

    @Test
    fun `the hex window spans the region the version should occupy`() {
        val line = firmwareGateDiagnostic(payload(128, 51), 27)
        assertTrue(line, line.contains("hex[88..<101]="))
        assertEquals(26, line.substringAfter("hex[88..<101]=").length)
    }

    @Test
    fun `a short payload cannot trap and says so`() {
        // A malformed/truncated hello must not crash the decoder; the window clamps and at93 reports n/a.
        val line = firmwareGateDiagnostic(byteArrayOf(1, 2, 3), 2)
        assertTrue(line, line.contains("at93=n/a"))
        assertTrue(line, line.contains("len=3"))
    }

    @Test
    fun `a payload ending exactly at the window start yields an empty window`() {
        assertTrue(firmwareGateDiagnostic(ByteArray(88), 20).endsWith("hex[88..<88]="))
    }
}
