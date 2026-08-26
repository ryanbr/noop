package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the Settings → Strap status detail copy, in particular that an in-flight scan takes
 * precedence over bonded/connected so the user gets "Searching…" feedback the moment Re-scan is
 * tapped (issue #1). The button's `enabled = !live.scanning` relies on the same scanning flag, so
 * a regression here is the visible half of "Re-scan does nothing".
 */
class StrapStatusDetailTest {

    @Test
    fun scanning_takesPrecedence_overEveryOtherState() {
        // Even when already bonded + connected, an active scan must say "Searching…".
        assertTrue(
            strapStatusDetail(encryptedBond = true, bonded = true, connected = true, scanning = true)
                .startsWith("Searching for your WHOOP"),
        )
        assertTrue(
            strapStatusDetail(encryptedBond = false, bonded = false, connected = false, scanning = true)
                .startsWith("Searching for your WHOOP"),
        )
    }

    @Test
    fun nonScanning_branches_areUnchanged() {
        assertEquals(
            "Your strap is paired and sending data. Open Live for a real-time heart rate.",
            strapStatusDetail(encryptedBond = true, bonded = true, connected = true, scanning = false),
        )
        assertEquals(
            "Connected. Finishing the secure pairing handshake…",
            strapStatusDetail(encryptedBond = false, bonded = false, connected = true, scanning = false),
        )
        assertEquals(
            "Previously paired but not currently connected. Re-scan to reconnect.",
            strapStatusDetail(encryptedBond = true, bonded = true, connected = false, scanning = false),
        )
        assertEquals(
            "No strap connected. Put your WHOOP nearby and tap Re-scan to pair.",
            strapStatusDetail(encryptedBond = false, bonded = false, connected = false, scanning = false),
        )
    }

    @Test
    fun `a live-HR-only link is not described as paired`() {
        // #1635/#69: the 5/MG live-HR shortcut sets bonded without any encrypted pairing, and hello
        // suppression makes that the permanent state. Telling the user their strap "is paired" there
        // contradicts the Devices screen and the buzz/alarm rows on this same screen.
        val detail = strapStatusDetail(
            encryptedBond = false, bonded = true, connected = true, scanning = false,
        )
        assertFalse(detail.contains("is paired"))
        assertTrue(detail.contains("not fully paired"))

        assertEquals("Live HR (not fully paired)",
            strapStatusTitle(encryptedBond = false, bonded = true, connected = true))
        assertEquals("Bonded · streaming",
            strapStatusTitle(encryptedBond = true, bonded = true, connected = true))
    }

    @Test
    fun `only a real bond on a live link is a positive tone`() {
        assertEquals(StrandTone.Positive, strapTone(encryptedBond = true, bonded = true, connected = true))
        assertEquals(StrandTone.Warning, strapTone(encryptedBond = false, bonded = true, connected = true))
        assertEquals(StrandTone.Critical, strapTone(encryptedBond = false, bonded = false, connected = false))
    }
}
