package com.noop.ble

/**
 * #971: paces the WHOOP 4.0 bond-handshake watchdog (#50) so a genuinely SLOW bond gets progressively
 * more time before the link is bounced, and a strap whose handshake never completes stops bouncing after
 * a capped number of tries instead of looping forever.
 *
 * The failure this fixes is DISTINCT from the #617 [PostBondTimeoutLoopDetector] loop: #617 is a strap
 * that DOES reach a genuine encrypted bond and then drops ~1s later with a real GATT_CONN_TIMEOUT (status
 * 0x08). #971 is the handshake never LANDING inside the fixed 7s window at all — the CCCD subscribe +
 * confirmed bond write is slow on some phone/strap pairings, the #50 watchdog fires mid-handshake and
 * bounces the link with `gatt.disconnect()`, which the stack reports as GATT_CONN_TERMINATE_LOCAL_HOST
 * (status 22 / 0x16, a LOCAL-host terminate, NOT the 0x08 the #617 detector keys on). Because
 * STATE_CONNECTED is reached every cycle, [WhoopBleClient.resetReconnectBackoff] zeroes the reconnect
 * backoff on each pass, so the bond phase itself never backs off — bond → 7s → bounce → reconnect →
 * bond → 7s → bounce, indefinitely, and the user never sees a re-pair guide.
 *
 * The fix has three parts, all decided here so they're unit-testable without a BLE seam (same shape as
 * [PostBondTimeoutLoopDetector] / [BondRefusalGiveUp]):
 *
 *  1. ESCALATE the watchdog window per consecutive bounce ([windowMsForAttempt]) so a slow-but-healthy
 *     handshake that just needs 9-10s gets it on the second/third try instead of being bounced forever at
 *     a too-tight 7s. Capped so a truly dead handshake can't wait minutes.
 *  2. COUNT consecutive bounces ([recordBounce]); the streak survives the intermediate STATE_CONNECTED
 *     (unlike the reconnect backoff), and is cleared only by a genuine bond ([reset]) or an explicit user
 *     reconnect — exactly like [bondRefusalStreak] / [BondRefusalGiveUp].
 *  3. GIVE UP after [giveUpThreshold] bounces ([shouldGiveUp]): stop bouncing, surface the EXISTING
 *     re-pair guide and pause auto-reconnect (reusing the #747/#844 pause machinery), so a strap that
 *     genuinely can't finish the handshake stops draining the battery.
 *
 * This is an ANDROID-ONLY fix: the bond watchdog itself only exists on Android (iOS's CoreBluetooth owns
 * bonding and never needed a handshake watchdog), so there is no Swift twin to keep in parity.
 *
 * Reimplemented under NoopApp; no upstream code adopted.
 */
class BondWatchdogBackoff(
    /** The first (tightest) watchdog window, matching the historical fixed 7s #50 timeout. */
    private val baseWindowMs: Long = 7_000L,
    /** Extra time added to the window per prior bounce (attempt 1 → base, 2 → base+step, ...). */
    private val stepMs: Long = 3_000L,
    /** Ceiling — a slow handshake gets at most this long before a bounce, so a dead one can't hang. */
    private val maxWindowMs: Long = 16_000L,
    /**
     * Consecutive bounces before we STOP bouncing and hand off to the re-pair guide + auto-reconnect
     * pause. 4 (not the #617 detector's 2): each bounce here also costs a full reconnect + rediscover, so
     * we give a slow-but-recoverable handshake several escalating windows (7s, 10s, 13s, 16s) before we
     * declare it stuck, which is generous enough that a genuinely healthy slow bond lands first.
     */
    private val giveUpThreshold: Int = 4,
) {
    /** Consecutive bond-watchdog bounces with no genuine bond in between. Drives the window escalation. */
    var consecutiveBounces = 0
        private set

    /**
     * The subset of [consecutiveBounces] that actually says something about BONDING, and the only one
     * [giveUpThreshold] is measured against.
     *
     * A bounce is attributable only when the link reached the phase this watchdog is for. On a marginal
     * link an MTU negotiation can take 14-17s against a 1.5s expected wait, so service discovery has not
     * returned when the window expires: nothing was discovered, no handshake was written, and the strap
     * was never asked anything. Counting that toward the give-up is how a range problem came to pause
     * auto-reconnect for 5h 57m while reporting "strap keeps refusing to pair" — with `writeInFlight=false`
     * in the same line. Escalating the WINDOW on those bounces is still right (a slow link should get
     * longer), which is why the two counters are separate rather than one gated counter.
     */
    var attributableBounces = 0
        private set

    /** True once [giveUpThreshold] bounces have accrued — the caller must stop bouncing and hand off. */
    var gaveUp = false
        private set

    /**
     * The watchdog window to arm for the NEXT handshake, given the bounces seen so far. Escalates from
     * [baseWindowMs] by [stepMs] per prior bounce, capped at [maxWindowMs]. With 0 bounces this is the
     * historical 7s, so the first, common healthy connect is UNCHANGED.
     */
    fun currentWindowMs(): Long = windowMsForAttempt(consecutiveBounces)

    /** Pure window schedule: [priorBounces] = how many bounces have already happened (0-based). */
    fun windowMsForAttempt(priorBounces: Int): Long {
        val n = priorBounces.coerceAtLeast(0)
        val window = baseWindowMs + stepMs * n
        return window.coerceAtMost(maxWindowMs)
    }

    /**
     * Record one bond-watchdog bounce (the handshake didn't land inside its window). Returns true if THIS
     * bounce freshly crossed [giveUpThreshold] — the caller then stops bouncing and surfaces the re-pair
     * guide + pauses auto-reconnect exactly once.
     *
     * [attributable] is whether this bounce is evidence about BONDING: false when the link never reached
     * the bond phase at all, which on a weak link is the common case rather than an edge one. It has NO
     * default on purpose. A default is how a counter comes to count things nobody decided it should, and
     * that is the whole of the bug this parameter exists to end. An
     * unattributable bounce still escalates the window — it is still a link that did not get where it
     * needed to in time — but it can never trip the give-up, because there is nothing to give up ON.
     */
    fun recordBounce(attributable: Boolean): Boolean {
        consecutiveBounces += 1
        if (!attributable) return false
        attributableBounces += 1
        if (!gaveUp && attributableBounces >= giveUpThreshold) {
            gaveUp = true
            return true
        }
        return false
    }

    /** Whether the caller should give up bouncing now (already at/over the threshold). */
    fun shouldGiveUp(): Boolean = gaveUp

    /** Bounces that said nothing about bonding, because the link never reached the command channel. */
    val unattributableBounces: Int get() = consecutiveBounces - attributableBounces

    /**
     * Should the caller STOP bouncing links that never reached the command channel?
     *
     * Bouncing is bounded in both directions or it is not bounded at all. Excusing these bounces from the
     * give-up (which is right — they are no evidence about pairing) would otherwise hand them an infinite
     * loop instead: a link that never completes discovery would be dropped every window, forever, which
     * is precisely the battery drain [giveUpThreshold] was introduced to end.
     *
     * The CONSEQUENCE differs, and that is the whole point of keeping them apart. Reaching the pairing
     * give-up pauses auto-reconnect and tells the user to re-pair. Reaching this one only stops the
     * bouncing: auto-reconnect keeps running, because a weak link is transient and the next attempt may
     * well succeed, and the link is left up, because the standard HR profile can still be delivering the
     * only data a strap that cannot bond will ever give (#1635).
     */
    fun shouldStopBouncingWithoutCommandChannel(): Boolean = unattributableBounces >= giveUpThreshold

    /**
     * Clear the streak: a genuine bond landed, or the user explicitly reconnected. Re-arms the tight
     * base window and lets a later slow handshake escalate afresh.
     */
    fun reset() {
        consecutiveBounces = 0
        attributableBounces = 0
        gaveUp = false
    }
}
