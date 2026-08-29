import Foundation
import GRDB
import WhoopProtocol

/// One downsampled heart-rate point: the bucket's start (unix seconds) and the mean bpm over it.
/// Returned by the `GROUP BY ts/bucket` aggregate so a day chart plots ~N-minute means instead of
/// loading the raw ~1 Hz rows (a fully-worn 24h is ~86k samples).
public struct HRBucket: Sendable, Equatable {
    public let ts: Int
    public let bpm: Double
    /// The WEAKEST signal confidence contributing to this bucket: 1.0 for measured `hrSample`
    /// rows, the stored autocorrelation `conf` for PPG-derived fallback rows. Lets a chart render
    /// a weak-optical stretch distinctly instead of identically to a clean measured beat. Defaults
    /// to 1.0 so existing constructors/tests are unchanged. (adopted from ryanAtriumAi #988 —
    /// purely additive surfacing; the acceptance floor itself is unchanged.)
    public let conf: Double
    public init(ts: Int, bpm: Double, conf: Double = 1.0) { self.ts = ts; self.bpm = bpm; self.conf = conf }
}

/// Aggregate HR over a time window: sample count + mean/peak bpm. Result of [WhoopStore.hrWindowStats],
/// not a table. `avg`/`max` are nil when `n == 0`. Twin of the Kotlin `HrWindowStats` data class.
public struct HRWindowStats: Sendable, Equatable {
    public let n: Int
    public let avg: Double?
    public let max: Int?
    public init(n: Int, avg: Double?, max: Int?) { self.n = n; self.avg = avg; self.max = max }
}

extension WhoopStore {
    /// Shared decoder, JSONDecoder is stateless across decodes and was previously allocated once
    /// per event row. Battery events are dense (~every 8 min), so a multi-year read decodes
    /// thousands of rows; reusing one decoder removes that per-row allocation.
    fileprivate static let eventDecoder = JSONDecoder()

    /// Raw HR samples over `[from, to]`, measured-first with PPG-derived fallback.
    ///
    /// COALESCEs the measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156) using the same
    /// anti-join as `hrBuckets`: every measured second wins, and any second with NO hrSample row falls
    /// back to its PPG estimate (never doubling a beat). This keeps the raw read in lockstep with the
    /// chart path, and lets a PPG-only WHOOP 5 night clear the night-stager's HR-count gate so it is
    /// scorable (#172). The PPG `bpm` is REAL, so it is ROUND-ed to the `HRSample.bpm` Int domain.
    public func hrSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) AS bpm FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to,
                                 deviceId, from, to,
                                 limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    /// Cheap change-detector for the raw HR stream: `(count, maxTs)` over `[from, to]`, computed in
    /// SQLite over the `(deviceId, ts)` index WITHOUT materializing any rows (#836). Lets a caller decide
    /// "nothing was inserted since last time, skip the expensive re-read" for pennies, `COUNT(*)` moves on
    /// any insert (including a backfilled OLD night whose `maxTs` wouldn't change), and `maxTs` distinguishes
    /// fresh appends. COALESCE so an empty window is `(0, 0)`, never nil.
    public func hrFingerprint(deviceId: String, from: Int, to: Int) async throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            // COUNT(*) and COALESCE(MAX(ts),0) are both NON-NULL, and the aggregate query always returns
            // exactly one row, so fetchOne is non-nil and the columns read straight into Int. The guard is
            // belt-and-suspenders.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, from, to]) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
        }
    }

    /// Cross-device raw-HR fingerprint: `(count, maxTs)` over EVERY `hrSample` row, no `deviceId` filter.
    /// The `analyzeRecent` re-score gate (#1392) only needs to answer "did the raw stream change AT ALL",
    /// so it must see HR that lands under ANY id — an Oura ring, an Apple Watch, or a WHOOP re-added under a
    /// fresh `whoop-<uuid>` — not only the literal "my-whoop" the engine is constructed with. The per-device
    /// `hrFingerprint(deviceId:from:to:)` above stayed pinned to that literal (there is no setter to
    /// re-point it when the active strap changes), so on a non-WHOOP install the fingerprint read 0 rows,
    /// the watermark never advanced, and the idle-tick / post-offload gates always skipped. This mirrors the
    /// Kotlin twin `WhoopRepository.hrFingerprint()`, which already has no device filter.
    public func hrFingerprint() async throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                """) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
        }
    }

    /// Cross-device change detector for every raw stream that can change a daily score or sleep session.
    ///
    /// The original analysis watermark covered `hrSample` only. Historical offloads do not commit their
    /// streams atomically: HR can land first and motion/gravity later. A pass run between those commits sees
    /// no usable sleep, then the post-offload gate used to skip the decisive retry because HR itself had not
    /// changed. Fingerprint the complete scoring input instead. HR keeps its established count+timestamp
    /// fingerprint; the other streams use SQLite's monotonic rowid frontier, which catches old backfills
    /// without full-table COUNT scans over millions of dense motion/R-R rows.
    /// `v2` intentionally changes the persisted watermark once on upgrade so every install gets one clean
    /// rescore under the complete contract.
    public func analysisFingerprint() async throws -> String {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                  (SELECT COUNT(*) FROM hrSample) AS hc,
                  (SELECT COALESCE(MAX(ts), 0) FROM hrSample) AS hm,
                  (SELECT COALESCE(MAX(rowid), 0) FROM ppgHrSample) AS p,
                  (SELECT COALESCE(MAX(rowid), 0) FROM rrInterval) AS r,
                  (SELECT COALESCE(MAX(rowid), 0) FROM respSample) AS x,
                  (SELECT COALESCE(MAX(rowid), 0) FROM gravitySample) AS g,
                  (SELECT COALESCE(MAX(rowid), 0) FROM sleepStateSample) AS s,
                  (SELECT COALESCE(MAX(rowid), 0) FROM event) AS e,
                  (SELECT COALESCE(MAX(rowid), 0) FROM spo2Sample) AS o,
                  (SELECT COALESCE(MAX(rowid), 0) FROM skinTempSample) AS t,
                  (SELECT COALESCE(MAX(rowid), 0) FROM stepSample) AS z
                """) else { return "" }
            let hc: Int = row["hc"], hm: Int = row["hm"]
            let keys = ["p", "r", "x", "g", "s", "e", "o", "t", "z"]
            let tails = keys.map { key -> String in
                let frontier: Int = row[key]
                return key + String(frontier)
            }
            return "v2|h\(hc):\(hm)|" + tails.joined(separator: "|")
        }
    }

    /// Aggregate HR over a window: `(n, avg, max)` computed in SQLite over the same measured-∪-PPG rows
    /// [hrSamples] returns, WITHOUT materialising them and WITHOUT a row limit.
    ///
    /// #836 follow-through. The workout Avg HR reconcile used to read `hrSamples(limit: 8000)` and reduce
    /// it in Swift, so any workout longer than ~2 h 13 m at 1 Hz reported the mean of its FIRST 8000
    /// samples as the whole-session average — on a 3 h session with drifting HR, 131 bpm against a true
    /// 135. That is wrong on its own terms, and it diverged from Kotlin, whose `WhoopDao.hrWindowStats`
    /// aggregates the entire window. This is that query's twin, byte-for-byte.
    ///
    /// Same anti-join as [hrSamples]: a measured second is never double-counted by its PPG estimate.
    /// `avg`/`max` are nil when `n == 0`. Kotlin twin: `WhoopDao.hrWindowStats`.
    ///
    /// #856: aggregates across up to TWO device ids, `primaryId` winning per second. A naive
    /// `deviceId IN (…)` is wrong here — a second banked under both ids after a strap re-add would be
    /// counted twice, inflating `n` and skewing `avg`, and both numbers would stay plausible so nothing
    /// would look wrong. `GROUP BY ts` with `MIN(pri)` keeps one row per second and takes the primary's,
    /// matching the dedup `hrBuckets` already does for the chart; SQLite's bare-column rule makes `bpm`
    /// come from the row that supplied the `MIN`.
    ///
    /// Passing the same id for both is byte-identical to the old single-id read, so a single-WHOOP
    /// install needs no special case and every existing number is unchanged.
    public func hrWindowStats(primaryId: String, secondaryId: String,
                              from: Int, to: Int) async throws -> HRWindowStats {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, AVG(bpm) AS avg, MAX(bpm) AS max FROM (
                    SELECT ts, MIN(pri), bpm FROM (
                        SELECT ts, bpm, 0 AS pri FROM hrSample
                        WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        UNION ALL
                        SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER), 0 FROM ppgHrSample p
                        WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                          AND NOT EXISTS (SELECT 1 FROM hrSample h
                                          WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                        UNION ALL
                        SELECT ts, bpm, 1 FROM hrSample
                        WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        UNION ALL
                        SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER), 1 FROM ppgHrSample p
                        WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                          AND NOT EXISTS (SELECT 1 FROM hrSample h
                                          WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                    ) GROUP BY ts
                )
                """, arguments: [primaryId, from, to, primaryId, from, to,
                                 secondaryId, from, to, secondaryId, from, to])
            else { return HRWindowStats(n: 0, avg: nil, max: nil) }
            return HRWindowStats(n: row["n"], avg: row["avg"], max: row["max"])
        }
    }

    /// Downsampled HR for charting: mean bpm per `bucketSeconds`-wide bucket over `[from, to]`,
    /// keyed by the bucket's start (floor(ts/bucket)*bucket). Aggregates in SQL so a 24h window
    /// returns ~`(to-from)/bucketSeconds` rows instead of every ~1 Hz sample. Ascending by time.
    ///
    /// COALESCEs the measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156): every measured
    /// second wins, and any second with NO hrSample row falls back to its PPG estimate so the chart
    /// stays continuous through v26-heavy stretches. The fallback rows are `bpm REAL` and only appear
    /// where the device genuinely had no measured HR for that second (anti-join), never doubling a beat.
    public func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket] {
        let bucket = max(1, bucketSeconds)
        return try syncRead { db in
            // MIN(conf) per bucket: measured rows contribute 1.0, PPG fallback rows their stored
            // autocorrelation conf — so a bucket touched by ANY weak-optical estimate reads as weak
            // (conservative), and a purely-measured bucket stays 1.0. Purely additive projection:
            // the bpm aggregate and the anti-join semantics are byte-identical. (ryanAtriumAi #988)
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, AVG(bpm) AS avgBpm, MIN(conf) AS minConf FROM (
                    SELECT ts, bpm, 1.0 AS conf FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, p.bpm, p.conf FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                GROUP BY ts / ?
                ORDER BY bucket ASC
                """, arguments: [bucket, bucket,
                                 deviceId, from, to,
                                 deviceId, from, to,
                                 bucket])
                .map { HRBucket(ts: $0["bucket"], bpm: $0["avgBpm"], conf: $0["minConf"] ?? 1.0) }
        }
    }

    /// R-R intervals in EMISSION order (#823). `ord` leads the sort: ordering by `rrMs` returned a
    /// second's beats sorted by VALUE, which makes successive beats similar by construction and biases
    /// RMSSD — all successive differences — downward. Pre-v30 rows have `ord` NULL and SQLite sorts NULL
    /// first in ASC, so an all-NULL second ties and falls through to the old (rrMs, seq) order unchanged.
    /// Byte-parity twin of Kotlin `WhoopDao.rrIntervals`; both are SQLite, so NULL ordering matches.
    ///
    /// ONE optical channel (#1071). An Oura ring measures the same heartbeats on more than one tag, and
    /// every one of them is stored, so an unfiltered read returned roughly TWO complete copies of a night
    /// — 2.06x the beats the measured HR curve allows. That leaves `meanNN` (and resting HR) correct and
    /// destroys every statistic built on successive differences: RMSSD and a ~200 ms nocturnal SDNN where
    /// a healthy adult asleep is 40-100 ms.
    ///
    /// The predicate EXCLUDES the one channel proven redundant (`spo2Ibi`, 0x6E) rather than whitelisting
    /// the one preferred (`greenQuality`, 0x80), which matters for what it does NOT drop:
    ///   - NULL is kept. Every WHOOP row is NULL by construction (one beat source), as is every row
    ///     written before v32. A whitelist would delete every WHOOP night from scoring.
    ///   - `ibiAmplitude` (0x60/0x44) is kept. It does not fire on the Gen-3 hardware this was measured
    ///     on, so there is no evidence it duplicates green — and dropping a ring's ONLY beat source on an
    ///     untested assumption is the more expensive mistake. If a capture ever shows 0x60 and 0x80 firing
    ///     together, that is a second exclusion here, decided on that evidence.
    /// 0x6E is the one excluded because it is the demonstrated duplicate AND the worse measurement of the
    /// two: it is quantised to an 8 ms grid, applies no quality gate, and runs only while an SpO2
    /// measurement is on — so scoring off it would make HRV coverage a function of the SpO2 duty cycle.
    ///
    /// Rows are FILTERED, never deleted: the 0x6E stream stays on disk as the cross-check on green.
    /// Every R-R consumer reads through this one function, so the `hrv diag` trace moves with the scores
    /// rather than reporting a coverage nobody can reproduce.
    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs, srcChannel, ord, seq FROM rrInterval
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                AND (srcChannel IS NULL OR srcChannel <> ?)
                AND (tsSuspect IS NULL OR tsSuspect <> 1)   -- #1073: exclude future-stamped beats
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT ?
                """, arguments: [deviceId, from, to, RRSourceChannel.spo2Ibi.rawValue, limit])
                .map { row in
                    RRInterval(ts: row["ts"], rrMs: row["rrMs"],
                               srcChannel: (row["srcChannel"] as Int?).flatMap(RRSourceChannel.init(rawValue:)),
                               ord: row["ord"] as Int?, seq: row["seq"])
                }
        }
    }

    public func events(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WhoopEvent] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? WhoopStore.eventDecoder.decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
        }
    }

    public func batterySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [BatterySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"]) }
        }
    }

    public func spo2Samples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SpO2Sample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
        }
    }

    public func skinTempSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SkinTempSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw, aux1Raw, aux2Raw FROM skinTempSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // aux1Raw/aux2Raw (v31) read back nil for any pre-v31 row and for any WHOOP 4.0 record,
                // whose layout has no such channels. No caller reads them; they are hydrated so the
                // carrier is a faithful view of the row rather than a lossy one.
                .map { SkinTempSample(ts: $0["ts"], raw: $0["raw"],
                                      aux1Raw: $0["aux1Raw"], aux2Raw: $0["aux2Raw"]) }
        }
    }

    public func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // activityClass (#316, v19) reads back nil for any pre-v19 row (the column defaulted null) and
                // for any record whose @63 byte was 0xFF/invalid/absent, an absent class stays absent.
                .map { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]) }
        }
    }

    public func respSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RespSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    /// Raw biometric sample counts per device id in a window, across every id present in the tables -
    /// including ids the device registry cannot see.
    ///
    /// The registry is the wrong place to ask "where did this night's samples go". `my-whoop` is a source
    /// LABEL for imported/computed data, not necessarily a `pairedDevice` row, and `DeviceRegistryStore.remove`
    /// deletes the row while leaving every sample table untouched. So a forgotten or import-only id owns rows
    /// that `all()` will never list. Asking the sample tables directly has no such blind spot.
    ///
    /// Counts `hrSample` + `ppgHrSample` + `gravitySample` - the same streams the night funnel's
    /// "no raw biometric samples" guard tests. Unordered; callers sort.
    ///
    /// Filtering on `ts` without a `deviceId` cannot seek into the `(deviceId, ts)` primary key, so this
    /// is an index-ONLY scan (both columns live in that index, so no table rows are touched) with
    /// `deviceId` leading, which also lets the GROUP BY skip a temp b-tree. Cheap enough for a
    /// user-triggered diagnostics export, which is the only caller.
    public func rawSampleCountsByDevice(from: Int, to: Int) async throws -> [(String, Int)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT deviceId, SUM(n) AS total FROM (
                    SELECT deviceId, COUNT(*) AS n FROM hrSample WHERE ts >= ? AND ts <= ? GROUP BY deviceId
                    UNION ALL
                    SELECT deviceId, COUNT(*) AS n FROM ppgHrSample WHERE ts >= ? AND ts <= ? GROUP BY deviceId
                    UNION ALL
                    SELECT deviceId, COUNT(*) AS n FROM gravitySample WHERE ts >= ? AND ts <= ? GROUP BY deviceId
                )
                GROUP BY deviceId
                """, arguments: [from, to, from, to, from, to])
            .map { row -> (String, Int) in
                // `deviceId` is NOT NULL and the GROUP BY guarantees SUM(n) >= 1 per row, so both read
                // straight into non-optionals - same idiom as `hrFingerprint` above.
                let d: String = row["deviceId"]
                let t: Int = row["total"]
                return (d, t)
            }
            .filter { !$0.0.isEmpty && $0.1 > 0 }
        }
    }

    public func gravitySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [GravitySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z, dynAccel FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // dynAccel (v31) reads back nil for any pre-v31 row and for any WHOOP 4.0 record. The
                // sleep stager reads x/y/z only — this column is carried, never scored.
                .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"],
                                     dynAccel: $0["dynAccel"]) }
        }
    }

    /// Max HR sample timestamp for a device, or nil if there are none. The biometric "data frontier"
    /// used by the stuck-strap watchdog (advances iff the strap is actually logging + offloading).
    ///
    /// Coalesces measured `hrSample` with PPG-derived `ppgHrSample` (#156) so a PPG-only offload (a v26
    /// WHOOP 5 night with no measured HR) still advances the frontier. The two persist in the same
    /// offload, so this only ever moves the watchdog forward when the strap really logged + offloaded.
    /// Each arm is its OWN `SELECT MAX(ts)` rather than one `MAX(ts)` over a `UNION ALL` of the two
    /// timestamp streams. SQLite's MIN/MAX optimization only fires on a bare `SELECT MAX(col)` that can
    /// seek the last matching index entry; wrapping the columns in a compound subquery first makes the
    /// planner materialize that subquery, walking EVERY index entry for the device. On a 746 MB store
    /// (3.1M hrSample rows) the old shape measured 4.3–5.8 s per call and this one 0.01–0.07 s — the
    /// same answer, verified equal for every device id including one with no rows (both NULL).
    public func latestHRSampleTs(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(m) FROM (
                    SELECT (SELECT MAX(ts) FROM hrSample WHERE deviceId = ?) AS m
                    UNION ALL
                    SELECT (SELECT MAX(ts) FROM ppgHrSample WHERE deviceId = ?)
                )
                """, arguments: [deviceId, deviceId])
        }
    }

    /// Aggregate storage footprint: total decoded rows, raw batch count, total raw byteSize.
    public func storageStats() async throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int) {
        try syncRead { db in
            // The COMPLETE set of accumulating decoded raw streams — KEEP IN SYNC with
            // `TimestampHeal.rawTables` (its per-timestamp purge is the canonical list) and the Android
            // `WhoopRepository.storageRowCounts`. Summed by iterating the list rather than a hand-written
            // expression, because the old fixed sum silently under-reported: it omitted stepSample,
            // ppgHrSample, sleepStateSample, ppgWaveformSample, rawImuSample and v18AuxSample — and a 4.0
            // with PPG (ppgHrSample/ppgWaveformSample) or IMU capture (rawImuSample) banks millions of rows.
            // Table names are compile-time constants (never user input), so the interpolation is safe.
            let rawTables = ["hrSample", "rrInterval", "event", "battery",
                             "spo2Sample", "skinTempSample", "respSample", "gravitySample",
                             "stepSample", "ppgHrSample", "sleepStateSample", "ppgWaveformSample",
                             "v18AuxSample"]
            var decoded = 0
            for t in rawTables {
                decoded += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? 0
            }
            let batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
            let bytes   = try Int.fetchOne(db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0
            return (decoded, batches, bytes)
        }
    }
}
