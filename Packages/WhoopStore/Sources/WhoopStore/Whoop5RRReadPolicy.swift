import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Whether the device registry CONFIRMS this owner is a WHOOP 4, so its labelled type-47 history is
    /// the stream `rrIntervals` scores for the interval.
    ///
    /// Registry-CONFIRMED, not inferred: `confirmedRegistryFamily` returns nil for an unknown brand or an
    /// unrecognised model spelling, and nil must NOT be read as "a WHOOP 4". An unregistered device falls
    /// through to the row-level check instead (does any channel-8 row exist at all), so the policy never
    /// depends on the registry being populated.
    ///
    /// Twin of the Kotlin `WhoopRepository.isWhoop4RrSource`.
    static func isWhoop4RRSource(db: Database, deviceId: String) throws -> Bool {
        let row = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?", arguments: [deviceId])
        return DeviceFamily.confirmedRegistryFamily(model: row?["model"], brand: row?["brand"]) == .whoop4
    }
    /// The transports a WHOOP 5 window may be SCORED through, as a SQL list.
    ///
    /// One constant rather than a literal per query. `rrIntervals` pins a window to the lowest of these
    /// present, and `firstScorableWhoop5RRTimestamp` reports when the first of them was banked, so the
    /// day the app tells a wearer its scoring begins is derived from the same set the scoring uses. Two
    /// literals would let those drift apart silently, and the drift would show as an explanation that
    /// names the wrong date. Type-40 live (6) is deliberately absent: it is a labelling channel that
    /// standard BLE (7) already covers beat for beat.
    static let scorableWhoop5Channels = "(5, 7)"

    /// #2371: marks the strap's 500 ms fill beats in one device's ts window. `insert` runs it after a batch
    /// that carries a 500 ms WHOOP 5 beat, once that batch's heart rate is on disk.
    ///
    /// A WHOOP 5/MG emits an exact 500 ms interval (120 bpm) as a filler at rest, on both scored
    /// transports: v18 history (5) and standard BLE (7). On one 5.0's backup (443,896 beats, 28 Sep 2026),
    /// split by the strap's own heart rate in the same second, 500 ms occurred 33-37 times as often as its
    /// neighbours (495-499, 501-505 ms) at 80-94 bpm, 3 times at 95-99, and no more often than them from
    /// 100 bpm up (1.7x on four beats at 100-104, none at 105-109, 1.0x at 110-124). Below 100 bpm a
    /// 500 ms beat would be at least 17% shorter than the mean interval of its second.
    ///
    /// The row is MARKED `tsSuspect = 1`, the flag every scoring read already filters (#1073), never
    /// deleted: it stays on disk, so the fill stays inspectable. A beat whose second has no heart rate is
    /// left alone, since nothing then says it is a fill. One literal, not a composition, so the parity
    /// ledger can compare it with the Kotlin twin: `WHOOP5_RR_FILL_FLAG_SQL`.
    static let whoop5RrFillFlagSQL = "UPDATE rrInterval SET tsSuspect = 1 WHERE deviceId = :deviceId AND ts >= :fromTs AND ts <= :toTs AND rrMs = 500 AND srcChannel IN (5, 7) AND tsSuspect IS NULL AND EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)"

    /// Marks every stored fill beat once, in `v47-rr-whoop5-fill`: the condition of `whoop5RrFillFlagSQL`
    /// over the whole table. Kotlin twin: `WHOOP5_RR_FILL_MIGRATION_SQL`.
    static let whoop5RrFillMigrationSQL = "UPDATE rrInterval SET tsSuspect = 1 WHERE rrMs = 500 AND srcChannel IN (5, 7) AND tsSuspect IS NULL AND EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)"

    /// The earliest beat this device has banked that the unit policy can actually score, or nil when it
    /// has none at all.
    ///
    /// Cheap and device-level, not per-day: one indexed MIN over the beats already on disk. Carries the
    /// same suspect-timestamp exclusion as the scoring read (#1073), so it cannot name a day that
    /// scoring would then refuse. The caller turns it into a local day key; the calendar is the app's
    /// policy, not the store's.
    public func firstScorableWhoop5RRTimestamp(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(ts) FROM rrInterval
                WHERE deviceId = ? AND srcChannel IN \(Self.scorableWhoop5Channels)
                AND (tsSuspect IS NULL OR tsSuspect <> 1)
                """, arguments: [deviceId])
        }
    }

    /// The earliest beat this device has banked AT ALL, labelled or not, or nil when it has none.
    ///
    /// The lower bound on the "cannot be scored" explanation: it is what separates history this strap
    /// actually recorded from history imported from somewhere else, and only the former can have lost
    /// anything to a labelling change. Same shape and same suspect exclusion as the scorable read above.
    public func firstRecordedRRTimestamp(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(ts) FROM rrInterval
                WHERE deviceId = ? AND (tsSuspect IS NULL OR tsSuspect <> 1)
                """, arguments: [deviceId])
        }
    }

    /// Whether the strict WHOOP 5 read policy withheld this exact window solely because it contains
    /// unlabelled, non-quarantined legacy rows and no verified scoring transport. This is deliberately
    /// narrower than "the R-R read was empty": an unworn night, WHOOP 4, another brand, and a labelled
    /// but insufficient transport all return false and therefore remain ordinary current-score outcomes.
    public func legacyWhoop5RRWithheld(deviceId: String, from: Int, to: Int,
                                       unlabelledAliasOfWhoop5: Bool = false) async throws -> Bool {
        try syncRead { db in
            guard try Self.isWhoop5RRSource(db: db, deviceId: deviceId,
                                            unlabelledAliasOfWhoop5: unlabelledAliasOfWhoop5) else {
                return false
            }
            return try Bool.fetchOne(db, sql: """
                SELECT
                  EXISTS(SELECT 1 FROM rrInterval
                         WHERE deviceId = :d AND ts >= :f AND ts <= :t
                           AND srcChannel IS NULL
                           AND (tsSuspect IS NULL OR tsSuspect <> 1))
                  AND NOT EXISTS(SELECT 1 FROM rrInterval
                         WHERE deviceId = :d AND ts >= :f AND ts <= :t
                           AND srcChannel IN \(Self.scorableWhoop5Channels)
                           AND (tsSuspect IS NULL OR tsSuspect <> 1))
                """, arguments: ["d": deviceId, "f": from, "t": to]) ?? false
        }
    }

    /// Shared by RR reads and consumers whose cached/union reads must obey the same owner policy.
    public func isWhoop5RRSource(deviceId: String, unlabelledAliasOfWhoop5: Bool = false) async throws -> Bool {
        try syncRead { try Self.isWhoop5RRSource(db: $0, deviceId: deviceId,
                                              unlabelledAliasOfWhoop5: unlabelledAliasOfWhoop5) }
    }

    static func isWhoop5RRSource(db: Database, deviceId: String,
                               unlabelledAliasOfWhoop5: Bool = false) throws -> Bool {
        let row = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?",
                                   arguments: [deviceId])
        let model: String? = row?["model"]
        let brand: String? = row?["brand"]
        // Only unknown identity needs wire evidence. Avoid scanning tagged rows for a known family.
        let knownFamily = DeviceFamily.confirmedRegistryFamily(model: model, brand: brand)
        let nonWhoop = brand.map { !$0.isEmpty && $0.lowercased() != "whoop" } ?? false
        var tagged = false
        if knownFamily == nil && !nonWhoop {
            tagged = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ? AND srcChannel IN (5, 6, 7))
                """, arguments: [deviceId]) ?? false
            // Re-pairing can leave legacy rows under the canonical alias while callers still hold
            // that old ID. Resolve its active strap here so sleep edits and ordinary reads agree.
            // Physical owners and confirmed WHOOP 4 history never inherit another strap's policy.
            if !tagged && !unlabelledAliasOfWhoop5 && deviceId == "my-whoop",
               let active = try String.fetchOne(db, sql: DeviceRegistryStore.activeDeviceIdSQL),
               active != deviceId {
                tagged = try isWhoop5RRSource(db: db, deviceId: active)
            }
        }
        return Whoop5RR.usesCanonicalSource(model: model, brand: brand, hasTaggedIntervals: tagged || unlabelledAliasOfWhoop5)
    }
}
