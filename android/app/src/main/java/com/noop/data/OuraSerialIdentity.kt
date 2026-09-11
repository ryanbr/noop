package com.noop.data

/**
 * What may be written to a SHAREABLE strap log for an Oura ring's serial (#2092). Byte-parity twin of
 * Swift `OuraSerialIdentity`.
 *
 * Mirrors [WhoopSerialIdentity.logSafe]'s shape exactly (same 3-character prefix + "…") so a masked
 * WHOOP serial and a masked Oura serial read identically in a shared log — the reader should not need to
 * know which brand a masked id came from to trust it is masked.
 *
 * Kept as its OWN type rather than a shared call into [WhoopSerialIdentity]: Oura's serial identity has
 * its own home and does not share WHOOP's `adoptedId`/`mayAdopt`/`isAlreadyAdopted` machinery — only the
 * LOG-SAFETY shape is common, not the identity model.
 */
object OuraSerialIdentity {
    /** The one place the Oura id namespace is spelled — matches the brand catalog's "oura" entry. */
    const val ID_PREFIX = "oura"

    /** Never log "$ID_PREFIX-$serial" (or the bare serial) directly — only this. */
    fun logSafe(serial: String?): String {
        val raw = serial?.trim().orEmpty()
        if (raw.isEmpty()) return "?"
        return raw.uppercase().take(3) + "…"
    }
}
