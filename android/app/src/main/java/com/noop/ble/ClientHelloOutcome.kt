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

/**
 * Is this write completion genuinely the CLIENT_HELLO's ack, and therefore proof of an encrypted bond?
 *
 * The bond branch used to match on family alone: on a 5/MG link, ANY with-response completion that
 * arrived while `didBond` was false was taken as the ack and set `encryptedBond`. A characteristic check
 * on its own does not fix that, because the puffin command characteristic (fd4b0002) carries BOTH the
 * CLIENT_HELLO and every ordinary command - DISABLE_ALARM is written there on the same connect - so the
 * hello and an unrelated command are indistinguishable by uuid.
 *
 * What separates them is whether a hello is actually OUTSTANDING. The hello is written straight past the
 * command queue while sharing its in-flight slot, so when a queued command is already in flight the write
 * is rejected by the stack and no callback is owed (the caller zeroes its stopwatch to say so). That is
 * exactly the case seen in the field: the hello was rejected, DISABLE_ALARM's completion landed a moment
 * later, and the link was declared bonded on the strength of it (#1635).
 *
 * Both conditions are required, and neither is redundant:
 *  - [isHelloChar] alone admits DISABLE_ALARM and every other puffin command.
 *  - [helloOutstanding] alone admits a completion from a different characteristic that happens to land
 *    inside the hello's window.
 *
 * Declining does not claim the strap refused anything - it says only that THIS completion is not evidence
 * of a bond. A real ack still arrives on its own callback and still bonds.
 *
 * Pure, so the rule is tested without a radio. Swift twin: `ClientHelloOutcome.isAck`.
 */
internal fun completionIsClientHelloAck(
    isHelloChar: Boolean,
    helloOutstanding: Boolean,
    alreadyBonded: Boolean,
    isWhoop5: Boolean,
): Boolean {
    if (alreadyBonded) return false
    if (!isWhoop5) return false
    return isHelloChar && helloOutstanding
}

/**
 * The shortest an ATT round trip can plausibly take, in milliseconds.
 *
 * BLE's minimum connection interval is 7.5ms. A peripheral may answer inside the same connection event,
 * so this is not a hard floor and is NOT used to reject anything - it decides only whether the log points
 * the reader at the timing. It earns its place from the field distribution, which is starkly bimodal:
 * across 41 captures every hello either "completed" in 0, 4, 5 or 7ms, or produced no callback at all
 * about 3150ms later. Nothing in between, and 0ms cannot be a round trip at all.
 */
internal const val MIN_PLAUSIBLE_ATT_ROUND_TRIP_MS = 8L

/**
 * Does a completed CLIENT_HELLO write prove the link is ENCRYPTED?
 *
 * No, and conflating the two is the second false bond. [completionIsClientHelloAck] answers a narrower
 * question - "is this completion the hello's?" - and the ack branch then took a yes as proof of an
 * encrypted just-works bond. Those are different facts. A write completion says the stack considers the
 * write finished. Encryption is a property of the LINK, and on Android the only thing that attests it is
 * the OS bond state.
 *
 * The field capture shows them disagreeing outright: "CLIENT_HELLO acked after 5ms", "encryptedBond
 * family=whoop5", and then two seconds later "bond state poll: BOND_NONE" on the same link - with an HCI
 * capture already showing this strap answers SMP `Pairing Not Supported`, so an encrypted bond is not
 * merely absent but impossible. The app displayed "Bonded, streaming." for it.
 *
 * So the completion still drives the HANDSHAKE - subscribe the puffin chars, clock the strap, offload,
 * all of which only need the strap to be listening - while `encryptedBond` waits for something that
 * actually attests encryption: the OS bond state, or the strap's own BLE_BONDED event.
 *
 * ANDROID-ONLY, deliberately, and this one has no Swift twin. CoreBluetooth exposes no link-encryption
 * or bond state at all, so Apple has nothing to supply for [osBonded] — a twin taking it would be handed
 * a constant `false` and would suppress bonds that are genuine there. The gap is real on Apple too; it
 * simply cannot be closed the same way, and pretending otherwise in a shared helper would be worse than
 * leaving it Android-only and saying so.
 */
internal fun helloCompletionProvesEncryptedBond(osBonded: Boolean): Boolean = osBonded

/**
 * The line for a hello completion that did NOT come with encryption.
 *
 * Without it the split is invisible: the log would show the handshake proceeding and no bond claim, and a
 * reader would have to infer why. It also carries the elapsed time, because on a completion faster than a
 * connection interval the timing is itself the evidence that the callback came from the local stack rather
 * than the strap - and a 0ms "round trip" is the clearest thing in the whole #1635 capture set.
 */
internal fun helloAckedWithoutEncryptionLine(elapsedMs: Long, osBondState: String): String =
    "CLIENT_HELLO outcome: the write completed after ${elapsedMs}ms, but the OS bond state is" +
        " $osBondState — a completed write says the stack finished it, NOT that the link is encrypted," +
        " so this is not a bond." +
        (if (elapsedMs < MIN_PLAUSIBLE_ATT_ROUND_TRIP_MS)
            " ${elapsedMs}ms is under one BLE connection interval, so the callback most likely came from" +
                " the local stack rather than the strap."
        else "") +
        " Continuing the handshake anyway — subscribing, clocking and offloading need the strap to be" +
        " listening, not the link to be encrypted (#1635)."

/**
 * A pre-bond write completion on a 5/MG link that arrived with NO CLIENT_HELLO outstanding.
 *
 * [completionIsClientHelloAck] declines these, and without a line it declines in SILENCE — which is worse
 * for a capture than the wrong answer it replaces. The field log for #1635 said "CLIENT_HELLO acked —
 * link established" here; the honest replacement is not nothing, it is "a completion arrived and it was
 * not the hello's". Without it the reader cannot tell a completion arrived at all, and the evidence that
 * identified this bug in the first place would not appear in the next capture.
 *
 * Names the characteristic because the whole point is that fd4b0002 carries traffic other than the hello,
 * and the reader needs to see WHICH command completed to match it against the `→ CMD` line above it.
 *
 * Bounded: this branch is 5/MG-only and runs only while unbonded, and the field capture shows about one
 * such completion per connect attempt.
 *
 * Pure. Swift twin: `ClientHelloOutcome.declinedLine`.
 */
internal fun clientHelloDeclinedLine(charUuid: String?, status: String?): String {
    // trim(), not just isNotBlank(): the Swift twin trims, and an untrimmed uuid would render with its
    // padding intact — a byte-level parity break the oracle test below catches.
    val where = charUuid?.trim()?.takeIf { it.isNotEmpty() } ?: "unknown"
    val st = status?.trim()?.takeIf { it.isNotEmpty() }?.let { " $it" } ?: ""
    return "CLIENT_HELLO outcome: completion from $where$st with NO hello outstanding — not a bond," +
        " so the link stays unbonded (#1635)"
}

