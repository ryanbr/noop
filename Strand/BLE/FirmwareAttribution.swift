import Foundation

/// Which firmware string belongs to a device, given what is known about it.
///
/// The persisted firmware used to live under one global key, written on any WHOOP connect and read back
/// for whichever strap was active. On a single-strap install those are the same strap, which is why it
/// went unnoticed; with two straps paired it reports the OTHER strap's firmware — a WHOOP 5/MG showing a
/// 4.0's 41.17.6.0 because the 4.0 connected last.
///
/// The rule, in order:
///  - `live` wins: it came from THIS connection's handshake.
///  - `perDevice` next: this device's own persisted value, from a previous connection.
///  - `legacyGlobal` ONLY when `pairedCount` is 1. The old global key cannot say which strap it belongs
///    to, so it is trustworthy exactly when there is only one strap it could have come from. This keeps a
///    single-strap install reading correctly across the upgrade instead of showing "unknown" until the
///    next connect; a multi-strap install refuses it, which is the bug.
///  - otherwise nil — "not known yet" is the honest answer, and better than another strap's number.
///
/// Pure so the attribution is unit-tested without defaults, a strap, or a registry. Kotlin twin:
/// `com.noop.ble.resolveFirmware`.
enum FirmwareAttribution {

    static func resolve(live: String?,
                        perDevice: String?,
                        legacyGlobal: String?,
                        pairedCount: Int) -> String? {
        if let live, !live.isBlank { return live }
        if let perDevice, !perDevice.isBlank { return perDevice }
        if let legacyGlobal, !legacyGlobal.isBlank, pairedCount == 1 { return legacyGlobal }
        return nil
    }

    /// The per-device defaults key for a persisted firmware string.
    ///
    /// Keyed on the BLE peripheral identifier rather than the registry id: the BLE layer knows the
    /// peripheral it connected to, and resolving it to a registry row there would repeat the mis-mapping
    /// #1527 fixed for `lastSeen` (stamping "the active row" records a sighting of a strap that was never
    /// connected). The registry row carries the same identifier, so the read side resolves without
    /// guessing.
    ///
    /// Returns nil for a blank identifier, so a caller with none writes nothing rather than writing to a
    /// key that belongs to no device.
    static func prefKey(peripheralId: String?) -> String? {
        guard let p = peripheralId?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return "noop.lastFirmware.\(p.lowercased())"
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}
