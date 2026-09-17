import Foundation
import GRDB

// MARK: - v47 store: the Oura ring's per-minute MET series (0x50, #2242)
// Same shape as the per-second stream tables: an idempotent `ON CONFLICT DO NOTHING` insert keyed by
// (deviceId, ts) and a bounded range read, all GRDB work via syncWrite/syncRead. The rows feed
// `Calories.estimateDayEnergyFromMET` when the Experimental MET-calories toggle is on; the writer
// (`OuraLiveSource`) only inserts while that toggle is on, so an OFF install never grows this table.

/// One MET sample as stored. `ts` is the unix second the sample's interval starts; `epochS` how many
/// seconds it covers (60 on every ring observed); `state` the 0x50 record's leading state byte, verbatim.
public struct OuraMetSample: Equatable, Sendable {
    public let ts: Int
    public let met: Double
    public let state: Int
    public let epochS: Int
    public init(ts: Int, met: Double, state: Int, epochS: Int = 60) {
        self.ts = ts; self.met = met; self.state = state; self.epochS = epochS
    }

    /// The samples of `incoming` that overlap neither a row of `existing` nor an earlier-starting sample
    /// of `incoming` itself. Two intervals overlap when `a.ts < b.ts + b.epochS && b.ts < a.ts + a.epochS`.
    /// Pure and order-independent (incoming is sorted by ts, lower MET first on a tie, before the walk)
    /// so the insert's dedupe rule is testable without a database. Twin: Kotlin
    /// `OuraMetSampleEntity.droppingOverlaps`.
    public static func droppingOverlaps(_ incoming: [OuraMetSample], existing: [OuraMetSample]) -> [OuraMetSample] {
        var kept = existing.map { ($0.ts, $0.ts + $0.epochS) }
        var out: [OuraMetSample] = []
        for s in incoming.sorted(by: { $0.ts != $1.ts ? $0.ts < $1.ts : $0.met < $1.met }) {
            let end = s.ts + s.epochS
            if kept.contains(where: { s.ts < $0.1 && $0.0 < end }) { continue }
            kept.append((s.ts, end))
            out.append(s)
        }
        return out
    }
}

extension WhoopStore {

    /// Insert MET samples for a device. Idempotent by MINUTE, not only by (deviceId, ts): a record the ring
    /// re-serves across reconnects lands once even when the re-serve carries a different second.
    ///
    /// Why the key alone is not enough (2026-09-17): `ts` is anchored ring time, and the `0x13` anchor is
    /// taken per session, so the same ring record served under two sessions lands 2–5 s apart — the
    /// (deviceId, ts) key sees two rows. On the first hardware day 157 of 1,035 rows were such twins
    /// (an Oura-app replay re-served the day from the app's older cursor) and the day read +8 %. So
    /// an incoming sample whose interval overlaps a stored one — or one accepted earlier in the same
    /// batch — is dropped; the first copy stays. Returns rows actually inserted.
    @discardableResult
    public func insertOuraMetSamples(_ samples: [OuraMetSample], deviceId: String) async throws -> Int {
        if samples.isEmpty { return 0 }
        return try syncWrite { db in
            let lo = samples.map(\.ts).min()! - samples.map(\.epochS).max()!
            let hi = samples.map { $0.ts + $0.epochS }.max()!
            let existing = try Row.fetchAll(db, sql: """
                SELECT ts, epochS FROM ouraMetSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                """, arguments: [deviceId, lo, hi])
                .map { OuraMetSample(ts: $0["ts"], met: 0, state: 0, epochS: $0["epochS"]) }
            let accepted = OuraMetSample.droppingOverlaps(samples, existing: existing)
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO ouraMetSample (deviceId, ts, met, state, epochS) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, ts) DO NOTHING
                """)
            var n = 0
            for s in accepted {
                try stmt.execute(arguments: [deviceId, s.ts, s.met, s.state, s.epochS])
                n += db.changesCount
            }
            return n
        }
    }

    /// MET samples for a device in `[from, to]` (inclusive, like every stream read), ts ascending.
    public func ouraMetSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [OuraMetSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, met, state, epochS FROM ouraMetSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { OuraMetSample(ts: $0["ts"], met: $0["met"], state: $0["state"], epochS: $0["epochS"]) }
        }
    }

    /// Row count for a device (diagnostics / tests).
    public func ouraMetSampleCount(deviceId: String) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ouraMetSample WHERE deviceId = ?",
                             arguments: [deviceId]) ?? 0
        }
    }
}
