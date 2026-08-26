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
