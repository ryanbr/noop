package com.noop.ble

/**
 * Mirror of the Swift `BondRefusalGiveUp` (Strand/BLE/BLEManager.swift).
 *
 * #747 / #750: decides when a strap that keeps REFUSING the encrypted bond
 * (INSUFFICIENT_AUTHENTICATION/_ENCRYPTION, no genuine bond in between) has refused enough times that
 * hammering it further is pointless. Two responsibilities, both pure so they're unit-testable without a
 * BLE seam:
 *
 *  - #747 PAUSE: after [giveUpThreshold] consecutive refusals the auto-reconnect should STOP re-kicking
 *    (it can't bond without the user freeing the strap / re-pairing), so the caller pauses the rescan and
 *    surfaces an honest hint instead of looping forever and draining the battery.
 *  - #750 EPITAPH: at the same moment, emit ONE summary "epitaph" line recording how the bond attempt
 *    died (the streak + an opaque, install-local id), so a shared strap log carries the cause without any
 *    PII (no MAC, no serial, just the count and a short opaque token).
 *
 * The streak accumulates across the reconnect loop (a disconnect does NOT reset it) and is cleared only by
 * a genuine bond or an explicit user reconnect, exactly like the client's existing [bondRefusalStreak].
 */
class BondRefusalGiveUp(
    /**
     * Consecutive bond refusals before we PAUSE auto-reconnect + write the epitaph. 5 (not 2, where the
     * pairing HINT already shows): the hint asks the user to act; we give them several reconnect cycles to
     * do it before we stop hammering. A genuinely held/stale strap reaches 5 within a couple of minutes.
     *
     * This is the AUTH-REFUSAL number specifically, and [recordRefusal] takes a per-refusal override for
     * that reason: an unanswered handshake asks the user for nothing, so waiting five cycles for a decision
     * they cannot make just buys ~4.8s link drops. See [giveUpThresholdFor].
     */
    val giveUpThreshold: Int = 5,
) {
    var refusals = 0
        private set

    /**
     * True once [giveUpThreshold] is reached: auto-reconnect should pause and the epitaph has been (or
     * should be) written. Stays true until [reset] so the pause holds across the loop.
     */
    var gaveUp = false
        private set

    /**
     * Record one bond refusal. Returns true if THIS refusal freshly crossed the give-up threshold (so the
     * caller pauses the reconnect + writes the epitaph exactly once).
     *
     * [threshold] defaults to the constructed [giveUpThreshold]; callers that can tell the two give-up
     * CAUSES apart pass the one for the refusal in hand ([giveUpThresholdFor]). The latch is still reported
     * exactly once whatever the threshold, so a lower one moves the crossing without duplicating it.
     */
    fun recordRefusal(threshold: Int = giveUpThreshold): Boolean {
        refusals += 1
        if (!gaveUp && refusals >= threshold) {
            gaveUp = true
            return true
        }
        return false
    }

    /** Clear the streak: a genuine bond landed, or the user explicitly reconnected. Re-arms auto-reconnect. */
    fun reset() {
        refusals = 0
        gaveUp = false
    }

    companion object {
        /**
         * #750: the one-line bond-refusal EPITAPH. Records the streak + an OPAQUE install-local id only,
         * never a MAC or serial. [opaqueId] should be a short token derived from the per-install local
         * device id, which carries no PII. Pure so a fixture pins it. No em-dash (project rule).
         * Byte-identical to the Swift `BondRefusalGiveUp.epitaphLine`.
         */
        fun epitaphLine(refusals: Int, opaqueId: String): String =
            "Bond epitaph: the strap [$opaqueId] refused the encrypted bond ${refusals}x in a row with no " +
                "successful bond - giving up auto-reconnect to stop hammering it. It is almost certainly " +
                "held by the official WHOOP app or a stale phone pairing. Free it (close the WHOOP app, put " +
                "the strap in pairing mode, forget it in Bluetooth settings) then reconnect in NOOP."

        /**
         * #747: the honest user-facing hint shown when auto-reconnect pauses. Tells them WHY it stopped and
         * how to get going again. Pure; no em-dash. Byte-identical to the Swift `BondRefusalGiveUp.pausedHint`.
         */
        fun pausedHint(): String =
            "NOOP stopped retrying because your strap keeps refusing to pair. It is likely still held by the " +
                "official WHOOP app, or your phone is holding an old pairing. Close the WHOOP app, put the " +
                "strap in pairing mode (tap until the LEDs flash blue), and if it is listed in your Bluetooth " +
                "settings choose Forget This Device. Then tap Connect to try again."

        /**
         * #1635: the hint for a strap whose CLIENT_HELLO is never acknowledged, where NOOP now stays
         * connected with the handshake switched off rather than pausing.
         *
         * Deliberately does NOT say "paused" (nothing is paused) and does NOT name a cause. An unanswered
         * write is not evidence the strap is held by the official app, and the epitaph that asserts that is
         * reserved for an actual auth refusal. Says what was observed and what the user still gets.
         *
         * #1635 follow-up: it used to end "Tap Connect to try the handshake again", which framed a strap
         * that REFUSES pairing as a retryable failure. A field report read all of this and still asked how
         * to fix it, so the ending now leads with pairing mode (reported once on #1635, hedged) and keeps
         * Connect as the follow-up. It also no longer claims HRV and resting heart rate are unavailable:
         * since #1884 an HR-only night reports both.
         *
         * Pure; no em-dash. Byte-identical to the Swift `BondRefusalGiveUp.helloSuppressedHint`.
         */
        fun helloSuppressedHint(): String =
            "The secure handshake with your strap never completes, and the attempt itself is what drops t" +
            "he link. NOOP has switched it off for this strap so live heart rate keeps streaming. History" +
            " sync stays unavailable until it pairs, and so do motion, skin temperature, SpO₂ and respira" +
            "tory rate, so sleep is staged from heart rate alone. Some straps have paired again after bei" +
            "ng put in pairing mode. Tap until the LEDs flash blue, then tap Connect."

        /**
         * #1635: the log epitaph for the suppression path.
         *
         * Separate from [epitaphLine] because that one asserts a cause ("almost certainly held by the
         * official WHOOP app") that only an auth refusal supports. Reusing it here would print a confident
         * explanation for a write that simply vanished.
         *
         * Pure. Byte-identical to the Swift `BondRefusalGiveUp.helloSuppressedEpitaph`.
         */
        fun helloSuppressedEpitaph(refusals: Int, opaqueId: String): String =
            "Bond epitaph: the strap [$opaqueId] never acknowledged the secure handshake ${refusals}x in a " +
                "row, and the attempt is what drops the link - leaving the handshake off so live heart " +
                "rate keeps streaming. Tap Connect to try it again."

        /**
         * The paused hint for a bond that failed WITHOUT the strap ever answering (#1635).
         *
         * [pausedHint] names a cause — the strap still held by the official WHOOP app, or a stale OS
         * pairing — which is well founded when the refusal arrived as INSUFFICIENT_AUTHENTICATION or
         * INSUFFICIENT_ENCRYPTION: the strap actively said no. It is NOT founded when the CLIENT_HELLO
         * simply goes unanswered and the link drops on a timer, which is a different observation with
         * several possible causes. Telling that user to close the WHOOP app would be a guess dressed as
         * instruction, and if it is wrong they have no way to know.
         *
         * So this describes what was observed and offers the one action that is definitely theirs to
         * take, without asserting why. Pure; no em-dash.
         */
        fun pausedHintHandshakeUnanswered(): String =
            "NOOP stopped retrying because the secure handshake with your strap never completes: the " +
                "strap does not answer, and the link drops a few seconds later. Auto-reconnect is paused " +
                "so it stops draining both batteries. Tap Connect to try again, and if it keeps happening " +
                "please share your strap log."

        /**
         * #1997: the three inputs the guide choice turns on, logged at the pause.
         *
         * The held-link branch is now deliberately conservative: it fires only when the OS itself reports
         * the connection still held. Nothing in the field log that prompted it actually shows that signal
         * on the silent links, because those took the give-up path, which prints no ACL marker. So the
         * branch may be right and may simply never fire, and without this line the next log would not say
         * which.
         *
         * The counters ship rather than just the behaviour, for the same reason the windowed-read ones do.
         *
         * [held] is PASSED IN rather than re-derived here. Restating `heldLinkWithoutTraffic`'s rule in a
         * second file would let the line report a verdict the code did not reach the moment either copy
         * changed. The caller evaluates the predicate once and hands the answer to both this and the guide,
         * so all three cannot disagree.
         */
        fun heldLinkDiagLine(aclHeld: Boolean, inboundFrames: Int, held: Boolean): String =
            "held-link check: aclHeld=$aclHeld inbound=$inboundFrames -> ${if (held) "held" else "not held"}"

        /**
         * #1997: which reconnect guide the never-bonded pause should show.
         *
         * Pure so the SELECTION is pinned and not just the two texts. Testing a predicate and a string
         * separately proves neither is wired to the other, and an inline `if` in a BLE callback cannot be
         * reached from a JVM test at all. Same shape as the other decisions in this file.
         */
        fun reconnectGuideFor(heldLink: Boolean): String =
            if (heldLink) heldLinkGuide() else stalePairingGuide()

        /**
         * The long-standing guide: a stale pairing, or the official app holding the strap. Correct advice
         * when the strap really is refusing, and the default whenever there is no evidence of a held link.
         */
        fun stalePairingGuide(): String =
            """
            Your strap connects but never finishes pairing with NOOP, so it drops and retries in a loop. This is almost always a stale Bluetooth pairing, usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

            1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
            2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
            3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
            4. Come back here and tap Connect.
            """.trimIndent()

        /**
         * #1997: the reconnect GUIDE for a held link, replacing the re-pair steps for this state only.
         *
         * The re-pair guide's four steps are the right advice when a stale pairing is the cause. They are
         * actively harmful here: nothing was exchanged for the strap to refuse, so forgetting the pairing
         * and re-pairing changes nothing, and the reporter was doing it several times a day.
         *
         * Auto-reconnect still pauses, which is what stops both batteries draining on a retry loop. Only
         * the explanation and the actions change.
         */
        fun heldLinkGuide(): String =
            """
            Your phone is still holding a Bluetooth connection to your strap, and your strap is not
            answering on it: the connection size negotiation is refused and no data arrives. Re-pairing
            will not change this, so it is not worth doing.

            1. Turn Bluetooth off and back on. That releases the held connection.
            2. If you have the official WHOOP app installed, quit it too. A strap talks to one phone at a time.
            3. Come back here and tap Connect.
            """.trimIndent()

        /**
         * #750: a short OPAQUE token for the epitaph, derived from the strap's device id.
         *
         * DIVERGENCE FROM SWIFT (deliberate, PII): on iOS the source is a CoreBluetooth-local UUID
         * (per-install, NOT a hardware address), so the Swift twin can keep its hex prefix directly. On
         * Android the strap id IS a MAC address (PII), so we must NEVER expose its bytes. We therefore HASH
         * it (SHA-256, first 8 hex of the digest) so the token is stable within a log, lets us tell two
         * straps apart, but is irreversible and carries no device-identifying PII. Pure + deterministic.
         */
        fun opaqueId(localId: String): String = try {
            val digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest(localId.lowercase().toByteArray(Charsets.UTF_8))
            digest.take(4).joinToString("") { "%02x".format(it) }
        } catch (t: Throwable) {
            // Defense-in-depth: never let id-formatting throw into the bond path. A safe constant token
            // still keeps the MAC out of the log.
            "device"
        }
    }
}
