package com.noop.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/*
 * Room entities mirroring the verified GRDB schema in
 * Packages/WhoopStore/Sources/WhoopStore/Database.swift (+ MetricsCache.swift).
 *
 * That mirroring is CHECKED, not just described: `SchemaOracleTest` compares the schema Room's processor
 * generates from these entities against the shared `schema_oracle.json`, and the Swift `SchemaOracleTests`
 * compares GRDB's `PRAGMA table_info` against the same file. Editing an entity here — adding a column,
 * reordering fields, changing a type or nullability — fails that test until the GRDB twin lands with it or
 * the difference is written into the fixture's `divergenceReasons`. The notes below are a reader's summary
 * of what the oracle enforces.
 *
 * Natural keys mirror the Swift `ON CONFLICT(...) DO NOTHING` upserts so insert dedupe behaves identically,
 * with ONE deliberate exception noted inline:
 *   - hrSample        PK (deviceId, ts)
 *   - rrInterval      PK (deviceId, ts, rrMs, seq)  // v18: `seq` tiebreaks EQUAL same-second beats.
 *                                                   // Swift matches since WhoopStore `v24-rr-seq`; this
 *                                                   // note used to say the fix was still pending there.
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

/**
 * HR derived from the WHOOP 5/MG **v26** optical PPG waveform (#156). The v26 record stores no
 * per-second bpm (HR is PPG-derived on-device), so [com.noop.protocol.PpgHr] reconstructs it by
 * autocorrelation. Kept in its own table (NOT merged into `hrSample`) so a real sensor HR is never
 * confused with a derived estimate; [conf] (0…1) records the autocorrelation strength. PK
 * (deviceId, ts) = one estimate per window-centre second; [hrBuckets][WhoopDao.hrBuckets] COALESCE-
 * unions it with `hrSample` so PPG HR only fills seconds the strap never reported. v5_6 migration.
 */
@Entity(tableName = "ppgHrSample", primaryKeys = ["deviceId", "ts"])
data class PpgHrSample(
    val deviceId: String,
    val ts: Long,
    val bpm: Int,
    val conf: Double,
    val synced: Int = 0,
)

/** One downsampled HR point, the bucket's start (unix seconds) + the mean bpm over it. Query
 *  result of [WhoopDao.hrBuckets], not a table. Mirrors the macOS `HRBucket`. */
data class HrBucket(
    val bucket: Long,
    val avgBpm: Double,
)

/** Aggregate HR over a time window, sample count + avg/max bpm. Query result of
 *  [WhoopDao.hrWindowStats], not a table. Used to derive a workout's HR from strap samples when
 *  the imported session carries none (#77). avg/max are null when n == 0. */
data class HrWindowStats(
    val n: Long,
    val avg: Double?,
    val max: Int?,
)

/**
 * R-R interval. Swift `rrInterval` (v1); PK widened in Room v18 to (deviceId, ts, rrMs, **seq**), adding
 * `seq` as a tiebreaker for two EQUAL R-R intervals that fall in the same 1-second `ts` bucket. Keying by
 * value alone (deviceId, ts, rrMs) + `ON CONFLICT DO NOTHING` silently dropped the second of two equal
 * successive beats in a second, removing a zero-difference pair and biasing RMSSD/HRV **high** — the bias
 * matters most at rest/sleep, exactly when HRV is scored. `seq` counts equal (ts, rrMs) beats (0, 1, …) so
 * both survive. DISTINCT intervals keep their own (ts, rrMs) slot exactly as before, so no distinct beat is
 * ever dropped — including across separate insert batches or the live/historical merge (rrMs stays in the
 * key). Re-syncing identical records reproduces the same (ts, rrMs, seq), so the insert stays idempotent.
 *
 * `ord` (Room v24, #823) is the beat's EMISSION order within its (deviceId, ts) group — the position the
 * strap sent it in, recorded at decode time. It is deliberately NOT in the key: the key must stay
 * (deviceId, ts, rrMs, seq) for the dedup/idempotency reasons above, and an insertion counter in the key
 * would collide distinct beats across batches. `ord` exists purely so reads can restore emission order.
 * Reads MUST order by it — see WhoopDao.rrIntervals. Without it, reads came back in MAGNITUDE order
 * (`ORDER BY ts, rrMs`), which sorts successive beats to be similar by construction and biases RMSSD
 * DOWN, since RMSSD is built entirely from successive differences.
 *
 * NULL means "emission order unknown": every row written before v24, and any row from a source that
 * cannot supply it. That is honest rather than a guess, and it sorts correctly for free — SQLite orders
 * NULL first in ASC, so a pre-v24 second (all NULL) ties on `ord` and falls through to the old
 * `rrMs, seq` order exactly. Not backfillable: the order was never recorded.
 *
 * `srcChannel` (Room v26, #1071) is WHICH sensor channel measured the beat, as [RrSourceChannel.code].
 * An Oura ring reports the SAME heartbeats on more than one tag — 0x80 green-quality for the whole wear
 * period, 0x6E only while an SpO2 measurement runs — and every one of them decoded to an R-R row, so an
 * untagged table held roughly TWO complete copies of every night (2.06x the beats the measured HR curve
 * allows over one 488-min window). That leaves the MEAN correct — resting HR was never wrong — and
 * destroys everything built on successive differences: RMSSD, and a ~200 ms nocturnal SDNN where a
 * healthy adult asleep is 40-100 ms.
 *
 * NOT a de-duplication: both rows are real measurements of one beat by different optics, and the second
 * channel is the obvious cross-check on the first. So nothing is deleted — the column labels the source
 * and `WhoopDao.rrIntervals` filters at READ. Also NOT in the key, for the same reason `ord` is not:
 * keying on the label would make the SAME beat insertable twice under two labels, which is the
 * double-count being fixed.
 *
 * NULL means "no channel to name": every WHOOP row forever (one beat source), every row written before
 * v26, and any source that does not report one. Pre-v26 rows are still READ — a filter that dropped NULL
 * would delete every WHOOP night from scoring — so historical Oura rows keep their old inflated
 * coverage. Not backfillable: the channel was never recorded. (For the record, since it is how this was
 * diagnosed: in an existing DB the two remain separable by `rrMs % 8`, an 0x6E row always being a
 * multiple of 8 and an 0x80 row landing there only 1 time in 8 by chance.)
 *
 * PARITY: the Swift `rrInterval` key was widened to match in WhoopStore `v24-rr-seq`, `ord` lands there
 * as `v30-rr-ord`, and `srcChannel` as `v32-rr-src-channel`. (An earlier revision of this note said the
 * Swift widening was still pending; it had already shipped.)
 */
@Entity(tableName = "rrInterval", primaryKeys = ["deviceId", "ts", "rrMs", "seq"])
data class RrInterval(
    val deviceId: String,
    val ts: Long,
    val rrMs: Int,
    val seq: Int = 0,
    val synced: Int = 0,
    val ord: Int? = null,
    val srcChannel: Int? = null,
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
    // The two AUXILIARY thermal channels riding the same 5/MG v18 record: `temp_aux_1_raw@69` and
    // `temp_aux_2_raw@71`, signed i16 whose °C = value/10 (a DIFFERENT scale from [raw]'s /100). Decoded
    // since the v18 layout was mapped and dropped at the insert boundary until MIGRATION_24_25 (Swift
    // WhoopStore v31 parity). Nullable INTEGER, no SQL DEFAULT, so old rows and every WHOOP 4.0 record
    // read back null — an absent channel stays absent, never a fabricated 0. Declared AFTER `synced` so
    // the entity order matches what ALTER TABLE ADD COLUMN produces (both append at the end).
    val aux1Raw: Int? = null,
    val aux2Raw: Int? = null,
)

/**
 * Step / motion counter sample (WHOOP5 type-47 step_motion_counter@57). PK (deviceId, ts).
 * `counter` is the device's CUMULATIVE u16 running step counter (0..65535, wraps). It is NOT a
 * per-sample delta, the daily step total is derived in AnalyticsEngine by summing positive
 * consecutive deltas (with u16 wraparound handling). Mirrors SkinTempSample exactly (IGNORE-dedupe
 * by natural key). APPROXIMATE: @57's step semantics are an on-device estimate, unverified against
 * the official WHOOP app (see HistoricalStreams.decodeWhoop5Historical comments). (#78)
 */
@Entity(tableName = "stepSample", primaryKeys = ["deviceId", "ts"])
data class StepSample(
    val deviceId: String,
    val ts: Long,
    val counter: Int,
    // The per-record activity-class enum decoded from @63 (community finding #316): 0=still, 1=walk, 2=run;
    // null when the byte was 0xFF/invalid or absent. The decoder ALREADY carries this on [StepRow], but it
    // was DROPPED at the insert boundary (the v2_3 stepSample held only ts/counter), so it could never be
    // persisted or read. Added by MIGRATION_12_13 (Swift WhoopStore v19 parity). Nullable INTEGER (no SQL
    // DEFAULT, a Kotlin construction default never reaches the schema), so old rows read back null: an
    // absent class stays absent, never a fabricated 0/"still".
    val activityClass: Int? = null,
    val synced: Int = 0,
)

/**
 * The strap's OWN per-record band sleep_state (#175). The decoder reads the v18 @81 high nibble
 * (`(sb ushr 4) and 3`) as 0 wake / 1 still / 2 asleep / 3 up. The BYTE + offset are read off real captured
 * frames exactly like every other v18 field; ONLY the non-zero code meanings are community/structure
 * inference (every real capture we hold reads 0, a worn daytime wake), so this is carried VERBATIM (the
 * strap's own byte) and surfaced/persisted as the strap's reported state, NOT trusted to override the derived
 * hypnogram. Added by MIGRATION_14_15 (Swift WhoopStore v21 parity). PK (deviceId, ts). Swift `SleepStateSample`.
 */
@Entity(tableName = "sleepStateSample", primaryKeys = ["deviceId", "ts"])
data class SleepStateSampleEntity(
    val deviceId: String,
    val ts: Long,
    val state: Int,   // 0 wake / 1 still / 2 asleep / 3 up (band's own high-nibble code)
    // The RAW @81 flag byte, all 8 bits, verbatim (MIGRATION_24_25 / Swift WhoopStore v31). [state] stays
    // exactly `(rawByte shr 4) and 3`, so every existing #175 consumer is bit-identical; this column keeps
    // the bits the mask throws away — b0-1 `onwrist`, b2-3 `wake_quality`, and b6-7, which have no
    // interpretation at all yet. Nullable, no DEFAULT: null on every pre-migration row.
    val rawByte: Int? = null,
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
    // The strap's OWN gravity-removed motion magnitude for the same second (`dynamic_acceleration@41`,
    // f32 g) — added by MIGRATION_24_25 (Swift WhoopStore v31). Stored BESIDE the vector, never instead
    // of it, and read by NOTHING: the sleep stager's motion spine still derives stillness from the 1 Hz
    // gravity deltas. Nullable REAL, no DEFAULT, so pre-migration rows and every WHOOP 4.0 record read
    // back null. Declared after `synced` to match the ALTER TABLE column order.
    val dynAccel: Double? = null,
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
    // On-device derived or imported step total. WHOOP5 days use step_motion_counter@57 (sum of
    // positive u16-counter deltas); activity-file imports can fill missing steps from file summaries.
    // APPROXIMATE, not cloud/clinical parity. (#78)
    val steps: Int? = null,
    // On-device APPROXIMATE whole-day active+resting energy estimate (kcal), computed from HR alone
    // by AnalyticsEngine (Keytel active + Harris–Benedict BMR). Null when the day has no scored HR
    // window. NOT cloud/clinical parity, a heart-rate estimate. (#78)
    val activeKcalEst: Double? = null,
    // WHOOP 4.0 raw SpO2 PPG ADC means over detected sleep (v17 columns, #93). The RAW red/IR optical
    // channels banked on the v24 historical layout (spo2_red@68 / spo2_ir@70), NOT a calibrated
    // blood-oxygen % — that needs WHOOP's proprietary curve. Both nullable and on-device only
    // (imports/cloud never carry them), so old rows + non-4.0 nights stay null.
    val spo2Red: Int? = null,           // mean raw red PPG ADC during detected sleep
    val spo2Ir: Int? = null,            // mean raw IR PPG ADC during detected sleep
)

/**
 * Cached server-computed sleep session. Swift `sleepSession` (v4 + v13 userEdited + v14 startTsAdjusted).
 * Natural key (deviceId, startTs). `stagesJSON` is the verbatim stage-segments JSON array.
 *
 * Durable bed/wake editing (port of iOS PR #395):
 *   - [userEdited] (v13, MIGRATION_6_7): set true when the user hand-corrects this night's bed/wake
 *     time. The post-sync recompute pass preserves those bounds instead of re-upserting the
 *     strap-detected session over them (the overlap guard in IntelligenceEngine), so a later strap
 *     re-sync can't revert the correction. Stored as INTEGER NOT NULL DEFAULT 0 (Room maps Boolean →
 *     INTEGER), so every existing row reads as un-edited.
 *   - [startTsAdjusted] (v14, MIGRATION_6_7): the hand-set bed (onset) time. [startTs] stays the
 *     IMMUTABLE detected primary key (so the recompute guard + daily override keep matching on it,
 *     and the upsert REPLACEs the row in place rather than spawning a duplicate at a moved key, the
 *     latent Android bug this fix removes). Nullable INTEGER; null means "onset not edited, use
 *     startTs". Display / sort / re-staging use [effectiveStartTs]. Mirrors the GRDB v14 migration.
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
    // v13/v14 (iOS PR #395 parity). Defaulted so every existing constructor call-site compiles
    // unchanged and old rows read userEdited=false / startTsAdjusted=null.
    val userEdited: Boolean = false,
    val startTsAdjusted: Long? = null,
    // v18 (Swift WhoopStore v18 parity, MIGRATION_11_12). Per-epoch analytics the stager/interpreter
    // compute then discard, banked beside [stagesJSON] on the same row:
    //   - [motionJSON]: a compact JSON array of per-epoch motion magnitudes (the SleepStager's per-epoch
    //     restlessness signal), one entry per stage epoch on the SAME 30 s grid as stagesJSON (H8).
    //   - [sleepStateJSON]: a compact JSON array of the decoded v18 band sleep_state per epoch, the
    //     Interpreter's `(sb shr 4) and 3` (H2 persist half).
    // Both nullable TEXT (no SQL DEFAULT, a Kotlin construction default never reaches the schema), so old
    // rows read back null. HONESTY: an absent signal stays null, never a fabricated zero series. Written/read
    // through the targeted DAO methods (not the @Upsert path, which never names them and so preserves them).
    val motionJSON: String? = null,
    val sleepStateJSON: String? = null,
) {
    /** The bed (onset) time to DISPLAY / sort / re-stage by: the user's hand-set onset when edited,
     *  else the immutable detected [startTs]. Mirrors Swift `CachedSleepSession.effectiveStartTs`. */
    val effectiveStartTs: Long get() = startTsAdjusted ?: startTs

    /** Whole-block duration in hours (effective onset → wake). */
    val durationHours: Double get() = (endTs - effectiveStartTs) / 3600.0

    /**
     * DERIVED nap classification (#518), computed at READ time, NO schema column / migration. A block
     * is a nap when it is SHORT (< [NAP_MAX_HOURS]) or DAYTIME-onset (onset not in the overnight window).
     * The day's MAIN sleep is resolved separately (the longest, overnight-preferring block, see
     * SleepScreen.mainSleepBlock); this flag only describes the block's own shape, so the UI can label /
     * count naps consistently with iOS SleepView.isNap. A long overnight split-sleep block is NOT a nap.
     */
    val isNapShaped: Boolean
        get() {
            val cal = java.util.Calendar.getInstance().apply { timeInMillis = effectiveStartTs * 1000L }
            val h = cal.get(java.util.Calendar.HOUR_OF_DAY)
            val overnightOnset = h >= 20 || h < 10
            return durationHours < NAP_MAX_HOURS || !overnightOnset
        }

    companion object {
        /** A block shorter than this is nap-shaped regardless of onset. Mirrors iOS SleepView.napMaxHours. */
        const val NAP_MAX_HOURS: Double = 3.0
    }
}

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
 * Provider provenance for one NOOP-computed score. Separate from `dayOwnership`: ownership controls
 * raw-input resolution, while this records the source actually used for a persisted metric.
 */
@Entity(
    tableName = "scoreInputProvenance",
    primaryKeys = ["deviceId", "day", "key"],
    indices = [Index(name = "idx_scoreInputProvenance_source", value = ["sourceId"])],
)
data class ScoreInputProvenanceRow(
    val deviceId: String,
    val day: String,
    @ColumnInfo(name = "key") val key: String,
    val sourceId: String,
)

/**
 * Lab Book marker reading (Health Records pillar). Swift `labMarker` (Database.swift v17 /
 * LabMarkerStore.swift). The richer source-of-truth behind the daily `metricSeries` projection:
 * one row per dated reading the USER entered themselves, a day can hold several readings, each
 * carries a precise `takenAt` instant and `unit`, and notes / qualitative (`valueText`) results
 * don't fit a REAL-only `metricSeries` cell.
 *
 * `id` is the client-generated stable primary key (edit/delete by id, backup round-trips); the
 * natural key (deviceId, markerKey, takenAt, source) is a UNIQUE index so a re-import of the same
 * reading is idempotent (`OnConflictStrategy.REPLACE` on that index, matching the Swift
 * `ON CONFLICT(deviceId, markerKey, takenAt, source) DO UPDATE`). `value` is nullable (a
 * qualitative entry stores only `valueText`); `day` is the pre-derived yyyy-MM-dd projection key.
 *
 * NON-CLINICAL: holds ONLY user-entered values + an OPTIONAL user-entered `referenceText` (their
 * own report's range, verbatim). No reference-range tables, no normality judgement. Added by
 * MIGRATION_10_11.
 */
@Entity(
    tableName = "labMarker",
    indices = [
        Index(name = "idx_labMarker_natural", value = ["deviceId", "markerKey", "takenAt", "source"], unique = true),
        Index(name = "idx_labMarker_device_marker_takenAt", value = ["deviceId", "markerKey", "takenAt"]),
        Index(name = "idx_labMarker_device_category", value = ["deviceId", "category"]),
    ],
)
data class LabMarkerRow(
    @androidx.room.PrimaryKey
    val id: String,
    val deviceId: String,
    val markerKey: String,
    val category: String,
    val day: String,          // yyyy-MM-dd (projection key)
    val takenAt: Long,        // epoch seconds (precise instant)
    val value: Double? = null, // nullable: qualitative entries store only valueText
    val valueText: String? = null,
    val unit: String,
    val source: String,
    val note: String? = null,
    val referenceText: String? = null, // user-entered range, shown verbatim; NOOP ships none
)

/**
 * Cached journal answer (logged behaviour). Swift `journal` (v8, JournalWorkoutAppleCache.swift).
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
    /**
     * Optional numeric reading for a numeric journal item (e.g. caffeine mg, alcohol units), #322.
     * null for a plain yes/no answer and for every imported WHOOP row. A numeric log writes
     * answeredYes=true AND numericValue=v, so the EffectRanker with/without split is unchanged.
     * Swift twin: JournalEntry.numericValue (v20). Room maps `Double?` -> nullable REAL.
     */
    val numericValue: Double? = null,
)

/**
 * Cached workout (Whoop + Apple Health). Swift `workout` (v8, JournalWorkoutAppleCache.swift).
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
    // #1058: per-session step count (activity-file foot sports; null otherwise). The day's step total is
    // recomputed as SUM over that day's sessions, so a second file for a day adds instead of clobbering.
    // Declared LAST so the v27 ALTER-appended column matches this fresh-schema order. Swift `WorkoutRow.steps`.
    val steps: Int? = null,
)

/**
 * Durable "this detected bout is not a workout" marker (#107). The IntelligenceEngine wipes +
 * re-derives sport="detected" rows under "<deviceId>-noop" every run, so a plain delete only hides a
 * bout until the next re-detect recreates it. This table is INDEPENDENT of that churn: a detected row
 * is filtered out at read time whenever it OVERLAPS a marker's [startTs, endTs] span, so dismissal is
 * permanent, and span-overlap (not an exact-key match) survives the small startTs DRIFT a bout's
 * boundary can take as more HR arrives, matching the macOS dismissed-span semantics exactly.
 *
 * PK (deviceId, startTs), one marker per detected start; `endTs` is the span end. Android-only table
 * (no GRDB twin): the macOS read model can't add a column to its shared workout struct, so macOS
 * persists the equivalent as a UserDefaults "startTs:endTs" span list. Added by MIGRATION_4_5.
 */
@Entity(tableName = "dismissedWorkout", primaryKeys = ["deviceId", "startTs"])
data class DismissedWorkout(
    val deviceId: String,
    val startTs: Long,
    val endTs: Long,
)

/**
 * Durable tombstone for a user-DELETED sleep session (#33): keeps a deleted computed night from being
 * re-derived by the recompute, mirroring [DismissedWorkout] (#107). PK (deviceId, startTs), keyed on
 * the deleted session's start; `endTs` is the span the recompute's overlap test uses (a re-detected
 * onset can drift second-to-second). iOS has the twin sleep-delete path since #68 (its tombstones live in
 * UserDefaults, not a table); the undo lifts a tombstone by (deviceId, startTs) (#65).
 * [managementVisible] controls only whether the Android Sleep screen offers this marker for
 * recomputation. Hiding that row must never weaken the tombstone's suppression of re-detection (#515).
 * Added by MIGRATION_9_10; managementVisible by MIGRATION_21_22.
 */
@Entity(tableName = "dismissedSleep", primaryKeys = ["deviceId", "startTs"])
data class DismissedSleep(
    val deviceId: String,
    val startTs: Long,
    val endTs: Long,
    val managementVisible: Boolean = true,
)

/**
 * Cached Apple-Health daily aggregate. Swift `appleDaily` (v8, JournalWorkoutAppleCache.swift).
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

/**
 * The RAW WHOOP 5.0 v26 optical PPG waveform, one record per second (v27 / MIGRATION_18_19, issue #156
 * follow-up). Swift `ppgWaveformSample` (WhoopStore Database.swift `v27-ppg-waveform` migration). The
 * strap's 24 Hz buffer was fully decoded but only ever used to derive [PpgHrSample]; the samples
 * themselves were discarded right after. Persisted here so a future re-analysis (a better HR estimator,
 * HRV-from-PPG, a waveform viewer) can run over the ORIGINAL samples, not just the derived bpm.
 *
 * The 24 raw i16 ADC samples are packed into a compact BLOB (2 bytes/sample, little-endian i16, see
 * [StreamPersistence.packPpgSamples]/[StreamPersistence.unpackPpgSamples]) instead of 24 scalar rows,
 * keeping a v26-heavy night to roughly the same order of magnitude as ONE extra per-second stream. The
 * BLOB format is byte-identical to the Swift GRDB `WhoopStore.packPpgSamples` so a `.noopbak` round-trips.
 * PK (deviceId, ts) mirrors every other per-second stream; a truncated frame can decode fewer than 24
 * samples. Fields are declared in the SAME order as the GRDB schema (deviceId, ts, samples) so the
 * migration's CREATE TABLE column order matches Room's generated shape.
 */
@Entity(tableName = "ppgWaveformSample", primaryKeys = ["deviceId", "ts"])
data class PpgWaveformSampleEntity(
    val deviceId: String,
    val ts: Long,
    val samples: ByteArray,
) {
    // ByteArray needs structural equals/hashCode (the generated identity ones break round-trip asserts).
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PpgWaveformSampleEntity) return false
        return deviceId == other.deviceId && ts == other.ts && samples.contentEquals(other.samples)
    }

    override fun hashCode(): Int {
        var result = deviceId.hashCode()
        result = 31 * result + ts.hashCode()
        result = 31 * result + samples.contentHashCode()
        return result
    }
}

/**
 * One 1-second WHOOP 5/MG raw-IMU offload buffer (#423): 100 Hz 6-axis inertial data. [samples] is a
 * packed little-endian i16 BLOB of the six columns in wire order — ax×100, ay×100, az×100, gx×100, gy×100,
 * gz×100 (1200 bytes) — decoded by [com.noop.protocol.Whoop5RawImu] (scales 1/4096 g/LSB, 2000/32768 dps/
 * LSB). The strap already delivers this in the connect-time offload burst; capturing it needs NO arming.
 * Instrument-first + bounded: written only when raw capture is enabled, and pruned to a rolling recent
 * window ([WhoopRepository.RAW_IMU_RETENTION_ROWS]). Twin of the GRDB `rawImuSample` table. Natural key
 * (deviceId, ts) = one row per strap-second.
 */
@Entity(tableName = "rawImuSample", primaryKeys = ["deviceId", "ts"])
data class RawImuSampleEntity(
    val deviceId: String,
    val ts: Long,
    val samples: ByteArray,
) {
    // ByteArray needs structural equals/hashCode (the generated identity ones break round-trip asserts).
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RawImuSampleEntity) return false
        return deviceId == other.deviceId && ts == other.ts && samples.contentEquals(other.samples)
    }

    override fun hashCode(): Int {
        var result = deviceId.hashCode()
        result = 31 * result + ts.hashCode()
        result = 31 * result + samples.contentHashCode()
        return result
    }
}

/**
 * One Live Session (silent guardian) record (v22 / MIGRATION_15_16). Natural key (deviceId, startTs).
 * `endTs` is null while the session is still in progress. Fields are declared in the SAME order as the
 * Swift WhoopStore `liveSession` schema so the migration SQL matches Room's generated shape. Twin of the
 * Swift `LiveSessionRow`. See docs/superpowers/specs/2026-07-04-live-sessions-design.md.
 */
@Entity(tableName = "liveSession", primaryKeys = ["deviceId", "startTs"])
data class LiveSessionRow(
    val deviceId: String,
    val startTs: Long,
    val endTs: Long?,
    val chargeAtStart: Double?,
    val floorBpm: Double,
    val ceilingBpm: Double,
    val inBandSec: Double,
    val belowSec: Double,
    val aboveSec: Double,
    val pushCount: Int,
    val easeCount: Int,
    val hrSource: String,
)

/**
 * Every remaining 5/MG v18 per-second field the decoder produces and the extractor used to DROP
 * (MIGRATION_24_25 / Swift WhoopStore `v31-deep-capture-channels`).
 *
 * `extractHistoricalStreams` names a dozen fields and silently discards the rest; the strap trims its
 * banked history as soon as NOOP acks the offload, so a field not banked here is gone permanently and can
 * never be censused, correlated, or validated. [fields] is a compact blob of the fifteen leftover slots
 * (see [V18AuxCodec] for the wire format and the column-vs-blob tradeoff) rather than fifteen nullable
 * columns on a hot per-second table.
 *
 * Its OWN table rather than a column on an existing row because no existing per-second table is
 * guaranteed present: `gravitySample` needs `gravity_x` to decode, `skinTempSample` needs @73 to clear
 * its thermal gate, `hrSample` skips bpm=0 — a v18 record can carry aux fields while every one of those
 * gated out. [fields] is NOT NULL because a row is only written when at least one slot is present:
 * absence is "no row", and within a row a clear bitmap bit, never a fabricated 0.
 *
 * The BLOB format is byte-identical to the Swift GRDB `V18AuxCodec` so a `.noopbak` round-trips. PK
 * (deviceId, ts) and field order (deviceId, ts, fields) mirror the GRDB schema.
 *
 * CAPPED, not unbounded: [WhoopRepository.V18_AUX_RETENTION_ROWS] rolling rows per device, the same shape
 * `rawImuSample` uses. This is the only NEW row growth v31 introduces — the columns added to the three
 * existing per-second tables widen rows that were already being written.
 *
 * INSTRUMENTATION ONLY: nothing reads these rows.
 *
 * CONSUMER STATUS — deliberately none, stated here so nobody has to re-derive it. The writer is live, but
 * every `v18AuxSamples` call site on BOTH platforms is a TEST: no analytic, no score, no gate, no UI, no
 * export reads a row. **Do NOT "clean up" the reader as dead code** — the rows are the point, and the
 * reader is how they become reachable once a consumer is validated. The same applies to the four named
 * columns v31/MIGRATION_24_25 added alongside this table (`gravitySample.dynAccel`,
 * `sleepStateSample.rawByte`, `skinTempSample.aux1Raw/aux2Raw`): they are read into their entities and no
 * consumer touches the properties, on purpose.
 *
 * Why the rows still matter unread: before this migration these fields were not merely unread, they were
 * DESTROYED — the strap trims its history the moment an offload is acked, so each one was unrecoverable.
 * This converts permanent loss into retained-but-unread, which is the whole fix and is complete. Fifteen
 * of the slots are unpinned bytes whose names deliberately assert nothing; wiring them to anything before
 * a census would be exactly the overclaiming this project has already had to retract. The capture IS the
 * deliverable. Twin of the Swift `v31-deep-capture-channels` migration note in `Database.swift`.
 */
@Entity(tableName = "v18AuxSample", primaryKeys = ["deviceId", "ts"])
data class V18AuxSampleEntity(
    val deviceId: String,
    val ts: Long,
    val fields: ByteArray,
) {
    // ByteArray needs structural equals/hashCode (the generated identity ones break round-trip asserts).
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is V18AuxSampleEntity) return false
        return deviceId == other.deviceId && ts == other.ts && fields.contentEquals(other.fields)
    }

    override fun hashCode(): Int {
        var result = deviceId.hashCode()
        result = 31 * result + ts.hashCode()
        result = 31 * result + fields.contentHashCode()
        return result
    }
}
