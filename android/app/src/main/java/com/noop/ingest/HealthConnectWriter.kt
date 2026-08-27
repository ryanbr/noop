package com.noop.ingest

import kotlinx.coroutines.sync.withLock

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import com.noop.data.MetricSeriesRow
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Percentage
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.NoopPrefs
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import kotlin.reflect.KClass

/** PII-safe category of a Health Connect writeback failure — a coarse reason, never a raw message. */
enum class WritebackFailure { PERMISSION_DENIED, REMOTE_ERROR }

/**
 * Outcome of a writeback attempt (#660): how many records landed, plus any per-concern failure
 * categories. Lets callers/UI distinguish "wrote 0 because nothing to share" from "wrote 0 because
 * the write FAILED" — the silent-zero the previous `Int` return couldn't express.
 */
data class WritebackResult(val written: Int, val failures: List<WritebackFailure>) {
    val ok: Boolean get() = failures.isEmpty()

    /** PII-safe status code persisted for the UI — a permission failure outranks a generic one, since it
     *  needs a distinct "re-grant" action. Pure/testable; must equal the `NoopPrefs.HC_WB_*` constants. */
    val statusCode: String get() = when {
        WritebackFailure.PERMISSION_DENIED in failures -> "PERMISSION_DENIED"
        failures.isNotEmpty() -> "REMOTE_ERROR"
        else -> "OK"
    }

    companion object {
        /** HC unavailable / nothing attempted — benign, not a failure. */
        val UNAVAILABLE = WritebackResult(0, emptyList())
    }
}

/** Map a thrown write error to a PII-safe category; rethrow coroutine cancellation (never a "failure"). */
private fun Throwable.writebackCategory(): WritebackFailure {
    if (this is kotlin.coroutines.cancellation.CancellationException) throw this
    return if (this is SecurityException) WritebackFailure.PERMISSION_DENIED else WritebackFailure.REMOTE_ERROR
}

/**
 * OPT-IN writeback: pushes NOOP's on-device computed nightly metrics (resting HR, HRV RMSSD, sleep
 * SpO2, respiratory rate) INTO Health Connect, so other apps can see what the strap measured.
 * Inverse of [HealthConnectImporter]; default OFF (NoopPrefs.hcWriteback), toggled in Data Sources.
 *
 * Two deliberate scope limits:
 *  - **Computed days only** (`repo.days(computedDeviceId)`) — never imported ones. Echoing imported
 *    WHOOP-export or Health-Connect-sourced rows back into HC would duplicate another app's data
 *    (or loop our own import). What NOOP computed from the strap is genuinely ours to contribute.
 *  - **Idempotent by clientRecordId** (`noop-<metric>-<day>`): Health Connect does NOT auto-dedupe
 *    on re-insert the way HealthKit does — without a client id every 15-min recompute would stack
 *    duplicates. With it, HC upserts: same id + higher [Metadata.clientRecordVersion] replaces, so
 *    we stamp the version with the write time and the latest computation always wins.
 */
object HealthConnectWriter {

    /** How far back to write. Recomputation only ever touches recent nights; 60 days is generous. */
    private const val WINDOW_DAYS = 60L

    private val WRITE_RECORDS: List<KClass<out Record>> = listOf(
        RestingHeartRateRecord::class,
        HeartRateVariabilityRmssdRecord::class,
        OxygenSaturationRecord::class,
        RespiratoryRateRecord::class,
        HeartRateRecord::class,
        SleepSessionRecord::class,
    )

    /** The write-permission strings the UI must request before calling [write]. */
    val PERMISSIONS: Set<String> =
        WRITE_RECORDS.map { HealthPermission.getWritePermission(it) }.toSet()

    /**
     * #1677: exports are serialized. Three callers can start one - the post-sync hook in WhoopBleClient
     * and two in AppViewModel - with no uniqueness guard between them, so two could previously overlap on
     * the same external store. That is newly consequential now the writer keeps a ledger: both would read
     * the same `previous`, both would write their own result, and the loser's carried-forward retractions
     * would be forgotten, orphaning exactly the records this change exists to retract. Serializing also
     * stops two exports doing the same insert work twice.
     */
    private val exportMutex = kotlinx.coroutines.sync.Mutex()

    /**
     * Write the last [WINDOW_DAYS] of computed metrics. Returns a [WritebackResult] — the record
     * count PLUS any per-concern failure categories, so a revoked permission no longer looks like a
     * benign "wrote 0" (#660). Persists the outcome via [recordStatus] for the Data Sources UI.
     * Assumes [PERMISSIONS] are granted (HC throws SecurityException otherwise — caught + categorized).
     *
     * [deviceId] must be the registry's ACTIVE strap id (SPINE / #814): a wizard-paired strap banks
     * rows under `whoop-<address>`, so a hardcoded legacy "my-whoop" id reads empty tables and
     * exports nothing.
     */
    suspend fun write(context: Context, repo: WhoopRepository, deviceId: String): WritebackResult =
        exportMutex.withLock { writeLocked(context, repo, deviceId) }

    private suspend fun writeLocked(context: Context, repo: WhoopRepository, deviceId: String): WritebackResult {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return WritebackResult.UNAVAILABLE

        // Guard the pre-insert work (client acquisition + the day read) the same way the concern inserts
        // below are guarded, so a provider race or DB error can't throw PAST recordStatus and leave the
        // UI showing a stale "OK" while sharing is actually broken (#660). Cancellation still propagates.
        val (client, days) = runCatching {
            val c = HealthConnectClient.getOrCreate(context)
            val cutoff = LocalDate.now().minusDays(WINDOW_DAYS).toString()
            c to repo.days(repo.computedDeviceId(deviceId)).filter { it.day >= cutoff }
        }.getOrElse { t ->
            val result = WritebackResult(0, listOf(t.writebackCategory()))
            recordStatus(context, result)
            return result
        }

        val zone = ZoneId.systemDefault()
        // Stamp every record in this batch with one version so a later recompute (higher stamp)
        // replaces the whole day consistently.
        val version = System.currentTimeMillis() / 1000

        val records = ArrayList<Record>()
        for (d in days) {
            // Noon local on the metric's day: an unambiguous, stable instant for a daily summary
            // (midnight would straddle the previous night across DST shifts).
            val date = runCatching { LocalDate.parse(d.day) }.getOrNull() ?: continue
            val time = date.atTime(LocalTime.NOON).atZone(zone)
            val instant: Instant = time.toInstant()
            val offset = time.offset

            d.restingHr?.let {
                records.add(RestingHeartRateRecord(
                    time = instant, zoneOffset = offset, beatsPerMinute = it.toLong(),
                    metadata = meta("rhr", d.day, version),
                ))
            }
            d.avgHrv?.let {
                records.add(HeartRateVariabilityRmssdRecord(
                    time = instant, zoneOffset = offset, heartRateVariabilityMillis = it,
                    metadata = meta("hrv", d.day, version),
                ))
            }
            d.spo2Pct?.let {
                records.add(OxygenSaturationRecord(
                    time = instant, zoneOffset = offset, percentage = Percentage(it),
                    metadata = meta("spo2", d.day, version),
                ))
            }
            d.respRateBpm?.let {
                records.add(RespiratoryRateRecord(
                    time = instant, zoneOffset = offset, rate = it,
                    metadata = meta("resp", d.day, version),
                ))
            }
        }

        // NOTE: steps + active-calories are deliberately NOT written back (was #528). NOOP's strap
        // step/kcal figures are estimates, and the phone pedometer / a watch already feed Health
        // Connect the authoritative values — writing ours too would double-count in the OS's daily
        // totals. iOS (#249) excludes them for the same reason; this keeps the two platforms aligned.
        // The unique strap signals (vitals, HR, sleep, workouts) are still written below.

        // Each export concern inserts independently so a failure in one — e.g. a revoked per-type WRITE
        // permission — can't suppress the others. Failures are CATEGORIZED (PII-safe, never raw messages)
        // and folded into the result instead of collapsing to a silent 0, so the UI can surface them (#660).
        var total = 0
        val failures = mutableListOf<WritebackFailure>()
        if (records.isNotEmpty()) {
            runCatching { client.insertRecords(records); records.size }
                .fold({ total += it }, { failures += it.writebackCategory() })
        }
        runCatching { writeHeartRate(client, context, repo, deviceId, version) }
            .fold({ total += it }, { failures += it.writebackCategory() })
        runCatching { writeSleep(client, context, repo, deviceId) }
            .fold({ total += it }, { failures += it.writebackCategory() })
        // #1525: separate attempt on purpose. The daily records above go in ONE insertRecords call, so a
        // missing permission there loses resting HR, HRV, SpO2 and respiratory rate together. On its own,
        // an ungranted VO2 max permission costs only VO2 max and is categorized like any other failure.
        runCatching { writeVo2Max(client, repo, deviceId, version) }
            .fold({ total += it }, { failures += it.writebackCategory() })
        val result = WritebackResult(total, failures.distinct())
        recordStatus(context, result)
        return result
    }

    /** Persist the last writeback outcome (PII-safe category + count + time) for the Data Sources UI (#660). */
    private fun recordStatus(context: Context, result: WritebackResult) {
        NoopPrefs.setHcWritebackStatus(context, result.statusCode, result.written, System.currentTimeMillis())
    }

    private fun meta(metric: String, day: String, version: Long) = Metadata(
        clientRecordId = "noop-$metric-$day",
        clientRecordVersion = version,
    )

    /** Health Connect caps records per insert call; insert in batches to stay well under it. */
    private suspend fun insertChunked(client: HealthConnectClient, records: List<Record>, batch: Int = 1000): Int {
        var n = 0
        records.chunked(batch).forEach { client.insertRecords(it); n += it.size }
        return n
    }

    /**
     * #528 — export NOOP's heart-rate samples (raw [deviceId], not computed) above the persisted
     * frontier. Inside workout/sleep windows the series is kept at full resolution; elsewhere it is
     * decimated to ~1 sample / 30 s so a continuous day doesn't flood Health Connect. The frontier
     * (a single epoch-second cursor in [NoopPrefs]) advances past every sample seen, so each 15-min
     * writeback only emits NEW samples and decimated-away points are never reconsidered.
     */
    private suspend fun writeHeartRate(client: HealthConnectClient, context: Context, repo: WhoopRepository, deviceId: String, version: Long): Int {
        val now = System.currentTimeMillis() / 1000
        val floor = now - WINDOW_DAYS * 86_400
        val frontier = maxOf(NoopPrefs.hcHrFrontier(context), floor)

        val samples = repo.hrSamples(deviceId, from = frontier + 1, to = now, limit = 200_000)
            .map { HealthExportPlan.HrPoint(it.ts, it.bpm) }
        if (samples.isEmpty()) return 0

        // Workout + sleep windows where the full-resolution series matters; everything else decimates.
        val windows = buildList {
            repo.workouts(deviceId, frontier, now).forEach { add(HealthExportPlan.Window(it.startTs, it.endTs)) }
            repo.sleepSessions(deviceId, frontier, now).forEach { add(HealthExportPlan.Window(it.startTs, it.endTs)) }
        }

        val plan = HealthExportPlan.heartRate(samples, windows, frontier)
        if (plan.chunks.isEmpty()) {
            if (plan.newFrontierSec > frontier) NoopPrefs.setHcHrFrontier(context, plan.newFrontierSec)
            return 0
        }

        val zone = ZoneId.systemDefault()
        val records = plan.chunks.map { c ->
            val startTs = c.startSec
            val endTs = if (c.endSec > c.startSec) c.endSec else c.startSec + 1 // HC needs end > start
            val start = Instant.ofEpochSecond(startTs)
            val end = Instant.ofEpochSecond(endTs)
            HeartRateRecord(
                startTime = start, startZoneOffset = zone.rules.getOffset(start),
                endTime = end, endZoneOffset = zone.rules.getOffset(end),
                samples = c.points.map {
                    HeartRateRecord.Sample(time = Instant.ofEpochSecond(it.tsSec), beatsPerMinute = it.bpm.toLong())
                },
                metadata = Metadata(clientRecordId = c.clientId, clientRecordVersion = version),
            )
        }
        val n = insertChunked(client, records)
        NoopPrefs.setHcHrFrontier(context, plan.newFrontierSec)
        return n
    }

    /**
     * #528 — export finalized sleep sessions with the detailed stage timeline NOOP computed. Uses the
     * MERGED view (imported wins, on-device-computed gap-fills) so a
     * strap-only user's locally-computed nights (stored under the "-noop" computed id) are included.
     * #364 — fragments are grouped into BRIDGED NIGHTS (the same #561 bridge the daily totals score
     * with), so a night split by a brief mid-night wake exports as ONE record whose gap is an AWAKE
     * stage; the clientRecordId keys off the group's earliest fragment's immutable detected startTs,
     * and the absorbed fragments' old per-fragment records are DELETED (HC upserts by id but never
     * removes an id we stop writing).
     */
    private suspend fun writeSleep(
        client: HealthConnectClient,
        context: Context,
        repo: WhoopRepository,
        deviceId: String,
    ): Int {
        val now = System.currentTimeMillis() / 1000
        val floor = now - WINDOW_DAYS * 86_400
        val sessions = repo.sleepSessionsMerged(deviceId, from = floor, to = now)
            .map { HealthExportPlan.SleepInput(it.startTs, it.effectiveStartTs, it.endTs, it.stagesJSON) }
        val offsetSec = (java.util.TimeZone.getDefault().getOffset(now * 1000) / 1000).toLong()
        val plans = HealthExportPlan.sleepSessions(sessions, now, offsetSec)
        // Deliberately BEFORE the ledger below. "No plans" is not the same statement as "the user has no
        // sleep": a read that came back empty for any reason would, with retraction enabled, delete every
        // night this window covers. Saying nothing is the recoverable failure; deleting is not.
        if (plans.isEmpty()) return 0

        val zone = ZoneId.systemDefault()
        val records = plans.map { p ->
            val start = Instant.ofEpochSecond(p.startSec)
            val end = Instant.ofEpochSecond(p.endSec)
            SleepSessionRecord(
                startTime = start, startZoneOffset = zone.rules.getOffset(start),
                endTime = end, endZoneOffset = zone.rules.getOffset(end),
                title = null, notes = null,
                stages = p.stages.map { s ->
                    SleepSessionRecord.Stage(
                        startTime = Instant.ofEpochSecond(s.startSec),
                        endTime = Instant.ofEpochSecond(s.endSec),
                        stage = when (s.kind) {
                            HealthExportPlan.StageKind.AWAKE -> SleepSessionRecord.STAGE_TYPE_AWAKE
                            HealthExportPlan.StageKind.SLEEPING -> SleepSessionRecord.STAGE_TYPE_SLEEPING
                            HealthExportPlan.StageKind.LIGHT -> SleepSessionRecord.STAGE_TYPE_LIGHT
                            HealthExportPlan.StageKind.DEEP -> SleepSessionRecord.STAGE_TYPE_DEEP
                            HealthExportPlan.StageKind.REM -> SleepSessionRecord.STAGE_TYPE_REM
                        },
                    )
                },
                metadata = Metadata(clientRecordId = p.clientId, clientRecordVersion = p.endSec),
            )
        }
        // Clear absorbed fragments' old records BEFORE the merged upsert, so a night previously
        // exported as two entries never lingers as one merged + one stale fragment. (#364)
        val absorbed = plans.flatMap { it.absorbedClientIds }
        // #1677: and the ids we wrote on a PREVIOUS export that this one no longer produces. `absorbed`
        // cannot cover those: it is derived from sleepSession rows still in the database, and the
        // #1248/#1284 heal deletes a stale row the moment a fuller copy of that night wins. A record
        // exported mid-sync under the partial night's start then had nothing left pointing at it, so no
        // later export could correct or remove it — the permanent wrong duration #1677 describes.
        // Scoped to this export's own window by `staleClientIds`, so a night that merely aged out is
        // never retracted.
        val currentIds = plans.map { it.clientId }.toSet()
        val stale = HealthConnectLedger.staleClientIds(
            previous = HealthConnectLedger.previouslyWritten(
                context, deviceId, HealthConnectLedger.SLEEP_PREFIX),
            current = currentIds,
            prefix = HealthConnectLedger.SLEEP_PREFIX,
            windowStartSec = floor,
            nowSec = now,
        )
        val retract = (absorbed + stale).distinct()
        // Ids whose retraction did NOT land. They stay on the books so the next export tries again -
        // forgetting one would orphan its record permanently, which is the very failure this fixes.
        val unretracted = LinkedHashSet<String>()
        if (retract.isNotEmpty()) {
            // One call for the common case. If it throws, retry per id: the reporter of #1677 had already
            // deleted the bad record by hand, and an id that is no longer there must not take the rest of
            // the batch down with it. `retract` is a handful of entries at most, so the fallback is cheap.
            runCatching {
                client.deleteRecords(SleepSessionRecord::class,
                    recordIdsList = emptyList(), clientRecordIdsList = retract)
            }.onFailure {
                for (one in retract) {
                    runCatching {
                        client.deleteRecords(SleepSessionRecord::class,
                            recordIdsList = emptyList(), clientRecordIdsList = listOf(one))
                    }.onFailure { unretracted += one }
                }
            }
        }
        val written = insertChunked(client, records)
        // Recorded only AFTER the write lands. Remembering ids we failed to write would make the NEXT
        // export retract records that never existed - harmless in itself, but it would also drop the ids
        // that do need retracting from the ledger, quietly restoring the bug this fixes.
        HealthConnectLedger.remember(
            context, deviceId, HealthConnectLedger.SLEEP_PREFIX,
            HealthConnectLedger.ledgerAfterExport(currentIds, unretracted),
        )
        return written
    }

    /**
     * VO2 max writeback (#1525). NOOP computes this weekly and persists it as the `vo2max_est` metric
     * series, keyed to the week's Saturday — nothing exported it before, so a value the app already had
     * never reached Health Connect.
     *
     * Read through [WhoopRepository.metricSeriesComputedUnion], which is what that series' own doc says
     * the weekly computed scores MUST use: it merges the active strap's computed sibling with the
     * canonical "my-whoop-noop", so a re-added strap does not silently export half its history.
     *
     * Declared as MEASUREMENT_METHOD_OTHER rather than HEART_RATE_RATIO. The stored value is whichever
     * estimator ran — the Nes multivariable regression when a waist is set, the Uth HR-ratio formula
     * otherwise (#1493) — and the row does not record which. HEART_RATE_RATIO would be true of only one
     * of them, so the honest label is the general one.
     *
     * Timestamped at local noon on the series' day, matching the daily records above.
     */
    private suspend fun writeVo2Max(
        client: HealthConnectClient,
        repo: WhoopRepository,
        deviceId: String,
        version: Long,
    ): Int {
        val zone = ZoneId.systemDefault()
        val cutoff = LocalDate.now().minusDays(WINDOW_DAYS).toString()
        val today = LocalDate.now().toString()
        val rows = repo.metricSeriesComputedUnion(deviceId, "vo2max_est", cutoff, today)
        val records = buildVo2MaxRecords(rows, version, zone)
        if (records.isEmpty()) return 0
        return insertChunked(client, records)
    }

    /**
     * Pure: map `vo2max_est` series rows to records, testable without a client — the same split
     * [buildExerciseRecords] uses below.
     *
     * Skips a day whose key will not parse, and any value at or below zero: a stored 0 means the estimator
     * declined that week, and exporting it would publish "VO2 max: 0" as a fitness reading rather than
     * saying nothing. Timestamped at local noon on the series' own day, matching the daily records, and
     * keyed by day in the clientRecordId so a re-export upserts instead of duplicating.
     */
    internal fun buildVo2MaxRecords(
        rows: List<MetricSeriesRow>,
        version: Long,
        zone: ZoneId,
    ): List<Record> = rows.mapNotNull { row ->
        val date = runCatching { LocalDate.parse(row.day) }.getOrNull() ?: return@mapNotNull null
        if (row.value <= 0.0) return@mapNotNull null
        val time = date.atTime(LocalTime.NOON).atZone(zone)
        Vo2MaxRecord(
            time = time.toInstant(),
            zoneOffset = time.offset,
            vo2MillilitersPerMinuteKilogram = row.value,
            measurementMethod = Vo2MaxRecord.MEASUREMENT_METHOD_OTHER,
            metadata = meta("vo2max", row.day, version),
        )
    }

    // --- Workout (ExerciseSession) writeback (GPS workouts, v1.71) ---

    /**
     * Write permission for VO2 max (#1525). Deliberately NOT in [WRITE_RECORDS]: that set feeds both the
     * daily batch and the UI's `containsAll` gate, so adding it there would re-prompt every existing user
     * and block ALL writeback until they re-granted. Requested alongside the others, but its records are
     * written in their own attempt, so a decline costs only VO2 max.
     */
    val VO2MAX_PERMISSIONS: Set<String> = setOf(HealthPermission.getWritePermission(Vo2MaxRecord::class))

    /** Write-permission strings for exercise sessions + distance; union into the writeback request. */
    val EXERCISE_PERMISSIONS: Set<String> = setOf(
        HealthPermission.getWritePermission(ExerciseSessionRecord::class),
        HealthPermission.getWritePermission(DistanceRecord::class),
    )

    /** Pure: build the records for one workout (testable without a client). */
    fun buildExerciseRecords(row: WorkoutRow, exerciseType: Int): List<Record> {
        val start = Instant.ofEpochSecond(row.startTs)
        val end = Instant.ofEpochSecond(row.endTs)
        val offset = ZoneId.systemDefault().rules.getOffset(start)
        val out = ArrayList<Record>()
        out.add(
            ExerciseSessionRecord(
                startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = offset,
                exerciseType = exerciseType, title = row.sport,
                metadata = Metadata(clientRecordId = "noop-workout-${row.startTs}", clientRecordVersion = row.endTs),
            ),
        )
        row.distanceM?.let {
            out.add(
                DistanceRecord(
                    startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = offset,
                    distance = Length.meters(it),
                    metadata = Metadata(clientRecordId = "noop-workout-dist-${row.startTs}", clientRecordVersion = row.endTs),
                ),
            )
        }
        return out
    }

    /** Insert one workout's records into Health Connect. Opt-in caller. Returns a [WritebackResult] so a
     *  failed exercise share is visible instead of silently swallowed, and records the outcome (#660). */
    suspend fun writeExercise(context: Context, row: WorkoutRow, exerciseType: Int): WritebackResult {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return WritebackResult.UNAVAILABLE
        val recs = buildExerciseRecords(row, exerciseType)
        val result = runCatching { HealthConnectClient.getOrCreate(context).insertRecords(recs); recs.size }
            .fold({ WritebackResult(it, emptyList()) }, { WritebackResult(0, listOf(it.writebackCategory())) })
        recordStatus(context, result)
        return result
    }

    /** Remove a workout's session + distance records from Health Connect by client-record id (the same ids
     *  [buildExerciseRecords] assigns: "noop-workout-$startTs" + "-dist"). Used when an edit MOVES the start
     *  time so the old record doesn't orphan beside the new one — mirroring the iOS delete-before-write.
     *  Best-effort; a missing record is a no-op. (#1195) */
    suspend fun deleteExercise(context: Context, startTs: Long) {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return
        val client = HealthConnectClient.getOrCreate(context)
        runCatching {
            client.deleteRecords(ExerciseSessionRecord::class,
                recordIdsList = emptyList(), clientRecordIdsList = listOf("noop-workout-$startTs"))
        }
        runCatching {
            client.deleteRecords(DistanceRecord::class,
                recordIdsList = emptyList(), clientRecordIdsList = listOf("noop-workout-dist-$startTs"))
        }
    }
}
