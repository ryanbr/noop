package com.noop.ble

/**
 * A redacted description of what a strap ADVERTISED, for the #1635 pairing-mode question.
 *
 * The one thing no strap log can currently answer is the question the field report put back to the
 * thread: *was the strap in pairing mode during any of those refusals?* A strap that accepts pairing
 * almost certainly advertises differently from one that refuses, but the scan path reads only the
 * device name and discards the rest, so the evidence is thrown away at the moment it exists.
 *
 * It is also the ONLY diagnostic on this path that still works unbonded. The event census and the
 * battery-pack read both ride characteristics that need an encrypted link, so on the strap we are
 * actually trying to debug they are silent by construction. An advertisement arrives before any of
 * that.
 *
 * STRUCTURE, NOT PAYLOAD. The local name can carry a person's name ("<Name>'s Whoop" is what WHOOP
 * sets by default), service data can carry a serial, and manufacturer data is opaque. So this reports
 * what is PRESENT and how big it is — flags, which service UUIDs, which data blocks and their
 * lengths — and never a byte of any of them. That is enough to tell two advertising modes apart,
 * which is the whole question, and carries nothing identifying.
 *
 * Pure and platform-free so both platforms format it identically and it can be tested without a radio.
 * Swift twin: `ScanAdvertisementSummary`.
 */
object ScanAdvertisementSummary {

    /**
     * @param flags the AD flags byte, or null when the advertisement carries none.
     * @param serviceUuids advertised service UUIDs, already lowercased short form where possible.
     * @param serviceDataLengths bytes per service-data UUID, keyed by that UUID.
     * @param manufacturerDataLengths bytes per manufacturer id.
     * @param txPower advertised TX power, or null.
     * @param localNameLength length of the local name — its SIZE can differ between advertising modes,
     *   and unlike the name itself it identifies nobody.
     * @param connectable whether the advertisement was connectable.
     */
    fun line(
        flags: Int?,
        serviceUuids: List<String>,
        serviceDataLengths: Map<String, Int>,
        manufacturerDataLengths: Map<Int, Int>,
        txPower: Int?,
        localNameLength: Int?,
        connectable: Boolean,
    ): String {
        val parts = mutableListOf<String>()
        parts += "flags=" + (flags?.let { "0x%02x".format(it) } ?: "none")
        parts += "connectable=$connectable"
        parts += "svc=" + if (serviceUuids.isEmpty()) "none" else serviceUuids.sorted().joinToString(",")
        parts += "svcData=" + if (serviceDataLengths.isEmpty()) "none" else
            serviceDataLengths.entries.sortedBy { it.key }.joinToString(",") { "${it.key}:${it.value}B" }
        parts += "mfg=" + if (manufacturerDataLengths.isEmpty()) "none" else
            manufacturerDataLengths.entries.sortedBy { it.key }.joinToString(",") { "0x%04x:%dB".format(it.key, it.value) }
        parts += "tx=" + (txPower?.toString() ?: "none")
        parts += "nameLen=" + (localNameLength?.toString() ?: "none")
        return "[adv] " + parts.joinToString(" ")
    }
}
