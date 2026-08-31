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
 *
 * ## Why the bond give-up reaches this request, having been built for the CLIENT_HELLO
 *
 * The two are separate experiments, and gating one on the other is deliberate rather than sloppy.
 * [BondRefusalGiveUp] does not track the hello; it tracks whether this strap will form an encrypted bond,
 * which is the single thing both routes are trying to achieve and neither has. Its threshold is reached on
 * the strap's own refusals, so by the time it latches the pairing request has had its five links and
 * returned the same answer every time — BOND_NONE, with an HCI capture showing SMP "Pairing Not Supported"
 * underneath. That is the experiment concluding, not being cut short.
 *
 * Every other probe here is bounded and this one was not. The hello has a give-up, the unbonded offload
 * probe has a silence budget, and asking Android to pair had nothing at all: it fired once per link,
 * forever, on a strap that had definitively said no. The 31 Aug capture caught the consequence — repeated
 * system "Pairing rejected" notices, which is worse than a quiet loop because the user has to read them.
 *
 * `bondGivenUpForDevice` is the PERSISTED suppression latch and not [BondRefusalGiveUp.gaveUp], which
 * lives in one process; a bound that dies with the process is the bug this area has now had to fix twice.
 * Both things that clear the latch are user actions that could have changed the answer — tapping Connect
 * (`clearPairingHintForUserConnect`) and forgetting the device. Putting a 5/MG into pairing mode and
 * tapping Connect is the one flow known to have worked on real hardware, and it still asks.
 */
internal fun shouldRequestExplicitBond(
    optedIn: Boolean,
    isWhoop5: Boolean,
    alreadyBondedAtOsLevel: Boolean,
    appLevelBonded: Boolean,
    alreadyRequestedThisLink: Boolean,
    bondGivenUpForDevice: Boolean,
): Boolean {
    if (!optedIn) return false
    if (!isWhoop5) return false
    if (alreadyBondedAtOsLevel) return false
    if (appLevelBonded) return false
    // The strap has refused the bond by every route the app has, and Android says so out loud: each
    // request it declines surfaces a system "Pairing rejected" notice the user did not ask for. Stop.
    if (bondGivenUpForDevice) return false
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
 *
 * [priorDeferrals] ends the cycle for everyone else, and is why the override is no longer the only way
 * out. Deferring ONCE is the honest form of the original reasoning: give the pairing the one connect it
 * asked for. Deferring again is not caution, it is repeating an experiment whose answer is already in —
 * this link has now seen a bond requested and not achieved, so the next connect writes the hello.
 *
 * The cost of being wrong in each direction is what settles the threshold. Deferring one connect too many
 * costs a user their entire history sync, silently and permanently: no hello means no bond, no bond means
 * no SET_CLOCK, and an un-clocked 5/MG does not bank to flash at all, so there is nothing to offload even
 * once the link is healthy. Writing one hello too early costs, at worst, the link dropping and
 * reconnecting — the failure this deferral was added to avoid, which the bond watchdog already handles.
 * Field-confirmed on a 5/MG: four days without a sync, thirteen backfill deferrals in one session, and
 * not a single hello written since the experiment was enabled.
 */
internal fun explicitBondDefersHello(
    requestedThisLink: Boolean,
    helloOverride: Boolean = false,
    priorDeferrals: Int = 0,
): Boolean = requestedThisLink && !helloOverride && priorDeferrals < 1

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

/**
 * The line printed when the pairing request retires, so the log says why the requests stopped.
 *
 * The give-up lines in this area all exist because something stopped silently and cost weeks of
 * unreadable captures. This one has a second job: the user has been watching Android say "Pairing
 * rejected", so the log should be able to tell them the app heard it and stopped asking, and what would
 * make it ask again.
 *
 * It claims the RETIREMENT, not a skip — "on this strap again", matching [helloOverrideExhaustedLine]'s
 * "stopping" and the offload probe's "Not asking this strap again". It is printed once per process while
 * governing every connect after it, so wording it as a one-connect decision would leave a reader looking
 * at twenty later connects to conclude the line was stale or the gate was per-connect. Both wrong, and
 * both cost more than the two words it takes to be accurate.
 */
internal fun explicitBondGivenUpLine(): String =
    "WHOOP 5/MG: not asking Android to pair on this strap again — it has refused the encrypted bond" +
        " enough times for the handshake to be latched off, and every further request only produces" +
        " another system \"Pairing rejected\" notice. Press Connect to ask again (put the strap in" +
        " pairing mode first if you want the pairing itself to have a chance), or turn \"Ask Android to" +
        " pair\" off (#1635, experimental)."

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
