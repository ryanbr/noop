package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.BodyFatRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.HydrationRecord
import androidx.health.connect.client.records.LeanBodyMassRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.noop.analytics.FitnessAgeEngine
import com.noop.analytics.HydrationStore
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.NoopPrefs
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import kotlin.math.round
import kotlin.reflect.KClass

/**
 * Native Android Health Connect importer.
 *
 * Reads a fixed set of record types out of the on-device Health Connect store via
 * `androidx.health.connect:connect-client`, aggregates them **per LOCAL calendar day**
 * (the device's default zone), and upserts them into the same Room store the WHOOP/Apple
 * importers write to (see [WhoopRepository]). All timestamps written are wall-clock UNIX
 * **seconds** (Long), matching the rest of the data layer.
 *
 * Device-id mapping (so this co-exists with real WHOOP + Apple Health data):
 *   - Daily "Apple-style" aggregates (steps / calories / VO2max / weight / avg-HR)
 *     -> [AppleDaily] under deviceId "apple-health".
 *   - WHOOP-style autonomic markers (resting-HR / HRV / sleep-minutes / SpO2 / respiration)
 *     -> [DailyMetric] under deviceId "my-whoop", BUT only for days the strap does NOT already
 *     cover — where "cover" means either a raw "my-whoop" daily row OR a computed "my-whoop-noop"
 *     row (the derived recovery/strain/sleep source). Strap data is richer (recovery/strain/
 *     stages), so we never clobber it — we only backfill days the strap left empty. A strap-only
 *     user has NO raw "my-whoop" rows, so the computed source is what marks their days as owned.
 *   - Exercise sessions -> [WorkoutRow] with source "health-connect".
 *
 * Permissions are assumed to have been granted by the UI (via the Health Connect permission
 * flow) BEFORE [import] is called. If Health Connect is unavailable, or the required
 * read permissions are not in fact granted, [import] returns [ImportSummary.failure].
 */
object HealthConnectImporter {

    const val SOURCE = "Health Connect"

    private const val WHOOP = "my-whoop"
    // The computed/derived source IntelligenceEngine writes recovery/strain/sleep+stages under,
    // namely "<importedDeviceId>-noop" with importedDeviceId == WHOOP. For a strap-only WHOOP user
    // there are NO raw "my-whoop" daily rows — the strap's nights live only here — so the backfill
    // guard below must treat a day the strap COMPUTED as already-owned too, or the sparse HC row
    // (recovery/strain/stages all null) shadows it and blanks Today / regresses Sleep stages (#112).
    private const val WHOOP_COMPUTED = "$WHOOP-noop"
    // Health Connect data is stored under its OWN source ("health-connect"), NOT the shared
    // "apple-health" bucket — otherwise it's mis-attributed to Apple Health in the UI (issue #34).
    // (The recovery/sleep backfill still lands under "my-whoop"; only the external-health aggregates
    // + workouts carry this source.)
    private const val HC_DEVICE = "health-connect"
    private const val HC_WORKOUT_SOURCE = "health-connect"

    /** Read window: a wide ~10-year span ending now. Health Connect itself caps retention. */
    private const val WINDOW_YEARS = 10L

    /** Page size for paginated readRecords() calls. */
    private const val PAGE_SIZE = 5000

    /** Slack (seconds) when matching a DistanceRecord to a workout session — a relay app can write the
     *  distance record offset by up to a few minutes from the session it belongs to (#215). Overlap
     *  clipping keeps a neighbouring activity inside this window from over-counting. */
    private const val DISTANCE_MATCH_BUFFER_S = 300L

    /** The record types this importer reads, in one place so PERMISSIONS stays in sync. */
    private val READ_RECORDS: List<KClass<out Record>> = listOf(
        StepsRecord::class,
        TotalCaloriesBurnedRecord::class,
        ActiveCaloriesBurnedRecord::class,
        HeartRateRecord::class,
        RestingHeartRateRecord::class,
        HeartRateVariabilityRmssdRecord::class,
        SleepSessionRecord::class,
        OxygenSaturationRecord::class,
        RespiratoryRateRecord::class,
        Vo2MaxRecord::class,
        WeightRecord::class,
        BodyFatRecord::class,
        LeanBodyMassRecord::class,
        ExerciseSessionRecord::class,
        DistanceRecord::class,
        HydrationRecord::class,
    )

    /**
     * Hydration import window, in days (#949) — deliberately much shorter than [WINDOW_YEARS].
     *
     * Imported water is stored as one REPLACED row per day, and every day in the window is written
     * (0.0 included) so a drink deleted in the source app disappears here too. Over the 10-year window
     * that zero-fill would be ~3,650 rows on every import to back a screen that shows today plus a
     * 7-day bar chart. 30 days covers it, and matches the iOS sync window exactly so the two platforms
     * import the same span.
     */
    private const val HYDRATION_WINDOW_DAYS = 30L

    /**
     * The set of Health Connect read-permission strings the UI must request before calling
     * [import]. One `READ_*` permission per record type in [READ_RECORDS].
     */
    val PERMISSIONS: Set<String> =
        READ_RECORDS.map { HealthPermission.getReadPermission(it) }.toSet()

    /**
     * Whether the user has been asked about the CURRENT permission set (#949).
     *
     * The import gate is `granted.any { ... }` by design (#150): partial grants are legitimate, so
     * having any one permission is enough to import. But that also means a permission ADDED in an
     * update is never requested — an existing user goes straight to importing and the new type reads
     * as empty forever, indistinguishable from "you have no water logged". Water would have done
     * nothing at all for every existing Android user.
     *
     * Comparing a stored fingerprint of [PERMISSIONS] catches that: when the set grows, the caller
     * launches the request once so the user is asked about the new type, then marks it asked. It is
     * asked ONCE — declining is remembered, so this never becomes a nag.
     */
    fun hasUnaskedPermissions(context: Context): Boolean =
        prefs(context).getString(PERMISSION_SIGNATURE_KEY, null) != permissionSignature

    /** Record that the user has now been asked about the current [PERMISSIONS] set. */
    fun markPermissionsAsked(context: Context) {
        prefs(context).edit().putString(PERMISSION_SIGNATURE_KEY, permissionSignature).apply()
    }

    private const val PERMISSION_SIGNATURE_KEY = "noop.hc.permissionSignature"

    private val permissionSignature: String get() = PERMISSIONS.sorted().joinToString(",")

    private fun prefs(context: Context) =
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)

    /**
     * Whether Health Connect is installed/available on this device.
     * One of [HealthConnectClient.SDK_AVAILABLE],
     * [HealthConnectClient.SDK_UNAVAILABLE],
     * [HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED].
     */
    fun sdkStatus(context: Context): Int = HealthConnectClient.getSdkStatus(context)

    /** The Health Connect client. Caller should gate on [sdkStatus] == SDK_AVAILABLE first. */
    fun client(context: Context): HealthConnectClient = HealthConnectClient.getOrCreate(context)

    /**
     * Read all configured record types, aggregate per local day, and upsert into [repo].
     * Assumes [PERMISSIONS] have already been granted. Returns [ImportSummary.failure] when
     * Health Connect is unavailable or the permissions are not actually granted.
     *
     * [heightCm] is the user's profile height, used ONLY to derive BMI on days that carry a weight
     * (Health Connect has no BMI record, unlike Apple Health). Pass 0.0 to skip BMI derivation.
     */
    suspend fun import(context: Context, repo: WhoopRepository, heightCm: Double = 0.0): ImportSummary {
        if (sdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) {
            return ImportSummary.failure(SOURCE, "Health Connect is not available on this device.")
        }

        // Refile any legacy Health Connect data that landed in the shared "apple-health" bucket before
        // #34 BEFORE importing, so a re-import refiles cleanly instead of duplicating across both sources.
        try { repo.refileLegacyHealthConnect() } catch (_: Exception) { /* best-effort */ }
        // #112 follow-up heal: purge the shadow rows earlier imports wrote while the covered-days
        // gate missed active-strap ids — sparse HC-shaped "my-whoop" sleep/daily rows sitting over
        // nights the strap's computed ("-noop") source already covers. Runs BEFORE this import's
        // own gate is read so the healed coverage is what gets consulted. Idempotent, best-effort
        // like the refile above.
        try { repo.purgeHcShadowedStrapDays() } catch (_: Exception) { /* best-effort */ }

        val client = client(context)

        // Verify the permissions really are granted (the UI may have been dismissed).
        val granted = try {
            client.permissionController.getGrantedPermissions()
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE, "Could not read Health Connect permissions: ${e.message}")
        }
        // Partial permissions are fine (#150): import the record types the user DID grant and skip the
        // rest, instead of refusing the whole import when any single type is missing. Each per-type read
        // below is already independently fault-tolerant — a type whose read permission was revoked throws
        // and is caught/skipped in [readAll] (same path as #34) — so we only need to bail when NOTHING is
        // granted. The user choosing exactly what NOOP can see is the intended behaviour.
        if (granted.none { it in PERMISSIONS }) {
            return ImportSummary.failure(
                SOURCE,
                "No Health Connect data types are granted. Allow at least one type for NOOP in Health Connect, then import.",
            )
        }

        val zone = ZoneId.systemDefault()
        val end = Instant.now()
        val start = LocalDate.now(zone).minusYears(WINDOW_YEARS).atStartOfDay(zone).toInstant()
        val filter = TimeRangeFilter.between(start, end)
        // #528: skip our own writes on import (see readAll / isSelfWritten).
        val selfPackage = context.packageName

        // Per-day accumulators. Keyed by "YYYY-MM-DD" (local).
        val acc = HashMap<String, DayAcc>()
        // #1002: key each record by the offset it was RECORDED in. See [localDayKey] for why the
        // phone's zone is still the right fallback, and for what this does and does not fix.
        fun dayOf(instant: Instant, offset: ZoneOffset?): String = localDayKey(instant, offset, zone)
        fun bucket(day: String): DayAcc = acc.getOrPut(day) { DayAcc() }

        // #949: imported water, ml per local day. Separate from `acc` because it is written to the
        // hydration source (HydrationStore), not the health-connect aggregates.
        val hydrationMl = HashMap<String, Double>()
        // Whether the water read actually COMPLETED. Distinct from "found nothing": the write below
        // replaces the stored figure, so a swallowed read error must not be mistaken for an authoritative
        // zero and wipe 30 days of imported water.
        var hydrationReadOk = false

        val workouts = ArrayList<WorkoutRow>()
        // #1002: each workout's day key, computed at READ time while the record's own zone offset is
        // still in hand. WorkoutRow carries only epoch seconds, so re-deriving the key later would
        // silently fall back to the phone's zone and undo the fix for exactly the travelled sessions
        // it exists for. Index-parallel to [workouts] — append to both together.
        val workoutDays = ArrayList<String>()
        // (startEpochS, endEpochS, kcal) of every active-calorie record, so an imported exercise
        // session can be credited with the calories burned inside its window (#117). Garmin/Fit write
        // ActiveCaloriesBurned as interval records; ExerciseSessionRecord itself carries no energy.
        val activeKcalRecords = ArrayList<KcalRecord>()
        // #835: the same per-record windows for TotalCaloriesBurned. A session whose source writes only
        // Total (common) was previously credited with unrelated background Active alone.
        val totalKcalRecords = ArrayList<KcalRecord>()
        // #983: HC-only users (no strap) had NO sleep at all — the importer collapsed each
        // SleepSessionRecord to a per-day minute total and never wrote a SleepSession row, so the Sleep
        // screen (which reads repo.sleepSessions) fell to its empty state. Keep each night's bounds +
        // per-stage minutes here, paired with its wake day for the coveredDays gate at write-out.
        val hcSleepSessions = ArrayList<Pair<String, SleepSession>>()

        try {
            // --- Steps ---
            // #589: per-SOURCE sums. A phone AND a watch both writing Health Connect steps count the same
            // walk, so summing across sources double-counts (~2x). Sum WITHIN a source (keyed by the record's
            // dataOrigin package), then take the MAX source per day at write-out, mirroring the de-overlap
            // already shipped on iOS/macOS and the Android XML importer.
            readAll(client, StepsRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.startTime, r.startZoneOffset))
                val src = r.metadata.dataOrigin.packageName
                b.stepsBySource[src] = (b.stepsBySource[src] ?: 0L) + r.count
            }
            // --- Total calories burned (basal + active) ---
            // #589: per-SOURCE sums, max-across-sources at write-out (same overlap reasoning as steps).
            readAll(client, TotalCaloriesBurnedRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.startTime, r.startZoneOffset))
                val src = r.metadata.dataOrigin.packageName
                b.totalKcalBySource[src] = (b.totalKcalBySource[src] ?: 0.0) + r.energy.inKilocalories
            totalKcalRecords.add(
                KcalRecord(r.startTime.epochSecond, r.endTime.epochSecond, r.energy.inKilocalories, src))
            }
            // --- Active calories burned ---
            // #589: per-SOURCE sums, max-across-sources at write-out (same overlap reasoning as steps). The
            // per-record window list below gets EVERY record, tagged with its source: the per-workout credit
            // de-overlaps by source ITSELF (#835 — it used to cross-source SUM, roughly doubling a ride that
            // two apps both logged), so the per-source map here only governs the day total.
            readAll(client, ActiveCaloriesBurnedRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.startTime, r.startZoneOffset))
                val src = r.metadata.dataOrigin.packageName
                b.activeKcalBySource[src] = (b.activeKcalBySource[src] ?: 0.0) + r.energy.inKilocalories
                activeKcalRecords.add(
                KcalRecord(r.startTime.epochSecond, r.endTime.epochSecond, r.energy.inKilocalories, src))
            }
            // --- Heart rate (instantaneous samples) -> per-day average ---
            readAll(client, HeartRateRecord::class, filter, selfPackage) { r ->
                for (s in r.samples) {
                    val b = bucket(dayOf(s.time, r.startZoneOffset))
                    b.hrSum += s.beatsPerMinute
                    b.hrCount += 1
                }
            }
            // --- Resting heart rate -> per-day average (rounded to Int) ---
            readAll(client, RestingHeartRateRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                b.rhrSum += r.beatsPerMinute
                b.rhrCount += 1
            }
            // --- HRV (RMSSD, ms) -> per-day average ---
            readAll(client, HeartRateVariabilityRmssdRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                b.hrvSum += r.heartRateVariabilityMillis
                b.hrvCount += 1
            }
            // --- Sleep sessions -> per-day total sleep minutes, assigned to the WAKE day ---
            readAll(client, SleepSessionRecord::class, filter, selfPackage) { r ->
                // Wake-day keyed, so the END offset is the right one — but a writer that sets only the
                // start offset is common, and the start is far better evidence of the sleeper's zone than
                // the phone's zone at import time. Fall through start before giving up.
                val day = dayOf(r.endTime, r.endZoneOffset ?: r.startZoneOffset)
                val b = bucket(day)
                // Prefer summed asleep-stage minutes; fall back to session span when no stages.
                val asleepMin = asleepMinutes(r)
                val totalMin = if (asleepMin > 0.0) asleepMin
                else (r.endTime.epochSecond - r.startTime.epochSecond) / 60.0
                b.sleepMin += totalMin
                b.hasSleep = true
                // #983: also keep the session itself so the Sleep screen has a night to show. startTs/endTs
                // are epoch SECONDS (what repo.sleepSessions queries). Per-stage minutes -> stagesJSON in the
                // same shape the WHOOP CSV / Xiaomi importers use; a generic-SLEEPING-only night has no
                // sub-stage breakdown so stagesJSON is null and the row rides on totalSleepMin.
                hcSleepSessions.add(day to SleepSession(
                    deviceId = WHOOP,
                    startTs = r.startTime.epochSecond,
                    endTs = r.endTime.epochSecond,
                    stagesJSON = hcStagesJson(r),
                ))
            }
            // --- SpO2 (%) -> per-day average ---
            readAll(client, OxygenSaturationRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                b.spo2Sum += r.percentage.value
                b.spo2Count += 1
            }
            // --- Respiratory rate (breaths/min) -> per-day average ---
            readAll(client, RespiratoryRateRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                b.respSum += r.rate
                b.respCount += 1
            }
            // --- VO2 max (ml/kg/min) -> latest value of the day wins ---
            readAll(client, Vo2MaxRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                if (r.time.epochSecond >= b.vo2maxTs) {
                    b.vo2max = r.vo2MillilitersPerMinuteKilogram
                    b.vo2maxTs = r.time.epochSecond
                }
            }
            // --- Weight (kg) -> latest value of the day wins ---
            readAll(client, WeightRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                if (r.time.epochSecond >= b.weightTs) {
                    b.weightKg = r.weight.inKilograms
                    b.weightTs = r.time.epochSecond
                }
            }
            // --- Body fat (%) -> latest value of the day wins. Health Connect's Percentage.value is
            // already 0-100 (unlike Apple's 0..1 fraction), so it stores as-is and matches the iOS
            // "body_fat" key. ---
            readAll(client, BodyFatRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                if (r.time.epochSecond >= b.bodyFatTs) {
                    b.bodyFatPct = r.percentage.value
                    b.bodyFatTs = r.time.epochSecond
                }
            }
            // --- Lean body mass (kg) -> latest value of the day wins (iOS "lean_mass" twin). ---
            readAll(client, LeanBodyMassRecord::class, filter, selfPackage) { r ->
                val b = bucket(dayOf(r.time, r.zoneOffset))
                if (r.time.epochSecond >= b.leanMassTs) {
                    b.leanMassKg = r.mass.inKilograms
                    b.leanMassTs = r.time.epochSecond
                }
            }
            // --- Exercise sessions -> WorkoutRow(source="health-connect") ---
            readAll(client, ExerciseSessionRecord::class, filter, selfPackage) { r ->
                val startS = r.startTime.epochSecond
                val endS = r.endTime.epochSecond
                workouts.add(
                    WorkoutRow(
                        deviceId = HC_DEVICE,
                        startTs = startS,
                        endTs = endS,
                        sport = exerciseName(r),
                        source = HC_WORKOUT_SOURCE,
                        durationS = (endS - startS).toDouble().coerceAtLeast(0.0),
                        // Filled by the #835 post-pass below, which needs the day aggregate (basal = total −
                        // active) and so cannot run until every record has been read. Computing an Active-only
                        // value here too would just be a third full scan of the record lists per workout,
                        // thrown away — the post-pass result always supersedes it.
                        energyKcal = null,
                        avgHr = null,
                        maxHr = null,
                        strain = null,
                        distanceM = null,
                        zonesJSON = null,
                        notes = r.title,
                    )
                )
                // Count exercises per local day on the start day for the WHOOP daily backfill.
                val startDay = dayOf(r.startTime, r.startZoneOffset)
                workoutDays.add(startDay)   // #1002: index-parallel to the add() just above
                bucket(startDay).exerciseCount += 1
            }

            // --- #835: upgrade each workout's calories now the day aggregate exists ---
            // Runs here, not at construction, because the Total-derived estimate needs the day's BASAL
            // burn (total − active), which is only known once every record has been read. Purely a
            // read-side improvement of an imported value: nothing else about the row changes, and a
            // session that already had a good Active credit keeps it (the estimate is a max, not a
            // replacement).
            //
            // Cost: was two FULL record-list scans per workout, O(workouts × kcal records). At
            // WINDOW_YEARS = 10 and ~15-minute provider buckets each list runs to hundreds of thousands
            // of rows, so a first import paid that per workout. Now sorted once into a KcalIndex and
            // range-scanned per window — the fix the previous version of this comment nominated.
            // Sorted ONCE for the whole pass, not per workout: two O(n log n) sorts replace the
            // O(workouts x records) walk the comment above describes. LAZY because an import with no
            // exercise sessions must not pay for two sorts of a ten-year record list to answer nothing.
            val activeIndex by lazy(LazyThreadSafetyMode.NONE) { KcalIndex(activeKcalRecords) }
            val totalIndex by lazy(LazyThreadSafetyMode.NONE) { KcalIndex(totalKcalRecords) }
            for (i in workouts.indices) {
                val w = workouts[i]
                if (w.endTs <= w.startTs) continue
                val day = acc[workoutDays[i]]   // #1002: the key from the record's own offset
                val dayBasal = day?.let {
                    basalKcal(maxSourceDouble(it.totalKcalBySource), maxSourceDouble(it.activeKcalBySource))
                }
                val better = workoutKcal(activeIndex, totalIndex, dayBasal, w.startTs, w.endTs)
                if (better != null) workouts[i] = w.copy(energyKcal = round1(better))
            }

            // Fill per-workout HR (#77): an ExerciseSessionRecord carries no summary HR, so avg/max
            // were stored null and every imported workout showed "–". Intersect each session's window
            // with its HeartRateRecord samples — a targeted per-session read, bounded by workout count
            // (the day-aggregate HeartRateRecord pass above streams the full range and must not be
            // buffered). readAll swallows a per-session failure, so one bad session can't fail the
            // import. ≥60 samples (~1 min) required so a few strays can't fabricate an average.
            for (i in workouts.indices) {
                val w = workouts[i]
                if (w.endTs <= w.startTs) continue
                var sum = 0L
                var n = 0L
                var max = 0L
                readAll(
                    client, HeartRateRecord::class,
                    TimeRangeFilter.between(
                        Instant.ofEpochSecond(w.startTs), Instant.ofEpochSecond(w.endTs)
                    ),
                    selfPackage,
                ) { hr ->
                    for (s in hr.samples) {
                        sum += s.beatsPerMinute
                        n += 1
                        if (s.beatsPerMinute > max) max = s.beatsPerMinute
                    }
                }
                if (n >= 60) {
                    workouts[i] = w.copy(
                        avgHr = round(sum.toDouble() / n).toInt(),
                        maxHr = max.toInt(),
                    )
                }
            }

            // Fill per-workout distance (#215): an ExerciseSessionRecord carries no distance, so
            // distanceM was stored null and the "(Total) Distance" tile read 0. Sum the DistanceRecord
            // metres inside each session window — a targeted per-session read, bounded by workout count,
            // mirroring the HR fill above. readAll swallows a per-session failure / revoked permission
            // (partial-permissions design, #150), so one bad session can't fail the import. iOS/macOS
            // already source workout distance from Apple Health; this is the Android-only equivalent.
            for (i in workouts.indices) {
                val w = workouts[i]
                if (w.endTs <= w.startTs) continue
                var meters = 0.0
                // #215: a relay app (e.g. Suunto → Health Sync) often writes the cumulative DistanceRecord
                // with start/end offset by seconds-to-minutes from the ExerciseSession it belongs to, so a
                // strict between(session.start, session.end) read returned nothing and distance stayed 0
                // even though the distance was in Health Connect. Read a buffered window so an offset record
                // is found, then count only the portion of each record that OVERLAPS the actual session —
                // so a neighbouring activity's record inside the buffer can't over-count.
                val ws = w.startTs
                val we = w.endTs
                readAll(
                    client, DistanceRecord::class,
                    TimeRangeFilter.between(
                        Instant.ofEpochSecond(ws - DISTANCE_MATCH_BUFFER_S),
                        Instant.ofEpochSecond(we + DISTANCE_MATCH_BUFFER_S),
                    ),
                    selfPackage,
                ) { d ->
                    val rs = d.startTime.epochSecond
                    val re = d.endTime.epochSecond
                    val overlap = (minOf(re, we) - maxOf(rs, ws)).coerceAtLeast(0)
                    meters += when {
                        re > rs && overlap > 0 -> d.distance.inMeters * (overlap.toDouble() / (re - rs))
                        re <= rs && rs in (ws - DISTANCE_MATCH_BUFFER_S)..(we + DISTANCE_MATCH_BUFFER_S) ->
                            d.distance.inMeters // degenerate zero-length record near the session
                        else -> 0.0
                    }
                }
                if (meters > 0.0) {
                    workouts[i] = w.copy(distanceM = round1(meters))
                }
            }
            // --- Water (#949) ---
            // Its own short window (see HYDRATION_WINDOW_DAYS) and its own accumulator, because this
            // lands in the hydration source rather than the health-connect aggregates below.
            //
            // SUMMED across sources, unlike steps/calories which take the max (#589). That rule exists
            // because a phone and a watch both measure THE SAME walk; two apps writing water are logging
            // DIFFERENT drinks — a smart bottle and a manual entry are two real glasses, not one counted
            // twice. Taking the max here would silently drop whichever app logged less.
            val hydrationStart = LocalDate.now(zone).minusDays(HYDRATION_WINDOW_DAYS - 1)
                .atStartOfDay(zone).toInstant()
            hydrationReadOk = readAll(
                client, HydrationRecord::class, TimeRangeFilter.between(hydrationStart, end), selfPackage,
            ) { r ->
                // #1002: hydration deliberately keeps the PHONE's zone, unlike every other record here.
                // Its write is a windowed REPLACE: `windowDays` below is built from LocalDate.now(zone),
                // and HydrationStore.importWindow keeps only keys IN that window — anything else is
                // dropped, not merged. Keying a record by its own offset can move it a day off the phone
                // zone, so a drink near either edge of the window would land outside it and be silently
                // discarded. Losing water quietly in a replace path is a worse bug than the one this fixes
                // (see #986). Correcting it properly means making the window offset-aware too, which is a
                // change to shared code with an iOS twin, so it is left for its own PR.
                val day = dayOf(r.startTime, null)
                hydrationMl[day] = (hydrationMl[day] ?: 0.0) + r.volume.inMilliliters
            }
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE, "Health Connect read failed: ${e.message}")
        }

        // Zero-fill the whole hydration window and write it, BEFORE the "nothing found" bail below:
        // `acc` holds only the aggregate types, so a user whose Health Connect has water and nothing
        // else would otherwise return early and never see a drop of it. Writing the zeros is what makes
        // a deletion in the source app propagate (see HydrationStore.KEY_IMPORTED).
        // Only when water is actually granted (#150 partial permissions). Without this check a user who
        // declined the water scope would get the whole window written as zeros on every import — thirty
        // pointless rows, and worse, it would erase legitimately imported water the moment the scope was
        // revoked rather than simply leaving it be.
        // Hydration tracking is opt-in and default OFF, so an import must not quietly populate a feature
        // the user has turned off — and skipping it saves writing a window of rows nothing will read.
        if (hydrationReadOk &&
            HealthPermission.getReadPermission(HydrationRecord::class) in granted &&
            NoopPrefs.hydrationTracking(context)
        ) {
            val today = LocalDate.now(zone)
            val windowDays = (0 until HYDRATION_WINDOW_DAYS.toInt())
                .map { today.minusDays(it.toLong()).toString() }
            try {
                HydrationStore.setImported(repo, HydrationStore.importWindow(windowDays, hydrationMl))
            } catch (_: Exception) {
                // Best-effort: a hydration write failure must not sink an otherwise good import.
            }
        }

        if (acc.isEmpty() && workouts.isEmpty()) {
            return ImportSummary(
                source = SOURCE,
                counts = emptyMap(),
                message = "No Health Connect data found to import.",
            )
        }

        // Days the strap already covers: read ONCE so we never clobber richer strap data. This is
        // the UNION across EVERY strap-native source id — the canonical raw "my-whoop" + computed
        // "my-whoop-noop" pair AND any actively paired strap's "whoop-<mac>" / "whoop-<mac>-noop"
        // rows (#112 follow-up: the gate previously knew only the canonical pair, so a re-paired
        // strap's fresh nights were invisible to it and the sparse HC backfill shadowed them). The
        // computed rows are the ONLY source for a strap-only WHOOP user (no raw daily rows exist),
        // so without them the sparse HC backfill (recovery/strain/stages = null) shadows the computed
        // day and blanks Today / regresses Sleep stages (#112). Each read is wrapped so a missing
        // source is empty, not fatal; HC still gap-fills any day the strap did NOT cover.
        val coveredDays: Set<String> = buildSet {
            for (id in strapSourceIds(repo)) addAll(strapDays(repo, id))
        }

        val appleRows = ArrayList<AppleDaily>(acc.size)
        val dailyRows = ArrayList<DailyMetric>(acc.size)
        // Flattened (day, "weight", kg) points so the cross-source resolver Compare reads can SEE a
        // Health-Connect-only weight history — previously only the Apple-Health *file* importer emitted
        // these, so HC weight showed on Today but was invisible in Compare (#443). Mirrors
        // AppleHealthImporter's metricSeries emission; HC_DEVICE source is treated as apple-equivalent
        // in WhoopRepository.sourceCandidates.
        val metricSeriesRows = ArrayList<MetricSeriesRow>(acc.size)

        for ((day, a) in acc) {
            // #589: de-overlap the per-source maps by MAX (sum within a source, max across sources) so a
            // phone+watch pair doesn't double-count the day's steps / calories. Mirrors the iOS/macOS and
            // Android-XML de-overlap (stepsBySource.values.max()).
            val daySteps = maxSourceLong(a.stepsBySource)
            val dayTotalKcal = maxSourceDouble(a.totalKcalBySource)
            val dayActiveKcal = maxSourceDouble(a.activeKcalBySource)

            // AppleDaily: steps / calories / vo2max / weight / avg-HR.
            val hasApple = daySteps > 0L || dayTotalKcal > 0.0 || dayActiveKcal > 0.0 ||
                a.vo2max != null || a.weightKg != null || a.hrCount > 0
            if (hasApple) {
                appleRows.add(
                    AppleDaily(
                        deviceId = HC_DEVICE,
                        day = day,
                        steps = if (daySteps > 0L) daySteps.toInt() else null,
                        activeKcal = if (dayActiveKcal > 0.0) round1(dayActiveKcal) else null,
                        basalKcal = basalKcal(dayTotalKcal, dayActiveKcal),
                        vo2max = a.vo2max?.let { round1(it) },
                        avgHr = if (a.hrCount > 0) round(a.hrSum.toDouble() / a.hrCount).toInt() else null,
                        maxHr = null,
                        walkingHr = null,
                        weightKg = a.weightKg?.let { round2(it) },
                    )
                )
                a.weightKg?.let { metricSeriesRows += MetricSeriesRow(HC_DEVICE, day, "weight", round2(it)) }
                // Health Connect has NO BMI record (Apple Health carries one, which iOS imports directly),
                // so DERIVE it from the day's weight + the user's PROFILE height — the same height NOOP
                // already uses for its calorie / fitness-age estimates (it defaults to 178 cm until the user
                // sets theirs, so this reflects the profile, not a measured BMI). It sits inside the weight
                // gate because BMI needs a weight; the heightCm > 0 guard skips it when a caller passes none.
                // Compare labels this as profile-derived so it isn't mistaken for a measured reading.
                derivedBmi(a.weightKg, heightCm)?.let {
                    metricSeriesRows += MetricSeriesRow(HC_DEVICE, day, "bmi", it)
                }
            }

            // Body composition from a smart scale (e.g. a Garmin Index synced via Garmin Connect) is
            // metricSeries-only (no AppleDaily column), so emit it OUTSIDE the hasApple gate — a scale-only
            // day with no steps/HR still records its readings. Same keys + units as the iOS Apple Health
            // import: body_fat as a 0-100 percent, lean_mass in kg.
            a.bodyFatPct?.let { metricSeriesRows += MetricSeriesRow(HC_DEVICE, day, "body_fat", round2(it)) }
            a.leanMassKg?.let { metricSeriesRows += MetricSeriesRow(HC_DEVICE, day, "lean_mass", round2(it)) }

            // DailyMetric (my-whoop): resting-HR / HRV / sleep-minutes / SpO2 / respiration,
            // ONLY for days the strap does not already cover (raw OR computed).
            if (day !in coveredDays) {
                val rhr = if (a.rhrCount > 0) round(a.rhrSum.toDouble() / a.rhrCount).toInt() else null
                val hrv = if (a.hrvCount > 0) round1(a.hrvSum / a.hrvCount) else null
                val sleep = if (a.hasSleep) round1(a.sleepMin) else null
                val spo2 = if (a.spo2Count > 0) round1(a.spo2Sum / a.spo2Count) else null
                val resp = if (a.respCount > 0) round1(a.respSum / a.respCount) else null
                val exCount = if (a.exerciseCount > 0) a.exerciseCount else null
                val hasMetric = rhr != null || hrv != null || sleep != null ||
                    spo2 != null || resp != null || exCount != null
                if (hasMetric) {
                    dailyRows.add(
                        DailyMetric(
                            deviceId = WHOOP,
                            day = day,
                            totalSleepMin = sleep,
                            restingHr = rhr,
                            avgHrv = hrv,
                            spo2Pct = spo2,
                            respRateBpm = resp,
                            exerciseCount = exCount,
                        )
                    )
                }
            }
        }

        // Persist. Register the devices we write under so name() lookups resolve.
        try {
            if (appleRows.isNotEmpty()) {
                repo.upsertDevice(HC_DEVICE, name = "Health Connect")
                repo.upsertAppleDaily(appleRows)
            }
            if (metricSeriesRows.isNotEmpty()) repo.upsertMetricSeries(metricSeriesRows)
            if (dailyRows.isNotEmpty()) {
                repo.upsertDevice(WHOOP, name = "WHOOP")
                repo.upsertDailyMetrics(dailyRows)
            }
            // #983: write the collected sleep sessions under WHOOP, but ONLY for days the strap does not
            // already cover (same guard as the daily rows) so a real strap night is never shadowed.
            val sleepRows = hcSleepSessions.filter { it.first !in coveredDays }.map { it.second }
            if (sleepRows.isNotEmpty()) {
                repo.upsertDevice(WHOOP, name = "WHOOP")
                repo.upsertSleepSessions(sleepRows)
            }
            if (workouts.isNotEmpty()) {
                repo.upsertWorkouts(workouts)
            }
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE, "Saving Health Connect data failed: ${e.message}")
        }

        val counts = buildMap {
            if (appleRows.isNotEmpty()) put("appleDaily", appleRows.size)
            if (dailyRows.isNotEmpty()) put("dailyMetric", dailyRows.size)
            if (workouts.isNotEmpty()) put("workout", workouts.size)
        }

        // Day range across everything we touched (aggregates + workout start days).
        val touchedDays = sortedSetOf<String>().apply {
            addAll(appleRows.map { it.day })
            addAll(dailyRows.map { it.day })
            addAll(workoutDays)   // #1002: same keys the workouts were bucketed under
        }
        val firstDay = touchedDays.firstOrNull()
        val lastDay = touchedDays.lastOrNull()

        val total = counts.values.sum()
        return ImportSummary(
            source = SOURCE,
            counts = counts,
            firstDay = firstDay,
            lastDay = lastDay,
            message = if (total == 0) "Nothing new to import from Health Connect."
            else "Imported $total rows from Health Connect.",
        )
    }

    /**
     * Live top-up of TODAY's Health Connect step total (#150 follow-up). [import] is a manual
     * one-shot, so today's stored steps freeze at import time while the real count keeps climbing —
     * past days were fine, today wasn't. This does ONE StepsRecord read over [startOfDay, now],
     * bucketed by record START day exactly like [import], and rewrites only today's "health-connect"
     * [AppleDaily] row. The existing row is read first and updated via `copy(steps = …)` because
     * [WhoopRepository.upsertAppleDaily] is a Room `@Upsert` — on a (deviceId, day) conflict it
     * REPLACES the whole row, so a fresh steps-only row would null every other column.
     *
     * Returns the live sum, or the stored count when today read zero, or null when Health Connect
     * is unavailable / steps aren't granted / there's nothing at all. Never throws.
     */
    suspend fun refreshTodaySteps(context: Context, repo: WhoopRepository): Int? {
        if (sdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return null
        val client = client(context)
        val granted = try {
            client.permissionController.getGrantedPermissions()
        } catch (e: Exception) {
            return null
        }
        if (HealthPermission.getReadPermission(StepsRecord::class) !in granted) return null

        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val dayKey = today.toString()
        // #589: per-SOURCE sums so the live top-up de-overlaps a phone+watch pair exactly like [import]
        // (sum within a source, MAX across sources), instead of summing them into a ~2x inflated count.
        val stepsBySource = HashMap<String, Long>()
        val selfPackage = context.packageName // #528: skip our own writes (see readAll / isSelfWritten)
        // readAll swallows a failed read (the map stays empty), so a flaky provider degrades to the stored
        // row below rather than clobbering it with zero.
        readAll(
            client, StepsRecord::class,
            // #1002: reach back an extra day. The FILTER is in the phone's zone but the day key below is
            // now the record's own, and a record whose offset sits EAST of the phone's zone can belong to
            // today while having started before the phone's midnight — fetching only from midnight would
            // miss it, and the write below replaces a stored count with any non-zero sum, so a miss would
            // overwrite a good figure with a low one. A day of slack covers every real offset (-12..+14).
            // The `== dayKey` test still decides membership, so the extra records are read and discarded;
            // step records are coarse interval rows, a handful per day, so this is cheap on a screen refresh.
            TimeRangeFilter.between(today.minusDays(1).atStartOfDay(zone).toInstant(), Instant.now()),
            selfPackage,
        ) { r ->
            // The filter matches by overlap — drop records that STARTED yesterday so the bucketing
            // agrees with [import]'s dayOf(r.startTime, r.startZoneOffset). #1002: keyed by the
            // record's own offset for that agreement; `today` stays the phone's zone, which is what
            // "today" means for a live top-up of the screen you are looking at.
            if (localDayKey(r.startTime, r.startZoneOffset, zone) == dayKey) {
                val src = r.metadata.dataOrigin.packageName
                stepsBySource[src] = (stepsBySource[src] ?: 0L) + r.count
            }
        }
        val sum = maxSourceLong(stepsBySource) // #589 de-overlap: max source, not cross-source sum

        val existing = try {
            repo.appleDaily(HC_DEVICE, dayKey, dayKey).firstOrNull()
        } catch (e: Exception) {
            null
        }
        // Zero is indistinguishable from "no data yet today" — never overwrite a stored count with it.
        if (sum <= 0L) return existing?.steps

        val updated = existing?.copy(steps = sum.toInt())
            ?: AppleDaily(deviceId = HC_DEVICE, day = dayKey, steps = sum.toInt())
        try {
            if (existing == null) repo.upsertDevice(HC_DEVICE, name = "Health Connect")
            repo.upsertAppleDaily(listOf(updated))
        } catch (e: Exception) {
            return existing?.steps
        }
        return sum.toInt()
    }

    // MARK: - paginated read helper

    /**
     * Read every page of [type] within [filter], invoking [onRecord] for each record.
     * Loops on the response page token so we never miss records past the first page.
     *
     * Returns TRUE when the type was read to completion, FALSE when it was skipped by the catch below.
     * Every accumulating caller ignores this: for them a failed type is simply absent, which costs that
     * type's contribution and nothing else. It matters for a caller whose write REPLACES rather than adds
     * (#949 hydration), because there "read nothing" and "there is nothing" are the same empty map — and
     * treating a swallowed error as an authoritative zero would wipe the stored figure.
     */
    private suspend fun <T : Record> readAll(
        client: HealthConnectClient,
        type: KClass<T>,
        filter: TimeRangeFilter,
        selfPackage: String = "",
        onRecord: (T) -> Unit,
    ): Boolean {
        var pageToken: String? = null
        try {
            do {
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = type,
                        timeRangeFilter = filter,
                        pageSize = PAGE_SIZE,
                        pageToken = pageToken,
                    )
                )
                for (record in response.records) {
                    // #528: never re-ingest what NOOP itself wrote to Health Connect, or "share back"
                    // + import would double-count our own daily totals (steps / active energy / sleep).
                    if (isSelfWritten(record.metadata.dataOrigin.packageName, selfPackage)) continue
                    onRecord(record)
                }
                pageToken = response.pageToken
            } while (pageToken != null)
        } catch (e: Exception) {
            // One record type failing (e.g. a device/SDK validation quirk like "count must not be less
            // than 1" seen on some Health Connect builds) must NOT abort the whole import — log it and
            // keep whatever was read, so every other data type still comes in (issue #34). The reads
            // accumulate into shared buckets, so a partial type is simply absent, never corrupt.
            android.util.Log.w("HealthConnect", "read of ${type.simpleName} failed; skipping: ${e.message}")
            return false
        }
        return true
    }

    // MARK: - strap-coverage helpers

    /**
     * The set of "YYYY-MM-DD" days the strap already covers under [deviceId], read defensively:
     * a missing/empty source (the normal case for raw "my-whoop" on a strap-only user) yields an
     * empty set rather than throwing. The caller unions every strap-native source (#112).
     */
    private suspend fun strapDays(repo: WhoopRepository, deviceId: String): Set<String> =
        try {
            coveredDaySet(repo.days(deviceId))
        } catch (e: Exception) {
            emptySet()
        }

    /**
     * Every source id whose daily rows count as STRAP coverage for the #112 skip-set: the discovered
     * strap-native ids present in the daily cache, always unioned with the canonical
     * [WHOOP] / [WHOOP_COMPUTED] pair (so an empty/failed discovery degrades to the old behaviour,
     * never below it). Read defensively — a DB error must not fail the import.
     */
    private suspend fun strapSourceIds(repo: WhoopRepository): Set<String> =
        try {
            repo.dailyMetricDeviceIds().filterTo(hashSetOf(WHOOP, WHOOP_COMPUTED)) {
                isStrapNativeSourceId(it)
            }
        } catch (e: Exception) {
            setOf(WHOOP, WHOOP_COMPUTED)
        }

    /**
     * True when [id] is a strap-native daily-metric source: the canonical raw "my-whoop", ANY
     * on-device computed "-noop" source, or an actively paired strap's raw "whoop-<mac>" id.
     * These are the sources whose days the HC backfill must never shadow; importer-owned sources
     * ("health-connect", "apple-health", band importers) are NOT strap coverage. Internal (not
     * private) so the #112 skip-set semantics stay unit-testable without Room/Context, like
     * [coveredDaySet].
     */
    internal fun isStrapNativeSourceId(id: String): Boolean {
        val s = id.lowercase()
        return s == WHOOP || s.endsWith("-noop") || s.startsWith("whoop-")
    }

    /**
     * Pure mapper: the distinct local days carried by [rows]. Factored out (and internal) so the
     * #112 skip-set semantics — a strap-only user is covered by their COMPUTED rows — can be
     * unit-tested without Room/Context. Unioning two of these (raw + computed) is what stops the
     * sparse Health Connect backfill from shadowing a day the strap already covered.
     */
    internal fun coveredDaySet(rows: List<DailyMetric>): Set<String> =
        rows.mapTo(HashSet()) { it.day }

    // MARK: - field mapping helpers

    /** Sum of asleep-stage durations (minutes). Excludes AWAKE / OUT_OF_BED / UNKNOWN. */
    private fun asleepMinutes(r: SleepSessionRecord): Double {
        if (r.stages.isEmpty()) return 0.0
        var min = 0.0
        for (stage in r.stages) {
            if (stage.stage in ASLEEP_STAGES) {
                min += (stage.endTime.epochSecond - stage.startTime.epochSecond) / 60.0
            }
        }
        return min
    }

    /** Build the `[{stage,min},...]` stagesJSON (same shape as the WHOOP CSV / Xiaomi importers) from a
     *  Health Connect sleep session's per-stage segments (#983). Returns null when the session carries no
     *  sub-stage breakdown (e.g. a generic STAGE_TYPE_SLEEPING-only record), so the night rides on its
     *  total minutes alone. */
    private fun hcStagesJson(r: SleepSessionRecord): String? {
        if (r.stages.isEmpty()) return null
        var light = 0.0; var deep = 0.0; var rem = 0.0; var awake = 0.0
        for (s in r.stages) {
            val min = (s.endTime.epochSecond - s.startTime.epochSecond) / 60.0
            when (s.stage) {
                SleepSessionRecord.STAGE_TYPE_LIGHT -> light += min
                SleepSessionRecord.STAGE_TYPE_DEEP -> deep += min
                SleepSessionRecord.STAGE_TYPE_REM -> rem += min
                SleepSessionRecord.STAGE_TYPE_AWAKE -> awake += min
                else -> {}   // SLEEPING (generic) / UNKNOWN: counted in totalSleepMin, no sub-stage split
            }
        }
        if (light == 0.0 && deep == 0.0 && rem == 0.0 && awake == 0.0) return null
        val arr = org.json.JSONArray()
        fun seg(stage: String, min: Double) {
            if (min > 0.0) arr.put(org.json.JSONObject().put("stage", stage).put("min", min))
        }
        seg("light", light); seg("deep", deep); seg("rem", rem); seg("awake", awake)
        return if (arr.length() == 0) null else arr.toString()
    }

    /** SleepSessionRecord stage ints that count as "asleep". */
    private val ASLEEP_STAGES: Set<Int> = setOf(
        SleepSessionRecord.STAGE_TYPE_LIGHT,
        SleepSessionRecord.STAGE_TYPE_DEEP,
        SleepSessionRecord.STAGE_TYPE_REM,
        SleepSessionRecord.STAGE_TYPE_SLEEPING, // generic "asleep" with no sub-stage
    )

    /**
     * #528 — true when a record's origin is NOOP itself, so [readAll] skips it on import. Without this,
     * turning on "share back" makes a later import re-read NOOP's own daily totals and SUM them on top
     * of the original source records (cumulative steps / active energy / sleep would ~double). HC's
     * `dataOriginFilter` is include-only, so the exclusion has to be a code-level package check here.
     * Empty [selfPackage] (origin undeterminable) never skips, so we err toward keeping data.
     */
    internal fun isSelfWritten(originPackage: String, selfPackage: String): Boolean =
        selfPackage.isNotEmpty() && originPackage == selfPackage

    /**
     * #1002: which local civil day a record belongs to, keyed by the offset the record was RECORDED
     * in rather than the phone's zone at import time.
     *
     * What this does NOT fix, because it was never broken: DST. [zone] is a REGION id
     * (`ZoneId.systemDefault()` returns e.g. `Europe/London`, not a fixed `+01:00`), and
     * `LocalDate.ofInstant` applies that region's rules AT THE GIVEN INSTANT — so a January instant
     * is already keyed with the January offset even when the import runs in July. Pinning a fixed
     * current offset is what would break DST, and the importer never did that.
     *
     * What it does fix is travel and relocation: a record written at 01:30 in Tokyo is the 16th to
     * the person who made it, but a phone now set to `Europe/London` resolves the same instant to
     * the 15th. `WINDOW_YEARS` is 10, so one import keys a decade of history that way, and importing
     * again after moving re-keys the same records differently — which surfaces as a doubled day
     * beside a gap rather than as an obviously wrong timestamp.
     *
     * [offset] is nullable because Health Connect's `startZoneOffset` / `zoneOffset` are optional and
     * plenty of writers leave them null; the phone's zone stays the fallback, so behaviour is
     * unchanged for every record that carries no offset. `ZoneOffset` is a `ZoneId`, so the two cases
     * differ only in which rules resolve the instant.
     */
    internal fun localDayKey(instant: Instant, offset: ZoneOffset?, zone: ZoneId): String =
        LocalDate.ofInstant(instant, offset ?: zone).toString()

    /**
     * #589 de-overlap for a per-source step map: SUM is already folded WITHIN each source by the read
     * lambda, so the day total is the MAX source (a phone AND a watch both report the same walk, so the
     * cross-source SUM would ~double-count). An empty map (no sources that day) yields 0. Factored out
     * (and internal) so the de-overlap semantics can be unit-tested without a HealthConnectClient,
     * mirroring the iOS/macOS `stepsBySource.values.max()` and the Android XML importer's `maxOrNull()`.
     */
    internal fun maxSourceLong(bySource: Map<String, Long>): Long = bySource.values.maxOrNull() ?: 0L

    /** One Health Connect energy record's window + value, tagged with the writing app so the
     *  per-workout credit can de-overlap across sources the way the day totals do (#589, #835). */
    internal data class KcalRecord(
        val startS: Long,
        val endS: Long,
        val kcal: Double,
        val source: String,
    )

    /** #589 de-overlap for a per-source calorie map (Double twin of [maxSourceLong]); empty -> 0.0. */
    internal fun maxSourceDouble(bySource: Map<String, Double>): Double = bySource.values.maxOrNull() ?: 0.0

    /**
     * #951 — the BMI value the importer stores for a day, DERIVED from the day's weight + the user's
     * profile height (Health Connect has no BMI record, unlike Apple Health). Returns null — so no
     * "bmi" metricSeries point is written — when there's no weight that day or no usable profile
     * height (heightCm <= 0), so a missing height never fabricates a value. Uses the same
     * [FitnessAgeEngine.bmi] the calorie / fitness-age estimates use, rounded to two places like the
     * other body-composition series. Factored out (and internal) so the derive-or-skip contract can be
     * unit-tested without a HealthConnectClient.
     */
    internal fun derivedBmi(weightKg: Double?, heightCm: Double): Double? {
        if (heightCm <= 0.0) return null
        val w = weightKg ?: return null
        return round2(FitnessAgeEngine.bmi(w, heightCm))
    }

    /**
     * Derive basal kcal = total - active when both are present and positive; else null.
     * Takes the already de-overlapped per-day totals (#589 max-across-sources), not the raw [DayAcc],
     * so basal is computed from the same source-deduplicated totals the row writes for active.
     */
    private fun basalKcal(totalKcal: Double, activeKcal: Double): Double? {
        if (totalKcal <= 0.0) return null
        val basal = totalKcal - activeKcal
        return if (basal > 0.0) round1(basal) else null
    }

    /**
     * A start-sorted view of a kcal record list, so a per-workout window query can RANGE-scan instead of
     * walking the whole list (#835 follow-up).
     *
     * The post-pass calls [sumKcalInWindow] twice per workout, and each call scanned every record in the
     * import window. `WINDOW_YEARS` is 10 and providers write these in ~15-minute buckets, so each list
     * runs to hundreds of thousands of rows: the shape is O(workouts x records), which the original
     * comment flagged as "fine at realistic sizes; if a multi-year import ever makes it hurt, sort both
     * lists by start and range-scan". This is that.
     *
     * Correctness rests on one bound: a record overlaps `[startS, endS)` only if it STARTS before `endS`
     * and ENDS after `startS`. Sorted by start, the first is a binary search. The second needs a floor,
     * and [maxLenS] supplies it — no record can reach further back than the longest one in the list. The
     * resulting slice is therefore a SUPERSET of the overlapping records, never a subset.
     *
     * It then hands that slice to [sumKcalInWindow] unchanged, so the per-source max, the partial-overlap
     * proration and the empty/null behaviour are the same code, not a reimplementation of it. The window
     * arithmetic that decides a calorie figure is not worth duplicating for speed.
     */
    internal class KcalIndex(private val records: List<KcalRecord>) {
        // NOTE: these three properties initialise in DECLARATION order and each reads the one above —
        // maxLenS feeds usable, usable gates order. Reordering them would silently yield 0/false/empty
        // rather than a compile error.
        private val maxLenS: Long = records.maxOfOrNull { it.endS - it.startS } ?: 0L

        /**
         * Whether narrowing can narrow anything, decided ONCE here rather than per query.
         *
         * The lower bound reaches back by [maxLenS], so a single record spanning a large share of the
         * corpus — a weekly or lifetime aggregate row, which providers do write — makes every slice the
         * whole list. Sorting that per query is worse than the scan this replaces. When the longest
         * record is not comfortably shorter than the whole span, the index simply is not built and
         * every query goes straight to the original scan, so this can never cost more than it saves.
         * A per-DAY coarse record, the common case the workoutKcal note describes, passes this easily.
         */
        private val usable: Boolean = run {
            if (records.size < 2 || maxLenS <= 0L) return@run false
            val span = (records.maxOf { it.endS }) - (records.minOf { it.startS })
            span > 0L && maxLenS * 20L < span
        }

        /**
         * Record indices ordered by start time. An `IntArray` rather than a sorted list of records or of
         * `IndexedValue` wrappers: this runs on a phone mid-import over hundreds of thousands of rows,
         * and the wrapper form allocates one object per record — megabytes of garbage to answer a few
         * hundred queries. The indices double as the original ordering [sumInWindow] restores.
         *
         * Empty, and never sorted, when [usable] is false.
         */
        private val order: IntArray =
            if (usable) {
                IntArray(records.size) { it }.also { a ->
                    // This DOES box, once, to get a comparator sort: what the IntArray buys is the
                    // RETAINED footprint — the boxes and the temporary list are collectable the moment
                    // this returns, whereas a sorted List<IndexedValue> would be held for the whole
                    // import. A primitive sort-by-key would avoid the boxing too, but packing a start
                    // time and an index into one Long assumes both stay inside 32 bits, and a
                    // pre-1970 timestamp would break it silently. Not worth that for a one-off sort.
                    val sortedIdx = a.toTypedArray().sortedBy { records[it].startS }
                    for (i in sortedIdx.indices) a[i] = sortedIdx[i]
                }
            } else {
                IntArray(0)
            }

        /** First index whose `startS >= value`; `size` when none. Plain lower-bound bisection. */
        private fun lowerBound(value: Long): Int {
            var lo = 0
            var hi = order.size
            while (lo < hi) {
                val mid = (lo + hi) ushr 1
                if (records[order[mid]].startS < value) lo = mid + 1 else hi = mid
            }
            return lo
        }

        /**
         * Bit-identical to `sumKcalInWindow(allRecords, startS, endS)`, over a narrowed slice.
         *
         * The slice is restored to the ORIGINAL record order before delegating, which is not
         * fussiness: `sumKcalInWindow` accumulates each source with `+`, and floating-point addition
         * is not associative, so summing the same records start-sorted rather than as-read moves the
         * result by an ULP or two. Measured on an adversarial corpus, 104 of 595 windows differed by
         * up to 1.8e-15 before this line existed. `round1` downstream would have absorbed all of it,
         * but "same numbers as the scan" is a claim worth being literally true rather than nearly
         * true — the slice is a handful of records, so re-ordering it costs nothing next to the
         * hundreds of thousands of rows this avoids walking.
         */
        fun sumInWindow(startS: Long, endS: Long): Double? {
            if (endS <= startS) return null
            if (!usable) return sumKcalInWindow(records, startS, endS)
            val lo = lowerBound(startS - maxLenS)
            val hi = lowerBound(endS)
            if (hi <= lo) return null
            // Second guard, for a WIDE window rather than a long record: a slice that is most of the
            // list is cheaper to walk than to sort. Either branch ends in the same sumKcalInWindow over
            // the same records, so the answer is identical and only the route changes.
            if ((hi - lo) * 20 > records.size) return sumKcalInWindow(records, startS, endS)
            // Sorting the indices ascending IS restoring the original order — they are positions in
            // `records`. See the note above on why that matters for the arithmetic.
            val slice = order.copyOfRange(lo, hi).sorted().map { records[it] }
            return sumKcalInWindow(slice, startS, endS)
        }
    }

    /**
     * Active-calorie kcal attributable to an exercise session: for every active-calorie record that
     * overlaps [startS, endS], credit the kcal in proportion to the overlap fraction. Time-weighting
     * (not a flat overlap test) means a per-minute record fully inside the session counts in full,
     * while a day-spanning total record only contributes the session's slice — so neither under- nor
     * grossly over-credits. Returns null when nothing overlaps, so an energy-less session stays blank
     * rather than showing 0. (#117)
     */
    internal fun sumKcalInWindow(
        records: List<KcalRecord>,
        startS: Long,
        endS: Long,
    ): Double? {
        if (endS <= startS) return null
        // #835: sum WITHIN a source, then take the MAX source — never a cross-source sum. A phone and a
        // watch both writing ActiveCaloriesBurned over the same ride used to be ADDED together, roughly
        // doubling the session. The day totals already de-overlap this way (#589); the per-workout credit
        // did not, despite the comment at the read site claiming it did.
        val bySource = HashMap<String, Double>()
        for (r in records) {
            val overlap = minOf(endS, r.endS) - maxOf(startS, r.startS)
            if (overlap <= 0L) continue
            val recLen = (r.endS - r.startS).coerceAtLeast(1L)
            bySource[r.source] =
                (bySource[r.source] ?: 0.0) + r.kcal * (overlap.toDouble() / recLen.toDouble())
        }
        return bySource.values.maxOrNull()?.takeIf { it > 0.0 }
    }

    /**
     * Index-backed twin of [workoutKcal] for the per-workout post-pass (#835 follow-up). Same
     * arithmetic — it differs only in how the two windows are gathered. The list-taking overload below
     * stays as the reference the unit tests pin.
     */
    internal fun workoutKcal(
        activeIndex: KcalIndex,
        totalIndex: KcalIndex,
        dayBasalKcal: Double?,
        startS: Long,
        endS: Long,
    ): Double? {
        if (endS <= startS) return null
        val fromActive = activeIndex.sumInWindow(startS, endS)
        val totalInWindow = totalIndex.sumInWindow(startS, endS)
        val fromTotal = if (totalInWindow != null && dayBasalKcal != null) {
            val basalShare = dayBasalKcal * ((endS - startS).toDouble() / 86_400.0)
            (totalInWindow - basalShare).takeIf { it > 0.0 }
        } else {
            totalInWindow
        }
        return listOfNotNull(fromActive, fromTotal).maxOrNull()?.takeIf { it > 0.0 }
    }

    /**
     * #835 — a workout's active kcal, taking the BEST of the two energy streams Health Connect exposes
     * rather than only `ActiveCaloriesBurned`.
     *
     * Two ways the Active-only credit came out too low:
     *  - the session's source writes `TotalCaloriesBurned` and no Active at all, so the workout was
     *    credited only with whatever unrelated background Active happened to overlap it;
     *  - the only Active cover is a COARSE record (one per day is common), and prorating it by time
     *    assumes calories burn uniformly — a hard hour inside a 24 h record reads as 1/24 of the day.
     *
     * So also derive a candidate from Total: prorated Total over the window, minus the window's share of
     * the day's basal burn ([dayBasalKcal] spread evenly over 24 h — basal genuinely IS near-uniform, so
     * prorating THAT is sound in a way prorating a workout's active burn is not). Take whichever estimate
     * is larger: a stray background record is small, real session coverage is not, so the max picks the
     * stream that actually resolves this session without needing a threshold. Where both streams cover it
     * properly they agree, and the max is a no-op.
     *
     * Returns null when neither stream yields anything positive — no fabricated number.
     */
    internal fun workoutKcal(
        activeRecords: List<KcalRecord>,
        totalRecords: List<KcalRecord>,
        dayBasalKcal: Double?,
        startS: Long,
        endS: Long,
    ): Double? {
        if (endS <= startS) return null
        val fromActive = sumKcalInWindow(activeRecords, startS, endS)
        val totalInWindow = sumKcalInWindow(totalRecords, startS, endS)
        val fromTotal = if (totalInWindow != null && dayBasalKcal != null) {
            val basalShare = dayBasalKcal * ((endS - startS).toDouble() / 86_400.0)
            (totalInWindow - basalShare).takeIf { it > 0.0 }
        } else {
            totalInWindow
        }
        return listOfNotNull(fromActive, fromTotal).maxOrNull()?.takeIf { it > 0.0 }
    }

    /**
     * A short, human sport name for a Health Connect exercise session. Uses the user's title
     * if present, else maps the EXERCISE_TYPE_* int to a readable label, else "Workout".
     */
    private fun exerciseName(r: ExerciseSessionRecord): String {
        val title = r.title?.trim()
        if (!title.isNullOrEmpty()) return title
        return EXERCISE_TYPE_NAMES[r.exerciseType] ?: "Workout"
    }

    /**
     * Map of common ExerciseSessionRecord.EXERCISE_TYPE_* constants to readable labels. We reference the
     * library constants directly rather than hardcoding ints — the old hardcoded values were WRONG (e.g.
     * 79 was mapped to "Swimming" but 79 is actually WALKING, so a walking session showed as swimming —
     * issue #53; 80 was "Swimming" but is WATER_POLO; 82 was "Walking" but is WHEELCHAIR; etc.). Using
     * the constants makes the int↔label mapping impossible to get wrong, and a renamed/removed constant
     * becomes a compile error instead of a silent mismatch. Unknown types fall back to "Workout".
     */
    private val EXERCISE_TYPE_NAMES: Map<Int, String> = mapOf(
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING to "Running",
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL to "Running",
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING to "Cycling",
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY to "Cycling",
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "Swimming",
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL to "Swimming",
        ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING to "Strength",
        ExerciseSessionRecord.EXERCISE_TYPE_WALKING to "Walking",
        ExerciseSessionRecord.EXERCISE_TYPE_HIKING to "Hiking",
        ExerciseSessionRecord.EXERCISE_TYPE_YOGA to "Yoga",
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING to "Rowing",
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE to "Rowing",
        ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING to "HIIT",
        ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL to "Elliptical",
        ExerciseSessionRecord.EXERCISE_TYPE_PILATES to "Pilates",
        ExerciseSessionRecord.EXERCISE_TYPE_BOXING to "Boxing",
        ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON to "Badminton",
        ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL to "Baseball",
        ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL to "Basketball",
        ExerciseSessionRecord.EXERCISE_TYPE_SOCCER to "Soccer",
        ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING to "Weightlifting",
        // Racket / team / misc sports that were missing from the map (found via a volleyball session
        // that imported as a generic "Workout"): an untitled session of any type below used to lose
        // its sport identity even though the record itself imported fine.
        ExerciseSessionRecord.EXERCISE_TYPE_VOLLEYBALL to "Volleyball",
        ExerciseSessionRecord.EXERCISE_TYPE_TENNIS to "Tennis",
        ExerciseSessionRecord.EXERCISE_TYPE_TABLE_TENNIS to "Table Tennis",
        ExerciseSessionRecord.EXERCISE_TYPE_SQUASH to "Squash",
        ExerciseSessionRecord.EXERCISE_TYPE_RACQUETBALL to "Racquetball",
        ExerciseSessionRecord.EXERCISE_TYPE_HANDBALL to "Handball",
        ExerciseSessionRecord.EXERCISE_TYPE_ICE_HOCKEY to "Ice Hockey",
        ExerciseSessionRecord.EXERCISE_TYPE_ROLLER_HOCKEY to "Roller Hockey",
        ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AMERICAN to "Football",
        ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AUSTRALIAN to "Football",
        ExerciseSessionRecord.EXERCISE_TYPE_RUGBY to "Rugby",
        ExerciseSessionRecord.EXERCISE_TYPE_CRICKET to "Cricket",
        ExerciseSessionRecord.EXERCISE_TYPE_SOFTBALL to "Softball",
        ExerciseSessionRecord.EXERCISE_TYPE_WATER_POLO to "Water Polo",
        ExerciseSessionRecord.EXERCISE_TYPE_GOLF to "Golf",
        ExerciseSessionRecord.EXERCISE_TYPE_DANCING to "Dancing",
        ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS to "Martial Arts",
        ExerciseSessionRecord.EXERCISE_TYPE_FENCING to "Fencing",
        ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS to "Gymnastics",
        ExerciseSessionRecord.EXERCISE_TYPE_CALISTHENICS to "Calisthenics",
        ExerciseSessionRecord.EXERCISE_TYPE_STRETCHING to "Stretching",
        ExerciseSessionRecord.EXERCISE_TYPE_EXERCISE_CLASS to "Exercise Class",
        ExerciseSessionRecord.EXERCISE_TYPE_BOOT_CAMP to "Boot Camp",
        ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING to "Stair Climbing",
        ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING_MACHINE to "Stair Climbing",
        ExerciseSessionRecord.EXERCISE_TYPE_ROCK_CLIMBING to "Climbing",
        ExerciseSessionRecord.EXERCISE_TYPE_SKIING to "Skiing",
        ExerciseSessionRecord.EXERCISE_TYPE_SNOWBOARDING to "Snowboarding",
        ExerciseSessionRecord.EXERCISE_TYPE_SNOWSHOEING to "Snowshoeing",
        ExerciseSessionRecord.EXERCISE_TYPE_ICE_SKATING to "Skating",
        ExerciseSessionRecord.EXERCISE_TYPE_SKATING to "Skating",
        ExerciseSessionRecord.EXERCISE_TYPE_SURFING to "Surfing",
        ExerciseSessionRecord.EXERCISE_TYPE_PADDLING to "Paddling",
        ExerciseSessionRecord.EXERCISE_TYPE_SAILING to "Sailing",
        ExerciseSessionRecord.EXERCISE_TYPE_SCUBA_DIVING to "Diving",
        ExerciseSessionRecord.EXERCISE_TYPE_FRISBEE_DISC to "Frisbee",
    )

    private fun round1(x: Double) = round(x * 10.0) / 10.0
    private fun round2(x: Double) = round(x * 100.0) / 100.0

    /** Per-local-day accumulator. */
    private class DayAcc {
        // #589: per-SOURCE sums (keyed by dataOrigin.packageName), reduced by MAX across sources at
        // write-out so a phone+watch pair that both report the same steps/calories doesn't double-count.
        // Mirrors the iOS/macOS + Android-XML de-overlap (sum within a source, max across sources).
        val stepsBySource = HashMap<String, Long>()
        val totalKcalBySource = HashMap<String, Double>()
        val activeKcalBySource = HashMap<String, Double>()

        var hrSum: Long = 0L
        var hrCount: Int = 0

        var rhrSum: Long = 0L
        var rhrCount: Int = 0

        var hrvSum: Double = 0.0
        var hrvCount: Int = 0

        var sleepMin: Double = 0.0
        var hasSleep: Boolean = false

        var spo2Sum: Double = 0.0
        var spo2Count: Int = 0

        var respSum: Double = 0.0
        var respCount: Int = 0

        var vo2max: Double? = null
        var vo2maxTs: Long = Long.MIN_VALUE

        var weightKg: Double? = null
        var weightTs: Long = Long.MIN_VALUE

        var bodyFatPct: Double? = null
        var bodyFatTs: Long = Long.MIN_VALUE
        var leanMassKg: Double? = null
        var leanMassTs: Long = Long.MIN_VALUE

        var exerciseCount: Int = 0
    }
}
