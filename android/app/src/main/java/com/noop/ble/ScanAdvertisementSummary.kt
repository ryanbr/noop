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
     * @param serviceUuids advertised service UUIDs, lowercased; short forms are canonicalised here.
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
        val svc = serviceUuids.map { canonicalUuid(it) }.sorted()
        parts += "svc=" + if (svc.isEmpty()) "none" else svc.joinToString(",")
        // Normalise BEFORE sorting: the canonical form reorders keys that the short form would not.
        val svcData = serviceDataLengths.map { canonicalUuid(it.key) to it.value }.sortedBy { it.first }
        parts += "svcData=" + if (svcData.isEmpty()) "none" else
            svcData.joinToString(",") { "${it.first}:${it.second}B" }
        parts += "mfg=" + if (manufacturerDataLengths.isEmpty()) "none" else
            manufacturerDataLengths.entries.sortedBy { it.key }.joinToString(",") { "0x%04x:%dB".format(it.key, it.value) }
        parts += "tx=" + (txPower?.toString() ?: "none")
        parts += "nameLen=" + (localNameLength?.toString() ?: "none")
        return "[adv] " + parts.joinToString(" ")
    }

    /**
     * Expand an assigned short Bluetooth UUID to its canonical 128-bit form; pass anything else through.
     *
     * A no-op on Android, whose `UUID.toString()` is always already 128-bit. It exists because
     * CoreBluetooth renders an assigned 16-bit UUID as "180d" and a 32-bit one as "0000180d", so an
     * unnormalised iOS capture of the same strap could not be compared against an Android one — which is
     * exactly what this line exists to allow. Kept in BOTH twins so the formatters stay behaviourally
     * identical rather than agreeing only by accident of what their callers happen to pass.
     */
    internal fun canonicalUuid(s: String): String = when (s.length) {
        4 -> "0000$s-0000-1000-8000-00805f9b34fb"
        8 -> "$s-0000-1000-8000-00805f9b34fb"
        else -> s
    }
}
