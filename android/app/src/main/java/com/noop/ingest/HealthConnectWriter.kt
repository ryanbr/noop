package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Percentage
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import kotlin.reflect.KClass

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
    )

    /** The write-permission strings the UI must request before calling [write]. */
    val PERMISSIONS: Set<String> =
        WRITE_RECORDS.map { HealthPermission.getWritePermission(it) }.toSet()

    /**
     * Write the last [WINDOW_DAYS] of computed metrics. Returns the number of records written,
     * 0 when HC is unavailable / nothing computed yet. Assumes [PERMISSIONS] are granted (HC
     * throws SecurityException otherwise — callers wrap in runCatching).
     */
    suspend fun write(context: Context, repo: WhoopRepository, deviceId: String = "my-whoop"): Int {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return 0
        val client = HealthConnectClient.getOrCreate(context)

        val cutoff = LocalDate.now().minusDays(WINDOW_DAYS).toString()
        val days = repo.days(repo.computedDeviceId(deviceId)).filter { it.day >= cutoff }
        if (days.isEmpty()) return 0

        val zone = ZoneId.systemDefault()
        // Stamp every record in this batch with one version so a later recompute (higher stamp)
        // replaces the whole day consistently.
        val version = System.currentTimeMillis() / 1000

        val records = buildList<Record> {
            for (d in days) {
                // Noon local on the metric's day: an unambiguous, stable instant for a daily summary
                // (midnight would straddle the previous night across DST shifts).
                val date = runCatching { LocalDate.parse(d.day) }.getOrNull() ?: continue
                val time = date.atTime(LocalTime.NOON).atZone(zone)
                val instant: Instant = time.toInstant()
                val offset = time.offset

                d.restingHr?.let {
                    add(RestingHeartRateRecord(
                        time = instant, zoneOffset = offset, beatsPerMinute = it.toLong(),
                        metadata = meta("rhr", d.day, version),
                    ))
                }
                d.avgHrv?.let {
                    add(HeartRateVariabilityRmssdRecord(
                        time = instant, zoneOffset = offset, heartRateVariabilityMillis = it,
                        metadata = meta("hrv", d.day, version),
                    ))
                }
                d.spo2Pct?.let {
                    add(OxygenSaturationRecord(
                        time = instant, zoneOffset = offset, percentage = Percentage(it),
                        metadata = meta("spo2", d.day, version),
                    ))
                }
                d.respRateBpm?.let {
                    add(RespiratoryRateRecord(
                        time = instant, zoneOffset = offset, rate = it,
                        metadata = meta("resp", d.day, version),
                    ))
                }
            }
        }
        if (records.isEmpty()) return 0
        client.insertRecords(records)
        return records.size
    }

    private fun meta(metric: String, day: String, version: Long) = Metadata(
        clientRecordId = "noop-$metric-$day",
        clientRecordVersion = version,
    )

    // --- Workout (ExerciseSession) writeback (GPS workouts, v1.71) ---

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

    /** Insert one workout's records into Health Connect. Opt-in caller; wrap in runCatching. */
    suspend fun writeExercise(context: Context, row: WorkoutRow, exerciseType: Int): Int {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return 0
        val recs = buildExerciseRecords(row, exerciseType)
        HealthConnectClient.getOrCreate(context).insertRecords(recs)
        return recs.size
    }
}
