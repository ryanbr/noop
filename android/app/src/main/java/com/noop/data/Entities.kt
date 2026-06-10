package com.noop.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/*
 * Room entities mirroring the verified GRDB schema in
 * Packages/WhoopStore/Sources/WhoopStore/Database.swift (+ MetricsCache.swift).
 *
 * Natural keys are preserved EXACTLY so insert dedupe (OnConflictStrategy.IGNORE)
 * behaves identically to the Swift `ON CONFLICT(...) DO NOTHING` upserts:
 *   - hrSample        PK (deviceId, ts)
 *   - rrInterval      PK (deviceId, ts, rrMs)
 *   - event           PK (deviceId, ts, kind)
 *   - battery         PK (deviceId, ts)
 *   - spo2Sample      PK (deviceId, ts)
 *   - skinTempSample  PK (deviceId, ts)
 *   - respSample      PK (deviceId, ts)
 *   - gravitySample   PK (deviceId, ts)
 *   - dailyMetric     PK (deviceId, day)
 *   - sleepSession    PK (deviceId, startTs)
 *   - device          PK (id)
 *   - journal         PK (deviceId, day, question)
 *   - workout         PK (deviceId, startTs, sport)
 *   - appleDaily      PK (deviceId, day)
 *
 * `ts` columns are wall-clock unix SECONDS (Swift uses Int -> Kotlin Long for safety).
 */

/** Device row. Swift `device` table (Database.swift v1). Natural key = id. */
@Entity(tableName = "device")
data class DeviceRow(
    @androidx.room.PrimaryKey
    val id: String,
    val mac: String? = null,
    val name: String? = null,
    val firstSeen: Long? = null,
    val lastSeen: Long? = null,
)

/** Heart-rate sample. Swift `hrSample` (v1). PK (deviceId, ts). */
@Entity(tableName = "hrSample", primaryKeys = ["deviceId", "ts"])
data class HrSample(
    val deviceId: String,
    val ts: Long,
    val bpm: Int,
    // v5: per-row upload flag; unused locally, kept for schema parity. Defaults to 0.
    val synced: Int = 0,
)

/** One downsampled HR point — the bucket's start (unix seconds) + the mean bpm over it. Query
 *  result of [WhoopDao.hrBuckets], not a table. Mirrors the macOS `HRBucket`. */
data class HrBucket(
    val bucket: Long,
    val avgBpm: Double,
)

/** Aggregate HR over a time window — sample count + avg/max bpm. Query result of
 *  [WhoopDao.hrWindowStats], not a table. Used to derive a workout's HR from strap samples when
 *  the imported session carries none (#77). avg/max are null when n == 0. */
data class HrWindowStats(
    val n: Long,
    val avg: Double?,
    val max: Int?,
)

/** R-R interval. Swift `rrInterval` (v1). PK (deviceId, ts, rrMs) — multiple R-R per ts. */
@Entity(tableName = "rrInterval", primaryKeys = ["deviceId", "ts", "rrMs"])
data class RrInterval(
    val deviceId: String,
    val ts: Long,
    val rrMs: Int,
    val synced: Int = 0,
)

/**
 * Strap event. Swift `event` (v1). PK (deviceId, ts, kind).
 * `payloadJSON` is the deterministic (sorted-keys) JSON of the remaining parsed fields,
 * with `event`/`event_timestamp` removed (see Streams.swift extractStreams + StreamStore.encodePayload).
 */
@Entity(tableName = "event", primaryKeys = ["deviceId", "ts", "kind"])
data class EventRow(
    val deviceId: String,
    val ts: Long,
    val kind: String,
    val payloadJSON: String,
    val synced: Int = 0,
)

/**
 * Battery sample. Swift `battery` (v1 + v6 `charging`). PK (deviceId, ts).
 * `soc` is state-of-charge percent (nullable), `mv` millivolts (nullable),
 * `charging` only set by BATTERY_LEVEL events (nullable otherwise).
 */
@Entity(tableName = "battery", primaryKeys = ["deviceId", "ts"])
data class BatterySample(
    val deviceId: String,
    val ts: Long,
    val soc: Double? = null,
    val mv: Int? = null,
    val charging: Boolean? = null,
    val synced: Int = 0,
)

/** SpO2 raw-ADC sample (type-47). Swift `spo2Sample` (v3). PK (deviceId, ts). */
@Entity(tableName = "spo2Sample", primaryKeys = ["deviceId", "ts"])
data class Spo2Sample(
    val deviceId: String,
    val ts: Long,
    val red: Int,
    val ir: Int,
    val synced: Int = 0,
)

/** Skin-temperature raw-ADC sample (type-47). Swift `skinTempSample` (v3). PK (deviceId, ts). */
@Entity(tableName = "skinTempSample", primaryKeys = ["deviceId", "ts"])
data class SkinTempSample(
    val deviceId: String,
    val ts: Long,
    val raw: Int,
    val synced: Int = 0,
)

/**
 * Step / motion counter sample (WHOOP5 type-47 step_motion_counter@57). PK (deviceId, ts).
 * `counter` is the device's CUMULATIVE u16 running step counter (0..65535, wraps). It is NOT a
 * per-sample delta — the daily step total is derived in AnalyticsEngine by summing positive
 * consecutive deltas (with u16 wraparound handling). Mirrors SkinTempSample exactly (IGNORE-dedupe
 * by natural key). APPROXIMATE: @57's step semantics are an on-device estimate, unverified against
 * the official WHOOP app (see HistoricalStreams.decodeWhoop5Historical comments). (#78)
 */
@Entity(tableName = "stepSample", primaryKeys = ["deviceId", "ts"])
data class StepSample(
    val deviceId: String,
    val ts: Long,
    val counter: Int,
    val synced: Int = 0,
)

/** Respiration raw-ADC sample (type-47). Swift `respSample` (v3). PK (deviceId, ts). */
@Entity(tableName = "respSample", primaryKeys = ["deviceId", "ts"])
data class RespSample(
    val deviceId: String,
    val ts: Long,
    val raw: Int,
    val synced: Int = 0,
)

/** Gravity vector sample (type-47, unit "g"). Swift `gravitySample` (v3). PK (deviceId, ts). */
@Entity(tableName = "gravitySample", primaryKeys = ["deviceId", "ts"])
data class GravitySample(
    val deviceId: String,
    val ts: Long,
    val x: Double,
    val y: Double,
    val z: Double,
    val synced: Int = 0,
)

/**
 * Cached server-computed daily metrics. Swift `dailyMetric` (v4 + v7).
 * Natural key (deviceId, day) where day is "YYYY-MM-DD". All metric columns nullable.
 *
 * Field set/order matches MetricsCache.swift DailyMetric so com.noop.analytics.IllnessWatch
 * can read restingHr / avgHrv / recovery / strain / skinTempDevC / respRateBpm / totalSleepMin.
 */
@Entity(tableName = "dailyMetric", primaryKeys = ["deviceId", "day"])
data class DailyMetric(
    val deviceId: String,
    val day: String,
    val totalSleepMin: Double? = null,
    val efficiency: Double? = null,
    val deepMin: Double? = null,
    val remMin: Double? = null,
    val lightMin: Double? = null,
    val disturbances: Int? = null,
    val restingHr: Int? = null,
    val avgHrv: Double? = null,
    val recovery: Double? = null,
    val strain: Double? = null,
    val exerciseCount: Int? = null,
    // v7 in-sleep signal aggregates (nullable; computed server-side).
    val spo2Pct: Double? = null,        // mean SpO2 (%) during sleep
    val skinTempDevC: Double? = null,   // skin-temperature deviation (°C) from baseline
    val respRateBpm: Double? = null,    // mean respiration rate (breaths/min) during sleep
    // On-device derived daily step total from the WHOOP5 step_motion_counter@57 (sum of positive
    // consecutive u16-counter deltas over the day). APPROXIMATE — not cloud/clinical parity. (#78)
    val steps: Int? = null,
    // On-device APPROXIMATE whole-day active+resting energy estimate (kcal), computed from HR alone
    // by AnalyticsEngine (Keytel active + Harris–Benedict BMR). Null when the day has no scored HR
    // window. NOT cloud/clinical parity — a heart-rate estimate. (#78)
    val activeKcalEst: Double? = null,
)

/**
 * Cached server-computed sleep session. Swift `sleepSession` (v4).
 * Natural key (deviceId, startTs). `stagesJSON` is the verbatim stage-segments JSON array.
 */
@Entity(tableName = "sleepSession", primaryKeys = ["deviceId", "startTs"])
data class SleepSession(
    val deviceId: String,
    val startTs: Long,
    val endTs: Long,
    val efficiency: Double? = null,
    val restingHr: Int? = null,
    val avgHrv: Double? = null,
    val stagesJSON: String? = null,
)

/**
 * Generic long-format metric store. Swift `metricSeries` (v9).
 * Natural key (deviceId, day, key); `value` is always a REAL. The secondary index
 * (deviceId, key, day) mirrors `idx_metricSeries_device_key_day` for index-only range reads.
 */
@Entity(
    tableName = "metricSeries",
    primaryKeys = ["deviceId", "day", "key"],
    indices = [Index(name = "idx_metricSeries_device_key_day", value = ["deviceId", "key", "day"])],
)
data class MetricSeriesRow(
    val deviceId: String,
    val day: String,
    @ColumnInfo(name = "key") val key: String,
    val value: Double,
)

/**
 * Cached journal answer (logged behaviour). Swift `journal` (v8 — JournalWorkoutAppleCache.swift).
 * Natural key (deviceId, day, question) where day is "YYYY-MM-DD". `answeredYes` is stored as an
 * INTEGER 0/1 in SQLite; exposed as Boolean here (Room maps Boolean -> INTEGER), matching the
 * Swift `answeredYes ? 1 : 0` write and `(... as Int) != 0` read.
 */
@Entity(tableName = "journal", primaryKeys = ["deviceId", "day", "question"])
data class JournalEntry(
    val deviceId: String,
    val day: String,
    val question: String,
    val answeredYes: Boolean,
    val notes: String? = null,
)

/**
 * Cached workout (Whoop + Apple Health). Swift `workout` (v8 — JournalWorkoutAppleCache.swift).
 * Natural key (deviceId, startTs, sport). All metric columns nullable. `source` distinguishes
 * origin ("my-whoop" / "apple-health"); `zonesJSON` is verbatim HR-zone-percentages JSON.
 * `startTs`/`endTs` are wall-clock unix SECONDS (Swift Int -> Kotlin Long).
 */
@Entity(tableName = "workout", primaryKeys = ["deviceId", "startTs", "sport"])
data class WorkoutRow(
    val deviceId: String,
    val startTs: Long,
    val endTs: Long,
    val sport: String,
    val source: String,
    val durationS: Double? = null,
    val energyKcal: Double? = null,
    val avgHr: Int? = null,
    val maxHr: Int? = null,
    val strain: Double? = null,
    val distanceM: Double? = null,
    val zonesJSON: String? = null,
    val notes: String? = null,
    val routePolyline: String? = null, // Encoded GPS route (RouteMath polyline); null = no GPS.
)

/**
 * Cached Apple-Health daily aggregate. Swift `appleDaily` (v8 — JournalWorkoutAppleCache.swift).
 * Natural key (deviceId, day) where day is "YYYY-MM-DD". All metric columns nullable.
 */
@Entity(tableName = "appleDaily", primaryKeys = ["deviceId", "day"])
data class AppleDaily(
    val deviceId: String,
    val day: String,
    val steps: Int? = null,
    val activeKcal: Double? = null,
    val basalKcal: Double? = null,
    val vo2max: Double? = null,
    val avgHr: Int? = null,
    val maxHr: Int? = null,
    val walkingHr: Int? = null,
    val weightKg: Double? = null,
)
