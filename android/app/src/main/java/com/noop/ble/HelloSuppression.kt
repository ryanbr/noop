package com.noop.ble

/**
 * Whether to send the WHOOP 5/MG CLIENT_HELLO at all on this connect.
 *
 * The #1635 field captures show the hello is what ends the link. Across two sessions and sixteen writes it
 * was never once acknowledged, and the drop is locked to the HELLO rather than to the connect: 3.158s,
 * 3.159s, 3.155s after the write, cycle after cycle, while live HR streams happily over the standard
 * profile the whole time. The bond-state trace added for this (#1639) records no OS pairing attempt at all
 * — the write simply never completes and the local stack drops the ACL, which the log reports as an
 * unattributed GATT status 22.
 *
 * That trace was later read as "the strap is not refusing a pairing". An HCI capture disproves it: the
 * phone DOES transmit an SMP Pairing Request and the strap answers `Pairing Not Supported` (0x05). The
 * refusal is real, and it is categorical — the encrypted bond this hello was waiting behind can never
 * arrive on a 5/MG. That does not invalidate the suppression, whose evidence is about the hello's own
 * fate, but it does mean suppressing it leaves the app attempting NEITHER handshake. Hence the opt-in
 * override below.
 *
 * The result is a strap that CAN deliver live HR being knocked off every five seconds by a handshake that
 * has never once succeeded. Suppressing the hello after the give-up latches trades an unreachable
 * capability (puffin commands, history offload) for one that demonstrably works (continuous live HR) —
 * the "Live HR, not fully paired" state the app already models (#69), reached deliberately instead of
 * never at all.
 *
 * [userInitiated] always re-attempts: suppression is a fallback for automatic reconnects, never a
 * permanent verdict. Someone who puts the strap in pairing mode and presses Connect must get a fresh try,
 * and that is also how the suppression is cleared.
 *
 * Deliberately NOT re-armed by "an OS pairing exists". That looks right — a pairing is new evidence the
 * handshake might work — but the condition never goes away, so a strap that pairs and STILL will not
 * answer would have the latch bypassed on every connect for good: hello, drop at ~4.8s, reconnect,
 * forever, with the give-up powerless to stop it. That is the unbounded loop this suppression exists to
 * end, reintroduced through the back door. The explicit-bond experiment instead clears the latch ONCE at
 * the moment it asks for a pairing, which is self-limiting: the next failure re-latches and the condition
 * to clear it again does not recur.
 */
internal fun shouldSendClientHello(
    suppressedForDevice: Boolean,
    userInitiated: Boolean,
    overrideSuppression: Boolean = false,
): Boolean = !suppressedForDevice || userInitiated || overrideSuppression

/**
 * How many times the #1635 override may write an unanswered hello before it stops on its own.
 *
 * The override needs a bound that does not depend on the disconnect status, and the shared give-up cannot
 * supply one. `shouldCountNeverBondedSelfDrop` excludes `GATT_CONN_TERMINATE_LOCAL_HOST` (0x16) because
 * that normally means WE hung up — our own `gatt.disconnect()` or the bond-watchdog bounce — and counting
 * those would be self-referential. But the hello failure arrives as exactly that status: the strap answers
 * the write with ATT `Insufficient Authentication`, the local stack tries to elevate security, SMP is
 * refused, and the stack tears the ACL down. Not our teardown, same status code.
 *
 * Field result of leaving it unbounded: 57 reconnect cycles in an hour, each ~4.8s, with nothing able to
 * stop it. So the cap lives here instead — small enough to spare the battery, large enough that a strap
 * which answers on a later attempt is not written off.
 */
internal const val HELLO_OVERRIDE_MAX_ATTEMPTS = 6

/**
 * May the override write another hello, given how many it has already written unanswered?
 *
 * Counted per app process and reset on a genuine bond. A process restart resets it too, which is the
 * honest limit of an in-memory bound — but the loop it exists to stop runs within one process, and a
 * restart is not the failure mode.
 */
internal fun overrideHelloStillAllowed(
    attemptsSoFar: Int,
    cap: Int = HELLO_OVERRIDE_MAX_ATTEMPTS,
): Boolean = attemptsSoFar < cap

/**
 * Is the override actually in force — opted in AND with budget left?
 *
 * Every reader must ask through here rather than reading the pref directly. A spent override is not
 * "on": the hello genuinely stops going out, and a caller still reading the raw pref believes a hello
 * is on the wire that is not. That is the `didBond`-reader trap from CLAUDE.md pointed the other way,
 * and it had already reached [shouldCountNeverBondedSelfDrop]: with the budget spent, the app is in the
 * deliberate suppressed-hello live-HR state, but the raw pref reported the hello as still being sent, so
 * the never-bonded detector kept counting self-drops and would eventually pause auto-reconnect and raise
 * the stale-pairing guide — telling the user to re-pair for a cause that never happened.
 *
 * The boundary is deliberate: the link carrying the LAST permitted hello reads as inactive at its own
 * disconnect, because [helloOverrideAttempts] is charged when that hello is written. Under-counting that
 * one drop is the wanted behaviour — no further hello follows it, so the loop is already over, and
 * counting it could trip the pause at the exact moment the override retires.
 */
internal fun helloOverrideActive(
    optedIn: Boolean,
    attemptsSoFar: Int,
    cap: Int = HELLO_OVERRIDE_MAX_ATTEMPTS,
): Boolean = optedIn && overrideHelloStillAllowed(attemptsSoFar, cap)

/**
 * Does flipping the switch to on re-arm a spent budget?
 *
 * Turning the experiment off and on again is the user explicitly asking for another try, and without
 * this they would not get one: the counter outlives the toggle, so re-enabling a spent override does
 * nothing whatsoever — and silently, because the give-up line is one-shot and has already latched. The
 * edge is sampled per connect, which is the only moment the override can act anyway.
 */
internal fun helloOverrideBudgetRearms(optedInNow: Boolean, optedInLastSeen: Boolean): Boolean =
    optedInNow && !optedInLastSeen

/**
 * The line printed when the override gives up, so the log says why the hello stopped rather than leaving
 * a reader to notice its absence.
 */
internal fun helloOverrideExhaustedLine(attempts: Int): String =
    "WHOOP 5/MG: \"send hello despite bond refusal\" has written $attempts unanswered hellos — stopping." +
        " The strap answers the write with Insufficient Authentication and refuses SMP pairing, so the" +
        " handshake cannot complete; continuing would only loop the link. Turn the switch off to return to" +
        " the stable live-HR state (#1635)."

/**
 * Should the give-up latch suppress the hello, rather than pause auto-reconnect?
 *
 * The two give-up causes want opposite treatment, which is why they are split here rather than sharing
 * one branch:
 *
 *  - An AUTH REFUSAL means the strap actively declined the encrypted bond — typically because it is still
 *    held by the official WHOOP app. Reconnecting cannot help until the user acts, so pausing is right.
 *  - An UNANSWERED HANDSHAKE means the write vanished. The link itself is healthy and streaming, so
 *    pausing throws away working live HR to punish a handshake nobody is waiting on. Suppress the hello
 *    and stay connected instead.
 *
 * Splitting them is the whole point: before this, both ended in the same pause, so the strap that could
 * still deliver HR was treated exactly like the one that could not.
 */
internal fun giveUpSuppressesHello(authRefusal: Boolean): Boolean = !authRefusal

/**
 * SharedPreferences key holding the hello-suppression latch for one device.
 *
 * Per device, and lowercased for the same reason [firmwarePrefKey] is: the same strap can present its
 * address in different cases across sessions, and a case-sensitive key would silently latch a second time
 * under a second key instead of reading the first.
 */
internal fun helloSuppressionPrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }?.let { "noop.helloUnanswered.${it.lowercase()}" }
