package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * #2092, route 1: the product-info reply log line printed `ascii: <serial>` in the clear - neither
 * `redactStrapLogPii` rule matches a bare, unprefixed serial (by design: a shape-only rule would mask
 * ordinary prose), and the hex half was only masked by `redactHexDumpPii`'s accident of matching a
 * letter-led alnum run, which an all-digit serial (this repo's own #2075/#2090 evidence) never triggers.
 * `OuraLiveSource.logSafeProductInfo` is the fix: computed right where the code already knows (via
 * `isPlausibleSerial`) whether a decoded string IS a serial, so it can mask deliberately instead of
 * relying on an unrelated heuristic to get lucky. Swift twin: `OuraLiveSourceProductInfoLogRedactionTests`.
 */
class OuraLiveSourceProductInfoLogRedactionTest {

    @Test fun `a serial page is masked in both hex and ascii`() {
        val serial = "2H3B2405003655"
        val hex = serial.toByteArray().joinToString(" ") { "%02x".format(it) }
        val (safeHex, safeAscii) = OuraLiveSource.logSafeProductInfo(hex, serial, serial)
        assertEquals("<serial>", safeHex)
        assertEquals("2H3…", safeAscii)
        assertFalse(safeAscii.contains("2405003655"))
    }

    @Test fun `an all-digit serial page is masked too`() {
        val serial = "2038082631034041"
        val hex = serial.toByteArray().joinToString(" ") { "%02x".format(it) }
        val (safeHex, safeAscii) = OuraLiveSource.logSafeProductInfo(hex, serial, serial)
        assertEquals("<serial>", safeHex)
        assertEquals("203…", safeAscii)
    }

    @Test fun `a hardware page is logged in full`() {
        val hex = "BLB_03".toByteArray().joinToString(" ") { "%02x".format(it) }
        val (safeHex, safeAscii) = OuraLiveSource.logSafeProductInfo(hex, "BLB_03", "BLB_03")
        assertEquals(hex, safeHex)
        assertEquals("BLB_03", safeAscii)
    }

    @Test fun `a null decode is left alone`() {
        val (safeHex, safeAscii) = OuraLiveSource.logSafeProductInfo("00 01", "..", null)
        assertEquals("00 01", safeHex)
        assertEquals("..", safeAscii)
    }
}
