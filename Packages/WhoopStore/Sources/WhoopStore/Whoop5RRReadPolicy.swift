import GRDB
import WhoopProtocol

extension WhoopStore {
    /// The transports a WHOOP 5 window may be SCORED through, as a SQL list.
    ///
    /// One constant rather than a literal per query. `rrIntervals` pins a window to the lowest of these
    /// present, and `firstScorableWhoop5RRTimestamp` reports when the first of them was banked, so the
    /// day the app tells a wearer its scoring begins is derived from the same set the scoring uses. Two
    /// literals would let those drift apart silently, and the drift would show as an explanation that
    /// names the wrong date. Type-40 live (6) is deliberately absent: it is a labelling channel that
    /// standard BLE (7) already covers beat for beat.
    static let scorableWhoop5Channels = "(5, 7)"

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
               let active = try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1"),
               active != deviceId {
                tagged = try isWhoop5RRSource(db: db, deviceId: active)
            }
        }
        return Whoop5RR.usesCanonicalSource(model: model, brand: brand, hasTaggedIntervals: tagged || unlabelledAliasOfWhoop5)
    }
}
