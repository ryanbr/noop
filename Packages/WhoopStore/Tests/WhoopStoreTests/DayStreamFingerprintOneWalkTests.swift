import XCTest
import GRDB
@testable import WhoopStore

/// `dayStreamFingerprint` reads its five R-R figures in one walk instead of five sub-selects. The fingerprint is
/// only compared to itself, but it keys the per-day re-score cache, so a changed value for unchanged data would
/// re-score every night once and a value that stopped moving would re-serve stale nights. The reference below is
/// the five-sub-select statement it replaced, run over randomised stores; the two must agree on every window.
final class DayStreamFingerprintOneWalkTests: XCTestCase {

    /// The fingerprint every window gets from the replaced statement, composed exactly as the store does.
    private func fingerprintBeforeOneWalk(_ store: WhoopStore, deviceId: String, from: Int, to: Int) async throws -> String {
        try await store.referenceFingerprintInTest(deviceId: deviceId, from: from, to: to)
    }

    func testOneWalkMatchesTheFiveSubSelectsOnRandomStores() async throws {
        var rng = SplitMixInTest(seed: 0x2371)
        for round in 0..<6 {
            let store = try await WhoopStore.inMemory()
            let base = 1_790_000_000
            try await store.seedFingerprintRowsInTest(rng: &rng, base: base, beats: 4_000 + round * 500)
            var windows: [(Int, Int)] = [(base, base + 54 * 3600), (base - 7200, base - 1), (base + 200_000, base + 300_000),
                                         (base + 3600, base + 3600)]
            for _ in 0..<10 {
                let from = base - 3600 + Int(rng.next() % 80_000)
                windows.append((from, from + Int(rng.next() % 200_000)))
            }
            for device in ["my-whoop", "ring", "absent-device"] {
                for (from, to) in windows {
                    let now = try await store.dayStreamFingerprint(deviceId: device, from: from, to: to)
                    let before = try await fingerprintBeforeOneWalk(store, deviceId: device, from: from, to: to)
                    XCTAssertEqual(now, before, "round \(round) \(device) [\(from), \(to)]")
                }
            }
        }
    }

    /// The fixture exercises every branch of every figure, or agreement would prove little.
    func testTheFixtureCoversEveryFigure() async throws {
        var rng = SplitMixInTest(seed: 0x2371)
        let store = try await WhoopStore.inMemory()
        let base = 1_790_000_000
        try await store.seedFingerprintRowsInTest(rng: &rng, base: base, beats: 4_000)
        let fp = try await store.dayStreamFingerprint(deviceId: "my-whoop", from: base, to: base + 54 * 3600)
        for zero in ["r0:", "|w50|", "|w70|", "|w4h0|"] {
            XCTAssertFalse(fp.contains(zero), "a figure the fixture never moves: \(zero) in \(fp)")
        }
        let suspect = try await store.fillMarkCountInTest()
        XCTAssertGreaterThan(suspect.suspect, 0)
        XCTAssertGreaterThan(suspect.spo2Ibi, 0)
    }
}

/// A small deterministic generator, so a failure names a reproducible store.
struct SplitMixInTest {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension WhoopStore {
    /// Beats on every channel, suspect or not, on two devices, plus rows in the other fingerprinted streams.
    func seedFingerprintRowsInTest(rng: inout SplitMixInTest, base: Int, beats: Int) throws {
        let channels: [Int?] = [nil, 1, 2, 3, 5, 6, 7, 8, 9]
        try syncWrite { db in
            try db.execute(sql: "INSERT OR REPLACE INTO pairedDevice (id, brand, model, sourceKind, capabilities, status, "
                           + "addedAt, lastSeenAt) VALUES ('my-whoop', 'WHOOP', 'WHOOP 5.0 / MG', 'liveBLE', 'hr', 'active', 1, 1)")
            for i in 0..<beats {
                let device = rng.next() % 5 == 0 ? "ring" : "my-whoop"
                let ts = base - 3600 + Int(rng.next() % 250_000)
                let channel = channels[Int(rng.next() % UInt64(channels.count))]
                let suspect: Int? = rng.next() % 9 == 0 ? 1 : nil
                try db.execute(sql: """
                    INSERT OR IGNORE INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel, tsSuspect)
                    VALUES (?, ?, ?, 0, 0, ?, ?)
                    """, arguments: [device, ts, 600 + Int(rng.next() % 600), channel, suspect])
                if i % 7 == 0 {
                    try db.execute(sql: "INSERT OR IGNORE INTO gravitySample (deviceId, ts, x, y, z) VALUES (?, ?, 0, 0, 1)",
                                   arguments: [device, ts])
                    try db.execute(sql: "INSERT OR IGNORE INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, 'k', '{}')",
                                   arguments: [device, ts])
                }
            }
        }
    }

    func fillMarkCountInTest() throws -> (suspect: Int, spo2Ibi: Int) {
        try syncRead { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE tsSuspect = 1") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE srcChannel = 2") ?? 0)
        }
    }

    /// The statement `dayStreamFingerprint` ran before the one-walk change, verbatim, composed the same way.
    func referenceFingerprintInTest(deviceId: String, from: Int, to: Int) throws -> String {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                  (SELECT COUNT(*) FROM ppgHrSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS pc,
                  (SELECT COALESCE(MAX(ts), 0) FROM ppgHrSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS pm,
                  (SELECT COUNT(*) FROM rrInterval WHERE deviceId = :d AND ts >= :f AND ts <= :t
                     AND (srcChannel IS NULL OR srcChannel <> :rrx)
                     AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS rc,
                  (SELECT COALESCE(MAX(ts), 0) FROM rrInterval WHERE deviceId = :d AND ts >= :f AND ts <= :t
                     AND (srcChannel IS NULL OR srcChannel <> :rrx)
                     AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS rm,
                  (SELECT COUNT(*) FROM rrInterval WHERE deviceId = :d AND ts >= :f AND ts <= :t
                     AND srcChannel = 5 AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS w5,
                  (SELECT COUNT(*) FROM rrInterval WHERE deviceId = :d AND ts >= :f AND ts <= :t
                     AND srcChannel = 7 AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS w7,
                  EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = :d AND srcChannel IN (5, 6, 7)) AS w5owner,
                  (SELECT COUNT(*) FROM rrInterval WHERE deviceId = :d AND ts >= :f AND ts <= :t
                     AND srcChannel = :whoop4Historical AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS w4h,
                  COALESCE((SELECT QUOTE(brand) || ':' || QUOTE(model) FROM pairedDevice
                            WHERE id = :d), 'absent') AS registry,
                  (SELECT COUNT(*) FROM respSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS xc,
                  (SELECT COALESCE(MAX(ts), 0) FROM respSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS xm,
                  (SELECT COUNT(*) FROM spo2Sample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS oc,
                  (SELECT COALESCE(MAX(ts), 0) FROM spo2Sample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS om,
                  (SELECT COUNT(*) FROM gravitySample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS gc,
                  (SELECT COALESCE(MAX(ts), 0) FROM gravitySample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS gm,
                  (SELECT COUNT(*) FROM stepSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS zc,
                  (SELECT COALESCE(MAX(ts), 0) FROM stepSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS zm,
                  (SELECT COUNT(*) FROM skinTempSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS tc,
                  (SELECT COALESCE(MAX(ts), 0) FROM skinTempSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS tm,
                  (SELECT COUNT(*) FROM sleepStateSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS bc,
                  (SELECT COALESCE(MAX(ts), 0) FROM sleepStateSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS bm,
                  (SELECT COUNT(*) FROM event WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS ec,
                  (SELECT COALESCE(MAX(ts), 0) FROM event WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS em
                """, arguments: ["d": deviceId, "f": from, "t": to, "rrx": 2, "whoop4Historical": 8]) else { return "" }
            let keys = ["p", "r", "x", "o", "g", "z", "t", "b", "e"]
            let parts = keys.map { key -> String in
                let count: Int = row[key + "c"], maxTs: Int = row[key + "m"]
                return "\(key)\(count):\(maxTs)"
            }
            let historyCount: Int = row["w5"]
            let registry: String = row["registry"]
            let strictRR = try Self.isWhoop5RRSource(db: db, deviceId: deviceId)
            return "s4|" + parts.joined(separator: "|") + "|w5\(historyCount)|w7\(row["w7"] as Int)"
                + "|w4h\(row["w4h"] as Int)|ownerTagged\(row["w5owner"] as Int)|registry\(registry)|rr5=\(strictRR)"
        }
    }
}
