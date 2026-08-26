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
     * Consecutive bond refusals before we pause auto-reconnect + write the epitaph. 5 (not 2, where the
     * pairing HINT already shows): the hint asks the user to act; we give them several reconnect cycles to
     * do it before we stop hammering. A genuinely held/stale strap reaches 5 within a couple of minutes.
     */
    private val giveUpThreshold: Int = 5,
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
     */
    fun recordRefusal(): Boolean {
        refusals += 1
        if (!gaveUp && refusals >= giveUpThreshold) {
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
