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
