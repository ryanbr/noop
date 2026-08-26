package com.noop.ble

/**
 * Should NOOP try reading the Device Information Service on a 5/MG that has NOT bonded?
 *
 * Today `readDisIdentity` is issued only inside the post-bond handshake, so a strap that never bonds never
 * reads DIS at all — which is why a field capture of the reconnect loop contains zero `DIS:` lines and the
 * Devices screen shows a WHOOP 4.0 with its firmware beside a 5/MG with none. The firmware, the serial and
 * the MG-vs-5.0 hardware revision all sit behind the same bond that never happens.
 *
 * Whether they NEED to is unproven, and the evidence is one-sided in an uncomfortable way. Standard
 * NOTIFICATIONS demonstrably work unbonded — live HR and battery both arrive that way on exactly these
 * straps — but nothing shows a standard READ working unbonded, and the Swift side carries a note (#490)
 * that a 5/MG refuses standard reads on an unencrypted link. A read is also the same class of operation
 * as the write that has been provoking the teardown, so this can plausibly cost the stable link that
 * #1635 suppression just bought.
 *
 * Hence: once per device, and never again after a refusal. [previouslyRefused] is persisted, so a strap
 * that says no says it once rather than on every reconnect forever. That makes the experiment
 * self-limiting in the same way the hello suppression is — the failure mode of "keeps trying something
 * that will never work" is the one this whole area keeps producing.
 *
 * A refusal is a RESULT, not a defeat: it settles #490 for Android, which no capture has ever done.
 */
internal fun shouldReadDisUnbonded(
    isWhoop5: Boolean,
    bonded: Boolean,
    alreadyReadThisLink: Boolean,
    previouslyRefused: Boolean,
): Boolean {
    if (!isWhoop5) return false
    if (bonded) return false          // the post-bond path already covers this
    if (alreadyReadThisLink) return false
    return !previouslyRefused
}

/** Persisted key for "this strap refused an unbonded DIS read". Per device and lowercased, for the same
 *  reason [firmwarePrefKey] is. */
internal fun disRefusedPrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }?.let { "noop.disRefused.${it.lowercase()}" }

/**
 * The line for a DIS read that came back with a failure status.
 *
 * Without it the read fails in SILENCE — `onCharacteristicRead` drops any non-success status on the floor
 * — so a capture cannot tell a refusal from a read that was never issued. That is the same ambiguity that
 * made the CLIENT_HELLO failure unreadable for eleven weeks, and it is not worth reproducing.
 *
 * INSUFFICIENT_AUTHENTICATION / INSUFFICIENT_ENCRYPTION are the interesting answers: they say the strap
 * requires an encrypted link for this read, which confirms #490 on Android and means the firmware simply
 * cannot be had without a bond.
 */
internal fun disReadFailureLine(uuid: String, status: String): String =
    "DIS: read of $uuid failed $status — the strap declined it on this link. If this is an" +
        " insufficient-authentication or -encryption status, DIS needs an encrypted bond and the firmware" +
        " cannot be read without one (#490)"

/**
 * Should the standard Device Information Service firmware string be published for this strap?
 *
 * A 5/MG that never completes the puffin handshake has no firmware to show, because the only source NOOP
 * reads it from is a framed command that needs the bond. The Devices screen therefore shows a WHOOP 4.0
 * with its firmware beside a 5/MG with none — which reads as a missing feature and is really a missing
 * READ: DIS `0x2A26` sits in the same service NOOP already reads the serial and hardware revision from,
 * unbonded, on every 5/MG connect (#520). It was simply never asked for.
 *
 * DIS is a FALLBACK, never an override. The puffin value is the strap's own report of the firmware it is
 * running and is what the 4.0 has always shown; DIS is whatever the device chose to publish in its
 * standard profile, and the two are not guaranteed to agree. So this yields to anything already decoded
 * rather than racing it — the decode lands later in the connect, and a value that appeared and then
 * changed would be worse than one that arrived once.
 */
internal fun shouldPublishDisFirmware(
    disFirmware: String?,
    alreadyDecoded: String?,
): Boolean = !disFirmware.isNullOrBlank() && alreadyDecoded.isNullOrBlank()
