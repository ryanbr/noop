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

    @Test
    fun `an existing OS pairing does NOT permanently bypass the latch`() {
        // Tempting, and wrong: "a pairing exists" never goes away, so re-arming on it would rewrite the
        // hello on every connect for good - drop at ~4.8s, reconnect, forever - with the give-up powerless.
        // That is the unbounded loop suppression exists to end. The experiment clears the latch ONCE when
        // it asks for a pairing instead, which is self-limiting.
        assertFalse(shouldSendClientHello(suppressedForDevice = true, userInitiated = false))
    }

    // #1635: the opt-in override, after the HCI capture changed the premise

    /**
     * The capture showed the strap answers createBond with SMP "Pairing Not Supported", so the encrypted
     * bond the hello waits behind can never arrive. With the hello also suppressed the app attempts
     * NEITHER handshake — the same capture shows zero writes to fd4b0002 beyond DISABLE_ALARM and zero
     * puffin subscriptions. The override exists to ask the only question left.
     */
    @Test
    fun `the override sends the hello on a suppressed strap`() {
        assertTrue(shouldSendClientHello(suppressedForDevice = true, userInitiated = false,
                                         overrideSuppression = true))
    }

    /** Default OFF must leave the latch behaving exactly as it did — no behaviour change for anyone else. */
    @Test
    fun `without the override a suppressed strap still skips the hello`() {
        assertFalse(shouldSendClientHello(suppressedForDevice = true, userInitiated = false))
        assertFalse(shouldSendClientHello(suppressedForDevice = true, userInitiated = false,
                                          overrideSuppression = false))
    }

    /** The override is not needed to explain an unsuppressed strap, and must not change it. */
    @Test
    fun `an unsuppressed strap is unaffected by the override either way`() {
        assertTrue(shouldSendClientHello(suppressedForDevice = false, userInitiated = false))
        assertTrue(shouldSendClientHello(suppressedForDevice = false, userInitiated = false,
                                         overrideSuppression = true))
    }

    /** A user-initiated Connect already overrode the latch; the new switch must not disturb that path. */
    @Test
    fun `a user-initiated connect still wins on its own`() {
        assertTrue(shouldSendClientHello(suppressedForDevice = true, userInitiated = true,
                                         overrideSuppression = false))
    }

    /**
     * The give-up must still fire while the override is sending hellos.
     *
     * `shouldCountNeverBondedSelfDrop` skips counting when the hello was withheld — correct, because a
     * suppressed strap's drops are ordinary link losses, not a failing handshake. But the override leaves
     * the LATCH set while sending the hello anyway, so reading the raw pref there would disable the
     * give-up for precisely the case that needs it: an unbounded hello-drop-reconnect loop with nothing
     * to stop it. The caller passes `suppressed && !override`, which is the same expression that decided
     * to send. This pins the semantics that expression has to satisfy.
     */
    @Test
    fun `a drop counts toward the give-up whenever the hello was actually sent`() {
        // Effective suppression = the latch AND no override. These are the four combinations.
        fun effectivelySuppressed(latched: Boolean, override: Boolean) = latched && !override
        assertTrue(effectivelySuppressed(latched = true, override = false))    // withheld: do not count
        assertFalse(effectivelySuppressed(latched = true, override = true))    // SENT: must count
        assertFalse(effectivelySuppressed(latched = false, override = false))  // sent normally: counts
        assertFalse(effectivelySuppressed(latched = false, override = true))   // sent: counts
        // And the send decision agrees with it in every case.
        for (latched in listOf(true, false)) for (ov in listOf(true, false)) {
            val sent = shouldSendClientHello(latched, userInitiated = false, overrideSuppression = ov)
            assertTrue("counting must be the inverse of withholding",
                       sent != effectivelySuppressed(latched, ov))
        }
    }

    // #1635: the override must bound itself — the shared give-up cannot

    /**
     * The field failure this exists for. With the override on, the hello fails with ATT
     * `Insufficient Authentication`, the local stack tears the ACL down, and the disconnect arrives as
     * GATT_CONN_TERMINATE_LOCAL_HOST (22) — which `shouldCountNeverBondedSelfDrop` excludes, because that
     * status normally means WE hung up. So nothing counted, nothing paused, and a real strap ran 57
     * reconnect cycles in an hour. The cap does not consult the status at all.
     */
    @Test
    fun `the override stops itself after the cap`() {
        assertTrue(overrideHelloStillAllowed(0))
        assertTrue(overrideHelloStillAllowed(HELLO_OVERRIDE_MAX_ATTEMPTS - 1))
        assertFalse(overrideHelloStillAllowed(HELLO_OVERRIDE_MAX_ATTEMPTS))
        assertFalse(overrideHelloStillAllowed(57))   // the observed field value
    }

    @Test
    fun `the cap is small enough to bound the loop and large enough to be a fair test`() {
        // ~4.8s per cycle, so the whole experiment costs well under a minute of churn.
        assertTrue("a cap of 1 would not survive a single flaky link", HELLO_OVERRIDE_MAX_ATTEMPTS >= 3)
        assertTrue("more than ~10 is a loop, not an experiment", HELLO_OVERRIDE_MAX_ATTEMPTS <= 10)
    }

    /** The give-up line must name the cause and the remedy, not merely announce that it stopped. */
    @Test
    fun `the exhausted line says why and what to do`() {
        val line = helloOverrideExhaustedLine(HELLO_OVERRIDE_MAX_ATTEMPTS)
        assertTrue(line.contains("unanswered hellos"))
        assertTrue(line.contains("Insufficient Authentication"))
        assertTrue(line.contains("refuses SMP pairing"))
        assertTrue("must tell the user how to get back to a working strap",
                   line.contains("Turn the switch off"))
    }

    /**
     * The budget must only be charged for hellos the override CAUSED.
     *
     * `shouldSendClientHello` also returns true for a strap that is neither suppressed nor deferring a
     * bond — that hello goes out regardless of the switch. Charging those would retire the experiment
     * after six ordinary connects without it ever having done anything, and then report "6 unanswered
     * hellos" about writes it never caused.
     */
    @Test
    fun `the budget is charged only when the override is load-bearing`() {
        fun charges(suppressed: Boolean, bondDeferred: Boolean, override: Boolean, userAsked: Boolean) =
            shouldSendClientHello(suppressed, userAsked, override) &&
                override && !userAsked && (suppressed || bondDeferred)

        // Load-bearing: the hello would NOT have gone out without the override.
        assertTrue(charges(suppressed = true, bondDeferred = false, override = true, userAsked = false))
        assertTrue(charges(suppressed = false, bondDeferred = true, override = true, userAsked = false))
        // Not load-bearing: nothing was standing in the hello's way.
        assertFalse(charges(suppressed = false, bondDeferred = false, override = true, userAsked = false))
        // A user-initiated Connect already overrides the latch on its own.
        assertFalse(charges(suppressed = true, bondDeferred = false, override = true, userAsked = true))
        // Switch off: never charged.
        assertFalse(charges(suppressed = true, bondDeferred = true, override = false, userAsked = false))
    }

    /**
     * The give-up line must still fire if the counter steps PAST the cap. `++` on a @Volatile Int is not
     * atomic, so two overlapping connects can skip the exact boundary; an `== cap` guard would then leave
     * the override inert with nothing in the log to explain it.
     */
    @Test
    fun `the give-up condition holds past the cap, not only at it`() {
        assertFalse(overrideHelloStillAllowed(HELLO_OVERRIDE_MAX_ATTEMPTS))
        assertFalse(overrideHelloStillAllowed(HELLO_OVERRIDE_MAX_ATTEMPTS + 1))
        assertFalse(overrideHelloStillAllowed(HELLO_OVERRIDE_MAX_ATTEMPTS + 7))
        // And the line reports whatever count it actually reached, not a hardcoded cap.
        assertTrue(helloOverrideExhaustedLine(9).contains("9 unanswered hellos"))
    }

    /**
     * A spent override is not "on". Every reader must agree on that, because they act in opposite
     * directions: the connect path stops writing hellos, and the never-bonded detector must go back to
     * counting self-drops. Reading the raw pref made the detector believe hellos were still on the wire
     * after they had stopped.
     */
    @Test
    fun `the override is only in force while opted in AND under the cap`() {
        assertTrue(helloOverrideActive(optedIn = true, attemptsSoFar = 0))
        assertTrue(helloOverrideActive(optedIn = true, attemptsSoFar = HELLO_OVERRIDE_MAX_ATTEMPTS - 1))
        assertFalse(helloOverrideActive(optedIn = true, attemptsSoFar = HELLO_OVERRIDE_MAX_ATTEMPTS))
        assertFalse(helloOverrideActive(optedIn = true, attemptsSoFar = HELLO_OVERRIDE_MAX_ATTEMPTS + 3))
        assertFalse(helloOverrideActive(optedIn = false, attemptsSoFar = 0))
    }

    /**
     * The never-bonded detector's input, spelled out end to end: `latch && !active`. A spent override
     * must report the hello as withheld, or the detector keeps counting drops the hello no longer causes
     * and eventually pauses auto-reconnect over a cause that never happened.
     */
    @Test
    fun `a spent override reports the hello as withheld again`() {
        fun withheld(latched: Boolean, optedIn: Boolean, attempts: Int) =
            latched && !helloOverrideActive(optedIn, attempts)

        assertTrue(withheld(latched = true, optedIn = false, attempts = 0))
        // In force: the hello IS on the wire, so the detector must stay armed.
        assertFalse(withheld(latched = true, optedIn = true, attempts = 0))
        // Spent: the hello has genuinely stopped, so we are back to the suppressed live-HR state.
        assertTrue(withheld(latched = true, optedIn = true, attempts = HELLO_OVERRIDE_MAX_ATTEMPTS))
        // No latch, nothing withheld, whatever the switch says.
        assertFalse(withheld(latched = false, optedIn = true, attempts = HELLO_OVERRIDE_MAX_ATTEMPTS))
    }

    /** Only the off->on edge re-arms, so a spent override does not silently resurrect on every connect. */
    @Test
    fun `flipping the switch back on re-arms the budget, staying on does not`() {
        assertTrue(helloOverrideBudgetRearms(optedInNow = true, optedInLastSeen = false))
        assertFalse(helloOverrideBudgetRearms(optedInNow = true, optedInLastSeen = true))
        assertFalse(helloOverrideBudgetRearms(optedInNow = false, optedInLastSeen = true))
        assertFalse(helloOverrideBudgetRearms(optedInNow = false, optedInLastSeen = false))
    }
}
