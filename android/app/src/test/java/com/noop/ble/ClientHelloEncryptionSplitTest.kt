package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The second false bond, found in the 30 Aug 22:47 capture.
 *
 * The ack branch took "the CLIENT_HELLO write completed" as proof of an encrypted just-works bond and set
 * `encryptedBond`, so the app showed "Bonded, streaming." on a link whose OS bond state read BOND_NONE two
 * seconds later — for a strap an HCI capture already showed answering SMP `Pairing Not Supported`, where an
 * encrypted bond is not merely absent but impossible.
 */
class ClientHelloEncryptionSplitTest {

    @Test
    fun `a completed write is not proof of encryption`() {
        assertFalse(helloCompletionProvesEncryptedBond(osBonded = false))
    }

    @Test
    fun `the OS bond state is what attests it`() {
        assertTrue(helloCompletionProvesEncryptedBond(osBonded = true))
    }

    /**
     * The line must say the handshake CONTINUES. The split would otherwise read as a refusal, and the
     * whole point is that subscribing, clocking and offloading need the strap to be listening — not the
     * link to be encrypted.
     */
    @Test
    fun `the line separates the two facts and says the handshake goes on`() {
        val line = helloAckedWithoutEncryptionLine(elapsedMs = 5L, osBondState = "BOND_NONE")
        assertTrue(line.contains("NOT that the link is encrypted"))
        assertTrue(line.contains("BOND_NONE"))
        assertTrue(line.contains("Continuing the handshake"))
        assertTrue(line.contains("#1635"))
    }

    /**
     * A completion faster than one connection interval is itself evidence the callback came from the local
     * stack. Across 41 captures every hello either "completed" in 0-7ms or produced no callback at all
     * ~3150ms later — nothing in between, and 0ms cannot be a round trip. The line points at that only
     * when it applies; it must not editorialise about a plausible latency.
     */
    @Test
    fun `an impossibly fast completion is called out, a plausible one is not`() {
        assertTrue(helloAckedWithoutEncryptionLine(0L, "BOND_NONE").contains("under one BLE connection interval"))
        assertTrue(helloAckedWithoutEncryptionLine(5L, "BOND_NONE").contains("under one BLE connection interval"))
        assertFalse(helloAckedWithoutEncryptionLine(40L, "BOND_NONE").contains("under one BLE connection interval"))
        // The boundary is the physical floor, not a round number pulled from the observed values.
        assertFalse(
            helloAckedWithoutEncryptionLine(MIN_PLAUSIBLE_ATT_ROUND_TRIP_MS, "BOND_NONE")
                .contains("under one BLE connection interval"),
        )
    }

    /**
     * Timing is diagnostic, never a gate. A strap that genuinely bonds must not have its bond rejected for
     * answering quickly — a peripheral may reply inside the same connection event, so a fast round trip is
     * unusual, not impossible.
     */
    @Test
    fun `timing never decides the bond`() {
        assertTrue(helloCompletionProvesEncryptedBond(osBonded = true))
        assertFalse(helloCompletionProvesEncryptedBond(osBonded = false))
    }
}
