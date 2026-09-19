package com.noop.oura

/**
 * Escalation policy for an auth handshake the ring does not answer (#2304). Kotlin twin of
 * `Packages/OuraProtocol/Sources/OuraProtocol/OuraAuthWatchdog.swift` — same timeout, same table.
 *
 * The connect sequence is link up → discover → enable notifications → `get_nonce`, and from there the
 * app waits for the nonce. Nothing else is armed until `auth OK` reaches Streaming (the re-engage tick,
 * the history-fetch timer), so a ring that accepts the link and the subscription but never answers the
 * nonce left the session parked as "connected" until the OS dropped the link for its own reasons — on
 * the #2303 capture that was 52 and 55 minutes across five consecutive links. Healthy sessions never
 * wait: every answered `get_nonce` on file gets its nonce within the same second (one 5 s outlier over
 * ~270 handshakes), and the only `get_nonce` without a nonce are the ones where the link itself dropped
 * 1–3 s later — which takes the disconnect path and cancels the watchdog before it can fire.
 *
 * Pure so it is testable without a `BluetoothGatt`; the transport owns the timer and the writes, and
 * asks this table what to do when the timer fires. Every step is one the transport already makes on
 * every connection (a `get_nonce` write, a CCCD toggle, a disconnect) — nothing new is sent to the
 * ring, and silence is never turned into a pairing verdict.
 */
object OuraAuthWatchdog {
    /** How long a `get_nonce` may go unanswered before the first escalation. Swift: `nonceTimeout` = 10 s. */
    const val NONCE_TIMEOUT_MS = 10_000L

    /**
     * What the transport should do when the nonce timer fires. Ordered: the sequence is
     * [RESEND_NONCE] → [TOGGLE_NOTIFY] → [DROP_LINK], at most once each per session, then the link is
     * dropped and the ordinary reconnect backoff takes over. No loop.
     */
    enum class Step {
        /** Still inside the timeout (a timer fired early or was re-armed): keep waiting. */
        WAIT,
        /** Re-send `get_nonce` once (1/3) — the write may simply not have reached the ring. */
        RESEND_NONCE,
        /** Toggle the notify subscription off and back on, then re-send `get_nonce` (2/3). */
        TOGGLE_NOTIFY,
        /** Disconnect and let the normal reconnect path bring the ring back (3/3). */
        DROP_LINK,
    }

    /**
     * The escalation table. Swift twin of `OuraAuthWatchdog.step` (the Swift side takes seconds against
     * `nonceTimeout`; same thresholds, same order, same attempt semantics).
     *
     * The claim is on the FUNCTION deliberately: file authority is derived from resolved FUNCTION pairs,
     * so the twin line already on the object header above pairs nothing on its own.
     *
     * @param msSinceNonceRequest age of the most recent `get_nonce` write of this session.
     * @param attempt how many escalations have already been taken this session (0 = none yet).
     */
    fun step(msSinceNonceRequest: Long, attempt: Int): Step {
        if (msSinceNonceRequest < NONCE_TIMEOUT_MS) return Step.WAIT
        return when {
            attempt < 1 -> Step.RESEND_NONCE
            attempt == 1 -> Step.TOGGLE_NOTIFY
            else -> Step.DROP_LINK
        }
    }
}
