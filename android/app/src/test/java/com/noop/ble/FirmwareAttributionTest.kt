package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins firmware attribution. Swift twin: `FirmwareAttributionTests`.
 *
 * The reported bug: a WHOOP 5/MG showed 41.17.6.0 — the 4.0's firmware — because the persisted value
 * lived under ONE global key, written on any WHOOP connect and read back for whichever strap was active.
 */
class FirmwareAttributionTest {

    @Test
    fun `live wins over everything`() {
        assertEquals("50.1.0.0", resolveFirmware("50.1.0.0", "49.0.0.0", "41.17.6.0", 2))
    }

    @Test
    fun `this device's own persisted value beats the legacy global`() {
        assertEquals("50.1.0.0", resolveFirmware(null, "50.1.0.0", "41.17.6.0", 2))
    }

    @Test
    fun `the legacy global is REFUSED when more than one device is paired`() {
        // The exact reported bug: two straps, no per-device value yet for the active one, and the global
        // key holds the other strap's firmware. "unknown" is correct; 41.17.6.0 is not.
        assertNull(resolveFirmware(null, null, "41.17.6.0", 2))
    }

    @Test
    fun `the legacy global is honoured for a single-device install`() {
        // It cannot have come from anything else, so a single-strap install does not regress to
        // "unknown" on upgrade before the next connect.
        assertEquals("41.17.6.0", resolveFirmware(null, null, "41.17.6.0", 1))
    }

    @Test
    fun `blank values are treated as absent, not as an answer`() {
        assertEquals("41.17.6.0", resolveFirmware("", "   ", "41.17.6.0", 1))
        assertNull(resolveFirmware("", "", "", 1))
    }

    @Test
    fun `the pref key is per-device and case-insensitive on the address`() {
        assertEquals("noop.lastFirmware.f1:d4:f7:24:53:de", firmwarePrefKey("F1:D4:F7:24:53:DE"))
        assertEquals(firmwarePrefKey("f1:d4:f7:24:53:de"), firmwarePrefKey("F1:D4:F7:24:53:DE"))
    }

    @Test
    fun `no address means no key, so nothing is written to a key owned by no device`() {
        assertNull(firmwarePrefKey(null))
        assertNull(firmwarePrefKey("   "))
    }

    @Test
    fun `DIS firmware fills the gap for a strap that never bonds`() {
        // The screenshot case: a WHOOP 4.0 shows its firmware, the 5/MG beside it shows none - because the
        // only source NOOP read it from is a framed command that needs a bond the 5/MG never gets. DIS
        // 0x2A26 is readable unbonded, in the same service the serial already comes from.
        assertTrue(shouldPublishDisFirmware("1.2.3", alreadyDecoded = null))
        assertTrue(shouldPublishDisFirmware("1.2.3", alreadyDecoded = ""))
    }

    @Test
    fun `DIS never overrides a decoded firmware`() {
        // The two are not guaranteed to agree - one is the strap's own report, the other is whatever it
        // publishes in its standard profile. A value that appeared and then changed would be worse than
        // one that arrived once, so DIS yields rather than racing the decode that lands later.
        assertFalse(shouldPublishDisFirmware("1.2.3", alreadyDecoded = "41.17.6.0"))
    }

    @Test
    fun `a blank or absent DIS string publishes nothing`() {
        assertFalse(shouldPublishDisFirmware(null, alreadyDecoded = null))
        assertFalse(shouldPublishDisFirmware("   ", alreadyDecoded = null))
    }
}
