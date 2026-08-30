import Foundation

/// Which "last sync" timestamp belongs to a strap, given what is known about it.
///
/// The same defect `FirmwareAttribution` fixed for firmware strings, in the same file's other line.
/// `lastSyncedAt` is ONE defaults key, stamped on any strap's HISTORY_COMPLETE and read back for
/// whichever strap is active. On a single-strap install those are the same strap, which is why it went
/// unnoticed. With two paired it reports the other one's: an Android capture showed "Last sync: 4d ago"
/// beside zero banked rows for the active 5/MG, the timestamp belonging to a 4.0 last worn three days
/// earlier.
///
/// Worse than merely wrong: it is wrong in the reassuring direction. A strap that has never synced reads
/// as recently synced, and the pull-to-refresh that cannot possibly change it looks broken rather than
/// inapplicable. On Android that sent an investigation after a sync regression that never existed.
///
/// The rule, in order:
///  - `perDevice` wins: this strap's own stamp, from its own completed offload.
///  - `legacyGlobal` ONLY when `pairedCount` is 1. The old key cannot say which strap it belongs to, so
///    it is trustworthy exactly when there is only one strap it could have come from — which keeps a
///    single-strap install reading correctly across the upgrade instead of resetting to "never".
///  - otherwise nil, meaning "this strap has never synced". For a strap in that state it is not a
///    degraded answer, it is the correct one.
///
/// Deliberately NOT migrated by writing the global onto the active device at upgrade: that is the same
/// guess in a different place, and on a multi-strap install it would bake the wrong attribution in
/// permanently instead of leaving it to self-correct at the next real sync.
///
/// Pure so the attribution is unit-tested without defaults, a strap, or a registry. Kotlin twin:
/// `com.noop.ble.resolveLastSync`.
enum LastSyncAttribution {

    static func resolve(perDevice: Double?,
                        legacyGlobal: Double?,
                        pairedCount: Int) -> Double? {
        if let perDevice, perDevice > 0 { return perDevice }
        if let legacyGlobal, legacyGlobal > 0, pairedCount == 1 { return legacyGlobal }
        return nil
    }

    /// The per-device defaults key for a persisted last-sync timestamp.
    ///
    /// Keyed on the BLE peripheral identifier for the same reason `FirmwareAttribution.prefKey` is:
    /// HISTORY_COMPLETE arrives on a connection whose peripheral is known, and resolving it to a registry
    /// id there would repeat the mis-mapping #1527 fixed for `lastSeen` — stamping "the active row"
    /// records a sync for a strap that was never connected, which is the class of error being removed.
    ///
    /// Lowercased, because the same strap can present its identifier in different cases across sessions
    /// and a case-sensitive key would strand the earlier stamp under a second name. Returns nil for a
    /// blank identifier, so a caller with none writes nothing rather than writing to a key that belongs
    /// to no device.
    static func prefKey(peripheralId: String?) -> String? {
        guard let p = peripheralId?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return "noop.lastSyncAt.\(p.lowercased())"
    }

    /// The per-device defaults key for the #57 write-health stamps ("rows last landed", "offload stalled").
    ///
    /// Same defect as `prefKey` and found in the same capture, one line below it: "Data write: rows last
    /// landed 4d ago" printed against a strap whose own row count was zero, because the stamp was global
    /// and the other strap had written it.
    ///
    /// `kind` separates "ok" from "stalled" so both keep the per-device scoping rather than only the one
    /// that happened to be noticed — they are read as a PAIR ("stalled more recently than ok" is the
    /// alarm), and scoping one without the other would compare a strap's own stall against another
    /// strap's success. Kotlin twin: `com.noop.ble.writeHealthPrefKey`.
    static func writeHealthPrefKey(peripheralId: String?, kind: String) -> String? {
        guard let p = peripheralId?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return "sync.\(kind).\(p.lowercased())"
    }
}
