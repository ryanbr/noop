package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The #1635 hello-suppression rules: when to skip the handshake, and which give-up cause suppresses. */
class HelloSuppressionTest {
    @Test
    fun `an unlatched strap always gets its handshake`() {
        assertTrue(shouldSendClientHello(suppressedForDevice = false, userInitiated = false))
        assertTrue(shouldSendClientHello(suppressedForDevice = false, userInitiated = true))
    }

    @Test
    fun `a latched strap skips it on an automatic reconnect`() {
        // The whole point: the automatic reconnect is the one that was looping every five seconds.
        assertFalse(shouldSendClientHello(suppressedForDevice = true, userInitiated = false))
    }

    @Test
    fun `an explicit Connect always re-attempts, so suppression is never permanent`() {
        assertTrue(shouldSendClientHello(suppressedForDevice = true, userInitiated = true))
    }

    @Test
    fun `only an unanswered handshake suppresses - an auth refusal still pauses`() {
        // An auth refusal is evidence the strap actively declined and reconnecting cannot help, so the
        // existing pause is right. An unanswered write is not that, and pausing would throw away live HR.
        assertTrue(giveUpSuppressesHello(authRefusal = false))
        assertFalse(giveUpSuppressesHello(authRefusal = true))
    }

    @Test
    fun `the pref key is per device and case-insensitive`() {
        assertEquals("noop.hellounanswered.fd:d4:f7:24:53:4a".replace("unanswered", "Unanswered"),
            helloSuppressionPrefKey("FD:D4:F7:24:53:4A"))
        assertEquals(helloSuppressionPrefKey("fd:d4:f7:24:53:4a"), helloSuppressionPrefKey("  FD:D4:F7:24:53:4A  "))
        assertEquals(null, helloSuppressionPrefKey("   "))
        assertEquals(null, helloSuppressionPrefKey(null))
    }

    @Test
    fun `the suppression hint never claims a pause or a cause`() {
        val hint = BondRefusalGiveUp.helloSuppressedHint()
        // Nothing is paused on this branch, and an unanswered write is not evidence the official WHOOP app
        // is holding the strap - the two mistakes this issue has already produced.
        assertFalse(hint.contains("paus", ignoreCase = true))
        assertFalse(hint.contains("WHOOP app", ignoreCase = true))
        assertTrue(hint.contains("Connect"))
        val epitaph = BondRefusalGiveUp.helloSuppressedEpitaph(5, "abcd1234")
        assertFalse(epitaph.contains("held by", ignoreCase = true))
        assertTrue(epitaph.contains("abcd1234"))
    }
}
