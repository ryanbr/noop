package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A bare integer in a strap log is evidence nobody can read, and the log is the only evidence a remote
 * report carries. These pin the naming and, more importantly, pin that the three integer spaces stay
 * SEPARATE.
 */
class BleStatusLabelsTest {

    // --- scan failures ---

    /**
     * The code worth all of this: Android allows 5 scan starts per 30s and refuses the sixth, after
     * which scanning is dead until the window rolls. It is the leading cause of "it will not find my
     * strap", it is self-inflicted and fixable, and the log used to report it as "6".
     */
    @Test
    fun `the scan throttle explains itself`() {
        val l = scanFailureLabel(SCAN_FAILED_SCANNING_TOO_FREQUENTLY)
        assertTrue(l, l.contains("SCANNING_TOO_FREQUENTLY(6)"))
        assertTrue(l, l.contains("5 scan starts per 30s"))
    }

    @Test
    fun `the other defined scan codes are named`() {
        assertTrue(scanFailureLabel(1).startsWith("ALREADY_STARTED(1)"))
        assertTrue(scanFailureLabel(2).startsWith("APPLICATION_REGISTRATION_FAILED(2)"))
        assertTrue(scanFailureLabel(3).startsWith("INTERNAL_ERROR(3)"))
        assertTrue(scanFailureLabel(4).startsWith("FEATURE_UNSUPPORTED(4)"))
        assertTrue(scanFailureLabel(5).startsWith("OUT_OF_HARDWARE_RESOURCES(5)"))
    }

    /** An undefined code prints as itself. A wrong name in a failure line is worse than no name. */
    @Test
    fun `an unknown scan code is not given an invented name`() {
        assertEquals("7", scanFailureLabel(7))
        assertEquals("0", scanFailureLabel(0))
    }

    // --- disconnect reasons ---

    @Test
    fun `the disconnect reasons that matter are named`() {
        assertTrue(disconnectStatusLabel(8).contains("out of range"))
        assertTrue(disconnectStatusLabel(19).contains("STRAP terminated"))
        assertTrue(disconnectStatusLabel(22).contains("phone terminated"))
        assertTrue(disconnectStatusLabel(62).contains("failed to establish"))
    }

    /** 133 keeps its honesty: it is Android's catch-all, so it is not given a cause it does not have. */
    @Test
    fun `the catch-all is described as a catch-all`() {
        val l = disconnectStatusLabel(133)
        assertTrue(l, l.contains("catch-all"))
        assertTrue(l, l.contains("no specific cause"))
    }

    @Test
    fun `an unknown disconnect status keeps the old bare rendering`() {
        assertEquals("status=41", disconnectStatusLabel(41))
    }

    // --- and the spaces stay apart ---

    /**
     * THE point of three functions instead of one. 8 is a link-supervision timeout as a DISCONNECT
     * reason and something else entirely as a GATT operation status, so a shared table would hand one
     * of them a name from the wrong space. This fails the moment someone merges them.
     */
    @Test
    fun `the same integer means different things in the two spaces`() {
        assertNotEquals(disconnectStatusLabel(8), gattStatusLabel(8))
        assertTrue(disconnectStatusLabel(8).contains("link supervision"))
        assertEquals("status=8", gattStatusLabel(8))
    }

    /**
     * The flip side of the test above, and the reason it is not enough on its own. 133 is Android's
     * catch-all in BOTH spaces and genuinely means the same thing, so the labellers AGREE about it.
     * Separate tables was a decision about which codes differ, not a claim that every code does, and
     * pinning only the disagreement would leave the boundary half-documented.
     */
    @Test
    fun `the catch-all means the same thing in both spaces`() {
        assertTrue(disconnectStatusLabel(133).contains("GATT_ERROR"))
        assertTrue(gattStatusLabel(133).contains("GATT_ERROR"))
        assertTrue(disconnectStatusLabel(0).contains("clean"))
        assertTrue(gattStatusLabel(0).contains("GATT_SUCCESS"))
    }

    /** A GATT status the write path already named keeps that name wherever it is now used. */
    @Test
    fun `gatt statuses keep their names on the paths that reuse the labeller`() {
        assertEquals("status=GATT_INSUFFICIENT_AUTHENTICATION(5)", gattStatusLabel(5))
        assertEquals("status=GATT_INSUFFICIENT_ENCRYPTION(15)", gattStatusLabel(15))
    }
}
