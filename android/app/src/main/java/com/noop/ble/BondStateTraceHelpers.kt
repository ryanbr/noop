package com.noop.ble

import com.noop.protocol.DeviceFamily

/**
 * Does this disconnect count as the strap refusing to bond?
 *
 * Two observations mean the same thing for the purpose of giving up: the strap answered the bond write
 * with INSUFFICIENT_AUTHENTICATION / INSUFFICIENT_ENCRYPTION, or it never answered the CLIENT_HELLO at
 * all. The second was invisible to the give-up until now, because the gate tested only the status — and
 * an unanswered handshake presents as a plain local terminate (status 22). The consequence, measured on
 * a real strap: eight consecutive connect attempts all logging "attempt 1", retrying every ~11 seconds
 * indefinitely, because the streak never incremented and the give-up never latched.
 *
 * Deliberately does NOT widen what counts as an AUTH refusal — [helloUnacked] is a separate signal
 * carried separately, so the user-facing guidance can stay honest about which was observed. An auth
 * refusal supports naming a cause; an unanswered handshake does not.
 *
 * Pure so the rule is unit-tested without a radio.
 */
internal fun countsAsBondRefusal(
    isAuthRefusalStatus: Boolean,
    helloUnacked: Boolean,
    alreadyBonded: Boolean,
    family: DeviceFamily,
): Boolean {
    if (alreadyBonded) return false                 // bonded already — not a pairing problem
    if (family != DeviceFamily.WHOOP5) return false // the 4.0 bonds cleanly; this is the 5/MG handshake
    return isAuthRefusalStatus || helloUnacked
}
