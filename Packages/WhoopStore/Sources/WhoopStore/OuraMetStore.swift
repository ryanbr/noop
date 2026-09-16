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
}

extension WhoopStore {

    /// Insert MET samples for a device. Idempotent by (deviceId, ts): a record the ring re-serves across
    /// reconnects (common under connection churn) lands once. Returns rows actually inserted.
    @discardableResult
    public func insertOuraMetSamples(_ samples: [OuraMetSample], deviceId: String) async throws -> Int {
        if samples.isEmpty { return 0 }
        return try syncWrite { db in
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO ouraMetSample (deviceId, ts, met, state, epochS) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, ts) DO NOTHING
                """)
            var n = 0
            for s in samples {
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
