package com.noop.data

import android.content.Context
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlin.math.roundToInt

/**
 * Decoded streams to persist in one transaction. Android mirror of the Swift `Streams`
 * struct (Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift) carrying the rows
 * for a single flush/backfill chunk. All `ts` values are wall-clock unix seconds (Long).
 *
 * The protocol/decoder layer builds one of these (deviceId stamped at insert time, not
 * stored on the per-row sample models — it is supplied to [WhoopRepository.insert]).
 */
data class StreamBatch(
    val hr: List<HrRow> = emptyList(),
    val rr: List<RrRow> = emptyList(),
    val events: List<EventEntry> = emptyList(),
    val battery: List<BatteryRow> = emptyList(),
    val spo2: List<Spo2Row> = emptyList(),
    val skinTemp: List<SkinTempRow> = emptyList(),
    val resp: List<RespRow> = emptyList(),
    val gravity: List<GravityRow> = emptyList(),
    val steps: List<StepRow> = emptyList(),
    /** HR derived from the WHOOP 5/MG v26 optical PPG waveform (autocorrelation). (#156) */
    val ppgHr: List<PpgHrRow> = emptyList(),
) {
    val isEmpty: Boolean
        get() = hr.isEmpty() && rr.isEmpty() && events.isEmpty() && battery.isEmpty() &&
            spo2.isEmpty() && skinTemp.isEmpty() && resp.isEmpty() && gravity.isEmpty() &&
            steps.isEmpty() && ppgHr.isEmpty()
}

// Device-agnostic decoded rows (deviceId attached when inserted). Mirror Streams.swift shapes.
data class HrRow(val ts: Long, val bpm: Int)
data class RrRow(val ts: Long, val rrMs: Int)

/** payloadJSON is the deterministic sorted-keys JSON for the remaining parsed fields. */
data class EventEntry(val ts: Long, val kind: String, val payloadJSON: String)
data class BatteryRow(val ts: Long, val soc: Double?, val mv: Int?, val charging: Boolean? = null)
data class Spo2Row(val ts: Long, val red: Int, val ir: Int)
data class SkinTempRow(val ts: Long, val raw: Int)
/**
 * Cumulative u16 step/motion counter at [ts] (WHOOP5 step_motion_counter@57). deviceId attached on insert. (#78)
 * [activityClass] is the per-record activity-class enum from @63 (community finding #316): 0=still, 1=walk,
 * 2=run; null when the byte was 0xFF/invalid or absent. Optional + defaulted so existing call sites and the
 * persisted store (which carries only ts/counter today) are unchanged.
 */
data class StepRow(val ts: Long, val counter: Int, val activityClass: Int? = null)
data class RespRow(val ts: Long, val raw: Int)
data class GravityRow(val ts: Long, val x: Double, val y: Double, val z: Double)
/** HR derived from the v26 PPG waveform: [ts] window-centre sec, [bpm], [conf] in 0…1. (#156) */
data class PpgHrRow(val ts: Long, val bpm: Int, val conf: Double)

/** Count of rows ACTUALLY inserted per stream (mirrors WhoopStore.insert return tuple). */
data class InsertCounts(
    val hr: Int = 0,
    val rr: Int = 0,
    val events: Int = 0,
    val battery: Int = 0,
    val spo2: Int = 0,
    val skinTemp: Int = 0,
    val steps: Int = 0,
    val resp: Int = 0,
    val gravity: Int = 0,
)

/**
 * A compact snapshot of how much history each source holds, for the Data Sources "Freshness
 * Pipeline" card (PR#196). Counts only — no per-day rows leave the read. Port of macOS
 * RepositoryFreshness.
 */
data class DataFreshness(
    val importedDays: Int = 0,
    val computedDays: Int = 0,
    val appleDays: Int = 0,
    val importedSleeps: Int = 0,
    val computedSleeps: Int = 0,
    val earliestDay: String? = null,
    val latestDay: String? = null,
) {
    val hasAnyHistory: Boolean get() = importedDays > 0 || computedDays > 0 || appleDays > 0

    companion object {
        val EMPTY = DataFreshness()
    }
}

/**
 * Repository over [WhoopDatabase] / [WhoopDao]. The single seam the rest of the app uses
 * to read/write the local store. Port of WhoopStore's public surface (StreamStore.swift,
 * Reads.swift, MetricsCache.swift) — the phone does NO metric computation here; daily/sleep
 * rows are an offline cache of server-computed values.
 */
class WhoopRepository(private val dao: WhoopDao) {

    constructor(db: WhoopDatabase) : this(db.whoopDao())

    // MARK: - Device

    suspend fun upsertDevice(id: String, mac: String? = null, name: String? = null) {
        val now = System.currentTimeMillis() / 1000
        // Preserve firstSeen on update: read existing, keep its firstSeen if present.
        val existing = dao.device(id)
        dao.upsertDevice(
            DeviceRow(
                id = id,
                mac = mac,
                name = name,
                firstSeen = existing?.firstSeen ?: now,
                lastSeen = now,
            )
        )
    }

    // MARK: - Insert decoded streams (idempotent by natural key)

    /**
     * Persist one decoded batch under [deviceId]. Returns the number of rows actually inserted
     * per stream (0 for rows that already existed). Empty sub-lists compile/run nothing.
     * Port of WhoopStore.insert(_:deviceId:).
     */
    suspend fun insert(streams: StreamBatch, deviceId: String): InsertCounts {
        if (streams.isEmpty) return InsertCounts()

        val hrIds = if (streams.hr.isEmpty()) emptyList() else
            dao.insertHr(streams.hr.map { HrSample(deviceId, it.ts, it.bpm) })
        val rrIds = if (streams.rr.isEmpty()) emptyList() else
            dao.insertRr(streams.rr.map { RrInterval(deviceId, it.ts, it.rrMs) })
        val evIds = if (streams.events.isEmpty()) emptyList() else
            dao.insertEvents(streams.events.map { EventRow(deviceId, it.ts, it.kind, it.payloadJSON) })
        val batIds = if (streams.battery.isEmpty()) emptyList() else
            dao.insertBattery(streams.battery.map { BatterySample(deviceId, it.ts, it.soc, it.mv, it.charging) })
        val spo2Ids = if (streams.spo2.isEmpty()) emptyList() else
            dao.insertSpo2(streams.spo2.map { Spo2Sample(deviceId, it.ts, it.red, it.ir) })
        val skinIds = if (streams.skinTemp.isEmpty()) emptyList() else
            dao.insertSkinTemp(streams.skinTemp.map { SkinTempSample(deviceId, it.ts, it.raw) })
        val stepIds = if (streams.steps.isEmpty()) emptyList() else
            dao.insertSteps(streams.steps.map { StepSample(deviceId, it.ts, it.counter) })
        val respIds = if (streams.resp.isEmpty()) emptyList() else
            dao.insertResp(streams.resp.map { RespSample(deviceId, it.ts, it.raw) })
        val gravIds = if (streams.gravity.isEmpty()) emptyList() else
            dao.insertGravity(streams.gravity.map { GravitySample(deviceId, it.ts, it.x, it.y, it.z) })
        // v26 PPG-derived HR (#156). Idempotent by (deviceId, ts); counted into InsertCounts.hr so the
        // backfill "persisted N" summary reflects HR recovered from the optical waveform too.
        val ppgHrIds = if (streams.ppgHr.isEmpty()) emptyList() else
            dao.insertPpgHr(streams.ppgHr.map { PpgHrSample(deviceId, it.ts, it.bpm, it.conf) })

        // OnConflictStrategy.IGNORE returns -1 for skipped (already-present) rows; count the inserts.
        return InsertCounts(
            hr = hrIds.countInserted() + ppgHrIds.countInserted(),
            rr = rrIds.countInserted(),
            events = evIds.countInserted(),
            battery = batIds.countInserted(),
            spo2 = spo2Ids.countInserted(),
            skinTemp = skinIds.countInserted(),
            steps = stepIds.countInserted(),
            resp = respIds.countInserted(),
            gravity = gravIds.countInserted(),
        )
    }

    // MARK: - Server-derived caches (latest value wins on conflict)

    suspend fun upsertDailyMetrics(days: List<DailyMetric>) = dao.upsertDailyMetrics(days)
    suspend fun upsertSleepSessions(sessions: List<SleepSession>) = dao.upsertSleepSessions(sessions)

    /** Delete the computed source's cached daily rows whose day-key is in [from, to] (inclusive,
     *  yyyy-MM-dd). The #277 local-day re-bucketing migration clears the computed UTC-keyed rows over
     *  the recompute window before re-upserting LOCAL-keyed rows. Imported rows are never touched. */
    suspend fun deleteComputedDailyInRange(deviceId: String, from: String, to: String) =
        dao.deleteDailyMetricsInRange(deviceId, from, to)

    /** Hand-correct the bed (onset) / wake (end) time of an existing sleep session, DURABLY — port
     *  of iOS PR #395 (Repository.editSleepTimes + MetricsCache.applySleepEdit).
     *
     *  The corrected onset is stored in [SleepSession.startTsAdjusted] and [SleepSession.startTs] stays
     *  the IMMUTABLE detected primary key, so this upsert REPLACEs the existing (deviceId, startTs) row
     *  IN PLACE — no delete, no key move. [SleepSession.userEdited] is set true so the post-sync
     *  recompute's overlap guard (IntelligenceEngine) preserves the correction instead of re-inserting
     *  the strap-detected twin over it.
     *
     *  This fixes the prior Android bug: the old delete-then-reinsert MUTATED the startTs primary key,
     *  so a later analysis run (which re-detects the night at a slightly drifted startTs) inserted a
     *  SECOND row beside the edited one (different PK ⇒ no ON CONFLICT match), double-counting time in
     *  bed AND reverting the edit. Every other field (efficiency, restingHr, avgHrv, stagesJSON) is
     *  preserved via [SleepSession.copy]. */
    suspend fun updateSleepSessionTimes(session: SleepSession, newStartTs: Long, newEndTs: Long) {
        val reclipped = com.noop.analytics.SleepWindowReclip.reclip(
            session.stagesJSON, session.effectiveStartTs, session.endTs, newEndTs,
        )
        dao.upsertSleepSessions(
            listOf(session.copy(
                startTsAdjusted = newStartTs,
                endTs = newEndTs,
                userEdited = true,
                stagesJSON = reclipped ?: session.stagesJSON,
            )),
        )
    }

    /** Remove a sleep session entirely — the delete half of [updateSleepSessionTimes] with no
     *  re-insert. (deviceId, startTs) is the primary key, so it uniquely identifies the row, letting
     *  the user clear a misread or spurious night so the day recomputes without it (#281). */
    suspend fun deleteSleepSession(session: SleepSession) {
        dao.deleteSleepSession(session.deviceId, session.startTs)
        // #33: record a durable tombstone so the recompute doesn't regenerate this night (mirrors the
        // dismissedWorkout marker). `endTs` is the span the engine's overlap test uses, since a
        // re-detected onset can drift second-to-second.
        dao.insertDismissedSleep(listOf(DismissedSleep(session.deviceId, session.startTs, session.endTs)))
    }

    /** Manually ADD a missed sleep session — typically a daytime NAP the detector didn't pick up (#508).
     *  Port of iOS Repository.addManualNap + MetricsCache.insertManualSleepSession.
     *
     *  Stages the chosen window from the raw streams via [SleepStageHealer.restageFromRaw] (the SAME
     *  density gate + stager the bed/wake edit's self-heal uses), falling back to a single "wake" block
     *  when the strap has no dense data there yet — the post-sync self-heal then swaps in real stages
     *  once the raw lands. Written under the COMPUTED source as its OWN separate session
     *  (userEdited = true, startTsAdjusted = null), so the recompute overlap guard preserves it and it is
     *  NEVER folded into the night's main sleep (which would mislabel the awake daytime gap as light
     *  sleep). Purely additive — the DAO's IGNORE-on-conflict makes a same-onset add a no-op. */
    suspend fun addManualNap(strapDeviceId: String, startTs: Long, endTs: Long) {
        if (endTs <= startTs) return
        val computedId = computedDeviceId(strapDeviceId)
        val stagesJSON = com.noop.analytics.SleepStageHealer.restageFromRaw(this, strapDeviceId, startTs, endTs)
            ?: com.noop.analytics.AnalyticsEngine.encodeStages(
                listOf(com.noop.analytics.StageSegment(start = startTs, end = endTs, stage = "wake")),
            )
        dao.insertSleepSession(
            SleepSession(
                deviceId = computedId,
                startTs = startTs,
                endTs = endTs,
                efficiency = sleepEfficiency(stagesJSON),
                stagesJSON = stagesJSON,
                userEdited = true,
                startTsAdjusted = null,
            ),
        )
    }

    /** Asleep fraction (light+deep+rem ÷ total in-bed) of a segment-array [stagesJSON], or null when the
     *  JSON is the fallback wake-only block / unparseable. Seeds a manual nap's efficiency so its footer
     *  reads sensibly before the next recompute re-derives it. Mirrors iOS `sleepEfficiency`. (#508) */
    private fun sleepEfficiency(stagesJSON: String?): Double? {
        stagesJSON ?: return null
        val arr = runCatching { org.json.JSONArray(stagesJSON) }.getOrNull() ?: return null
        var asleep = 0.0
        var total = 0.0
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val s = o.optLong("start", -1L)
            val e = o.optLong("end", -1L)
            val stage = o.optString("stage")
            if (s < 0 || e <= s) continue
            val dur = (e - s).toDouble()
            total += dur
            if (stage != "wake" && stage != "awake") asleep += dur
        }
        return if (total > 0 && asleep > 0) asleep / total else null
    }

    /** Narrow stages-ONLY write for the post-sync self-heal (port of iOS PR #449
     *  MetricsCache.updateSleepStages, driven by [com.noop.analytics.SleepStageHealer]). Replaces a
     *  user-edited night's stage breakdown with stages re-derived from the now-available raw, leaving
     *  the corrected bed/wake bounds and the userEdited flag untouched. Scoped to userEdited=1 rows by
     *  the DAO query; keyed by the IMMUTABLE detected [detectedStartTs]. Returns rows changed. */
    suspend fun updateSleepStages(deviceId: String, detectedStartTs: Long, stagesJSON: String): Int =
        dao.updateSleepStages(deviceId, detectedStartTs, stagesJSON)
    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>) = dao.upsertMetricSeries(rows)
    suspend fun upsertJournal(rows: List<JournalEntry>) = dao.upsertJournal(rows)
    suspend fun upsertWorkouts(rows: List<WorkoutRow>) = dao.upsertWorkouts(rows)
    suspend fun upsertAppleDaily(rows: List<AppleDaily>) = dao.upsertAppleDaily(rows)

    // MARK: - Lab Book markers (Swift labMarker, v17). Writing also projects the daily series into
    // metricSeries under WhoopDao.LAB_BOOK_SOURCE_ID, so Compare/Explore/Coach see markers unchanged.
    suspend fun upsertLabMarkers(rows: List<LabMarkerRow>) = dao.upsertLabMarkers(rows)
    suspend fun deleteLabMarker(id: String): Boolean = dao.deleteLabMarker(id)
    suspend fun labMarkersByKey(deviceId: String, markerKey: String) = dao.labMarkersByKey(deviceId, markerKey)
    suspend fun labMarkersByCategory(deviceId: String, category: String) = dao.labMarkersByCategory(deviceId, category)
    suspend fun markerKeysPresent(deviceId: String) = dao.markerKeysPresent(deviceId)

    // MARK: - Reads

    suspend fun hrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.hrSamples(deviceId, from, to, limit)

    /** Raw measured HR only (no v26 PPG-derived union) for the raw-sensor diagnostic export. */
    suspend fun rawHrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.rawHrSamples(deviceId, from, to, limit)

    /** v26 PPG-derived HR samples (own stream) for the raw-sensor diagnostic export. (#156) */
    suspend fun ppgHrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.ppgHrSamples(deviceId, from, to, limit)

    /** Downsampled HR (mean bpm per [bucketSeconds]) for the strap, for the Today 24h trend chart. */
    suspend fun hrBuckets(deviceId: String, from: Long, to: Long, bucketSeconds: Long = 300L) =
        dao.hrBuckets(deviceId, from, to, bucketSeconds)

    /**
     * DISPLAY-ONLY: reconcile a workout's shown HR with the strap trace that actually drives its
     * graph / zones / effort (#77, #499). The detail screen always charts and zone-bins the strap's
     * own ~1 Hz samples over [startTs, endTs] (under [strapDeviceId]); the displayed Avg HR comes from
     * the stored `avgHr` column. Those two can DIVERGE — a hand-edited Avg (128→139) changes the number
     * but not the trace, so the average no longer matches the graph/zones/effort (#499). Here we make the
     * stored field defer to the trace whenever the trace is present:
     *
     *  - STRAP-NATIVE rows (source "manual" or detected "<id>-noop") are charted/zoned/scored straight
     *    from this strap trace, so their Avg HR is ALWAYS recomputed as the true mean of those samples —
     *    a manual edit can no longer drift it out of agreement with the graph. (max likewise → true peak.)
     *  - IMPORTED rows (Apple Health / Health Connect / Whoop CSV) carry their OWN avg/max from the
     *    import; we only FILL them when null (and the strap happened to be worn), never override a real
     *    imported value with strap-derived numbers.
     *
     * Requires [minSamples] (~1 min of data) so a few stray samples can't fabricate an average, and caps
     * the lookups so a huge history can't jank first paint. NEVER persisted — the derived value is a
     * read-time projection of the trace (the workout PK upsert would wipe it anyway, and re-deriving on
     * every load keeps display == graph == zones == effort by construction).
     */
    suspend fun fillWorkoutHrFromStrap(
        rows: List<WorkoutRow>,
        strapDeviceId: String = "my-whoop",
        minSamples: Long = 60,
        cap: Int = 300,
    ): List<WorkoutRow> {
        var budget = cap
        return rows.map { row ->
            if (row.endTs <= row.startTs || budget <= 0) return@map row
            // Strap-native rows are graphed/zoned/scored from the strap trace, so their Avg HR must come
            // from that same trace (recompute, overriding any stored/edited value). Imported rows keep
            // their own avg/max and are only filled when missing.
            val src = row.source.lowercase()
            val strapNative = src == "manual" || src.endsWith("-noop")
            if (!strapNative && row.avgHr != null) return@map row
            budget -= 1
            val stats = dao.hrWindowStats(strapDeviceId, row.startTs, row.endTs)
            if (stats.n >= minSamples && stats.avg != null && stats.max != null) {
                if (strapNative) {
                    // True mean / peak of the very samples the graph + zones + effort use.
                    row.copy(avgHr = stats.avg.roundToInt(), maxHr = stats.max)
                } else {
                    // Imported row with no avg — fill from strap, preserving any imported max.
                    row.copy(avgHr = stats.avg.roundToInt(), maxHr = row.maxHr ?: stats.max)
                }
            } else row
        }
    }

    suspend fun rrIntervals(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.rrIntervals(deviceId, from, to, limit)

    suspend fun events(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.events(deviceId, from, to, limit)

    suspend fun batterySamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.batterySamples(deviceId, from, to, limit)

    suspend fun spo2Samples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.spo2Samples(deviceId, from, to, limit)

    suspend fun skinTempSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.skinTempSamples(deviceId, from, to, limit)

    suspend fun stepSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.stepSamples(deviceId, from, to, limit)

    /** Delete a computed source's [sport] workouts in [from, to] (makes re-detection idempotent). (#78) */
    suspend fun deleteComputedWorkouts(deviceId: String, sport: String, from: Long, to: Long) =
        dao.deleteWorkoutsBySport(deviceId, sport, from, to)

    // MARK: - Workout editing (manual add/edit · relabel · dismiss · delete) (#107)
    //
    // Mirrors macOS Repository's workout-editing surface. Manual workouts live under the strap source
    // ([strapDeviceId], source "manual") — the same place live-tracked sessions land. Detected bouts
    // live under "<strapDeviceId>-noop" with sport "detected" and are wiped + re-derived each engine
    // run, so a durable dismissal is recorded in the independent `dismissedWorkout` table.

    /** Dismissed detected-bout markers for the computed source of [strapDeviceId]. */
    suspend fun dismissedDetected(strapDeviceId: String = "my-whoop"): List<DismissedWorkout> =
        dao.dismissedWorkouts(computedDeviceId(strapDeviceId))

    /** Deleted-sleep tombstones for the computed source of [strapDeviceId] (#33). Mirrors dismissedDetected. */
    suspend fun dismissedSleeps(strapDeviceId: String = "my-whoop"): List<DismissedSleep> =
        dao.dismissedSleeps(computedDeviceId(strapDeviceId))

    /**
     * Persist a retroactive / edited manual workout under the strap source. [replacing] is the row the
     * edit started from:
     *  - editing a DETECTED bout replaces it with this manual row — the detected original is dismissed
     *    durably so the re-detector doesn't bring it back (else both would show);
     *  - editing a MANUAL row whose natural key (startTs/sport) changed deletes the stale row first
     *    (the (deviceId, startTs, sport) PK upsert would otherwise orphan it);
     *  - an IMPORTED row is never passed here as `replacing` (duplicating one is a pure add).
     */
    suspend fun saveManualWorkout(row: WorkoutRow, replacing: WorkoutRow? = null) {
        if (replacing != null && replacing.source.lowercase().endsWith("-noop")) {
            dismissDetected(replacing)
        } else if (replacing != null && (replacing.startTs != row.startTs || replacing.sport != row.sport)) {
            dao.deleteWorkoutByKey(replacing.deviceId, replacing.startTs, replacing.sport)
        }
        dao.upsertWorkouts(listOf(row))
    }

    /**
     * Re-label a detected bout: copy it to a manual strap row with the chosen [sport], then delete the
     * detected original. Survives analyzeRecent — the engine re-derives only sport="detected" rows AND
     * skips any re-derived bout overlapping a real strap workout, which this copy now is — so the same
     * session is never re-created as a duplicate. (#107)
     */
    suspend fun relabelDetected(row: WorkoutRow, sport: String, strapDeviceId: String = "my-whoop") {
        val trimmed = sport.trim()
        if (trimmed.isEmpty()) return
        val manual = row.copy(deviceId = strapDeviceId, sport = trimmed, source = "manual")
        dao.upsertWorkouts(listOf(manual))
        dao.deleteWorkoutsBySport(computedDeviceId(strapDeviceId), "detected", row.startTs, row.startTs)
    }

    /**
     * Dismiss a DETECTED bout the user says isn't a workout: record a durable marker (so a re-detect
     * that recreates the same PK stays hidden) AND delete the current row so it disappears now.
     * No-op when the row isn't a detected bout. (#107)
     */
    suspend fun dismissDetected(row: WorkoutRow) {
        if (!row.source.lowercase().endsWith("-noop")) return
        // Marker carries the bout's [startTs, endTs] span so a re-detected bout whose boundary drifts
        // still overlaps it and stays hidden (matches macOS dismissed-span semantics).
        dao.insertDismissed(listOf(DismissedWorkout(row.deviceId, row.startTs, row.endTs)))
        dao.deleteWorkoutsBySport(row.deviceId, row.sport, row.startTs, row.startTs)
    }

    /**
     * Delete ONE workout. A detected bout is dismissed durably (so it doesn't come back on the next
     * re-detect); everything else is removed by its exact natural key. (#107)
     */
    suspend fun deleteWorkout(row: WorkoutRow) {
        if (row.source.lowercase().endsWith("-noop")) { dismissDetected(row); return }
        dao.deleteWorkoutByKey(row.deviceId, row.startTs, row.sport)
    }

    suspend fun respSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.respSamples(deviceId, from, to, limit)

    suspend fun gravitySamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.gravitySamples(deviceId, from, to, limit)

    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.sleepSessions(deviceId, from, to, limit)

    suspend fun metricSeries(deviceId: String, key: String, from: String, to: String) =
        dao.metricSeries(deviceId, key, from, to)

    /** Distinct metric keys present for a [deviceId]/source, sorted ascending. */
    suspend fun metricKeys(deviceId: String): List<String> = dao.metricKeys(deviceId)

    /** Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited. */
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT): List<WorkoutRow> =
        dao.workouts(deviceId, from, to, limit)

    /** Journal entries for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun journal(deviceId: String, from: String, to: String): List<JournalEntry> =
        dao.journal(deviceId, from, to)

    /** Delete one native journal answer by natural key (only ever called with the "noop-journal"
     *  source id — imported rows are never touched). */
    suspend fun deleteJournalEntry(deviceId: String, day: String, question: String) =
        dao.deleteJournalEntry(deviceId, day, question)

    /** Apple-Health daily aggregates for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily> =
        dao.appleDaily(deviceId, from, to)

    /** All cached daily metrics for a device, oldest first. Feeds com.noop.analytics.IllnessWatch. */
    suspend fun days(deviceId: String): List<DailyMetric> = dao.days(deviceId)

    /**
     * One-time #34 refile: move legacy Health Connect data out of the shared "apple-health" bucket into
     * its own "health-connect" source, so it stops being shown as Apple Health. HC workouts are tagged
     * `source = "health-connect"` so they move unconditionally; the daily aggregates only move when there
     * is no Apple Health EXPORT (no apple-health metricSeries), since only the export writes metricSeries.
     * Idempotent + safe (runs before this import writes any HC data, so no PK conflict).
     */
    suspend fun refileLegacyHealthConnect() {
        dao.reassignWorkoutsBySource(from = "apple-health", to = "health-connect", source = "health-connect")
        if (dao.metricSeriesCount("apple-health") == 0) {
            dao.reassignAppleDaily(from = "apple-health", to = "health-connect")
            upsertDevice("health-connect", name = "Health Connect")
        }
    }

    // MARK: - Merged reads (imported source wins per day; computed "-noop" gap-fills)
    //
    // Mirrors macOS Repository.mergeDaily / mergeSleep: the IntelligenceEngine persists
    // on-device scores under "<deviceId>-noop"; the dashboard should see BOTH sources so
    // a strap-only user still gets a populated dashboard, while a real WHOOP import always
    // wins on the days it covers. The screens point their "my-whoop" reads at these merged
    // variants (the least invasive correct approach — no DAO/schema change, and the per-day
    // precedence lives in one place).

    /** The computed-source id for a given imported [deviceId] (e.g. "my-whoop" → "my-whoop-noop"). */
    fun computedDeviceId(deviceId: String): String = "$deviceId-noop"

    /**
     * All cached daily metrics for [deviceId], oldest first, MERGED with the on-device
     * computed scores from "<deviceId>-noop". Imported rows win per day; computed rows
     * fill the days the import doesn't cover. Port of macOS Repository.mergeDaily.
     */
    suspend fun daysMerged(deviceId: String): List<DailyMetric> =
        mergeDaily(imported = dao.days(deviceId), computed = dao.days(computedDeviceId(deviceId)))

    /**
     * Reactive merged daily metrics (oldest first): imported [deviceId] rows win per day,
     * computed "<deviceId>-noop" rows gap-fill. Emits whenever either source changes.
     */
    fun daysMergedFlow(deviceId: String): Flow<List<DailyMetric>> =
        dao.daysFlow(deviceId).combine(dao.daysFlow(computedDeviceId(deviceId))) { imported, computed ->
            mergeDaily(imported = imported, computed = computed)
        }

    /**
     * Sleep sessions for [deviceId] in [from, to] (unix seconds) MERGED with the computed
     * "<deviceId>-noop" sessions. Imported sessions win per night-end day; computed sessions
     * gap-fill. Port of macOS Repository.mergeSleep. Sorted by startTs ascending.
     */
    suspend fun sleepSessionsMerged(
        deviceId: String,
        from: Long,
        to: Long,
        limit: Int = DEFAULT_LIMIT,
    ): List<SleepSession> = mergeSleep(
        imported = dao.sleepSessions(deviceId, from, to, limit),
        computed = dao.sleepSessions(computedDeviceId(deviceId), from, to, limit),
    )

    /** Cached daily metrics for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun dailyMetrics(deviceId: String, from: String, to: String): List<DailyMetric> =
        dao.dailyMetricsRange(deviceId, from, to)

    // MARK: - Cross-source resolver (PR#196 — freshest-wins charts/metrics)
    //
    // Product surfaces (Compare/Insights/Stress/Explore/Today) historically read rows under the EXACT
    // requested source, hiding freshly-computed and Apple-compatible data sat under another device id.
    // [resolvedSeries] resolves a metric over an explicit precedence — imported WHOOP wins, NOOP-computed
    // fills the days it doesn't cover, and Apple Health only fills declared-compatible vitals on days
    // neither strap source has. Port of macOS Repository.resolvedSeries / sourceCandidates.

    /** One day's resolved value plus the source that supplied it (so a caption can name it). */
    data class ResolvedMetricPoint(
        val day: String,
        val value: Double,
        val source: String,
        val sourceKey: String,
    )

    /** A candidate (source, key) pair the resolver tries, in precedence order. */
    data class MetricSourceCandidate(val source: String, val key: String)

    /** The full result of resolving one metric: the sources tried + the merged per-day points. */
    data class MetricSeriesResolution(
        val requestedSource: String,
        val candidates: List<MetricSourceCandidate>,
        val points: List<ResolvedMetricPoint>,
    ) {
        /** Plain (day, value) rows — the shape the chart/correlation code already consumes. */
        val values: List<Pair<String, Double>> get() = points.map { it.day to it.value }

        /** Distinct sources that actually contributed a point, in first-seen order (for a caption). */
        val usedSources: List<String>
            get() {
                val seen = LinkedHashSet<String>()
                for (p in points) seen.add(p.source)
                return seen.toList()
            }
    }

    /**
     * Product-facing daily series for [key] across every COMPATIBLE source, freshest-wins. Use this
     * on surfaces where the user expects the best available signal; use [metricSeries] where one source
     * must be honoured verbatim. Precedence per [sourceCandidates]: imported WHOOP > NOOP-computed >
     * declared-compatible Apple Health. [from]/[to] are YYYY-MM-DD bounds.
     */
    suspend fun resolvedSeries(
        key: String,
        preferredSource: String,
        from: String,
        to: String,
        strapDeviceId: String = "my-whoop",
    ): MetricSeriesResolution {
        val candidates = sourceCandidates(key, preferredSource, strapDeviceId)
        // First candidate wins per day; later candidates only fill days no earlier one covered.
        val byDay = LinkedHashMap<String, ResolvedMetricPoint>()
        for (candidate in candidates) {
            val rows = resolvedRows(candidate, from, to)
            for ((day, value) in rows) {
                if (!byDay.containsKey(day)) {
                    byDay[day] = ResolvedMetricPoint(day, value, candidate.source, candidate.key)
                }
            }
        }
        val points = byDay.values.sortedBy { it.day }
        return MetricSeriesResolution(preferredSource, candidates, points)
    }

    /**
     * Read one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
     * for any day the metricSeries doesn't carry (a Bluetooth-only WHOOP 5 user has values in the daily
     * columns but not the long-format series). Ascending by day.
     */
    private suspend fun resolvedRows(
        candidate: MetricSourceCandidate,
        from: String,
        to: String,
    ): List<Pair<String, Double>> {
        val byDay = LinkedHashMap<String, Double>()
        for (row in dao.metricSeries(candidate.source, candidate.key, from, to)) byDay[row.day] = row.value
        for (row in dao.dailyMetricsRange(candidate.source, from, to)) {
            if (!byDay.containsKey(row.day)) {
                dailyColumn(candidate.key, row)?.let { byDay[row.day] = it }
            }
        }
        return byDay.entries.sortedBy { it.key }.map { it.key to it.value }
    }

    /**
     * A compact snapshot of how much history each source holds, for the Data Sources "Freshness
     * Pipeline" card (PR#196). Counts only — no per-day rows. Port of macOS RepositoryFreshness +
     * Repository.computeFreshness. Covers a wide window (the macOS 4000-day default).
     */
    suspend fun freshness(strapDeviceId: String = "my-whoop"): DataFreshness {
        val to = freshnessDayKey(1)
        val from = freshnessDayKey(-4000)
        val imported = dao.dailyMetricsRange(strapDeviceId, from, to)
        val computed = dao.dailyMetricsRange(computedDeviceId(strapDeviceId), from, to)
        val apple = dao.dailyMetricsRange(APPLE_HEALTH_SOURCE, from, to)
        val now = System.currentTimeMillis() / 1000L
        val lo = now - 4000L * 86_400L
        val hi = now + 86_400L
        val importedSleeps = dao.sleepSessions(strapDeviceId, lo, hi, DEFAULT_LIMIT)
        val computedSleeps = dao.sleepSessions(computedDeviceId(strapDeviceId), lo, hi, DEFAULT_LIMIT)
        val days = (imported + computed + apple).map { it.day }
        return DataFreshness(
            importedDays = imported.size,
            computedDays = computed.size,
            appleDays = apple.size,
            importedSleeps = importedSleeps.size,
            computedSleeps = computedSleeps.size,
            earliestDay = days.minOrNull(),
            latestDay = days.maxOrNull(),
        )
    }

    /** "yyyy-MM-dd" for today offset by [deltaDays], fixed UTC (freshness window bounds). */
    private fun freshnessDayKey(deltaDays: Int): String {
        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
        cal.add(java.util.Calendar.DAY_OF_YEAR, deltaDays)
        return String.format(
            java.util.Locale.US, "%04d-%02d-%02d",
            cal.get(java.util.Calendar.YEAR),
            cal.get(java.util.Calendar.MONTH) + 1,
            cal.get(java.util.Calendar.DAY_OF_MONTH),
        )
    }

    // MARK: - Flows

    /** Reactive daily metrics (oldest first) for a device. */
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>> = dao.daysFlow(deviceId)

    // MARK: - Frontier / convenience

    suspend fun latestHrSampleTs(deviceId: String): Long? = dao.latestHrSampleTs(deviceId)
    suspend fun latestHr(deviceId: String): HrSample? = dao.latestHr(deviceId)
    suspend fun latestBattery(deviceId: String): BatterySample? = dao.latestBattery(deviceId)

    companion object {
        /** Default row cap on range reads. Matches the Swift call sites' bounded scans. */
        const val DEFAULT_LIMIT = 100_000

        /** Canonical source ids the resolver cross-references. The strap's real id is passed in. */
        const val WHOOP_SOURCE = "my-whoop"
        const val APPLE_HEALTH_SOURCE = "apple-health"
        const val HEALTH_CONNECT_SOURCE = "health-connect"

        /** Build a repository backed by the process-wide singleton database. */
        fun from(context: Context): WhoopRepository = WhoopRepository(WhoopDatabase.get(context))

        /**
         * Candidate (source, key) pairs to try for [key], in precedence order, given the user's
         * [preferredSource]. The strap's real id is [strapDeviceId], so the computed sibling is
         * "$strapDeviceId-noop". Port of macOS Repository.sourceCandidates:
         *  • strap-preferred → [imported strap, computed strap, compatible Apple] (Apple only for
         *    vitals with a declared 1:1 mapping);
         *  • Apple-preferred → [Apple] (+ computed strap ONLY for steps/active_kcal, which the strap
         *    estimates and Apple may not carry);
         *  • any other source → itself only (nutrition/mood are single-source by design).
         */
        internal fun sourceCandidates(
            key: String,
            preferredSource: String,
            strapDeviceId: String,
        ): List<MetricSourceCandidate> {
            val computedSource = "$strapDeviceId-noop"
            fun uniqued(cs: List<MetricSourceCandidate>): List<MetricSourceCandidate> {
                val seen = LinkedHashSet<MetricSourceCandidate>()
                for (c in cs) seen.add(c)
                return seen.toList()
            }
            if (preferredSource == WHOOP_SOURCE || preferredSource == strapDeviceId) {
                val candidates = mutableListOf(
                    MetricSourceCandidate(strapDeviceId, key),
                    MetricSourceCandidate(computedSource, key),
                )
                appleCompatibleKey(key)?.let {
                    candidates.add(MetricSourceCandidate(APPLE_HEALTH_SOURCE, it))
                }
                return uniqued(candidates)
            }
            if (preferredSource == APPLE_HEALTH_SOURCE) {
                val candidates = mutableListOf(MetricSourceCandidate(APPLE_HEALTH_SOURCE, key))
                // Health Connect is an Apple-equivalent body-metric source on Android — a real Apple
                // EXPORT still wins per day (it's first), HC fills the rest. This is what makes a
                // Health-Connect-only weight history visible in Compare (#443); HC now emits a "weight"
                // metricSeries under this source from HealthConnectImporter.
                candidates.add(MetricSourceCandidate(HEALTH_CONNECT_SOURCE, key))
                if (noopComputedCanFillAppleMetric(key)) {
                    candidates.add(MetricSourceCandidate(computedSource, key))
                }
                return uniqued(candidates)
            }
            return listOf(MetricSourceCandidate(preferredSource, key))
        }

        /** The Apple-Health series key carrying the SAME quantity as a WHOOP key; null = no fallback. */
        internal fun appleCompatibleKey(key: String): String? = when (key) {
            "rhr" -> "resting_hr"
            "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal" -> key
            "sleep_total_min" -> "asleep_min"
            "sleep_deep_min" -> "deep_min"
            "sleep_rem_min" -> "rem_min"
            "sleep_light_min" -> "core_min"
            else -> null
        }

        /** Whether the NOOP-computed strap source may fill an Apple-preferred metric. Only the two
         *  daily totals the strap genuinely estimates (steps, calories) — never a derived score. */
        private fun noopComputedCanFillAppleMetric(key: String): Boolean = when (key) {
            "steps", "active_kcal" -> true
            else -> false
        }

        /**
         * The DailyMetric column backing a resolver key, for days the metricSeries doesn't cover
         * (strap-only WHOOP 5 users). Also handles the Apple-compatible sleep aliases (asleep_min /
         * deep_min / rem_min / core_min) the resolver may request. Keys with no daily column return
         * null. Mirrors macOS Repository.dailyColumn.
         */
        internal fun dailyColumn(key: String, d: DailyMetric): Double? = when (key) {
            "recovery" -> d.recovery
            "hrv" -> d.avgHrv
            "rhr", "resting_hr" -> d.restingHr?.toDouble()
            "strain" -> d.strain
            "resp_rate" -> d.respRateBpm
            "spo2" -> d.spo2Pct
            "skin_temp" -> d.skinTempDevC
            "sleep_total_min", "asleep_min" -> d.totalSleepMin
            "sleep_efficiency" -> d.efficiency
            "sleep_deep_min", "deep_min" -> d.deepMin
            "sleep_rem_min", "rem_min" -> d.remMin
            "sleep_light_min", "core_min" -> d.lightMin
            "steps" -> d.steps?.toDouble()
            "active_kcal", "energy_kcal" -> d.activeKcalEst
            else -> null
        }

        /**
         * Imported daily rows win per day; computed rows fill the days the import doesn't
         * cover. Returns oldest→newest by day string (lexicographic = chronological for
         * YYYY-MM-DD). Port of macOS Repository.mergeDaily.
         */
        internal fun mergeDaily(
            imported: List<DailyMetric>,
            computed: List<DailyMetric>,
        ): List<DailyMetric> {
            val byDay = LinkedHashMap<String, DailyMetric>()
            for (d in computed) byDay[d.day] = d // computed first…
            // …import overwrites, so a real WHOOP import always wins — BUT coalesce the strap-only
            // on-device metrics (steps / calories / RSA resp) from the computed row, since importers
            // (esp. Health Connect) write a "my-whoop" daily row with those columns null and would
            // otherwise blank them on days the import also covers. (#78)
            for (d in imported) {
                val c = byDay[d.day]
                // Per-FIELD coalesce: the imported row wins for every column it actually has, but any
                // column it leaves null is gap-filled from the computed row. A real WHOOP import has
                // its scores/stages set, so "d.x ?: c.x" is a no-op there. A Health Connect import,
                // though, writes a "my-whoop" row with recovery/strain/sleep-stages NULL — without this
                // it would BLANK a strap-computed day (and a stale one already written stays blanked).
                // Coalescing every nullable field both prevents that and HEALS days already shadowed. (#112)
                byDay[d.day] = if (c == null) d else d.copy(
                    totalSleepMin = d.totalSleepMin ?: c.totalSleepMin,
                    efficiency = d.efficiency ?: c.efficiency,
                    deepMin = d.deepMin ?: c.deepMin,
                    remMin = d.remMin ?: c.remMin,
                    lightMin = d.lightMin ?: c.lightMin,
                    disturbances = d.disturbances ?: c.disturbances,
                    restingHr = d.restingHr ?: c.restingHr,
                    avgHrv = d.avgHrv ?: c.avgHrv,
                    recovery = d.recovery ?: c.recovery,
                    strain = d.strain ?: c.strain,
                    exerciseCount = d.exerciseCount ?: c.exerciseCount,
                    spo2Pct = d.spo2Pct ?: c.spo2Pct,
                    skinTempDevC = d.skinTempDevC ?: c.skinTempDevC,
                    respRateBpm = d.respRateBpm ?: c.respRateBpm,
                    steps = d.steps ?: c.steps,
                    activeKcalEst = d.activeKcalEst ?: c.activeKcalEst,
                )
            }
            return byDay.values.sortedBy { it.day }
        }

        /**
         * Same precedence for sleep sessions, keyed by the LOCAL day the night ends on (#304).
         * Brought into line with macOS Repository.mergeSleep, which keys on the local wake-day. A
         * UTC key put a night that ends after local-but-before-UTC midnight (a UTC+ user waking
         * early) under yesterday's UTC date, so the dashboard's local "today" read missed it and
         * surfaced the previous night. The local key matches how IntelligenceEngine buckets nights
         * and how the resolver looks up "today". REUSES the existing
         * `AnalyticsEngine.dayString(ts, offsetSec)` overload — do NOT add a new offset overload,
         * it clashes on the JVM signature and breaks the build.
         */
        internal fun mergeSleep(
            imported: List<SleepSession>,
            computed: List<SleepSession>,
        ): List<SleepSession> {
            fun endDay(s: SleepSession): String {
                val offsetSec = (java.util.TimeZone.getDefault().getOffset(s.endTs * 1000) / 1000).toLong()
                return com.noop.analytics.AnalyticsEngine.dayString(s.endTs, offsetSec)
            }
            val byDay = LinkedHashMap<String, SleepSession>()
            for (s in computed) byDay[endDay(s)] = s
            for (s in imported) byDay[endDay(s)] = s
            return byDay.values.sortedBy { it.startTs }
        }
    }
}

/** OnConflictStrategy.IGNORE returns the new rowid, or -1 when the row was skipped. */
private fun List<Long>.countInserted(): Int = count { it != -1L }
