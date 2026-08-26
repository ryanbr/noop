package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The unbonded DIS attempt: once per device, never after a refusal. */
class DisUnbondedReadTest {
    private fun go(
        isWhoop5: Boolean = true,
        bonded: Boolean = false,
        already: Boolean = false,
        refused: Boolean = false,
    ) = shouldReadDisUnbonded(isWhoop5, bonded, already, refused)

    @Test
    fun `an unbonded 5-MG that has not been asked yet is tried once`() {
        assertTrue(go())
    }

    @Test
    fun `a strap that already refused is never asked again`() {
        // Self-limiting, like the hello suppression. "Keeps trying something that will never work" is the
        // failure this area keeps producing, and a refusal is a durable fact about the strap.
        assertFalse(go(refused = true))
    }

    @Test
    fun `a bonded link is left to the post-bond path`() {
        assertFalse(go(bonded = true))
    }

    @Test
    fun `never on a WHOOP 4, and never twice on one link`() {
        assertFalse(go(isWhoop5 = false))
        assertFalse(go(already = true))
    }

    @Test
    fun `the refusal key is per device and case-insensitive`() {
        assertEquals(disRefusedPrefKey("fd:d4:f7:24:53:4a"), disRefusedPrefKey("  FD:D4:F7:24:53:4A  "))
        assertEquals(null, disRefusedPrefKey("  "))
    }

    @Test
    fun `a failed read is no longer silent, and names the interesting statuses`() {
        // Both onCharacteristicRead overloads used to drop a non-success status on the floor, so a refusal
        // was indistinguishable from a read that never happened - the ambiguity that made the CLIENT_HELLO
        // failure unreadable for eleven weeks.
        val line = disReadFailureLine("00002a26-0000-1000-8000-00805f9b34fb", "status=GATT_INSUFFICIENT_AUTHENTICATION(5)")
        assertTrue(line.contains("GATT_INSUFFICIENT_AUTHENTICATION(5)"))
        assertTrue(line.contains("cannot be read without one"))
        assertTrue(line.contains("2a26"))
    }
}
