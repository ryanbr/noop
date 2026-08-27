package com.noop.ble

/**
 * Should NOOP ask Android to pair with this strap, rather than hoping a write provokes it?
 *
 * NOOP has never called `BluetoothDevice.createBond()` on either platform. The entire 5/MG pairing
 * strategy has been IMPLICIT: write the CLIENT_HELLO to the encrypted `fd4b0002` and rely on the stack
 * noticing that the characteristic needs encryption and starting pairing by itself.
 *
 * The bond-state trace (#1639) showed that mechanism has never once fired. Across two field captures the
 * device never enters `BOND_BONDING` at all — no pairing is attempted, the write never completes, and the
 * local stack drops the ACL ~3.15s later. So the only route NOOP had to an encrypted bond on a 5/MG was
 * one that does not work, with no fallback, because the explicit route was never built.
 *
 * This is that route, as an experiment. Asking directly is the obvious thing nobody has tried, and #1639
 * is what makes the answer readable: if `createBond()` works, the trace shows `BOND_NONE -> BOND_BONDING
 * -> BOND_BONDED`; if the strap refuses, it shows `BOND_BONDING -> BOND_NONE`. Either is a real answer,
 * which is more than the implicit path ever gave.
 *
 * OFF by default and its own switch, per the rule every strap-affecting probe in [PuffinExperiment]
 * follows: this one asks the OS to form a persistent pairing and can surface a system pairing dialog, so
 * it must not ride in on consent given for something else.
 *
 * [alreadyBondedAtOsLevel] is the REAL `BluetoothDevice.bondState`, not NOOP's `encryptedBond` flag. The
 * two are unrelated: `encryptedBond` only ever meant "a handshake write was acked", which is why a strap
 * can read Bonded in the UI while the OS holds no pairing at all.
 *
 * [alreadyRequestedThisLink] keeps it to one attempt per connection. Re-issuing `createBond()` while a
 * pairing is in flight is how you get a dialog per retry, and the retry cadence here is seconds.
 *
 * PARITY: deliberately Android-only, and not a gap to be filled later. CoreBluetooth exposes no explicit
 * pairing API at all — on Apple platforms pairing happens only as a side effect of touching an encrypted
 * characteristic, which is the very mechanism this file exists because it does not work. There is nothing
 * to mirror, so an audit finding this one-sided should leave it rather than delete it as untwinned.
 */
internal fun shouldRequestExplicitBond(
    optedIn: Boolean,
    isWhoop5: Boolean,
    alreadyBondedAtOsLevel: Boolean,
    appLevelBonded: Boolean,
    alreadyRequestedThisLink: Boolean,
): Boolean {
    if (!optedIn) return false
    if (!isWhoop5) return false
    if (alreadyBondedAtOsLevel) return false
    if (appLevelBonded) return false
    return !alreadyRequestedThisLink
}

/**
 * Once `createBond()` has been asked for, should this connection still write the CLIENT_HELLO?
 *
 * No — and this is the point of the experiment rather than an implementation detail. Writing to the
 * encrypted characteristic while a pairing is in flight is the behaviour that has been dropping the link
 * for eleven weeks, so doing both at once would test nothing and reproduce the bug.
 *
 * The hello is left for the NEXT connection. If the pairing succeeds the strap is OS-bonded by then, the
 * link comes up already encrypted, and the write has a chance to complete for the first time. If it fails
 * the strap is no worse off than it is today, and the trace says which happened.
 *
 * That reasoning assumed the pairing might succeed. An HCI capture has since shown it cannot: a 5/MG
 * answers every Pairing Request with SMP `Pairing Not Supported` (0x05). So "leave it for the next
 * connect" never resolves — the next connect requests a bond too, and defers again. The deferral is
 * permanent, which is why neither capture contains a single hello write.
 *
 * [helloOverride] breaks that cycle. The write-while-pairing hazard it guards against is real, but there
 * is no pairing in flight to protect: the refusal arrives in milliseconds, long before the hello. Someone
 * who has explicitly opted into "send hello despite bond refusal" is asking for exactly this write, and
 * silently swallowing it because a doomed pairing was requested first would make that switch a no-op for
 * everyone running the pairing experiment — which is precisely who would turn it on.
 */
internal fun explicitBondDefersHello(
    requestedThisLink: Boolean,
    helloOverride: Boolean = false,
): Boolean = requestedThisLink && !helloOverride

/**
 * The outcome line when `createBond()` THREW rather than returning.
 *
 * Almost always a missing BLUETOOTH_CONNECT permission. Reporting that as "Android refused to start
 * pairing" would blame the strap for something entirely local, and a capture would carry a confident wrong
 * answer about hardware — the exact failure this whole investigation kept producing. Names the throwable
 * instead and claims nothing about the strap.
 */
internal fun explicitBondThrewLine(throwableName: String, bondStateName: String): String =
    "WHOOP 5/MG: could not ask Android to pair — createBond threw $throwableName from $bondStateName." +
        " This is a local problem (usually a missing Bluetooth permission), NOT the strap refusing" +
        " (#1635, experimental)"

/** The outcome line for a `createBond()` call that returned. [initiated] is the API's own return value:
 *  false means the stack refused to even start, which is a different answer from a pairing that starts and
 *  then fails, and the two must not read the same in a capture. A throw is a third answer again — see
 *  [explicitBondThrewLine]. */
internal fun explicitBondRequestLine(initiated: Boolean, bondStateName: String): String =
    if (initiated) {
        "WHOOP 5/MG: asked Android to pair (createBond from $bondStateName) — watch the bond state lines" +
            " for the answer; the CLIENT_HELLO waits for the next connect (#1635, experimental)"
    } else {
        "WHOOP 5/MG: Android refused to START pairing (createBond returned false from $bondStateName) —" +
            " no pairing was attempted (#1635, experimental)"
    }
