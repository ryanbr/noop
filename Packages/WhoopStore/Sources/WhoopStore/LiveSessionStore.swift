import Foundation
import GRDB

// MARK: - v22 store: Live Sessions
//
// LiveSessionStore.swift — GRDB CRUD over the `liveSession` table (migration v22), the durable record
// behind the Live Sessions look-back summary + streak. Mirrors the established idiom exactly: a plain
// Codable row struct, raw `Row` fetch + manual decode, idempotent upsert keyed by the natural key
// (deviceId, startTs), all GRDB work via the actor's `syncWrite` / `syncRead` helpers.
//
// Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.

/// One Live Session (silent guardian) record. Natural key (deviceId, startTs). `endTs` is nil while the
/// session is still in progress. All second-totals are non-negative; the two cue counts are how many push
/// nudges / ease-offs the coach sent that session.
public struct LiveSessionRow: Equatable, Codable {
    public let startTs: Int              // unix seconds — session start (the key)
    public let endTs: Int?               // unix seconds — nil while in progress
    public let chargeAtStart: Double?    // 0...100 recovery Charge at start; nil if unknown
    public let floorBpm: Double          // guarded band, floor
    public let ceilingBpm: Double        // guarded band, ceiling
    public let inBandSec: Double
    public let belowSec: Double
    public let aboveSec: Double
    public let pushCount: Int            // "give more" cues sent
    public let easeCount: Int            // "ease off" cues sent
    public let hrSource: String          // "whoop" | "strap" | "power" etc.

    public init(startTs: Int, endTs: Int?, chargeAtStart: Double?, floorBpm: Double, ceilingBpm: Double,
                inBandSec: Double, belowSec: Double, aboveSec: Double, pushCount: Int, easeCount: Int,
                hrSource: String) {
        self.startTs = startTs; self.endTs = endTs; self.chargeAtStart = chargeAtStart
        self.floorBpm = floorBpm; self.ceilingBpm = ceilingBpm
        self.inBandSec = inBandSec; self.belowSec = belowSec; self.aboveSec = aboveSec
        self.pushCount = pushCount; self.easeCount = easeCount; self.hrSource = hrSource
    }
}

extension WhoopStore {

    /// Upsert one Live Session. Natural key (deviceId, startTs) — called once at start (endTs nil) and
    /// again at end with the final totals. Returns rows changed.
    ///
    /// The `WHERE excluded.endTs IS NOT NULL OR liveSession.endTs IS NULL` guard makes a start-write
    /// (endTs nil) refuse to overwrite an already-ended row: start/end persist as independent, unordered
    /// tasks, so a late start-write could otherwise clobber the final row back to "in progress" and lose
    /// the totals. Ordering-independent; the normal start→end order still updates (the row's endTs was
    /// nil). Byte-parity with the Android Room upsert. (@bhelm)
    @discardableResult
    public func upsertLiveSession(_ r: LiveSessionRow, deviceId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO liveSession
                    (deviceId, startTs, endTs, chargeAtStart, floorBpm, ceilingBpm,
                     inBandSec, belowSec, aboveSec, pushCount, easeCount, hrSource)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs) DO UPDATE SET
                    endTs = excluded.endTs,
                    chargeAtStart = excluded.chargeAtStart,
                    floorBpm = excluded.floorBpm,
                    ceilingBpm = excluded.ceilingBpm,
                    inBandSec = excluded.inBandSec,
                    belowSec = excluded.belowSec,
                    aboveSec = excluded.aboveSec,
                    pushCount = excluded.pushCount,
                    easeCount = excluded.easeCount,
                    hrSource = excluded.hrSource
                WHERE excluded.endTs IS NOT NULL OR liveSession.endTs IS NULL
                """, arguments: [deviceId, r.startTs, r.endTs, r.chargeAtStart, r.floorBpm, r.ceilingBpm,
                                 r.inBandSec, r.belowSec, r.aboveSec, r.pushCount, r.easeCount, r.hrSource])
            return db.changesCount
        }
    }

    /// The most-recent sessions first, for the look-back summary + streak. Newest by startTs.
    public func recentLiveSessions(deviceId: String, limit: Int) async throws -> [LiveSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, chargeAtStart, floorBpm, ceilingBpm, inBandSec, belowSec, aboveSec,
                       pushCount, easeCount, hrSource FROM liveSession
                WHERE deviceId = ?
                ORDER BY startTs DESC LIMIT ?
                """, arguments: [deviceId, limit])
                .map {
                    LiveSessionRow(startTs: $0["startTs"], endTs: $0["endTs"],
                                   chargeAtStart: $0["chargeAtStart"], floorBpm: $0["floorBpm"],
                                   ceilingBpm: $0["ceilingBpm"], inBandSec: $0["inBandSec"],
                                   belowSec: $0["belowSec"], aboveSec: $0["aboveSec"],
                                   pushCount: $0["pushCount"], easeCount: $0["easeCount"],
                                   hrSource: $0["hrSource"])
                }
        }
    }
}
