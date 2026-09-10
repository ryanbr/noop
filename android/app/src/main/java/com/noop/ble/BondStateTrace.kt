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
 * The `ACTION_BOND_STATE_CHANGED` extra carrying WHY a bond ended, and the values it takes.
 *
 * Both the extra and the `UNBOND_REASON_*` constants are `@hide` in AOSP, so they are mirrored here as
 * literals rather than referenced. That is the same trade the GATT status constants in `WhoopBleClient`
 * already make; the values have been stable across every release that ships this broadcast, and a
 * hidden-API reference would not compile.
 */
internal const val EXTRA_BOND_REASON = "android.bluetooth.device.extra.REASON"

/** What `getIntExtra` returns when the OS supplied no reason. Not a code the broadcast ever sends. */
internal const val NO_BOND_REASON = -1

/**
 * A `BluetoothDevice.UNBOND_REASON_*` value, named.
 *
 * Deliberately mirrors [gattStatusLabel]: name the codes that answer the question and leave
 * anything else as a bare number. A confidently wrong name in the line whose whole job is explaining a
 * pairing failure is worse than no name, and this broadcast's vendor stacks do emit values AOSP does
 * not define.
 *
 * The distinction this exists to preserve: AUTH_FAILED ("the strap refused authentication") and
 * AUTH_TIMEOUT ("nobody answered") and REMOTE_DEVICE_DOWN ("the link went away") are three different
 * findings for #1635, and a trace that only says "pairing did NOT complete" cannot tell them apart.
 */
internal fun bondFailureReasonLabel(reason: Int): String = when (reason) {
    1 -> "reason=AUTH_FAILED(1)"
    2 -> "reason=AUTH_REJECTED(2)"
    3 -> "reason=AUTH_CANCELED(3)"
    4 -> "reason=REMOTE_DEVICE_DOWN(4)"
    5 -> "reason=DISCOVERY_IN_PROGRESS(5)"
    6 -> "reason=AUTH_TIMEOUT(6)"
    7 -> "reason=REPEATED_ATTEMPTS(7)"
    8 -> "reason=REMOTE_AUTH_CANCELED(8)"
    9 -> "reason=REMOVED(9)"
    else -> "reason=$reason"
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
 * [reason] is the OS's own `UNBOND_REASON_*` for a bond that ENDED, and is the difference between
 * "the strap refused authentication" and "nobody answered in time" - two findings this line previously
 * rendered identically as "pairing did NOT complete".
 *
 * Appended ONLY to a failed transition that actually carries one. A successful pairing has no reason to
 * give, the broadcast leaves the extra absent on transitions INTO bonding, and a stack that supplies
 * nothing gets the wording it had before rather than a "reason=n/a" that says less than silence. The
 * existing failure line is therefore unchanged whenever there is no new information to add.
 *
 * Pure so the wording is unit-tested without a radio. Android-only: CoreBluetooth performs pairing
 * opaquely and exposes no equivalent transition, so there is nothing to twin.
 */
internal fun bondStateTraceLine(
    previous: Int,
    current: Int,
    address: String?,
    sinceMs: Long?,
    sinceLabel: String = "CLIENT_HELLO",
    reason: Int? = null,
): String {
    val who = address?.takeIf { it.isNotBlank() } ?: "unknown"
    val since = sinceMs?.let { " ${it}ms after $sinceLabel" } ?: ""
    // A bond ends two ways, and BOTH carry a reason. Scoping this to the failed-pairing transition would
    // have left the other one, a bond that EXISTED and then went away, as a bare state change with no
    // explanation - which is where REMOVED and REMOTE_DEVICE_DOWN actually show up.
    val why = reason?.takeIf { it != NO_BOND_REASON }?.let { ", " + bondFailureReasonLabel(it) } ?: ""
    val note = when {
        previous == BluetoothDevice.BOND_BONDING && current == BluetoothDevice.BOND_NONE ->
            " — pairing did NOT complete$why"
        // "ended" rather than "was removed": the transition says the bond is gone, the reason code says
        // why, and naming a cause here would be the line concluding rather than observing.
        previous == BluetoothDevice.BOND_BONDED && current == BluetoothDevice.BOND_NONE ->
            " — the bond ended$why"
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
 *
 * PARITY: Android-only, and permanently so. CoreBluetooth exposes no bond state and no pairing API at
 * all — there is no `BOND_BONDING` to observe on Apple platforms and nothing to mirror. An audit finding
 * this file one-sided should leave it rather than delete it as untwinned.
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

/** The one-per-link readout of the OS bond state the link STARTED with (#1635).
 *
 * Without it a capture cannot tell an already-paired link from an unpaired one, which is the single fact
 * that decides how to read everything after it: a CLIENT_HELLO that fails on an unencrypted link and one
 * that fails on an encrypted link are completely different findings, and they have been printing
 * identically. It also makes the explicit-pairing experiment legible — "did the pairing from last connect
 * actually survive?" is answered on the next connect line rather than inferred.
 */
internal fun bondStateAtConnectLine(bondState: Int, address: String?): String {
    val who = address?.takeIf { it.isNotBlank() } ?: "unknown"
    return "bond state at connect: ${bondStateName(bondState)} device=$who"
}

/**
 * What `BluetoothDevice.bondState` says a short while AFTER `createBond()` was accepted.
 *
 * This exists because absence of evidence kept being read as evidence. A capture showed `createBond`
 * returning true and then no bond-state transition of any kind — and that has two very different causes
 * which the log could not tell apart:
 *
 *  - Android genuinely did nothing, or
 *  - it did something and NOOP failed to hear it, because the broadcast receiver or its device filter is
 *    wrong. That receiver is ours and was added in the same week; it is a live suspect, not a given.
 *
 * Polling the device directly removes the broadcast from the chain, so the answer no longer depends on
 * the component under suspicion. A `BOND_BONDING` here with no transition line above it convicts our
 * receiver; a `BOND_NONE` clears it.
 *
 * It does NOT, however, put the silence on Android — which is what this line used to say, and it was
 * wrong. An HCI capture of exactly this case settled it: the phone DOES transmit an SMP Pairing Request,
 * and a WHOOP 5/MG answers `Pairing Failed — Pairing Not Supported (0x05)`. A refused pairing ends at
 * BOND_NONE with no BONDED transition, which is indistinguishable from never starting when all you can
 * see is the bond state. Two causes, one observation; the old verdict picked one and stated it as fact.
 *
 * Deliberately a single delayed read rather than a subscription: one fact is wanted, not a stream.
 */
internal fun bondStatePollLine(bondState: Int, sawTransitionLine: Boolean): String {
    val name = bondStateName(bondState)
    val verdict = when {
        bondState == android.bluetooth.BluetoothDevice.BOND_BONDING && !sawTransitionLine ->
            " — pairing IS underway and no transition line was logged, so the bond-state receiver missed it" +
                " (a NOOP bug, not the strap)"
        bondState == android.bluetooth.BluetoothDevice.BOND_BONDING ->
            " — pairing underway, as the transition line already said"
        bondState == android.bluetooth.BluetoothDevice.BOND_BONDED -> " — paired"
        !sawTransitionLine ->
            " — createBond was accepted and the bond did not complete. This is NOT evidence that Android" +
                " stayed silent: a REFUSED pairing ends here too. On a WHOOP 5/MG an HCI capture shows the" +
                " phone does transmit a Pairing Request and the strap answers \"Pairing Not Supported\"" +
                " (SMP 0x05), which lands in exactly this state (#1635). Only an HCI capture separates a" +
                " refused pairing from one never attempted"
        else -> " — back to this state after a transition"
    }
    return "bond state poll: $name$verdict"
}
