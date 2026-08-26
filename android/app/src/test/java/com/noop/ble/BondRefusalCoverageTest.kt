package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins what counts as a bond refusal (#1635).
 *
 * The measured bug: on a WHOOP 5/MG whose CLIENT_HELLO is never answered, the link drops as a plain
 * local terminate. The give-up gate tested only the status, so an unanswered handshake never
 * incremented the streak — eight consecutive attempts all logged "attempt 1" and it retried every ~11
 * seconds indefinitely.
 */
class BondRefusalCoverageTest {

    private val w5 = DeviceFamily.WHOOP5
    private val w4 = DeviceFamily.WHOOP4

    @Test
    fun `an unanswered handshake now counts, which is the fix`() {
        assertTrue(countsAsBondRefusal(isAuthRefusalStatus = false, helloUnacked = true,
                                       alreadyBonded = false, family = w5))
    }

    @Test
    fun `an auth rejection still counts, unchanged`() {
        assertTrue(countsAsBondRefusal(isAuthRefusalStatus = true, helloUnacked = false,
                                       alreadyBonded = false, family = w5))
    }

    @Test
    fun `an ordinary disconnect with neither signal does not count`() {
        // Guards the obvious over-reach: a normal drop after a healthy session must not accrue toward
        // giving up, or a working strap would eventually pause itself.
        assertFalse(countsAsBondRefusal(isAuthRefusalStatus = false, helloUnacked = false,
                                        alreadyBonded = false, family = w5))
    }

    @Test
    fun `an already-bonded link never counts, whatever the signal`() {
        assertFalse(countsAsBondRefusal(true, true, alreadyBonded = true, family = w5))
    }

    @Test
    fun `a WHOOP 4 never counts — this is the 5 or MG handshake`() {
        assertFalse(countsAsBondRefusal(true, true, alreadyBonded = false, family = w4))
    }

    @Test
    fun `the unanswered-handshake hint does not name a cause it cannot know`() {
        val unanswered = BondRefusalGiveUp.pausedHintHandshakeUnanswered()
        val refused = BondRefusalGiveUp.pausedHint()
        // The auth-refusal hint names the official WHOOP app, which an auth rejection is evidence for.
        assertTrue(refused.contains("official WHOOP app"))
        // The unanswered-handshake hint must NOT, because nothing observed supports it.
        assertFalse(unanswered.contains("official WHOOP app"))
        assertFalse(unanswered.contains("Forget This Device"))
        // It should still describe what was seen and offer the action that is the user's to take.
        assertTrue(unanswered.contains("never completes"))
        assertTrue(unanswered.contains("Tap Connect"))
    }
}
