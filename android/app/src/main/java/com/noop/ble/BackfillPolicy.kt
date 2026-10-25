package com.noop.ble

import kotlin.math.min
import kotlin.math.pow

/**
 * What prompted a historical-offload attempt. Mirror of the Swift `BackfillTrigger`
 * (Strand/BLE/BackfillPolicy.swift): the same six cases so [BackfillPolicy.shouldRun] gates
 * byte-identically across platforms (the cross-platform parity contract).
 */
enum class BackfillTrigger {
    /** The repeating 900s timer while connected + bonded. */
    PERIODIC,

    /** A (re)connect / bond confirmation. */
    CONNECT,

    /** The app became active (foreground). */
    FOREGROUND,

    /** The user tapped "Sync now". */
    MANUAL,

    /** An incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog). */
    STRAP,

    /** #364: an immediate back-to-back continuation of a deep oldest-first backlog, and the bounded
     *  WHOOP-5 history retry. Un-floored by design; its runaway protection lives in the caller's
     *  consecutive-cap, not here. */
    AUTO_CONTINUE,
}

/**
 * Pure rate-limiter for historical-offload kicks. No BLE/store deps. Floors match WHOOP
 * (observed: ~15-min periodic + expedited event syncs). Exact port of the Swift `BackfillPolicy`
 * (Strand/BLE/BackfillPolicy.swift) — the constants, the empty-streak backoff curve, and the
 * per-trigger rules are kept byte-identical so Android and macOS throttle the same way. Ports the
 * gate that [WhoopBleClient.requestSync] previously flagged as unported on Android, so a strap that
 * keeps offloading nothing (off-wrist / not banking) stops being re-polled every 15 min.
 */
object BackfillPolicy {
    const val PERIODIC_FLOOR_SECONDS = 900.0 // 15 min
    const val EVENT_FLOOR_SECONDS = 90.0 // absorbs reconnect-flaps / event bursts
    const val EMPTY_BACKOFF_THRESHOLD = 3 // empties before the floor starts stretching
    const val MAX_EMPTY_BACKOFF = 4.0 // cap -> ~6-min event / 1-hr periodic floor

    /**
     * [emptyStreak] = consecutive COMPLETED offloads that banked no sensor records (EmptySyncTracker).
     * Past [EMPTY_BACKOFF_THRESHOLD] the AUTOMATIC triggers ([BackfillTrigger.PERIODIC] /
     * [BackfillTrigger.STRAP]) stretch their floor — each further empty doubles it, capped at
     * [MAX_EMPTY_BACKOFF] — so an off-wrist / not-banking strap that still emits EVENT packets every 90s
     * isn't re-offloaded every 90s, draining its battery and ours (#77/#120/#216). [BackfillTrigger.MANUAL]
     * / [BackfillTrigger.CONNECT] / [BackfillTrigger.FOREGROUND] never back off, and the first real record
     * resets the streak, so baseline cadence resumes instantly — a user- or connection-driven sync is
     * never delayed.
     *
     * [clockUntrusted] = the strap's own RTC currently reads future-dated (#928). Such a strap still
     * BANKS real rows every pass, so it never trips [emptyStreak], yet chasing its future-dated range is
     * near-useless (#1012) while each ~60s offload holds the link — so PERIODIC/STRAP are SKIPPED ENTIRELY
     * while the clock is untrusted. The per-connection CONNECT pass still runs, so a clock that later
     * self-corrects is picked up on the next connection (or a manual sync).
     *
     * [automaticFloorSeconds] applies the active Power saving cadence to BOTH automatic triggers.
     * Otherwise strap events bypass the slower periodic timer through the 90 s event floor. Zero
     * preserves normal event-driven syncing; max composes it with empty backoff without multiplying it.
     */
    fun shouldRun(
        trigger: BackfillTrigger,
        nowSeconds: Double,
        lastBackfillAtSeconds: Double?,
        emptyStreak: Int = 0,
        clockUntrusted: Boolean = false,
        automaticFloorSeconds: Double = 0.0,
    ): Boolean {
        val last = lastBackfillAtSeconds ?: return true
        val elapsed = nowSeconds - last
        val backoff: Double = if (emptyStreak >= EMPTY_BACKOFF_THRESHOLD) {
            min(2.0.pow((emptyStreak - EMPTY_BACKOFF_THRESHOLD + 1).toDouble()), MAX_EMPTY_BACKOFF)
        } else {
            1.0
        }
        return when (trigger) {
            // Never floored: user-tapped, and the #364 expedited backlog drain / bounded history retry
            // (bounded by the caller's consecutive-cap, not here).
            BackfillTrigger.MANUAL, BackfillTrigger.AUTO_CONTINUE -> true
            BackfillTrigger.CONNECT, BackfillTrigger.FOREGROUND -> elapsed >= EVENT_FLOOR_SECONDS
            BackfillTrigger.STRAP -> !clockUntrusted && elapsed >= maxOf(EVENT_FLOOR_SECONDS * backoff, automaticFloorSeconds)
            BackfillTrigger.PERIODIC -> !clockUntrusted && elapsed >= maxOf(PERIODIC_FLOOR_SECONDS * backoff, automaticFloorSeconds)
        }
    }
}
