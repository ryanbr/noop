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

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertResp(rows: List<RespSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertGravity(rows: List<GravitySample>): List<Long>

    /** PPG-derived HR from the v26 optical waveform. Idempotent by (deviceId, ts). (#156) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertPpgHr(rows: List<PpgHrSample>): List<Long>

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

    @Upsert
    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>)

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

    /** Aggregate HR over a window (one indexed (deviceId,ts) range scan — no row materialisation,
     *  no [hrSamples] LIMIT truncation). Backs the imported-workout HR fallback (#77). */
    @Query(
        "SELECT COUNT(*) AS n, AVG(bpm) AS avg, MAX(bpm) AS max FROM hrSample " +
            "WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to"
    )
    suspend fun hrWindowStats(deviceId: String, from: Long, to: Long): HrWindowStats

    @Query(
        "SELECT * FROM rrInterval WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC, rrMs ASC LIMIT :limit"
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

    /** Reactive stream of all daily metrics for a device, oldest first. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>>

    @Query(
        "SELECT * FROM sleepSession WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int): List<SleepSession>

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
     * Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited.
     * Port of JournalWorkoutAppleCache.swift workouts(deviceId:from:to:limit:).
     */
    @Query(
        "SELECT * FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int): List<WorkoutRow>

    /**
     * Apple-Health daily aggregates for days in [from, to] (lexicographic compare), oldest first.
     * Port of JournalWorkoutAppleCache.swift appleDaily(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM appleDaily WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily>

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

    /** All deleted-sleep markers for a [deviceId] (the computed "<id>-noop" source the engine writes). */
    @Query("SELECT * FROM dismissedSleep WHERE deviceId = :deviceId")
    suspend fun dismissedSleeps(deviceId: String): List<DismissedSleep>

    // MARK: - Frontier / stats (Reads.swift)

    /** Max HR sample ts for a device, or null if none — the biometric data frontier.
     *  COALESCEs measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156) so a PPG-only
     *  offload (a v26 WHOOP 5 night with no measured HR) still advances the frontier, matching the
     *  Swift reader (Reads.swift latestHrSampleTs). Both persist on the same per-second ts grid. */
    @Query(
        "SELECT MAX(ts) FROM (" +
            "SELECT ts FROM hrSample WHERE deviceId = :deviceId " +
            "UNION ALL " +
            "SELECT ts FROM ppgHrSample WHERE deviceId = :deviceId)",
    )
    suspend fun latestHrSampleTs(deviceId: String): Long?

    @Query("SELECT COUNT(*) FROM hrSample") suspend fun countHr(): Int
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
}
