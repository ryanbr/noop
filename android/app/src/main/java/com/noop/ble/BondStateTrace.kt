package com.noop.ble

import android.bluetooth.BluetoothDevice

/** A `BluetoothDevice.BOND_*` constant, named. Unknown values print as-is rather than as a guess. */
internal fun bondStateName(state: Int): String = when (state) {
    BluetoothDevice.BOND_NONE -> "BOND_NONE"
    BluetoothDevice.BOND_BONDING -> "BOND_BONDING"
    BluetoothDevice.BOND_BONDED -> "BOND_BONDED"
    else -> "BOND_$state"
}

/**
 * One line per OS bond-state transition, with how long after the CLIENT_HELLO write it happened.
 *
 * NOOP has never observed `ACTION_BOND_STATE_CHANGED`, so the OS pairing flow has been invisible. That
 * is the gap that leaves #1635 undecided: a WHOOP 5/MG shows every CLIENT_HELLO going unacknowledged and
 * the link torn down locally on a clockwork timer (mean 3158 ms, 10 ms spread over nine attempts), and
 * two explanations fit equally well —
 *
 *  - the confirmed write to an encryption-requiring characteristic triggers OS pairing, which fails or
 *    times out and takes the link with it. Then this line shows `BOND_NONE -> BOND_BONDING` shortly
 *    after the write and `BOND_BONDING -> BOND_NONE` at the teardown, and the question is answered.
 *  - the write never triggers pairing at all. Then the device never enters `BOND_BONDING`, the absence
 *    is just as conclusive, and the cause lies elsewhere entirely.
 *
 * Both readings need the same evidence and neither can be inferred from what the log carries today,
 * which is why this observes rather than concludes.
 *
 * [sinceHelloMs] is null when no CLIENT_HELLO is outstanding — a transition from an unrelated pairing
 * (another app, another device) then carries no elapsed time rather than a misleading one measured from
 * a write it has nothing to do with.
 *
 * Pure so the wording is unit-tested without a radio. Android-only: CoreBluetooth performs pairing
 * opaquely and exposes no equivalent transition, so there is nothing to twin.
 */
internal fun bondStateTraceLine(
    previous: Int,
    current: Int,
    address: String?,
    sinceHelloMs: Long?,
): String {
    val who = address?.takeIf { it.isNotBlank() } ?: "unknown"
    val since = sinceHelloMs?.let { " ${it}ms after CLIENT_HELLO" } ?: ""
    val note = when {
        previous == BluetoothDevice.BOND_BONDING && current == BluetoothDevice.BOND_NONE ->
            " — pairing did NOT complete"
        current == BluetoothDevice.BOND_BONDED -> " — paired"
        else -> ""
    }
    return "bond state: ${bondStateName(previous)} -> ${bondStateName(current)} device=$who$since$note"
}

/**
 * Should this bond-state transition be traced at all?
 *
 * The receiver hears EVERY pairing on the phone - headphones, a car kit, a colleague's keyboard - and
 * the strap log is a file people attach to public issues. Recording unrelated pairings there is both
 * noise in a fixed-size rolling buffer and information about devices that have nothing to do with NOOP,
 * so the trace is scoped to the strap this app is talking to.
 *
 * Matched case-insensitively for the same reason [SourceCoordinator] matches addresses that way: the
 * stored form and the broadcast form can differ in case, and a case-sensitive compare would silently
 * trace nothing at all - the failure mode that looks exactly like "the pairing never happened", which is
 * one of the two answers this trace exists to distinguish.
 *
 * An event with NO address is traced only while a CLIENT_HELLO is outstanding: that is the window this
 * exists to observe, and outside it an anonymous transition cannot be attributed to us.
 *
 * Pure so the scoping rule is unit-tested without a radio.
 */
internal fun shouldTraceBondState(
    eventAddress: String?,
    strapAddress: String?,
    helloOutstanding: Boolean,
): Boolean {
    val ev = eventAddress?.trim().orEmpty()
    val ours = strapAddress?.trim().orEmpty()
    if (ev.isEmpty()) return helloOutstanding
    if (ours.isEmpty()) return false
    return ev.equals(ours, ignoreCase = true)
}

