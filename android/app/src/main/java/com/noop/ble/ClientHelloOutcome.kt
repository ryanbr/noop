package com.noop.ble

/**
 * What became of a WHOOP 5/MG CLIENT_HELLO write.
 *
 * A capture could not previously distinguish the three ways the 5/MG bond fails, because two of them
 * produce no line at all. In one field capture 14 of 16 CLIENT_HELLO writes went out and were never
 * acked, 1 was rejected by the stack, and 1 produced an "ack" — from a completion the code never checked
 * the characteristic of (#1635). From the log those look the same: silence, then a link drop.
 *
 * The three outcomes, and why each matters:
 *  - [helloAcked]: the completion came from the CLIENT_HELLO characteristic itself. The only one that is
 *    genuinely an ack.
 *  - [foreignAck]: a completion arrived from a DIFFERENT characteristic while the bond was still
 *    pending. The ack branch matches on family alone, so this is what silently sets `encryptedBond` on a
 *    strap that never bonded — and the line names the characteristic that did it.
 *  - [noCallback]: the write was accepted by the stack and no completion ever arrived before the link
 *    dropped. This is the dominant case in the field capture, and the one with no evidence at all today.
 *
 * Reports only what it observed; it does not attribute blame between the strap and the local stack,
 * because a write callback that never arrives cannot distinguish "the strap declined to respond" from
 * "the frame never reached the air". Naming the gap is what makes that answerable next.
 *
 * [status] is passed pre-rendered so each platform supplies its own (Android's BluetoothStatusCodes
 * label, CoreBluetooth's error description), leaving the line shape identical. Pure. Swift twin:
 * `ClientHelloOutcome.line`.
 */
internal fun clientHelloOutcomeLine(
    isHelloChar: Boolean,
    charUuid: String?,
    elapsedMs: Long,
    status: String?,
): String {
    val where = charUuid?.takeIf { it.isNotBlank() } ?: "unknown"
    val st = status?.takeIf { it.isNotBlank() }?.let { " $it" } ?: ""
    return when {
        charUuid == null ->
            "CLIENT_HELLO outcome: NO write callback after ${elapsedMs}ms — the link dropped before the" +
                " stack reported, so the strap may never have seen it"
        isHelloChar ->
            "CLIENT_HELLO outcome: acked by $where after ${elapsedMs}ms$st"
        else ->
            "CLIENT_HELLO outcome: bond declared from a DIFFERENT characteristic $where after" +
                " ${elapsedMs}ms$st — this is NOT a CLIENT_HELLO ack (#1635)"
    }
}

/**
 * A `BluetoothGatt.GATT_*` status from `onCharacteristicWrite`, labelled.
 *
 * NOT [WhoopBleClient.writeStatusLabel], which maps `BluetoothStatusCodes` — the return value of
 * `writeCharacteristic`, a different enumeration that collides with this one on small integers. Passing a
 * callback status through that mapper renders GATT_INVALID_HANDLE(1) as "ERROR_BLUETOOTH_NOT_ENABLED",
 * GATT_READ_NOT_PERMITTED(2) as "ERROR_BLUETOOTH_NOT_ALLOWED" and GATT_WRITE_NOT_PERMITTED(3) as
 * "ERROR_DEVICE_NOT_BONDED" — confidently wrong names in a line whose whole job is explaining a bond
 * failure, which is worse than printing no name at all.
 *
 * Names the codes that matter for a bond and leaves the rest as bare numbers rather than guessing:
 * INSUFFICIENT_AUTHENTICATION and INSUFFICIENT_ENCRYPTION are exactly "the strap refused the encrypted
 * bond" (the pair [BondRefusalGiveUp] already keys on), and 133 is the catch-all Android returns for a
 * link that went away underneath the operation.
 *
 * Android-only by design: CoreBluetooth reports `didWriteValueFor` with an `Error`, not a status code,
 * which is why the outcome line takes its status pre-rendered.
 */
internal fun gattWriteStatusLabel(status: Int?): String = when (status) {
    null -> "status=n/a"
    0 -> "status=GATT_SUCCESS(0)"
    3 -> "status=GATT_WRITE_NOT_PERMITTED(3)"
    5 -> "status=GATT_INSUFFICIENT_AUTHENTICATION(5)"
    13 -> "status=GATT_INVALID_ATTRIBUTE_LENGTH(13)"
    15 -> "status=GATT_INSUFFICIENT_ENCRYPTION(15)"
    133 -> "status=GATT_ERROR(133)"
    257 -> "status=GATT_FAILURE(257)"
    else -> "status=$status"
}

