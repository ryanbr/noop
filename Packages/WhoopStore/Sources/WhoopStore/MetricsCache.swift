import Foundation
import GRDB

// MARK: - Offline cache of SERVER-computed metrics (Task 3.1 → M0.4)
// This file is purely a local cache of values computed by the server — the phone does NO metric
// computation here. DailyMetric and CachedSleepSession mirror the server's daily_metrics /
// sleep_sessions tables and are cached locally so History = union(phone-collected raw streams,
// server-computed derived metrics). ServerSync.pull() populates this cache; MetricsRepository
// reads it for the view layer.

/// One cached sleep session pulled from the server's /v1/sleep. Natural key (deviceId, startTs).
/// `stagesJSON` is the verbatim JSON array of stage segments ([{start,end,stage}]) — stored as a
/// string so the cache stays schema-agnostic about the staging shape.
public struct CachedSleepSession: Equatable, Codable {
    public let startTs: Int          // unix seconds
    public let endTs: Int            // unix seconds
    public let efficiency: Double?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let stagesJSON: String?
    /// True once the user has hand-corrected this session's wake/sleep bounds. The recompute/import
    /// upsert preserves an edited session's `endTs`/`stagesJSON` instead of overwriting them with the
    /// strap-detected values (see `upsertSleepSessions`). Defaults false so every cache/recompute path
    /// that doesn't know about edits keeps producing un-edited rows.
    public let userEdited: Bool
    /// The user's hand-corrected sleep ONSET, or nil when the onset wasn't edited. `startTs` remains the
    /// immutable detected key; display + re-staging use `effectiveStartTs`. (#318)
    public let startTsAdjusted: Int?
    /// The onset to display / stage from: the user's correction if present, else the detected `startTs`.
    public var effectiveStartTs: Int { startTsAdjusted ?? startTs }
    /// True when this night's on-device staging ran on SPARSE motion coverage (`SleepStager.isGravitySparse`
    /// — the same signal that downgrades Rest confidence, #345). A sparse night is unreliable and can
    /// UNDER-detect: the gravity-only spine fragments and the sub-60-min pieces are dropped, so a real ~8h
    /// night can collapse to ~1h. The UI reads this to caption "sleep may be incomplete" honestly instead
    /// of presenting the short total as fact. nil for imported nights and pre-migration rows (unknown, not
    /// flagged). Set per session to the DAY's value; only NOOP-computed nights populate it. Byte-parity twin.
    public let stagingSparse: Bool?
    public init(startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?,
                avgHrv: Double?, stagesJSON: String?, userEdited: Bool = false,
                startTsAdjusted: Int? = nil, stagingSparse: Bool? = nil) {
        self.startTs = startTs; self.endTs = endTs
        self.efficiency = efficiency; self.restingHr = restingHr
        self.avgHrv = avgHrv; self.stagesJSON = stagesJSON
        self.userEdited = userEdited
        self.startTsAdjusted = startTsAdjusted
        self.stagingSparse = stagingSparse
    }

    /// A copy re-keyed to `newStartTs`, every other field (including the stage segments) unchanged. Used by
    /// the #1284 generation-side onset keying to set the session's PK to the rounded 0x49 onset (the stable
    /// per-night anchor); the onset key differs from the end-anchored first-code time by at most the grid.
    public func withStartTs(_ newStartTs: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: newStartTs, endTs: endTs, efficiency: efficiency, restingHr: restingHr,
                           avgHrv: avgHrv, stagesJSON: stagesJSON, userEdited: userEdited,
                           startTsAdjusted: startTsAdjusted, stagingSparse: stagingSparse)
    }
}

/// One cached daily-metrics row pulled from the server's /v1/daily. Natural key (deviceId, day).
public struct DailyMetric: Equatable, Codable {
    public let day: String           // YYYY-MM-DD
    public let totalSleepMin: Double?
    public let efficiency: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let lightMin: Double?
    public let disturbances: Int?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let recovery: Double?
    public let strain: Double?
    public let exerciseCount: Int?
    // In-sleep signal aggregates (v7 columns). All nullable; computed server-side.
    public let spo2Pct: Double?        // mean SpO2 (%) during sleep
    public let skinTempDevC: Double?   // skin-temperature deviation (°C) from baseline
    public let respRateBpm: Double?    // mean respiration rate (breaths/min) during sleep
    // On-device daily activity totals (v11 columns, APPROXIMATE estimates). Both nullable, so
    // imported/cloud rows that never carry them stay nil and old call sites are unaffected.
    public let steps: Int?             // daily/file step total from the cumulative @57 counter or activity import
    public let activeKcalEst: Double?  // whole-day HR-only calorie estimate (kcal)
    // WHOOP 4.0 raw SpO2 PPG ADC means over detected sleep (v23 columns, #93). These are the RAW
    // red/IR optical channels banked on the v24 historical layout (spo2_red@68 / spo2_ir@70), NOT a
    // calibrated blood-oxygen % — that needs WHOOP's proprietary curve. Both nullable and on-device
    // only (imports/cloud never carry them), so old rows + non-4.0 nights stay nil and every existing
    // call site is unaffected.
    public let spo2Red: Int?           // mean raw red PPG ADC during detected sleep
    public let spo2Ir: Int?            // mean raw IR PPG ADC during detected sleep
    /// Nightly SDNN (ms — the Task Force 5-min SDNN INDEX: mean of per-5-min-segment SDNN, ddof=1). The
    /// BROAD autonomic-variability twin of `avgHrv` (which is RMSSD for the strap: the fast, vagal,
    /// "recovered today?" metric). The 5-min index — not a single whole-night SD — is stored deliberately:
    /// whole-night SD is dominated by the slow HR drift across sleep stages (reads 2-3× high) and is not
    /// comparable to a watch's short-window SDNN; the index is. v31 column, nullable: WHOOP/on-device nights
    /// compute it from the night's R-R (`HRVAnalyzer.sdnnIndex`); Apple rows mirror their own SDNN reading;
    /// Oura/other imports carry no SDNN so it stays nil.
    public let avgSdnn: Double?
    public init(day: String, totalSleepMin: Double?, efficiency: Double?, deepMin: Double?,
                remMin: Double?, lightMin: Double?, disturbances: Int?, restingHr: Int?,
                avgHrv: Double?, recovery: Double?, strain: Double?, exerciseCount: Int?,
                spo2Pct: Double? = nil, skinTempDevC: Double? = nil, respRateBpm: Double? = nil,
                steps: Int? = nil, activeKcalEst: Double? = nil,
                spo2Red: Int? = nil, spo2Ir: Int? = nil, avgSdnn: Double? = nil) {
        self.day = day; self.totalSleepMin = totalSleepMin; self.efficiency = efficiency
        self.deepMin = deepMin; self.remMin = remMin; self.lightMin = lightMin
        self.disturbances = disturbances; self.restingHr = restingHr; self.avgHrv = avgHrv
        self.recovery = recovery; self.strain = strain; self.exerciseCount = exerciseCount
        self.spo2Pct = spo2Pct; self.skinTempDevC = skinTempDevC; self.respRateBpm = respRateBpm
        self.steps = steps; self.activeKcalEst = activeKcalEst
        self.spo2Red = spo2Red; self.spo2Ir = spo2Ir; self.avgSdnn = avgSdnn
    }

    /// The freshest STRICTLY-PRIOR day that carries at least one overnight vital (HRV / resting HR /
    /// respiratory), or nil. This is the recovery-INDEPENDENT twin of the whole-row Charge carry: it never
    /// gates on `recovery != nil`, so a night whose recovery is null but which still recorded real HRV/RHR
    /// is a valid vitals source (the whole-row carry would skip it). It only supplies the FALLBACK — each
    /// vital is read today-first at the call site (`displayDay?.field ?? vitalsDay?.field`), so today's own
    /// value always wins and this never overrides it. `days` is oldest→newest.
    ///
    /// `todayKey` must be the future-clock-safe "today" key (the later of the logical/local day key,
    /// mirroring `Repository.widgetAnchor`'s `carriedKey`); the `$0.day < todayKey` bound (yyyy-MM-dd
    /// compares lexicographically) keeps only genuine prior days, so today's own still-forming row and any
    /// stray future-dated row (a bad-clock strap) can never be picked up as "last night's" vitals.
    public nonisolated static func lastVitalsDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { ($0.avgHrv != nil || $0.restingHr != nil || $0.respRateBpm != nil) && $0.day < todayKey })
    }

    /// PER-FIELD twin of `lastVitalsDay` for SpO₂: the freshest STRICTLY-PRIOR day with a non-nil `spo2Pct`.
    /// `lastVitalsDay`'s predicate only checks HRV / resting-HR / respiratory, so it can land on a row whose
    /// `spo2Pct` is nil (the on-device engine writes `spo2Pct = nil` — it banks only raw `spo2Red`/`spo2Ir`;
    /// only imported rows carry a percentage) while an OLDER imported row holds a real reading. Resolving
    /// SpO₂ per field keeps the Blood Oxygen card honest instead of "No Data". Same `$0.day < todayKey`
    /// future-clock guard as `lastVitalsDay`; `days` is oldest→newest. Byte-twin of the Android `lastSpo2Row`.
    public nonisolated static func lastSpo2Day(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { $0.spo2Pct != nil && $0.day < todayKey })
    }

    /// PER-FIELD twin of `lastVitalsDay` for skin-temperature deviation. See `lastSpo2Day`. Byte-twin of the
    /// Android `lastSkinTempRow`.
    public nonisolated static func lastSkinTempDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { $0.skinTempDevC != nil && $0.day < todayKey })
    }
}

extension WhoopStore {

    // MARK: - Upserts (idempotent by natural key; latest server value wins on conflict)

    /// Upsert cached sleep sessions. Natural key (deviceId, startTs). Returns rows changed.
    @discardableResult
    public func upsertSleepSessions(_ sessions: [CachedSleepSession], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for s in sessions {
                try db.execute(sql: """
                    INSERT INTO sleepSession
                        (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                         userEdited, startTsAdjusted, stagingSparse)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        -- A user-corrected night keeps its hand-set bed/wake times and stage breakdown;
                        -- a recompute/import refresh (this path) updates only the derived vitals. The
                        -- `userEdited` flag is preserved, never cleared here, so a later strap re-sync
                        -- can't revert a correction (the dedicated edit path is `applySleepEdit`).
                        endTs = CASE WHEN sleepSession.userEdited THEN sleepSession.endTs ELSE excluded.endTs END,
                        efficiency = excluded.efficiency,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        stagesJSON = CASE WHEN sleepSession.userEdited THEN sleepSession.stagesJSON ELSE excluded.stagesJSON END,
                        startTsAdjusted = CASE WHEN sleepSession.userEdited THEN sleepSession.startTsAdjusted ELSE excluded.startTsAdjusted END,
                        userEdited = sleepSession.userEdited,
                        -- Derived from the day's motion coverage, so a recompute always refreshes it.
                        stagingSparse = excluded.stagingSparse
                    """, arguments: [deviceId, s.startTs, s.endTs, s.efficiency,
                                     s.restingHr, s.avgHrv, s.stagesJSON, s.userEdited, s.startTsAdjusted,
                                     s.stagingSparse])
                n += db.changesCount
            }
            return n
        }
    }

    /// Hand-correct a sleep session's bed (onset) and/or wake (end) time. Sets `userEdited = 1` so the
    /// next recompute/import `upsertSleepSessions` preserves the corrected bounds instead of overwriting
    /// them with the strap-detected values. Keyed by the stable detected natural key
    /// (deviceId, `detectedStartTs`) — which never moves; the corrected onset is stored in
    /// `startTsAdjusted`. `newStartTs == detectedStartTs` leaves the onset effectively unchanged.
    /// `stagesJSON`, when non-nil, replaces the stored breakdown (the caller re-derives it for the new
    /// window via `SleepStager.stageSession`, falling back to `SleepWindowReclip`); nil keeps the
    /// existing stages. Returns rows changed (0 if no such session).
    @discardableResult
    public func applySleepEdit(deviceId: String, detectedStartTs: Int, newStartTs: Int, newEndTs: Int,
                               stagesJSON: String? = nil) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET startTsAdjusted = ?, endTs = ?, stagesJSON = COALESCE(?, stagesJSON), userEdited = 1
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [newStartTs, newEndTs, stagesJSON, deviceId, detectedStartTs])
            return db.changesCount
        }
    }

    /// Delete ONE sleep session entirely — the delete half of `applySleepEdit` with no re-insert.
    /// (deviceId, startTs) is the primary key, so it uniquely identifies the row, letting the user clear a
    /// misread or spurious night so the day recomputes without it (#68/#281). Returns rows deleted (0 when
    /// no such session). Mirrors Android `dao.deleteSleepSession(deviceId, startTs)`. The durable
    /// "user deleted this night" tombstone that stops the recompute regenerating it lives in the
    /// Repository layer (`dismissedSleepSpans`), exactly as the dismissed-WORKOUT span list does — this
    /// store call only removes the row.
    @discardableResult
    public func deleteSleepSession(deviceId: String, startTs: Int) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                           arguments: [deviceId, startTs])
            return db.changesCount
        }
    }

    /// Manually ADD a sleep session the detector missed — typically a daytime NAP (#508). Inserts a NEW
    /// row keyed by the chosen `startTs`, flagged `userEdited = 1` so the post-sync recompute's overlap
    /// guard preserves it (drops any later re-detected session overlapping its window) exactly as it
    /// protects a hand-corrected night — the manual nap can never be overwritten or folded away. `startTs`
    /// is the immutable detected-style key; `startTsAdjusted` stays nil because a manually-added session's
    /// onset IS the chosen onset (there is no "detected" onset to diverge from). `stagesJSON` is staged from
    /// the raw streams over `[startTs, endTs]` by the caller (falling back to a single "awake" block when
    /// the strap has no dense data there yet — the self-heal swaps in real stages once raw lands).
    ///
    /// Uses `ON CONFLICT(deviceId, startTs) DO NOTHING` so it is purely ADDITIVE: it can never clobber an
    /// existing detected/edited session that happens to share the exact onset second. Returns rows inserted
    /// (0 when a session already exists at that onset). Mirrors Android `insertManualSleepSession`.
    @discardableResult
    public func insertManualSleepSession(deviceId: String, startTs: Int, endTs: Int,
                                         efficiency: Double?, stagesJSON: String?) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO sleepSession
                    (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                     userEdited, startTsAdjusted)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, 1, NULL)
                ON CONFLICT(deviceId, startTs) DO NOTHING
                """, arguments: [deviceId, startTs, endTs, efficiency, stagesJSON])
            return db.changesCount
        }
    }

    /// Replace ONLY the stage breakdown of an already user-edited night, leaving the corrected bed/wake
    /// bounds (`startTsAdjusted`/`endTs`) and the `userEdited` flag untouched. The post-sync self-heal
    /// calls this when a strap sync finally delivers the raw streams for a night that was edited BEFORE
    /// they arrived: at edit time the stages were fabricated by `SleepWindowReclip` (a trailing "awake"
    /// block) because the raw wasn't present yet, and `userEdited` then froze that breakdown against every
    /// later sync. This swaps in the real re-derived stages without disturbing the user's bound correction.
    /// Scoped to `userEdited = 1` rows so it can never rewrite an un-edited (freely re-derivable) night.
    /// Returns rows changed (0 when no such edited session exists).
    @discardableResult
    public func updateSleepStages(deviceId: String, detectedStartTs: Int, stagesJSON: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET stagesJSON = ?
                WHERE deviceId = ? AND startTs = ? AND userEdited = 1
                """, arguments: [stagesJSON, deviceId, detectedStartTs])
            return db.changesCount
        }
    }

    // MARK: - Per-epoch sleep analytics (v18: motionJSON / sleepStateJSON)
    //
    // Banked on the EXISTING sleepSession row (deviceId, startTs) beside `stagesJSON`, NOT on
    // CachedSleepSession — these are aux per-session series the analytics layer writes/reads through
    // targeted methods (the same shape as `updateSleepStages`), so the common session read path stays
    // lean and the recompute/import/edit upserts (which don't name these columns) preserve them.
    // HONESTY: an absent signal is stored as SQL NULL and read back as `nil`, never a fabricated zero array.

    /// Persist the SleepStager's per-epoch motion magnitudes for one session, as a compact JSON array on
    /// the same 30 s epoch grid as `stagesJSON`. Keyed by the immutable detected key (deviceId, startTs).
    /// Passing an EMPTY array clears the column to NULL (no series), never an empty `[]` masquerading as
    /// data. Returns rows changed (0 when no such session). Twin of Android `dao.updateSessionMotion`.
    @discardableResult
    public func persistSessionMotion(deviceId: String, sessionStart: Int, motionEpochs: [Double]) async throws -> Int {
        let json = motionEpochs.isEmpty ? nil : Self.encodeDoubleArray(motionEpochs)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession SET motionJSON = ?
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [json, deviceId, sessionStart])
            return db.changesCount
        }
    }

    /// The persisted per-epoch motion magnitudes for one session, or nil when the column is NULL / the
    /// session doesn't exist / the JSON is unparseable (absent stays absent). Keyed by detected startTs.
    public func sessionMotion(deviceId: String, sessionStart: Int) async throws -> [Double]? {
        try syncRead { db in
            let json = try String.fetchOne(db, sql: """
                SELECT motionJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, sessionStart])
            return json.flatMap(Self.decodeDoubleArray)
        }
    }

    /// Persist the decoded v18 band sleep_state per epoch for one session — the Interpreter's `(sb>>4)&3`
    /// band value, one entry per epoch — as a compact JSON array of ints. Keyed by (deviceId, startTs).
    /// EMPTY clears to NULL (no banked band state). Returns rows changed. Twin of `dao.updateSessionSleepState`.
    @discardableResult
    public func persistSessionSleepState(deviceId: String, sessionStart: Int, states: [Int]) async throws -> Int {
        let json = states.isEmpty ? nil : Self.encodeIntArray(states)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession SET sleepStateJSON = ?
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [json, deviceId, sessionStart])
            return db.changesCount
        }
    }

    /// The persisted decoded v18 band sleep_state per epoch for one session, or nil when unset / unparseable
    /// (absent stays absent). Keyed by detected startTs.
    public func sessionSleepState(deviceId: String, sessionStart: Int) async throws -> [Int]? {
        try syncRead { db in
            let json = try String.fetchOne(db, sql: """
                SELECT sleepStateJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, sessionStart])
            return json.flatMap(Self.decodeIntArray)
        }
    }

    /// Batched twin of `sessionMotion` for a SET of session starts: the persisted per-epoch motion series
    /// for each of `sessionStarts` that HAS one, in a SINGLE query, keyed by startTs. Same contract as the
    /// single-key accessor — a start whose column is NULL/absent (or an empty series) is simply omitted from
    /// the result (absent stays absent, never a fabricated zero array) — but without the per-session
    /// round-trip the Sleep tab's main-night group used to pay (N single-row reads → one). The `IN (…)` list
    /// is de-duplicated and chunked to stay well under SQLite's bound-parameter ceiling.
    public func sessionMotions(deviceId: String, sessionStarts: [Int]) async throws -> [Int: [Double]] {
        guard !sessionStarts.isEmpty else { return [:] }
        return try syncRead { db in
            var out: [Int: [Double]] = [:]
            let uniq = Array(Set(sessionStarts))
            var lo = 0
            while lo < uniq.count {
                let chunk = Array(uniq[lo ..< min(lo + Self.inClauseChunk, uniq.count)])
                lo += Self.inClauseChunk
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = [deviceId]
                args.append(contentsOf: chunk)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT startTs, motionJSON FROM sleepSession
                    WHERE deviceId = ? AND startTs IN (\(placeholders)) AND motionJSON IS NOT NULL
                    """, arguments: StatementArguments(args))
                for row in rows {
                    let startTs: Int = row["startTs"]
                    guard let json: String = row["motionJSON"],
                          let arr = Self.decodeDoubleArray(json), !arr.isEmpty else { continue }
                    out[startTs] = arr
                }
            }
            return out
        }
    }

    /// Batched twin of `sessionSleepState` over a RANGE: every session in `[from, to]` (by startTs) that has
    /// banked per-epoch band sleep_state, in ONE query, keyed by startTs. The H7 re-onset guard reads the
    /// SAME `[from, to]` window as its `sleepSessions` call, so a single range scan replaces the per-session
    /// round-trip (N single-row reads → one); the caller looks each kept (deduped) session up by startTs.
    /// NULL/absent columns are omitted (absent stays absent), identical to the single-key accessor.
    public func sessionSleepStates(deviceId: String, from: Int, to: Int) async throws -> [Int: [Int]] {
        try syncRead { db in
            var out: [Int: [Int]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT startTs, sleepStateJSON FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ? AND sleepStateJSON IS NOT NULL
                """, arguments: [deviceId, from, to])
            for row in rows {
                let startTs: Int = row["startTs"]
                guard let json: String = row["sleepStateJSON"],
                      let arr = Self.decodeIntArray(json), !arr.isEmpty else { continue }
                out[startTs] = arr
            }
            return out
        }
    }

    /// SQLite caps the number of bound `?` parameters per statement (SQLITE_MAX_VARIABLE_NUMBER — 999 on the
    /// system SQLite iOS ships). Chunk `IN (…)` lists comfortably under it, leaving room for the leading
    /// `deviceId` bind.
    static let inClauseChunk = 900

    /// Compact JSON encoders/decoders for the per-epoch series — a bare `[Double]`/`[Int]` array (no
    /// pretty-printing) so the column stays small and round-trips byte-for-byte with the Android port.
    static func encodeDoubleArray(_ xs: [Double]) -> String? {
        (try? JSONEncoder().encode(xs)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func decodeDoubleArray(_ json: String) -> [Double]? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode([Double].self, from: $0) }
    }
    static func encodeIntArray(_ xs: [Int]) -> String? {
        (try? JSONEncoder().encode(xs)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func decodeIntArray(_ json: String) -> [Int]? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode([Int].self, from: $0) }
    }

    /// Upsert cached daily metrics. Natural key (deviceId, day). Returns rows changed.
    @discardableResult
    public func upsertDailyMetrics(_ days: [DailyMetric], deviceId: String) async throws -> Int {
        try syncWrite { db in
            try Self.upsertDailyMetrics(days, deviceId: deviceId, in: db)
        }
    }

    /// Transaction-sharing primitive used by computed-score persistence. Keeping the SQL here ensures
    /// ordinary cache writes and score+provenance writes cannot drift.
    static func upsertDailyMetrics(_ days: [DailyMetric], deviceId: String, in db: Database) throws -> Int {
        var n = 0
        for d in days {
            try db.execute(sql: """
                INSERT INTO dailyMetric
                    (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                     disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                     spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                     spo2Red, spo2Ir, avgSdnn)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET
                    totalSleepMin = excluded.totalSleepMin,
                    efficiency = excluded.efficiency,
                    deepMin = excluded.deepMin,
                    remMin = excluded.remMin,
                    lightMin = excluded.lightMin,
                    disturbances = excluded.disturbances,
                    restingHr = excluded.restingHr,
                    avgHrv = excluded.avgHrv,
                    recovery = excluded.recovery,
                    strain = excluded.strain,
                    exerciseCount = excluded.exerciseCount,
                    spo2Pct = excluded.spo2Pct,
                    skinTempDevC = excluded.skinTempDevC,
                    respRateBpm = excluded.respRateBpm,
                    steps = excluded.steps,
                    activeKcalEst = excluded.activeKcalEst,
                    spo2Red = excluded.spo2Red,
                    spo2Ir = excluded.spo2Ir,
                    avgSdnn = excluded.avgSdnn
                """, arguments: [deviceId, d.day, d.totalSleepMin, d.efficiency, d.deepMin,
                                 d.remMin, d.lightMin, d.disturbances, d.restingHr, d.avgHrv,
                                 d.recovery, d.strain, d.exerciseCount,
                                 d.spo2Pct, d.skinTempDevC, d.respRateBpm,
                                 d.steps, d.activeKcalEst,
                                 d.spo2Red, d.spo2Ir, d.avgSdnn])
            n += db.changesCount
        }
        return n
    }

    /// Delete a source's cached daily rows whose day-key is in [from, to] (inclusive, yyyy-MM-dd
    /// lexicographic = chronological). The #277 local-day re-bucketing migration uses this to drop
    /// the computed ("-noop") UTC-keyed rows across the recompute window before re-upserting the
    /// LOCAL-keyed rows, so a UTC/local duplicate day can't linger. Source-scoped, so imported
    /// "my-whoop" rows are never touched. Returns rows deleted. Mirrors Android
    /// WhoopDao.deleteComputedDailyInRange.
    @discardableResult
    public func deleteDailyMetrics(deviceId: String, from: String, to: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            return db.changesCount
        }
    }

    // MARK: - Reads

    /// Cached sleep sessions overlapping [from, to] (by startTs), oldest first.
    public func sleepSessions(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [CachedSleepSession] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited,
                       startTsAdjusted, stagingSparse FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    CachedSleepSession(startTs: $0["startTs"], endTs: $0["endTs"],
                                       efficiency: $0["efficiency"], restingHr: $0["restingHr"],
                                       avgHrv: $0["avgHrv"], stagesJSON: $0["stagesJSON"],
                                       userEdited: $0["userEdited"], startTsAdjusted: $0["startTsAdjusted"],
                                       stagingSparse: $0["stagingSparse"])
                }
        }
    }

    /// Cached daily metrics for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest first.
    public func dailyMetrics(deviceId: String, from: String, to: String) async throws -> [DailyMetric] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                       restingHr, avgHrv, recovery, strain, exerciseCount,
                       spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                       spo2Red, spo2Ir, avgSdnn FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map {
                    DailyMetric(day: $0["day"], totalSleepMin: $0["totalSleepMin"],
                                efficiency: $0["efficiency"], deepMin: $0["deepMin"],
                                remMin: $0["remMin"], lightMin: $0["lightMin"],
                                disturbances: $0["disturbances"], restingHr: $0["restingHr"],
                                avgHrv: $0["avgHrv"], recovery: $0["recovery"],
                                strain: $0["strain"], exerciseCount: $0["exerciseCount"],
                                spo2Pct: $0["spo2Pct"], skinTempDevC: $0["skinTempDevC"],
                                respRateBpm: $0["respRateBpm"],
                                steps: $0["steps"], activeKcalEst: $0["activeKcalEst"],
                                spo2Red: $0["spo2Red"], spo2Ir: $0["spo2Ir"], avgSdnn: $0["avgSdnn"])
                }
        }
    }
}
