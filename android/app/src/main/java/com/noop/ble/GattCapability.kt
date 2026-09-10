package com.noop.ble

import android.bluetooth.BluetoothGattCharacteristic

/**
 * What a characteristic actually DECLARES it can do, and whether we are honouring that.
 *
 * Android gives an app no way to read the link's encryption state, so debugging an encrypted connection
 * has to be done through proxies. The two available are the OS bond state (see [bondStateAtConnectLine])
 * and this: the property bitmask the strap published for the characteristic in question.
 *
 * The reason it matters here is specific. The 5/MG CLIENT_HELLO is written to `fd4b0002` WITH RESPONSE,
 * and has been since the June change that swapped `WRITE_TYPE_NO_RESPONSE` for `WRITE_TYPE_DEFAULT`. If
 * that characteristic declares only `PROPERTY_WRITE_NO_RESPONSE` and not `PROPERTY_WRITE`, then a
 * with-response write is not something it supports — the stack may accept the call, never produce a
 * completion, and the link goes away. Which is exactly the shape of the failure: 16 writes, 0 acks, no
 * pairing attempted, drop ~3.15s later.
 *
 * That is a HYPOTHESIS, not a conclusion. The point of this line is that one capture settles it, and no
 * capture so far could, because the properties have never been printed. If `Write` is present the
 * hypothesis is dead and the with-response write is fine; if it is absent, the June regression has a
 * mechanism rather than just a correlation.
 *
 * Pure, and cheap: a bitmask decode on one characteristic at discovery.
 */
internal fun characteristicCapabilityLine(
    uuid: String,
    properties: Int,
    writingWithResponse: Boolean,
): String {
    val declared = characteristicPropertyNames(properties)
    val supportsWithResponse = properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
    val verdict = when {
        !writingWithResponse -> ""
        supportsWithResponse -> " — with-response writes are supported"
        else ->
            " — MISMATCH: we write WITH RESPONSE but this characteristic does not declare Write," +
                " so no completion is owed and the write may never be answered (#1635)"
    }
    return "characteristic $uuid properties=0x${properties.toString(16)} ($declared)$verdict"
}

/** The property bitmask as names, shared by the single-characteristic line and the whole-tree dump so
 *  the two can never describe the same bits differently. "none" for an empty mask. */
internal fun characteristicPropertyNames(properties: Int): String {
    val names = buildList {
        if (properties and BluetoothGattCharacteristic.PROPERTY_BROADCAST != 0) add("Broadcast")
        if (properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) add("Read")
        if (properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) add("WriteNoResponse")
        if (properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) add("Write")
        if (properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) add("Notify")
        if (properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) add("Indicate")
        if (properties and BluetoothGattCharacteristic.PROPERTY_SIGNED_WRITE != 0) add("SignedWrite")
        if (properties and BluetoothGattCharacteristic.PROPERTY_EXTENDED_PROPS != 0) add("Extended")
    }
    return if (names.isEmpty()) "none" else names.joinToString("+")
}

/**
 * The strap's whole GATT tree, one line per characteristic.
 *
 * NOOP has never asked a strap what it offers. Every characteristic in this file is looked up by a UUID
 * someone hardcoded, so anything the 5/MG exposes that nobody guessed is invisible — and the 5/MG protocol
 * is exactly the thing still being reverse-engineered.
 *
 * The reason this is the probe worth adding, rather than another puffin command: it needs no bond and
 * sends nothing. Service discovery has already happened by the time this runs, so walking the result is a
 * read of a local cache — no GATT operation, no traffic, and no way to provoke the teardown that a write
 * to an encrypted characteristic provokes. On a strap that never bonds, every puffin probe is unreachable
 * and this one still works, which is the whole distinction.
 *
 * Bounded and unsurprising: a handful of services on a strap, emitted once per connect and gated on the
 * Test Centre connection domain, since it is a per-connect readout rather than rare-event evidence.
 */
internal fun gattTreeLines(services: List<Pair<String, List<Pair<String, Int>>>>): List<String> {
    if (services.isEmpty()) return listOf("GATT tree: no services discovered")
    return buildList {
        add("GATT tree: ${services.size} service(s)")
        for ((svc, chars) in services) {
            add("  service $svc (${chars.size} char)")
            for ((uuid, props) in chars) {
                add("    $uuid props=0x${props.toString(16)} (${characteristicPropertyNames(props)})")
            }
        }
    }
}

/**
 * One puffin NOTIFY characteristic as the pairing dump sees it.
 *
 * Deliberately NO "subscribed" field. This dump is emitted at service discovery, before the CCCD queue is
 * drained, so any subscription state read here is "not yet" by construction rather than by fact — and on
 * API 33+ it could not be read anyway, since `writeDescriptor(descriptor, value)` never populates
 * `descriptor.value`. Which characteristics actually subscribed is already in the log, one confirmed
 * `Subscribed <uuid>` line each, written where the confirmation arrives.
 */
internal data class NotifyCharDump(
    val uuid: String,
    val hasCccd: Boolean,
)

/**
 * The link's PAIRING posture, next to the puffin notify chars and whether each carries a CCCD.
 *
 * [gattTreeLines] says what the strap OFFERS; this says what we hold with it. On a 5/MG the two together
 * are the difference between "the chars are not there" and "the chars are there and we never subscribed
 * them", which a log otherwise cannot distinguish — the capture that prompted this showed all four puffin
 * notify chars discovered, one standard-HR subscribe, and no further word (#1949).
 *
 * It reports POSTURE, not outcome: this runs at service discovery, before the CCCD queue is drained, so
 * every subscription is still ahead of it. The outcomes are the `Subscribed <uuid>` lines that follow, and
 * what their ABSENCE means flips with [probeOptedIn] — ours when the probe is off, the strap's when it is
 * on and subscribing those chars itself. The note says which, because guessing wrong there inverts the
 * single distinction this dump exists to draw.
 *
 * Same discipline as its sibling: reads already-known local state, sends nothing, and so works on exactly
 * the strap that no puffin probe can reach.
 *
 * NO Swift twin, and this file's Swift half already says why in general: `gattTreeLines` was twinned
 * because CoreBluetooth exposes services, characteristics and properties, "unlike the bond-state and
 * pairing helpers, which have no Apple equivalent at all". This is one of those — it is keyed on the OS
 * bond state, which CoreBluetooth does not publish, and on an opt-in for a probe that is Android-only.
 * Worth recording for whoever wants the iOS equivalent: the asymmetry there runs the other way, since
 * `CBCharacteristic.isNotifying` is authoritative, so iOS could carry the subscription column Android
 * cannot — after the subscribe attempt, not at discovery.
 *
 * On encryption it deliberately claims LESS than a reader might want. Android publishes no
 * link-encryption flag to a GATT client, and a remote characteristic's permissions read back as 0, so the
 * bond state is the only standing proxy and it is not the same question. The hard evidence is a CCCD
 * write status, which is why the note names the two codes that answer it (#1635).
 */
internal fun whoop5PairingDumpLines(
    bondState: Int,
    didBond: Boolean,
    helloWrittenThisLink: Boolean,
    probeOptedIn: Boolean,
    notifyChars: List<NotifyCharDump>,
): List<String> = buildList {
    // [bondStateName] is BondStateTrace's, deliberately: two spellings of one OS state in one log is
    // how a reader ends up believing they are two different readings.
    add(
        "pairing: bond=${bondStateName(bondState)} didBond=$didBond" +
            " helloWritten=$helloWrittenThisLink unbondedProbe=${if (probeOptedIn) "on" else "off"}"
    )
    if (notifyChars.isEmpty()) {
        add("  no puffin notify characteristics discovered")
    } else {
        for (c in notifyChars) {
            add("  ${c.uuid} cccd=${if (c.hasCccd) "yes" else "no"}")
        }
    }
    // Which way this reads FLIPS with the opt-in, and getting it wrong would invert the one distinction
    // the dump exists to draw. With the probe off, only the standard HR and battery chars are ever queued,
    // so an unsubscribed puffin char is ours. With it ON, the probe subscribes those same chars itself, so
    // a missing line there is the strap's answer and not a setting.
    add(
        if (probeOptedIn) {
            "  note: the unbonded probe is ON and subscribes the puffin chars itself, so one above with no" +
                " later \"Subscribed\" line is the STRAP's answer, logged with the status it refused on."
        } else {
            "  note: only the standard HR and battery chars are queued for subscription on a 5/MG, so a" +
                " puffin char above with no later \"Subscribed\" line went unsubscribed by OUR choice," +
                " not the strap's."
        }
    )
    add(
        "  note: Android publishes no link-encryption flag to a GATT client and a remote characteristic's" +
            " permissions read back as 0, so bond= above is a proxy, not the answer. The hard evidence is a" +
            " CCCD write returning status 5 (insufficient authentication) or 15 (insufficient encryption)."
    )
}
