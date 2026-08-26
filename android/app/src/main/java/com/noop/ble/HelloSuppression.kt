package com.noop.ble

/**
 * Whether to send the WHOOP 5/MG CLIENT_HELLO at all on this connect.
 *
 * The #1635 field captures show the hello is what ends the link. Across two sessions and sixteen writes it
 * was never once acknowledged, and the drop is locked to the HELLO rather than to the connect: 3.158s,
 * 3.159s, 3.155s after the write, cycle after cycle, while live HR streams happily over the standard
 * profile the whole time. The bond-state trace added for this (#1639) records no OS pairing attempt at all,
 * so the strap is not refusing a pairing — the write simply never completes and the local stack drops the
 * ACL, which the log reports as an unattributed GATT status 22.
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
 */
internal fun shouldSendClientHello(
    suppressedForDevice: Boolean,
    userInitiated: Boolean,
): Boolean = !suppressedForDevice || userInitiated

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
