package com.noop.ble

/**
 * Which firmware string belongs to a device, given what is known about it.
 *
 * The persisted firmware used to live under one global key, written on any WHOOP connect and read back
 * for whichever strap was active. On a single-strap install those are the same strap, which is why it
 * went unnoticed; with two straps paired it reports the OTHER strap's firmware — a WHOOP 5/MG showing a
 * 4.0's 41.17.6.0 because the 4.0 connected last.
 *
 * The rule, in order:
 *  - [live] wins: it came from THIS connection's handshake.
 *  - [perDevice] next: this device's own persisted value, from a previous connection.
 *  - [legacyGlobal] ONLY when [pairedCount] is 1. The old global key cannot say which strap it belongs
 *    to, so it is trustworthy exactly when there is only one strap it could have come from. This keeps a
 *    single-strap install reading correctly across the upgrade instead of showing "unknown" until the
 *    next connect; a multi-strap install refuses it, which is the bug.
 *  - otherwise null — "not known yet" is the honest answer, and better than another strap's number.
 *
 * Pure so the attribution is unit-tested without prefs, a strap, or a registry. Swift twin:
 * `FirmwareAttribution.resolve`.
 */
internal fun resolveFirmware(
    live: String?,
    perDevice: String?,
    legacyGlobal: String?,
    pairedCount: Int,
): String? = live?.takeIf { it.isNotBlank() }
    ?: perDevice?.takeIf { it.isNotBlank() }
    ?: legacyGlobal?.takeIf { it.isNotBlank() && pairedCount == 1 }

/**
 * The per-device preference key for a persisted firmware string.
 *
 * Keyed on the BLE peripheral address rather than the registry id: the BLE client knows the address it
 * connected to, and resolving it to a registry row there would repeat the mis-mapping #1527 fixed for
 * `lastSeen` (stamping "the active row" records a sighting of a strap that was never connected). The
 * registry row carries the same address, so the read side resolves without guessing.
 *
 * Returns null for a blank address, so a caller with no address writes nothing rather than writing to a
 * key that belongs to no device.
 */
internal fun firmwarePrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }?.let { "noop.lastFirmware.${it.lowercase()}" }

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

