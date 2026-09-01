package com.noop.ble

/**
 * When the app may clear a STALE platform pairing on the user's behalf.
 *
 * A bonded fast-path connect that drops before it ever reaches a session means the OS is holding a bond
 * the strap no longer honours — a firmware update, or the official WHOOP app re-bonding, leaves Android
 * with a pairing the band has forgotten. NOOP has always detected this ([WhoopBleClient] logs "stale OS
 * bond") and, from the second failure, shown the forget-and-re-pair guide. Asking is the right first
 * move, and it stays: this is what happens when asking did not work.
 *
 * OFF by default and behind its own switch, per the rule every strap-affecting probe in
 * [PuffinExperiment] follows. `removeBond()` deletes a pairing from the phone's Bluetooth settings —
 * at least as consequential as `createBond()` forming one, which [shouldRequestExplicitBond] already
 * gates the same way — so it must not ride in on consent given for something else.
 *
 * Independently arrived at by OpenStrap/edge, whose gen5 bootstrap removes the platform bond once after
 * five consecutive exchange failures and clears the counter only when a connect reaches READY. The
 * threshold and the once-only shape are taken from that behaviour as a fact; none of its code is.
 *
 * PARITY: Android-only, and the reason is IDENTITY rather than a missing API — worth stating precisely,
 * because "CoreBluetooth has no bond-removal call" is true but is not the whole blocker and invites
 * someone to go looking for a way round it.
 *
 * Apple DETECTS the same condition and gives the same advice: `BLEManager`'s `didFailToConnect` handles
 * `CBError.peerRemovedPairingInformation` and publishes a forget-and-re-pair guide naming the strap. It
 * simply cannot perform the step.
 *
 *  - iOS: the same identity problem, with nothing else to reach for. The app's own guide already tells
 *    the user to do it in Settings, which is the honest answer rather than a claim about Apple's intent.
 *  - macOS ships `IOBluetooth`, a separate classic-Bluetooth framework. Whether its device removal
 *    works on a BLE pairing is a question that never arises: it addresses devices by MAC, and Apple's
 *    side never has one — `BLEManager.epitaphLine`'s doc already states it, the peripheral UUID being
 *    "per-install, not the hardware address". The only bridge left is matching
 *    `IOBluetoothDevice.pairedDevices()` by NAME, and deleting a pairing on a name match is precisely the
 *    mistake this file's guards exist to prevent: two straps, or a renamed device, and it removes the
 *    wrong one.
 *
 * So the gap is real and stays: both platforms detect and ask, only this one can act. If CoreBluetooth
 * ever exposes the hardware address, or grows a removal call of its own, revisit it — do not close it
 * with a name match.
 */

/**
 * Consecutive stale-bond failures before the pairing is cleared automatically.
 *
 * Five, not the two at which the guide appears: the guide asks the user to do this themselves, and they
 * deserve several reconnect cycles to act before the app does it for them. A strap whose pairing really
 * is stale reaches five within a couple of minutes, and every one of those cycles is a failed connect.
 */
internal const val STALE_BOND_REMOVAL_THRESHOLD = 5

/**
 * Should this disconnect clear the platform pairing?
 *
 * Every clause is load-bearing:
 *  - [optedIn]: default-off, see the file note. No switch, no bond removal, ever.
 *  - [isWhoop5]: a 4.0 bonds by the route it always has. This failure mode is the 5/MG fast-path one,
 *    and removing a WHOOP 4 pairing would break a link that works.
 *  - [osBonded]: nothing to remove otherwise, and calling it anyway would log a failure that means
 *    nothing.
 *  - [consecutiveStaleFailures]: the streak, not a single drop — one stale-looking disconnect is a
 *    transient, and this is not an action to take on a transient.
 *  - [alreadyRemovedThisRun]: exactly ONCE per streak. Removing a bond and immediately failing again
 *    means the bond was not the problem, and repeating it would delete a pairing per reconnect for a
 *    cause it cannot fix. Cleared only by a genuine bond, which is the event that proves the strap and
 *    the phone agree again.
 */
internal fun shouldRemoveStaleBond(
    optedIn: Boolean,
    isWhoop5: Boolean,
    osBonded: Boolean,
    consecutiveStaleFailures: Int,
    alreadyRemovedThisRun: Boolean,
    threshold: Int = STALE_BOND_REMOVAL_THRESHOLD,
): Boolean {
    if (!optedIn) return false
    if (!isWhoop5) return false
    if (!osBonded) return false
    if (alreadyRemovedThisRun) return false
    return consecutiveStaleFailures >= threshold
}

/**
 * The one line that says what was done and whether the OS accepted it.
 *
 * `removeBond()` is not public API and is reached by reflection, so "we asked" and "it happened" are
 * genuinely different outcomes and the log must not conflate them. No PII: no MAC, no serial.
 */
internal fun staleBondRemovalLine(failures: Int, accepted: Boolean): String =
    if (accepted) {
        "Stale pairing: cleared the phone's Bluetooth pairing for this strap after $failures failed " +
            "bonded connects. Android accepted the request; the next connect starts from an unpaired " +
            "state, which is what the re-pair guide was asking you to do by hand (#1635)."
    } else {
        "Stale pairing: asked Android to clear this strap's pairing after $failures failed bonded " +
            "connects and it REFUSED (removeBond is not public API and can be denied). Nothing has " +
            "changed - clear it yourself in Settings > Bluetooth, as the re-pair guide describes."
    }
