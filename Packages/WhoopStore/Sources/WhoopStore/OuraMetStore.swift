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

    /// Whether two samples are the SAME minute served twice: their starts are less than half the shorter
    /// period apart (`|Δ| × 2 < min(epochS)` — integer, the same expression on both platforms and in
    /// `Calories.estimateDayEnergyFromMET`). A re-served record lands 2–5 s off its first copy (the
    /// per-session `0x13` anchor); the NEXT minute starts 55–61 s after — the ring's own grid steps by a
    /// second between records — so "any overlap" is the wrong test: it read a 59-s successor as a twin
    /// and dropped a real minute at the store about once an hour (2026-09-18: 8 holes on the first day
    /// after the overlap rule, one per phase step). Half a period tells the two apart.
    public static func isTwin(_ a: OuraMetSample, _ b: OuraMetSample) -> Bool {
        abs(a.ts - b.ts) * 2 < min(a.epochS, b.epochS)
    }

    /// The samples of `incoming` that are a twin (`isTwin`) of neither a row of `existing` nor an
    /// earlier-starting sample of `incoming` itself. Pure and order-independent (incoming is sorted by
    /// ts, lower MET first on a tie, before the walk) so the insert's dedupe rule is testable without a
    /// database. Twin: Kotlin `OuraMetSampleEntity.droppingTwins`.
    public static func droppingTwins(_ incoming: [OuraMetSample], existing: [OuraMetSample]) -> [OuraMetSample] {
        var kept = existing
        var out: [OuraMetSample] = []
        for s in incoming.sorted(by: { $0.ts != $1.ts ? $0.ts < $1.ts : $0.met < $1.met }) {
            if kept.contains(where: { isTwin(s, $0) }) { continue }
            kept.append(s)
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
    /// an incoming sample that is a twin (`OuraMetSample.isTwin`: starts within half a period) of a
    /// stored one — or of one accepted earlier in the same batch — is dropped; the first copy stays.
    /// Returns rows actually inserted.
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
            let accepted = OuraMetSample.droppingTwins(samples, existing: existing)
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

    /// Cheap change-detector for a device's MET series over `[from, to]`: `(count, maxTs)`, computed over the
    /// `(deviceId, ts)` key without fetching a row, the same shape as `hrFingerprint(deviceId:from:to:)`. The
    /// day-cycle load cache keys a MET-scored cycle on it, so a later drain that banks minutes inside an
    /// ended window moves the key (#2242). COALESCE so an empty window is `(0, 0)`.
    public func ouraMetFingerprint(deviceId: String, from: Int, to: Int) async throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM ouraMetSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, from, to]) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
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
}
