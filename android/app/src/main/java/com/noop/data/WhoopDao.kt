package com.noop.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/**
 * Data-access for the local store. Mirrors the GRDB reads/writes in WhoopStore
 * (StreamStore.swift, Reads.swift, MetricsCache.swift).
 *
 * Stream inserts use OnConflictStrategy.IGNORE == Swift `ON CONFLICT(...) DO NOTHING`
 * (idempotent by natural key — re-inserting an existing row is a no-op).
 *
 * Server-derived caches (dailyMetric, sleepSession, metricSeries) use @Upsert so the
 * latest server value wins on conflict, matching the `ON CONFLICT ... DO UPDATE SET ...`
 * upserts in MetricsCache.swift.
 *
 * Range reads are ORDER BY ts ASC (R-R and events add a secondary key matching Reads.swift),
 * and bound by [from, to] inclusive with a row limit.
 */
@Dao
interface WhoopDao : DeviceRegistryDao {

    // MARK: - Device

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertDevice(device: DeviceRow)

    @Query("SELECT * FROM device WHERE id = :id")
    suspend fun device(id: String): DeviceRow?

    // NOTE: the device-registry reads/writes (pairedDevice/dayOwnership, v8) live on the narrow
    // [DeviceRegistryDao] super-interface so [DeviceRegistry] can be unit-tested with a small fake DAO
    // (no Robolectric — see DeviceRegistryTest). Room flattens the inherited @Query/@Insert methods
    // into this @Dao at compile time, so they generate exactly as if declared here.

    // MARK: - Stream inserts (idempotent by natural key)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertHr(rows: List<HrSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertRr(rows: List<RrInterval>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertEvents(rows: List<EventRow>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertBattery(rows: List<BatterySample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSpo2(rows: List<Spo2Sample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSkinTemp(rows: List<SkinTempSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSteps(rows: List<StepSample>): List<Long>

    /** The strap's OWN band sleep_state per record (#175). Idempotent by (deviceId, ts). */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSleepState(rows: List<SleepStateSampleEntity>): List<Long>

    /** Upsert one Live Session (v22). Natural key (deviceId, startTs) — start (endTs null) then end. */
    @Upsert
    suspend fun upsertLiveSession(row: LiveSessionRow)

    /** Most-recent Live Sessions first, for the look-back summary + streak. */
    @Query("SELECT * FROM liveSession WHERE deviceId = :deviceId ORDER BY startTs DESC LIMIT :limit")
    suspend fun recentLiveSessions(deviceId: String, limit: Int): List<LiveSessionRow>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertResp(rows: List<RespSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertGravity(rows: List<GravitySample>): List<Long>

    /** PPG-derived HR from the v26 optical waveform. Idempotent by (deviceId, ts). (#156) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertPpgHr(rows: List<PpgHrSample>): List<Long>

    /** RAW v26 optical PPG waveform (packed i16 BLOB). Idempotent by (deviceId, ts). (#156 follow-up) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertPpgWaveform(rows: List<PpgWaveformSampleEntity>): List<Long>

    /** RAW 5/MG IMU offload buffers (packed i16 BLOB). Idempotent by (deviceId, ts). (#423) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertRawImu(rows: List<RawImuSampleEntity>): List<Long>

    /**
     * The remaining 5/MG v18 per-second fields, one compact blob per strap-second. Idempotent by
     * (deviceId, ts) — IGNORE keeps the FIRST-seen row, matching every other per-second stream, so a
     * re-sync cannot duplicate or overwrite. Instrumentation only.
     */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertV18Aux(rows: List<V18AuxSampleEntity>): List<Long>

    /**
     * Bound the v18 aux table to the newest [keep] rows for [deviceId] (rolling retention, v31). Same
     * shape as [pruneRawImu] — this is instrumentation nothing reads yet, so it is capped rather than
     * unbounded. Swift twin: the DELETE at the end of `WhoopStore.insert`.
     */
    @Query(
        "DELETE FROM v18AuxSample WHERE deviceId = :deviceId AND ts < " +
            "(SELECT MIN(ts) FROM (SELECT ts FROM v18AuxSample WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT :keep))"
    )
    suspend fun pruneV18Aux(deviceId: String, keep: Int)

    /** Bound the raw-IMU table to the newest [keep] rows for [deviceId] (rolling retention, #423). */
    @Query(
        "DELETE FROM rawImuSample WHERE deviceId = :deviceId AND ts < " +
            "(SELECT MIN(ts) FROM (SELECT ts FROM rawImuSample WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT :keep))"
    )
    suspend fun pruneRawImu(deviceId: String, keep: Int)

    /** RAW 5/MG IMU buffers in [from, to] (ascending), packed i16 BLOB. (#423) */
    @Query(
        "SELECT * FROM rawImuSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun rawImuSamples(deviceId: String, from: Long, to: Long, limit: Int): List<RawImuSampleEntity>

    // MARK: - Server-derived caches (latest value wins)

    @Upsert
    suspend fun upsertDailyMetrics(rows: List<DailyMetric>)

    @Upsert
    suspend fun upsertSleepSessions(rows: List<SleepSession>)

    /** Remove one sleep session by its full primary key (deviceId, startTs) — used by the
     *  bed/wake-time edit, which deletes then re-inserts because startTs is part of the PK. */
    @Query("DELETE FROM sleepSession WHERE deviceId = :deviceId AND startTs = :startTs")
    suspend fun deleteSleepSession(deviceId: String, startTs: Long)

    /** Manually ADD a sleep session the detector missed — typically a daytime NAP (#508). Port of iOS
     *  MetricsCache.insertManualSleepSession. `onConflict = IGNORE` makes it purely ADDITIVE: it can
     *  never clobber an existing detected/edited session that shares the exact onset second (it returns
     *  -1 then). The caller builds the row with userEdited = true (so the recompute overlap guard in
     *  [com.noop.analytics.IntelligenceEngine] preserves it) and startTsAdjusted = null (a manual nap's
     *  onset IS the chosen onset). Returns the inserted rowid, or -1 on a conflicting onset. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSleepSession(row: SleepSession): Long

    /**
     * Replace ONLY the stage breakdown of an already user-edited night, leaving the corrected
     * bed/wake bounds (startTsAdjusted/endTs) and the userEdited flag untouched. Port of iOS
     * MetricsCache.updateSleepStages (PR #449). The post-sync self-heal
     * ([com.noop.analytics.SleepStageHealer]) calls this when a strap sync finally delivers the raw
     * streams for a night that was edited BEFORE they arrived: at edit time the stages were
     * fabricated by SleepWindowReclip (a trailing "wake" block) because the raw wasn't present yet,
     * and userEdited then froze that breakdown against every later sync. This swaps in the real
     * re-derived stages without disturbing the user's bound correction.
     *
     * Scoped to `userEdited = 1` rows (Room stores Boolean true as INTEGER 1) so it can NEVER rewrite
     * an un-edited (freely re-derivable) night — the regular recompute upsert owns those. Keyed by the
     * IMMUTABLE detected primary key (deviceId, startTs); the caller passes the detected startTs, never
     * effectiveStartTs. Returns rows changed (0 when no such edited session exists).
     */
    @Query(
        "UPDATE sleepSession SET stagesJSON = :stagesJSON " +
            "WHERE deviceId = :deviceId AND startTs = :detectedStartTs AND userEdited = 1"
    )
    suspend fun updateSleepStages(deviceId: String, detectedStartTs: Long, stagesJSON: String): Int

    /**
     * v18 (H8): write the per-epoch motion magnitudes (compact JSON array) for one session, banked beside
     * `stagesJSON` on the same row. Keyed by the IMMUTABLE detected key (deviceId, startTs). `null` clears
     * the column (no series). Port of iOS WhoopStore.persistSessionMotion (the repository encodes the array).
     * Returns rows changed (0 when no such session). Targeted UPDATE so the @Upsert recompute/import path —
     * which never names this column — preserves it. */
    @Query(
        "UPDATE sleepSession SET motionJSON = :json WHERE deviceId = :deviceId AND startTs = :sessionStart"
    )
    suspend fun updateSessionMotion(deviceId: String, sessionStart: Long, json: String?): Int

    /** v18 (H8): read the per-epoch motion JSON for one session, or null when unset / no such session.
     *  The repository decodes it to `List<Double>?` (absent stays absent). */
    @Query("SELECT motionJSON FROM sleepSession WHERE deviceId = :deviceId AND startTs = :sessionStart")
    suspend fun sessionMotionJson(deviceId: String, sessionStart: Long): String?

    /**
     * v18 (H2 persist half): write the decoded v18 band sleep_state per epoch (compact JSON int array) for
     * one session. Keyed by (deviceId, startTs). `null` clears the column. Port of iOS
     * WhoopStore.persistSessionSleepState. Returns rows changed. Targeted UPDATE so the @Upsert path
     * preserves it. */
    @Query(
        "UPDATE sleepSession SET sleepStateJSON = :json WHERE deviceId = :deviceId AND startTs = :sessionStart"
    )
    suspend fun updateSessionSleepState(deviceId: String, sessionStart: Long, json: String?): Int

    /** v18 (H2): read the decoded v18 band sleep_state JSON for one session, or null when unset.
     *  The repository decodes it to `List<Int>?`. */
    @Query("SELECT sleepStateJSON FROM sleepSession WHERE deviceId = :deviceId AND startTs = :sessionStart")
    suspend fun sessionSleepStateJson(deviceId: String, sessionStart: Long): String?

    @Upsert
    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>)

    @Upsert
    suspend fun upsertScoreInputProvenance(rows: List<ScoreInputProvenanceRow>)

    @Query(
        "SELECT sourceId FROM scoreInputProvenance " +
            "WHERE deviceId = :deviceId AND day = :day AND key = :key"
    )
    suspend fun scoreInputSource(deviceId: String, day: String, key: String): String?

    @Query(
        "DELETE FROM scoreInputProvenance " +
            "WHERE deviceId = :deviceId AND day >= :from AND day <= :to"
    )
    suspend fun deleteScoreInputProvenanceInRange(deviceId: String, from: String, to: String)

    /**
     * Replace a computed scoring window atomically. If any score or provenance write fails, Room rolls
     * the whole transaction back, so an old score can never be labelled with a newer provider.
     */
    @Transaction
    suspend fun replaceComputedScoreWindow(
        deviceId: String,
        from: String,
        to: String,
        dailyMetrics: List<DailyMetric>,
        metricPoints: List<MetricSeriesRow>,
        provenance: List<ScoreInputProvenanceRow>,
    ) {
        deleteDailyMetricsInRange(deviceId, from, to)
        deleteScoreInputProvenanceInRange(deviceId, from, to)
        if (dailyMetrics.isNotEmpty()) upsertDailyMetrics(dailyMetrics)
        if (metricPoints.isNotEmpty()) upsertMetricSeries(metricPoints)
        if (provenance.isNotEmpty()) upsertScoreInputProvenance(provenance)
    }

    @Upsert
    suspend fun upsertJournal(rows: List<JournalEntry>)

    @Upsert
    suspend fun upsertWorkouts(rows: List<WorkoutRow>)

    @Upsert
    suspend fun upsertAppleDaily(rows: List<AppleDaily>)

    // MARK: - Range reads (ORDER BY ts ASC, inclusive [from, to], limited)

    /** COALESCE union (#172/#219 parity with Swift's hrSamples): the measured `hrSample` is
     *  authoritative; the v26 PPG-derived `ppgHrSample` fills ONLY seconds the strap never reported a
     *  bpm for (anti-join), so a PPG-only WHOOP 5 night still clears the scoring gate and is scorable —
     *  exactly as `hrBuckets` already coalesces for charts. PPG rows carry synced = 0. */
    @Query(
        "SELECT deviceId, ts, bpm, synced FROM (" +
            "SELECT deviceId, ts, bpm, synced FROM hrSample " +
            "WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.deviceId AS deviceId, p.ts AS ts, p.bpm AS bpm, 0 AS synced FROM ppgHrSample p " +
            "WHERE p.deviceId = :deviceId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)" +
            ") ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun hrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<HrSample>

    /** RAW measured HR only — the `hrSample` table with NO v26 PPG-derived union (cf. [hrSamples]).
     *  Backs the raw-sensor diagnostic export, which emits measured HR and PPG-derived HR as two
     *  distinct streams so they're never conflated. Range read, ts asc, row-limited. */
    @Query(
        "SELECT * FROM hrSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun rawHrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<HrSample>

    /** Downsampled HR for charting: mean bpm per [bucketSeconds]-wide bucket over [from, to],
     *  keyed by the bucket start (floor(ts/bucket)*bucket). Aggregated in SQL so a 24h window
     *  returns ~(to-from)/bucketSeconds rows, not every ~1 Hz sample. Mirrors macOS hrBuckets.
     *
     *  COALESCE union (#156): the real sensor `hrSample` is authoritative; the v26 PPG-derived
     *  `ppgHrSample` only contributes seconds the strap NEVER reported a bpm for (WHERE NOT EXISTS),
     *  so derived HR fills gaps without ever overriding or double-counting a true HR sample. The two
     *  selects are UNION ALL'd into one bpm stream, then bucket-averaged exactly as before. Matches
     *  the Swift hrBuckets COALESCE union. */
    @Query(
        "SELECT (ts / :bucketSeconds) * :bucketSeconds AS bucket, AVG(bpm) AS avgBpm FROM (" +
            "SELECT ts, bpm FROM hrSample " +
            "WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.ts AS ts, p.bpm AS bpm FROM ppgHrSample p " +
            "WHERE p.deviceId = :deviceId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)" +
            ") GROUP BY ts / :bucketSeconds ORDER BY bucket ASC"
    )
    suspend fun hrBuckets(deviceId: String, from: Long, to: Long, bucketSeconds: Long): List<HrBucket>

    /** Raw v26 PPG-derived HR samples in [from, to] (ascending). (#156) */
    @Query(
        "SELECT * FROM ppgHrSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun ppgHrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<PpgHrSample>

    /** RAW v26 optical PPG waveform rows in [from, to] (ascending), packed i16 BLOB. (#156 follow-up) */
    @Query(
        "SELECT * FROM ppgWaveformSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun ppgWaveformSamples(deviceId: String, from: Long, to: Long, limit: Int):
        List<PpgWaveformSampleEntity>

    /**
     * The banked 5/MG v18 auxiliary-field rows in [from, to] (ascending). Empty on a WHOOP 4.0 and for
     * any window offloaded before the columns existed. INSTRUMENTATION: no analytic calls this — it
     * exists so the banked bytes are reachable for a census, and so the write path has a round-trip test.
     */
    @Query(
        "SELECT * FROM v18AuxSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun v18AuxSamples(deviceId: String, from: Long, to: Long, limit: Int):
        List<V18AuxSampleEntity>

    /** Aggregate HR over a window (one indexed (deviceId,ts) range scan — no row materialisation,
     *  no [hrSamples] LIMIT truncation). Backs the imported-workout HR fallback (#77).
     *
     *  #836: aggregates the SAME measured-∪-PPG rows [hrSamples] returns, not `hrSample` alone. It used
     *  to read only measured rows, so on a WHOOP 5 — where the firmware banks v26 PPG instead of v18 HR
     *  per second — a PPG-heavy workout charted a full trace (the chart uses [hrSamples]) while this
     *  counted under `fillWorkoutHrFromStrap`'s 60-sample floor, and Avg HR rendered blank. iOS never had
     *  it: its twin reduces `store.hrSamples`, the coalescing read. Same anti-join as [hrSamples], so a
     *  measured second is never double-counted by its PPG estimate. */
    @Query(
        // #856: up to TWO ids, :primaryId winning per second. A naive `deviceId IN (…)` would count a
        // second banked under BOTH ids twice after a strap re-add, inflating n and skewing avg — and
        // both numbers would stay plausible, so nothing would look wrong. GROUP BY ts with MIN(pri)
        // keeps one row per second and takes the primary's, matching the dedup the chart already does.
        // Passing the same id for both is byte-identical to the old single-id read.
        "SELECT COUNT(*) AS n, AVG(bpm) AS avg, MAX(bpm) AS max FROM (" +
            "SELECT ts, MIN(pri), bpm FROM (" +
            "SELECT ts, bpm, 0 AS pri FROM hrSample " +
            "WHERE deviceId = :primaryId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.ts AS ts, p.bpm AS bpm, 0 AS pri FROM ppgHrSample p " +
            "WHERE p.deviceId = :primaryId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts) " +
            "UNION ALL " +
            "SELECT ts, bpm, 1 AS pri FROM hrSample " +
            "WHERE deviceId = :secondaryId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.ts AS ts, p.bpm AS bpm, 1 AS pri FROM ppgHrSample p " +
            "WHERE p.deviceId = :secondaryId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts) " +
            ") GROUP BY ts" +
            ")"
    )
    suspend fun hrWindowStats(primaryId: String, secondaryId: String, from: Long, to: Long): HrWindowStats

    @Query(
        // #823: `ord` FIRST, so same-second beats come back in EMISSION order. Ordering by rrMs made
        // successive beats similar by construction and biased RMSSD (all successive differences) down.
        // Pre-v24 rows have ord NULL and SQLite sorts NULL first in ASC, so an all-NULL second ties here
        // and falls through to the old (rrMs, seq) order — unchanged for existing data, and deterministic.
        // Byte-parity twin of Swift Reads.swift rrIntervals; both are SQLite, so NULL ordering matches.
        // Note this no longer matches the PK index (ts, rrMs, seq), so SQLite sorts; see the PR for why
        // that is acceptable at this query's size rather than adding a covering index.
        "SELECT * FROM rrInterval WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT :limit"
    )
    suspend fun rrIntervals(deviceId: String, from: Long, to: Long, limit: Int): List<RrInterval>

    @Query(
        "SELECT * FROM event WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC, kind ASC LIMIT :limit"
    )
    suspend fun events(deviceId: String, from: Long, to: Long, limit: Int): List<EventRow>

    @Query(
        "SELECT * FROM battery WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun batterySamples(deviceId: String, from: Long, to: Long, limit: Int): List<BatterySample>

    @Query(
        "SELECT * FROM spo2Sample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun spo2Samples(deviceId: String, from: Long, to: Long, limit: Int): List<Spo2Sample>

    @Query(
        "SELECT * FROM skinTempSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun skinTempSamples(deviceId: String, from: Long, to: Long, limit: Int): List<SkinTempSample>

    @Query(
        "SELECT * FROM stepSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun stepSamples(deviceId: String, from: Long, to: Long, limit: Int): List<StepSample>

    /** The strap's OWN banked band sleep_state (#175) in [from, to], ascending. Feeds the Deep Timeline
     *  band-state track and the per-session grid the H7 re-onset confirm guard reads. */
    @Query(
        "SELECT * FROM sleepStateSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun sleepStateSamples(deviceId: String, from: Long, to: Long, limit: Int): List<SleepStateSampleEntity>

    @Query(
        "SELECT * FROM respSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun respSamples(deviceId: String, from: Long, to: Long, limit: Int): List<RespSample>

    @Query(
        "SELECT * FROM gravitySample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun gravitySamples(deviceId: String, from: Long, to: Long, limit: Int): List<GravitySample>

    // MARK: - Daily metrics / sleep reads (mirror MetricsCache.swift)

    /**
     * Cached daily metrics for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest first.
     * Port of MetricsCache.swift dailyMetrics(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM dailyMetric WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun dailyMetricsRange(deviceId: String, from: String, to: String): List<DailyMetric>

    /**
     * Delete a source's cached daily rows whose day-key is in [from, to] (inclusive, yyyy-MM-dd
     * lexicographic = chronological). The #277 local-day re-bucketing migration uses this to drop the
     * computed ("-noop") UTC-keyed rows across the recompute window before re-upserting the LOCAL-keyed
     * rows, so a UTC/local duplicate day can't linger. Source-scoped, so imported "my-whoop" rows are
     * never touched. Mirrors WhoopStore MetricsCache.deleteDailyMetrics.
     */
    @Query("DELETE FROM dailyMetric WHERE deviceId = :deviceId AND day >= :from AND day <= :to")
    suspend fun deleteDailyMetricsInRange(deviceId: String, from: String, to: String)

    /** All cached daily metrics for a device, oldest first. Convenience for analytics windows. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    suspend fun days(deviceId: String): List<DailyMetric>

    /** Scalar COUNT twin of [days], for count badges that were materializing every row for `.size`. */
    @Query("SELECT COUNT(*) FROM dailyMetric WHERE deviceId = :deviceId")
    suspend fun daysCount(deviceId: String): Int

    /** Reactive stream of all daily metrics for a device, oldest first. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>>

    /**
     * Every distinct source id with at least one cached daily row. The Health Connect backfill's
     * covered-days gate filters these to the strap-native ids
     * (HealthConnectImporter.isStrapNativeSourceId), so its #112 skip-set also covers an actively
     * paired strap's "whoop-<mac>" / "whoop-<mac>-noop" rows — not just the canonical
     * "my-whoop" / "my-whoop-noop" pair.
     */
    @Query("SELECT DISTINCT deviceId FROM dailyMetric")
    suspend fun dailyMetricDeviceIds(): List<String>

    /**
     * #112 follow-up heal: delete un-edited "my-whoop" sleep sessions that carry NO signal beyond a
     * window (no efficiency / restingHr / avgHrv / motionJSON / sleepStateJSON — exactly the shape the
     * Health Connect backfill writes) when a computed ("-noop") session overlaps the same window.
     * These are the shadow rows an HC import wrote while the covered-days gate missed active-strap
     * ids; once purged, the richer computed night wins the merge again. Rows a WHOOP CSV / wearable
     * export wrote carry efficiency (or HR/HRV), and userEdited rows are never touched, so real data
     * survives. Idempotent: a re-run matches nothing.
     */
    @Query(
        "DELETE FROM sleepSession WHERE deviceId = 'my-whoop' AND userEdited = 0 " +
            "AND efficiency IS NULL AND restingHr IS NULL AND avgHrv IS NULL " +
            "AND motionJSON IS NULL AND sleepStateJSON IS NULL " +
            "AND EXISTS (SELECT 1 FROM sleepSession c WHERE c.deviceId LIKE '%-noop' " +
            "AND c.startTs < sleepSession.endTs AND c.endTs > sleepSession.startTs)"
    )
    suspend fun purgeHcShadowedSleepSessions(): Int

    /**
     * #112 follow-up heal (daily half): delete "my-whoop" daily rows shaped like the Health Connect
     * backfill (no efficiency / stage minutes / disturbances / recovery / strain / steps — HC only
     * writes totals + vitals) on a day a computed ("-noop") source also covers. A sparse row like
     * this shadows the computed day in the imported-wins merge (#112), blanking Today / regressing
     * Sleep stages. CSV-imported days carry stage minutes + efficiency and are never matched.
     */
    @Query(
        "DELETE FROM dailyMetric WHERE deviceId = 'my-whoop' " +
            "AND efficiency IS NULL AND deepMin IS NULL AND remMin IS NULL AND lightMin IS NULL " +
            "AND disturbances IS NULL AND recovery IS NULL AND strain IS NULL " +
            "AND steps IS NULL AND activeKcalEst IS NULL " +
            "AND day IN (SELECT day FROM dailyMetric d WHERE d.deviceId LIKE '%-noop')"
    )
    suspend fun purgeHcShadowedDailyMetrics(): Int

    /**
     * #797: the most-recent [limit] daily metrics for a device, returned oldest-first. Backs the bounded
     * dashboard merge: the SQL takes the newest rows (ORDER BY day DESC LIMIT), and the repository flips
     * them to ascending so every downstream consumer sees the SAME oldest-first order as [daysFlow]. A
     * generous bound (the repository's RECENT_DAYS_CAP) keeps every current surface intact (Trends' deepest
     * view, Fitness Age / Vitality 7-day windows) while a years-deep import no longer re-merges the WHOLE
     * history on every DB change.
     */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day DESC LIMIT :limit")
    fun recentDaysFlow(deviceId: String, limit: Int): Flow<List<DailyMetric>>

    @Query(
        "SELECT * FROM sleepSession WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int): List<SleepSession>

    /** Hand-edited sessions for a device (userEdited = 1), oldest first. Backs the H5 edit-merge (#509):
     *  the repository maps each to its LOCAL wake-day so [WhoopRepository.mergeDaily] lets the computed
     *  sleep fields win on those days over a re-imported night. */
    @Query("SELECT * FROM sleepSession WHERE deviceId = :deviceId AND userEdited = 1 ORDER BY startTs ASC")
    suspend fun editedSleepSessions(deviceId: String): List<SleepSession>

    /** Reactive variant of [editedSleepSessions] for the merged daily Flow. */
    @Query("SELECT * FROM sleepSession WHERE deviceId = :deviceId AND userEdited = 1 ORDER BY startTs ASC")
    fun editedSleepSessionsFlow(deviceId: String): Flow<List<SleepSession>>

    // MARK: - Generic metric series (Swift metricSeries, v9)

    @Query(
        "SELECT * FROM metricSeries WHERE deviceId = :deviceId AND key = :key AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun metricSeries(
        deviceId: String,
        key: String,
        from: String,
        to: String,
    ): List<MetricSeriesRow>

    /** Distinct metric keys present for a device, sorted ascending (Swift metricKeys, v9). */
    @Query("SELECT DISTINCT key FROM metricSeries WHERE deviceId = :deviceId ORDER BY key ASC")
    suspend fun metricKeys(deviceId: String): List<String>

    /** Row count for one (deviceId, key) series — the scalar COUNT twin of [metricSeries], for count
     *  badges (Data Sources) that were materializing the full history just to call `.size`. */
    @Query("SELECT COUNT(*) FROM metricSeries WHERE deviceId = :deviceId AND key = :key")
    suspend fun metricSeriesKeyCount(deviceId: String, key: String): Int

    /** The NEWEST row of a (deviceId, key) series, or null — the ORDER BY day DESC LIMIT 1 twin of
     *  [metricSeries] for latest-value tiles (day is yyyy-MM-dd, so lexicographic MAX(day) = newest).
     *  Rides the same idx_metricSeries_device_key_day index, so the read stops at one row instead of
     *  materializing the whole series for a `.lastOrNull()`. */
    @Query("SELECT * FROM metricSeries WHERE deviceId = :deviceId AND key = :key ORDER BY day DESC LIMIT 1")
    suspend fun latestMetricSeriesRow(deviceId: String, key: String): MetricSeriesRow?

    /** Delete one projected day for a key (used when a Lab Book reading's last numeric value
     *  for a (markerKey, day) cell is removed). Swift LabMarkerStore.reprojectCells delete branch. */
    @Query("DELETE FROM metricSeries WHERE deviceId = :deviceId AND day = :day AND key = :key")
    suspend fun deleteMetricSeriesPoint(deviceId: String, day: String, key: String)

    // MARK: - Lab Book markers (Swift labMarker, v17 / LabMarkerStore.swift)
    //
    // The book is `labMarker` (one row per dated reading the user entered themselves); the daily
    // `metricSeries` projection under source [LAB_BOOK_SOURCE_ID] is HOW the book talks to the rest
    // of the app. [upsertLabMarkers] / [deleteLabMarker] keep the two in lockstep in a single
    // transaction, byte-identical to the Swift LabMarkerStore.

    /** Raw upsert of marker rows by the natural key (UNIQUE index idx_labMarker_natural): a
     *  re-import of the same (deviceId, markerKey, takenAt, source) REPLACEs in place rather than
     *  duplicating, mirroring the Swift `ON CONFLICT(deviceId, markerKey, takenAt, source) DO UPDATE`.
     *  Prefer [upsertLabMarkers] (which also re-projects); this primitive backs it. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertLabMarkersRaw(rows: List<LabMarkerRow>)

    /** All readings in a category, oldest first (by takenAt). */
    @Query("SELECT * FROM labMarker WHERE deviceId = :deviceId AND category = :category ORDER BY takenAt ASC")
    suspend fun labMarkersByCategory(deviceId: String, category: String): List<LabMarkerRow>

    /** Full reading history for one marker, oldest first (by takenAt). */
    @Query("SELECT * FROM labMarker WHERE deviceId = :deviceId AND markerKey = :markerKey ORDER BY takenAt ASC")
    suspend fun labMarkersByKey(deviceId: String, markerKey: String): List<LabMarkerRow>

    /** Distinct marker keys present for a device, sorted ascending. */
    @Query("SELECT DISTINCT markerKey FROM labMarker WHERE deviceId = :deviceId ORDER BY markerKey ASC")
    suspend fun markerKeysPresent(deviceId: String): List<String>

    /** One reading by id, or null. Backs the delete-then-reproject flow. */
    @Query("SELECT * FROM labMarker WHERE id = :id")
    suspend fun labMarkerById(id: String): LabMarkerRow?

    /** Latest NUMERIC value for a (markerKey, day) cell (greatest takenAt with value not null),
     *  or null if the cell has no numeric reading. The latest-per-day projection rule. */
    @Query(
        "SELECT value FROM labMarker " +
            "WHERE deviceId = :deviceId AND markerKey = :markerKey AND day = :day AND value IS NOT NULL " +
            "ORDER BY takenAt DESC LIMIT 1"
    )
    suspend fun latestNumericForCell(deviceId: String, markerKey: String, day: String): Double?

    @Query("DELETE FROM labMarker WHERE id = :id")
    suspend fun deleteLabMarkerRaw(id: String)

    /**
     * Upsert marker rows, then re-project each affected (markerKey, day) cell into `metricSeries`
     * under [LAB_BOOK_SOURCE_ID]. Idempotent by natural key; LATEST-numeric-per-day wins in the
     * projection (qualitative valueText-only readings never project a REAL cell). Atomic — the
     * marker write and the projection can't diverge. Byte-identical to Swift
     * WhoopStore.upsertLabMarkers.
     */
    @Transaction
    suspend fun upsertLabMarkers(rows: List<LabMarkerRow>) {
        if (rows.isEmpty()) return
        insertLabMarkersRaw(rows)
        // Distinct touched cells, in a deterministic order.
        val cells = rows.map { Triple(it.deviceId, it.markerKey, it.day) }.toSet()
        for ((deviceId, markerKey, day) in cells) {
            reprojectCell(deviceId, markerKey, day)
        }
    }

    /**
     * Delete one reading by id; if it was the last numeric reading for its (markerKey, day) cell the
     * projected day is removed, otherwise the projection is recomputed from the remainder. Returns
     * true if a row was deleted. Byte-identical to Swift WhoopStore.deleteLabMarker.
     */
    @Transaction
    suspend fun deleteLabMarker(id: String): Boolean {
        val row = labMarkerById(id) ?: return false
        deleteLabMarkerRaw(id)
        reprojectCell(row.deviceId, row.markerKey, row.day)
        return true
    }

    /** Recompute the `metricSeries` projection (under [LAB_BOOK_SOURCE_ID]) for one cell from the
     *  CURRENT labMarker rows: latest-numeric-per-day wins; no numeric reading → drop the day. */
    @Transaction
    suspend fun reprojectCell(deviceId: String, markerKey: String, day: String) {
        val latest = latestNumericForCell(deviceId, markerKey, day)
        if (latest != null) {
            upsertMetricSeries(listOf(MetricSeriesRow(LAB_BOOK_SOURCE_ID, day, markerKey, latest)))
        } else {
            deleteMetricSeriesPoint(LAB_BOOK_SOURCE_ID, day, markerKey)
        }
    }

    companion object {
        /** The constant device-id the daily marker projection is written under, so Compare/Explore/
         *  Coach see markers as a single-source series (Swift WhoopStore.labBookSourceId). */
        const val LAB_BOOK_SOURCE_ID = "lab-book"
    }

    // MARK: - One-time #34 refile: separate legacy Health Connect data from the Apple Health bucket.
    // Only an Apple Health EXPORT writes metricSeries, so metricSeries-count==0 means the apple-health
    // daily rows are Health-Connect-origin and safe to move. HC workouts are tagged source so they move
    // unconditionally. Safe on first run: no `to` rows exist yet (no PK conflict), and post-#34 nothing
    // ever writes HC data to apple-health again, so it's idempotent (re-runs match 0 rows).
    @Query("SELECT COUNT(*) FROM metricSeries WHERE deviceId = :deviceId")
    suspend fun metricSeriesCount(deviceId: String): Int

    @Query("UPDATE appleDaily SET deviceId = :to WHERE deviceId = :from")
    suspend fun reassignAppleDaily(from: String, to: String)

    @Query("UPDATE workout SET deviceId = :to WHERE deviceId = :from AND source = :source")
    suspend fun reassignWorkoutsBySource(from: String, to: String, source: String)

    // MARK: - Journal / workouts / Apple-Health reads (mirror JournalWorkoutAppleCache.swift, v8)

    /**
     * Journal entries for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest day first
     * then by question. Port of JournalWorkoutAppleCache.swift journalEntries(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM journal WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC, question ASC"
    )
    suspend fun journal(deviceId: String, from: String, to: String): List<JournalEntry>

    /**
     * Delete one journal answer by natural key (the native logging card's "clear"). Source-scoped
     * by deviceId, so clearing a native ("noop-journal") answer never removes an identical imported
     * row. Port of JournalWorkoutAppleCache.swift deleteJournal(deviceId:day:question:).
     */
    @Query("DELETE FROM journal WHERE deviceId = :deviceId AND day = :day AND question = :question")
    suspend fun deleteJournalEntry(deviceId: String, day: String, question: String)

    /**
     * Delete a device's journal within a day range (#136). The WHOOP importer clears exactly the span
     * it re-writes before upserting, so the wake-day keying fix doesn't leave pre-fix onset-keyed rows
     * behind as duplicates. Bounded to [from, to] — journal outside the imported range is never touched.
     * Source-scoped by deviceId, so the native ("noop-journal") log is never touched.
     */
    @Query("DELETE FROM journal WHERE deviceId = :deviceId AND day >= :from AND day <= :to")
    suspend fun deleteJournalRange(deviceId: String, from: String, to: String)

    /**
     * Atomically replace a device's journal within a day range (#136): clear [from, to] then upsert
     * [rows] in ONE transaction, so a crash mid-import can't leave the range deleted-but-not-repopulated.
     */
    @Transaction
    suspend fun replaceJournalRange(deviceId: String, from: String, to: String, rows: List<JournalEntry>) {
        deleteJournalRange(deviceId, from, to)
        upsertJournal(rows)
    }

    /**
     * Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited.
     * Port of JournalWorkoutAppleCache.swift workouts(deviceId:from:to:limit:).
     */
    @Query(
        "SELECT * FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int): List<WorkoutRow>

    /** Scalar COUNT twin of [workouts] (no row limit — a count badge wants the exact total), for
     *  badges that were materializing the row list for `.size`. */
    @Query("SELECT COUNT(*) FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to")
    suspend fun workoutsCount(deviceId: String, from: Long, to: Long): Int

    /**
     * Apple-Health daily aggregates for days in [from, to] (lexicographic compare), oldest first.
     * Port of JournalWorkoutAppleCache.swift appleDaily(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM appleDaily WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily>

    /** Scalar COUNT twin of [appleDaily], for badges that were materializing the rows for `.size`. */
    @Query("SELECT COUNT(*) FROM appleDaily WHERE deviceId = :deviceId AND day >= :from AND day <= :to")
    suspend fun appleDailyCount(deviceId: String, from: String, to: String): Int

    /** Delete a computed source's workouts of a given [sport] whose startTs is in [from, to]
     *  (makes detected-workout re-derivation idempotent). (#78) */
    @Query("DELETE FROM workout WHERE deviceId = :deviceId AND sport = :sport AND startTs >= :from AND startTs <= :to")
    suspend fun deleteWorkoutsBySport(deviceId: String, sport: String, from: Long, to: Long)

    /** Delete ONE workout by its full natural key (deviceId, startTs, sport). Used by the Workouts
     *  screen to remove a single manual / re-labelled session. (#107) */
    @Query("DELETE FROM workout WHERE deviceId = :deviceId AND startTs = :startTs AND sport = :sport")
    suspend fun deleteWorkoutByKey(deviceId: String, startTs: Long, sport: String)

    // MARK: - Dismissed detected bouts (durable #107 marker; survives engine re-detection)

    /** Record a dismissed detected bout. IGNORE so re-dismissing the same bout is a no-op. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertDismissed(rows: List<DismissedWorkout>)

    /** All dismissed markers for a [deviceId] (the computed "<id>-noop" source the detector writes). */
    @Query("SELECT * FROM dismissedWorkout WHERE deviceId = :deviceId")
    suspend fun dismissedWorkouts(deviceId: String): List<DismissedWorkout>

    /** Record a deleted sleep night (#33). IGNORE so re-deleting the same night is a no-op. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertDismissedSleep(rows: List<DismissedSleep>)

    /** All deleted-sleep markers for a [deviceId]. The engine reads the UNION of the imported id and its
     *  computed "<id>-noop" id (see WhoopRepository.dismissedSleeps, #65 3A), since a tombstone is written
     *  under whichever namespace owned the deleted row. */
    @Query("SELECT * FROM dismissedSleep WHERE deviceId = :deviceId")
    suspend fun dismissedSleeps(deviceId: String): List<DismissedSleep>

    /** Hide one tombstone from the Sleep screen's recompute list while leaving the row in place so the
     *  detector continues to suppress the sleep the user deliberately deleted (#515). */
    @Query(
        "UPDATE dismissedSleep SET managementVisible = 0 " +
            "WHERE deviceId = :deviceId AND startTs = :startTs",
    )
    suspend fun hideDismissedSleepFromManagement(deviceId: String, startTs: Long): Int

    /** Lift ONE deleted-sleep tombstone (#65 undo / "allow re-detection"): removes the marker so the
     *  night is re-detected from raw on the next analyze pass. Keyed by (deviceId, startTs): the same
     *  natural key the insert uses, so it removes exactly the tombstone [deleteSleepSession] wrote. */
    @Query("DELETE FROM dismissedSleep WHERE deviceId = :deviceId AND startTs = :startTs")
    suspend fun deleteDismissedSleep(deviceId: String, startTs: Long)

    // MARK: - Frontier / stats (Reads.swift)

    /** Max HR sample ts for a device, or null if none — the biometric data frontier.
     *  COALESCEs measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156) so a PPG-only
     *  offload (a v26 WHOOP 5 night with no measured HR) still advances the frontier, matching the
     *  Swift reader (Reads.swift latestHrSampleTs). Both persist on the same per-second ts grid.
     *
     *  Each arm is its OWN `SELECT MAX(ts)` rather than one `MAX(ts)` over a `UNION ALL` of the two
     *  timestamp streams. SQLite's MIN/MAX optimization only fires on a bare `SELECT MAX(col)` that can
     *  seek the last matching index entry; wrapping the columns in a compound subquery first makes the
     *  planner materialize it and walk EVERY index entry for the device. Measured on Apple against a
     *  746 MB store (3.1M hrSample rows) at 4.3–5.8 s for the old shape and 0.01–0.07 s for this one
     *  (#908); Room is SQLite, so the same plan applies here, and this reader is on paths a user waits
     *  on — FullDayChartScreen's land-on-the-latest-day effect and DataSourcesScreen's load.
     *
     *  Identical answer in every case: each scalar subquery is NULL when that stream has no rows for the
     *  device, MAX() ignores NULLs, and both-empty stays NULL. Both arms are aliased because Room
     *  verifies queries at compile time and only the first arm's names survive a compound select. */
    @Query(
        "SELECT MAX(m) FROM (" +
            "SELECT (SELECT MAX(ts) FROM hrSample WHERE deviceId = :deviceId) AS m " +
            "UNION ALL " +
            "SELECT (SELECT MAX(ts) FROM ppgHrSample WHERE deviceId = :deviceId) AS m)",
    )
    suspend fun latestHrSampleTs(deviceId: String): Long?

    @Query("SELECT COUNT(*) FROM hrSample") suspend fun countHr(): Int
    // #836: max raw-HR timestamp across all devices. Paired with countHr() as a cheap whole-history change
    // fingerprint so the 15-min idle rescore can skip when nothing new has landed (COALESCE → 0 when empty).
    @Query("SELECT COALESCE(MAX(ts), 0) FROM hrSample") suspend fun maxHrTs(): Long
    @Query("SELECT COUNT(*) FROM rrInterval") suspend fun countRr(): Int
    @Query("SELECT COUNT(*) FROM event") suspend fun countEvents(): Int
    @Query("SELECT COUNT(*) FROM battery") suspend fun countBattery(): Int
    @Query("SELECT COUNT(*) FROM spo2Sample") suspend fun countSpo2(): Int
    @Query("SELECT COUNT(*) FROM skinTempSample") suspend fun countSkinTemp(): Int
    @Query("SELECT COUNT(*) FROM stepSample") suspend fun countSteps(): Int
    @Query("SELECT COUNT(*) FROM respSample") suspend fun countResp(): Int
    @Query("SELECT COUNT(*) FROM gravitySample") suspend fun countGravity(): Int

    // MARK: - Live convenience reads

    /** Latest HR sample for a device (most recent ts), or null. */
    @Query("SELECT * FROM hrSample WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT 1")
    suspend fun latestHr(deviceId: String): HrSample?

    /** Latest battery sample for a device (most recent ts), or null. */
    @Query("SELECT * FROM battery WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT 1")
    suspend fun latestBattery(deviceId: String): BatterySample?

    // MARK: - #547 one-time heal: purge rows polluted by a bad-strap-clock timestamp
    //
    // pikapik's WHOOP 4.0 (#547) emitted records whose `unix` decoded to garbage (far-past / a 2027 spike
    // / a future date), which entered the DB verbatim before the ingest gate existed. These deletes purge
    // the already-stored pollution ONCE on upgrade across EVERY device id (the bad rows can sit under
    // "my-whoop" raw streams AND the "-noop" computed daily/sleep rows), so a normal analyzeRecent rescore
    // recomputes the real days cleanly. Bounds are passed in from [MIN_PLAUSIBLE_UNIX]/[FUTURE_MARGIN]; the
    // future-day string is the local "today" key so a future-DATED computed day is removed. Each returns
    // the row count deleted (for the heal log). Re-running is harmless (idempotent — nothing left to match).

    /** Raw stream rows whose unix-second `ts` is implausible (before [minTs] or after [maxTs]). One per
     *  raw table (all keyed by `ts`); summed by the repository. */
    @Query("DELETE FROM hrSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneHrByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM ppgHrSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun prunePpgHrByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM rrInterval WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneRrByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM skinTempSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneSkinTempByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM stepSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneStepByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM respSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneRespByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM gravitySample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneGravityByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM spo2Sample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneSpo2ByTs(minTs: Long, maxTs: Long): Int

    // The instrumentation streams landed AFTER this heal was written and were never added to it, so a
    // bad-clock strap's garbage-ts rows survived in them while every sibling stream above was cleaned.
    // They are keyed by the SAME `ts` from the SAME type-47 ingest path, so there is no reason to exempt
    // them. Legacy-rows only in practice (the #547 ingest gate now rejects an implausible ts before it is
    // banked), which is why it went unnoticed. Swift twin: TimestampHeal.rawTables.
    @Query("DELETE FROM sleepStateSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneSleepStateByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM ppgWaveformSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun prunePpgWaveformByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM rawImuSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneRawImuByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM v18AuxSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneV18AuxByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM event WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneEventByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM battery WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneBatteryByTs(minTs: Long, maxTs: Long): Int

    /** Daily-metric rows whose `day` key is FUTURE (lexicographically after [today], valid for "yyyy-MM-dd",
     *  any source) or implausibly old (before [minDay]) AND computed (`-noop`). The far-past floor is
     *  `-noop`-scoped so a WHOOP CSV import (bare "my-whoop") carrying REAL multi-year history is never
     *  purged (v8.2.1). String compare is correct for ISO dates. */
    @Query("DELETE FROM dailyMetric WHERE day > :today OR (day < :minDay AND deviceId LIKE '%-noop')")
    suspend fun pruneDailyMetricByDay(today: String, minDay: String): Int

    /** Sleep-session rows whose onset `startTs` is future (after [maxTs], any source) or implausibly old
     *  (before [minTs]) AND computed (`-noop`), so an imported multi-year sleep history survives (v8.2.1). */
    @Query("DELETE FROM sleepSession WHERE startTs > :maxTs OR (startTs < :minTs AND deviceId LIKE '%-noop')")
    suspend fun pruneSleepSessionByTs(minTs: Long, maxTs: Long): Int
}
