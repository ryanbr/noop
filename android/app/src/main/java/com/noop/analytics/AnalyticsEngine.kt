package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.EventRow
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.StepSample
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/*
 * AnalyticsEngine.kt — orchestrator producing DailyMetric + sleep-session results.
 *
 * Faithful Kotlin port of StrandAnalytics/AnalyticsEngine.swift (verified on macOS).
 * Same algorithm, same constants, same thresholds; Kotlin-ized types, Double math.
 *
 * Given a day's raw streams + a user profile + personal baselines, it runs the
 * individual analyzers (SleepStager / RecoveryScorer / StrainScorer / WorkoutDetector
 * / Baselines) and assembles a [com.noop.data.DailyMetric] (Room cache shape) plus the
 * detected [DetectedSleep] sessions.
 *
 * This is a PURE function over its inputs — it does NOT touch the database
 * (persistence is wired by IntelligenceEngine). All derived values are APPROXIMATE.
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long); the Swift source
 * uses Int seconds.
 */
object AnalyticsEngine {

    /**
     * Pair the strap's WRIST_OFF/WRIST_ON events into off-wrist [start, end) intervals for the sleep
     * detector's fractional wear filter (#500; design credited to j0b-dev's #504). Each WRIST_OFF opens
     * an interval that closes at the next WRIST_ON, or at [windowEnd] if the strap is still off at the
     * end of the read window. Events need not be pre-sorted; kinds are formatted "NAME(n)" (e.g.
     * "WRIST_OFF(10)"), matched by prefix. Repeated OFFs/ONs without a partner are coalesced. Mirrors Swift.
     */
    fun offWristIntervals(events: List<EventRow>, windowEnd: Long): List<Pair<Long, Long>> {
        val wear = events
            .filter { it.kind.startsWith("WRIST_OFF") || it.kind.startsWith("WRIST_ON") }
            .sortedBy { it.ts }
        val intervals = ArrayList<Pair<Long, Long>>()
        var offStart: Long? = null
        for (e in wear) {
            if (e.kind.startsWith("WRIST_OFF")) {
                if (offStart == null) offStart = e.ts            // ignore repeated OFFs
            } else {                                             // WRIST_ON closes an open off-wrist span
                val s = offStart
                if (s != null && e.ts > s) intervals.add(s to e.ts)
                offStart = null
            }
        }
        val s = offStart
        if (s != null && windowEnd > s) intervals.add(s to windowEnd)
        return intervals
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Day-string helper (UTC YYYY-MM-DD), mirrors Swift AnalyticsEngine.isoDay.
    // ─────────────────────────────────────────────────────────────────────────

    private val isoDay: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)

    /** Format a unix-seconds timestamp as a UTC YYYY-MM-DD day string. */
    fun dayString(ts: Long): String = isoDay.format(Instant.ofEpochSecond(ts))

    /**
     * Format a unix-seconds timestamp as the device's LOCAL YYYY-MM-DD day string (#277).
     *
     * The day key is the core aggregation key for daily metrics; the dashboard reads "today" by the
     * device's LOCAL calendar day, so the bucket must be the LOCAL day too. A west-of-UTC user's
     * evening (which crosses midnight UTC) would otherwise flow into the next UTC bucket and the local
     * "today" read would never find it — freezing the dashboard (Toronto/UTC-4 report). [offsetSec] is
     * seconds EAST of UTC (TimeZone.getDefault().getOffset(...)/1000). The local date is the UTC date
     * of `(ts + offsetSec)`: shifting the instant by the offset turns the fixed-UTC formatter into a
     * local-calendar formatter. [offsetSec] == 0 is byte-identical to the UTC [dayString] above, so
     * pure-function callers/tests on UTC are unchanged.
     */
    fun dayString(ts: Long, offsetSec: Long): String = dayString(ts + offsetSec)

    /**
     * JSON-encode stage segments to the verbatim array shape the sleepSession cache
     * stores. Mirrors Swift `encodeStages` (JSONEncoder on [StageSegment]); the field
     * names (start, end, stage) match the Codable wire shape and the Android
     * SleepScreen reader (decoders are key-order-independent, so the reader is unaffected).
     *
     * DETERMINISM (parity with Swift's `.sortedKeys`): the object keys are emitted in a FIXED
     * alphabetical order — `end`, `stage`, `start` — built by hand rather than via
     * `JSONObject.put` order. `org.json.JSONObject` (both the stock Android runtime impl and the
     * `org.json:json` JVM test jar) backs its key store with a plain `HashMap`, so `toString()`
     * emits keys in hash-iteration order, which is NOT insertion order and is not guaranteed stable
     * across runtimes/versions. The post-sync self-heal ([SleepStageHealer.selfHealEditedStages])
     * skips its write when the re-derived JSON equals the stored JSON; an unstable key order would
     * defeat that equality check (spurious rewrites, or a Robolectric-vs-device mismatch). Sorting
     * the keys makes a re-derive over identical bounds+raw byte-identical to what was stored.
     * Values are escaped via [JSONObject.quote] (the stage string is constrained, but stay safe).
     */
    fun encodeStages(stages: List<StageSegment>): String? {
        return try {
            val sb = StringBuilder()
            sb.append('[')
            for ((i, s) in stages.withIndex()) {
                if (i > 0) sb.append(',')
                // Keys alphabetical: end, stage, start — matches Swift JSONEncoder.outputFormatting
                // = .sortedKeys on StageSegment{start,end,stage}.
                sb.append("{\"end\":").append(s.end)
                    .append(",\"stage\":").append(JSONObject.quote(s.stage))
                    .append(",\"start\":").append(s.start)
                    .append('}')
            }
            sb.append(']')
            sb.toString()
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Analyze one day's streams into a [DayResult].
     *
     * @param day the calendar day (UTC) this metric is for; a sleep session is
     *   attributed to the day its `end` falls on (a night ending that morning).
     * @param hr/rr/resp/gravity the day's raw streams (the wider window around the
     *   night may be passed; sleep detection finds the in-bed span itself).
     * @param profile user profile (age/sex/weight/height) for HRmax + calories.
     * @param baselines personal baselines for recovery normalization.
     * @param maxHROverride explicit HRmax (bpm) to use for strain/zones; null →
     *   Tanaka from profile.age.
     */
    fun analyzeDay(
        day: String,
        hr: List<HrSample> = emptyList(),
        rr: List<RrInterval> = emptyList(),
        resp: List<RespSample> = emptyList(),
        gravity: List<GravitySample> = emptyList(),
        steps: List<StepSample> = emptyList(),
        // Calendar-day-scoped overrides for the ADDITIVE daily totals (steps + activeKcalEst) AND
        // workout detection + strain. When null, each falls back to the same night window the rest of
        // the analysis uses (preserving the pure-function contract). The caller (IntelligenceEngine)
        // supplies a full [localMidnight(day), localMidnight(day)+86400) read here so a day's late
        // hours — which fall outside the ~42h night window (it ends at dayStart+12h ≈ noon) — are still
        // seen. dayHr/daySteps drive the additive step + calorie totals; dayHr/dayGravity ALSO feed
        // WorkoutDetector so an afternoon/evening workout is detected on its OWN calendar day instead of
        // lagging to the next pass; dayHr ALSO drives strain ("Effort") so the day's load reflects the
        // WHOLE calendar day, not midnight→noon (+ the night window's −30h prior-evening bleed). A
        // workout straddling local midnight splits at the day boundary (same tradeoff as the totals).
        // Sleep / recovery keep using hr/rr/resp/gravity — staging needs the pre-midnight night span.
        dayHr: List<HrSample>? = null,
        daySteps: List<StepSample>? = null,
        dayGravity: List<GravitySample>? = null,
        // Wear-gated nightly skin-temp mean is harvested here (baseline-independent); IntelligenceEngine
        // seeds a personal baseline from these means across nights and re-derives skinTempDevC in pass 2
        // (same two-pass shape as avgHrv→recovery). (PR #85)
        skinTemp: List<SkinTempSample> = emptyList(),
        profile: UserProfile,
        baselines: ProfileBaselines = ProfileBaselines(),
        maxHROverride: Double? = null,
        // Wall-clock UTC offset (seconds) for the sleep detector's daytime false-sleep guard (#90).
        // Default 0 keeps pure-function callers/tests on UTC; IntelligenceEngine passes the device's
        // real offset.
        tzOffsetSeconds: Long = 0L,
        // Off-wrist [start, end) intervals (unix seconds) for the off-wrist sleep backstop (#500),
        // paired from WRIST_OFF/WRIST_ON events by [offWristIntervals]. The HR-gap proxy in detectSleep
        // is the always-on guard; these explicit intervals sharpen it under the FRACTIONAL rule (#504) —
        // a session is dropped only when its off-wrist coverage reaches maxOffWristSleepFraction. Default
        // empty keeps pure-function callers/tests event-free; IntelligenceEngine passes the night window's intervals.
        wristOff: List<Pair<Long, Long>> = emptyList(),
        // Personal sleep need (hours) for the Rest "duration vs need" component. null → 8 h default.
        // IntelligenceEngine refines it from the user's recent average asleep hours. (Charge/Effort/Rest)
        sleepNeedHours: Double? = null,
        // How many recent nights informed [sleepNeedHours] (0 = still on the 8 h default). Drives the
        // Rest confidence tier ONLY; does not affect the score. (Charge/Effort/Rest)
        sleepNeedNights: Int = 0,
        // Sleep/wake regularity in [0,1] (1 = perfectly regular) for the Rest "consistency" component.
        // null (single-day / pure callers with no history) → the term drops and its weight
        // renormalizes, exactly like the recovery driver-drop discipline. (Charge/Effort/Rest)
        sleepConsistency: Double? = null,
        // The user's learned habitual midsleep (local time-of-day seconds in [0, 86400)) for the
        // main-night scored pick, so a late/shift sleeper's real night out-scores a daytime nap. null =
        // cold-start: the selector falls back to the broad overnight-band bonus. IntelligenceEngine
        // computes this once per run from the trailing sleep history and threads it down; pure-function
        // callers/tests leave it null and stay on the cold-start band. Mirrors Swift. (#547)
        habitualMidsleepSec: Long? = null,
        // The strap's OWN persisted v18 BAND sleep_state per timestamp (Interpreter's `(sb shr 4) and 3`:
        // 0 wake/1 still/2 asleep/3 up). Consumed ONLY to confirm a borderline H7 morning re-onset — a
        // daytime block the strap itself scored "asleep" is kept even on a borderline HR dip (#531). Default
        // empty keeps pure-function callers/tests free of it; IntelligenceEngine threads the night window's
        // persisted band state. Mirrors Swift. (#531 / H8 consume)
        bandSleepState: List<Pair<Long, Int>> = emptyList(),
        // Opt-in experimental sleep staging (V2). When true, detected nights are staged by [SleepStagerV2]
        // instead of V1. Default false keeps V1 the byte-identical default for pure-function callers/tests;
        // IntelligenceEngine threads PuffinExperiment.from(context).experimentalSleepV2. Mirrors Swift. (V7 / #690)
        useSleepStagerV2: Boolean = false,
    ): DayResult {

        // ── Sleep detection + staging ─────────────────────────────────────────
        val allSessions = SleepStager.detectSleep(
            hr = hr, rr = rr, resp = resp, gravity = gravity, tzOffsetSeconds = tzOffsetSeconds,
            wristOff = wristOff, bandSleepState = bandSleepState,
            useSleepStagerV2 = useSleepStagerV2,
        )
        // Sessions attributed to `day` = those whose end falls on `day` (LOCAL day, #277). `day` is
        // the caller's local-day key; attribute by the same offset so the bucket and the key agree.
        val matched = allSessions.filter { dayString(it.end, tzOffsetSeconds) == day }

        // ── The day's MAIN night (#525) ───────────────────────────────────────
        // A day can hold an overnight AND a daytime nap (both end on `day`, so both are in `matched`).
        // The sleep-DURATION figures (total sleep / stage minutes / efficiency / disturbances, hence the
        // Rest composite, the debt ledger, and the dashboard card) describe the MAIN night — the SAME
        // block the Sleep tab's hero shows (longest, preferring an overnight-anchored onset). They must
        // NOT silently sum the nap in, or the "your night" number disagrees across screens (the #525
        // report). Naps stay their OWN session rows in `sleepSessions`, where the Sleep tab lists and
        // labels them separately. [SleepStageTotals.mainNightIndex] is the single shared selector so the
        // analytics rollup and the Sleep tab resolve to the identical block.
        // Pick by the LEARNED-TIMING score, threading the user's learned habitual midsleep so a
        // late/shift sleeper's real night out-scores a daytime nap (null = cold-start overnight band).
        // BIPHASIC GAP-BRIDGE (#561): a main sleep briefly interrupted by a short wake (a fragment the
        // detector left split because the wake gap was longer than its sparse-gravity bridge, or a true
        // biphasic night) is scored as ONE night via [SleepStageTotals.mainNightGroupIndices]: it bridges
        // adjacent blocks whose gap is < `gapBridgeMaxMin`, scores the bridged span, and returns ALL the
        // fragments in the winning group. The AASM aggregate below then SUMS the group's stages — in-bed is
        // the SUM of each fragment's own in-bed span (the inter-fragment wake gap is NOT part of any fragment,
        // so it is excluded and we do NOT invent WASO for it). A day with no bridgeable gap collapses to the
        // single block the bare [mainNightIndex] would pick. Intelligence / the Ledger / the Sleep tab all
        // read this SAME group, so #525 does not regress. Mirrors Swift. (#525 / #561)
        val mainGroupIdx = SleepStageTotals.mainNightGroupIndices(
            matched.map { SleepStageTotals.NightBlock(it.start, it.end) },
            tzOffsetSeconds, habitualMidsleepSec,
        ) ?: emptyList()
        val mainGroup: List<DetectedSleep> = mainGroupIdx.map { matched[it] }

        // ── Daily sleep aggregates (AASM) SUMMED over the main-night GROUP (#525 / #561) ──
        var deepS = 0.0
        var remS = 0.0
        var lightS = 0.0
        var tstS = 0.0
        var inBedS = 0.0
        var effWeighted = 0.0
        var disturbances = 0
        for (s in mainGroup) {
            val m = SleepStager.hypnogramMetrics(s)
            val inBed = (s.end - s.start).toDouble()
            inBedS += inBed                       // SUM each fragment's in-bed span
            effWeighted += s.efficiency * inBed   // in-bed-weighted efficiency across the group
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        // (#777) Count the out-of-bed time BETWEEN bridged fragments as awake in-bed: the sleeper was up
        // (e.g. a 20-min walk) but it's one night, so the gap is WASO. Adding it to in-bed (not to asleep)
        // raises awake (= in-bed − asleep) and lowers efficiency, instead of vanishing the time entirely.
        val gapWakeS = SleepStageTotals.interFragmentWakeSeconds(mainGroup.map { it.start to it.end }).toDouble()
        inBedS += gapWakeS
        val efficiency = if (inBedS > 0) effWeighted / inBedS else 0.0

        // #525 NOTE: the sleep-DURATION figures above are main-night-only (the headline "your night"),
        // but the physiological aggregates below (resting HR, HRV, respiration) intentionally stay over
        // ALL matched sessions. This is deliberate, not an oversight: recovery should reflect the body's
        // best resting physiology for the day, the main overnight dominates these anyway (it is far longer
        // than any nap and HRV is in-bed-weighted by duration), and narrowing them to the main night would
        // widen the change's blast radius into the recovery score right at a release boundary for a
        // negligible shift. The Rest/sleep-quality term is main-night; the recovery physiology is
        // day-best-resting, night-dominated. Mirrors the Swift note in AnalyticsEngine.swift.
        // Daily resting HR = lowest per-session resting HR across matched sessions.
        val restingHRDaily: Int? = matched.mapNotNull { it.restingHR }.minOrNull()
        // Daily avg HRV = in-bed-weighted mean of per-session avg HRV.
        val avgHRVDaily: Double? = run {
            val pairs = matched.mapNotNull { s ->
                s.avgHRV?.let { it to (s.end - s.start).toDouble() }
            }
            if (pairs.isEmpty()) {
                null
            } else {
                val total = pairs.sumOf { it.first * it.second }
                val weight = pairs.sumOf { it.second }
                if (weight > 0) total / weight else null
            }
        }

        // Nightly APPROXIMATE respiratory rate (breaths/min) from the R-R stream via
        // RSA. WHOOP5 v18 carries no raw resp ADC, so this is an on-device estimate,
        // NOT a cloud/clinical respiration value. Per matched in-bed session, estimate
        // over [start, end]; the night's value = median of finite per-session
        // estimates; null only when no session yields a finite estimate.
        val respRateDaily: Double? = run {
            val perSession = matched
                .map { SleepStager.respRateFromRR(rr, it.start, it.end) }
                .filter { it.isFinite() }
            if (perSession.isEmpty()) null else HrvAnalyzer.median(perSession)
        }

        // sleepStart/sleepEnd available for callers wiring sleep_start/end columns.
        @Suppress("UNUSED_VARIABLE") val sleepStart = matched.minOfOrNull { it.start }
        @Suppress("UNUSED_VARIABLE") val sleepEnd = matched.maxOfOrNull { it.end }

        // ── Skin-temperature deviation (offline) ──────────────────────────────
        // Wear-gated in-bed mean (baseline-independent, harvested every pass) + the deviation against
        // the personal baseline. In pass 1 baselines.skinTemp is null so the deviation is null and the
        // mean is harvested; IntelligenceEngine seeds the baseline from those means and re-derives the
        // deviation in pass 2 (mirrors avgHrv→recovery). Computed BEFORE Charge so the Charge skin-temp
        // penalty can read it. APPROXIMATE. (PR #85)
        val nightlySkinTempC = wornNightlySkinTempC(matched, hr, skinTemp)
        val skinTempDevC: Double? = nightlySkinTempC?.let { v ->
            baselines.skinTemp?.takeIf { it.usable }?.let { round2(Baselines.deviation(v, it).delta) }
        }

        // ── Rest (sleep_performance composite, 0–100) ─────────────────────────
        // Replaces the bare efficiency proxy: duration-vs-personal-need 0.50 + efficiency 0.20 +
        // restorative (deep+REM)/asleep 0.20 + consistency 0.10. Stored under the sleep_performance
        // key. null when no in-bed session. (Charge/Effort/Rest)
        val rest: Double? = if (matched.isEmpty()) null else RestScorer.rest(
            asleepSeconds = tstS,
            efficiency = efficiency,
            deepSeconds = deepS,
            remSeconds = remS,
            sleepNeedHours = sleepNeedHours,
            consistency = sleepConsistency,
        )

        // ── Recovery / Charge ─────────────────────────────────────────────────
        var recovery: Double? = null
        val hrvVal = avgHRVDaily
        val rhrVal = restingHRDaily
        val hrvBase = baselines.hrv
        if (hrvVal != null && rhrVal != null && hrvBase != null) {
            // Charge "Rest quality" term reads the Rest composite ÷100 (0..1), not raw efficiency.
            val sleepPerf = rest?.let { it / 100.0 }
            recovery = RecoveryScorer.recovery(
                hrv = hrvVal,
                rhr = rhrVal.toDouble(),
                resp = respRateDaily, // term drops + renormalizes when null / no baseline
                hrvBaseline = hrvBase,
                rhrBaseline = baselines.restingHR,
                respBaseline = baselines.resp,
                sleepPerf = sleepPerf,
                skinTempDev = skinTempDevC, // symmetric penalty; term drops + renormalizes when null
            )
        }

        // ── Strain ("Effort") — cardiovascular load over the full CALENDAR day ──
        // Integrate dayHr ([localMidnight, +24h), clamped to now for today) when supplied so Effort
        // covers the WHOLE day — an afternoon/evening workout lands in today's Effort same-day instead
        // of being cut off at the night window's ≈ noon bound, and the prior evening's HR no longer
        // bleeds in. Falls back to the night hr for pure-function callers/tests.
        val effMaxHR: Double? = maxHROverride
            ?: if (profile.age > 0) StrainScorer.tanakaHRmax(profile.age) else null
        val restForStrain = restingHRDaily?.toDouble() ?: StrainScorer.defaultRestingHR
        val strain = StrainScorer.strain(
            hr = dayHr ?: hr,
            maxHR = effMaxHR,
            restingHR = restForStrain,
            sex = profile.sex,
        )

        // ── Workouts ──────────────────────────────────────────────────────────
        // Detect over the full CALENDAR day (dayHr/dayGravity) when supplied so a current-day
        // afternoon/evening workout is caught on its own day rather than lagging until a later pass
        // re-reads it through the next night window (which ends at ≈ noon). Falls back to the night
        // window for pure-function callers/tests.
        val workouts = WorkoutDetector.detect(
            hr = dayHr ?: hr,
            gravity = dayGravity ?: gravity,
            restingHR = restingHRDaily?.toDouble(),
            maxHR = maxHROverride,
            age = if (profile.age > 0) profile.age else null,
            profile = profile,
        )

        // ── Steps (APPROXIMATE) ───────────────────────────────────────────────
        // step_motion_counter@57 is a CUMULATIVE u16 running counter (it climbs while you move, holds
        // flat when still, and wraps at 65536). The daily total is the SUM of WRAP-AWARE increments of
        // that counter across the time-ordered 1 Hz records (already ts-ASC from the DAO): delta =
        // (cur - prev) and 0xFFFF. The first record has no predecessor (contributes 0). The day's read
        // window may include adjacent-day samples, so filter to the LOCAL-day key
        // dayString(ts, tzOffset)==day first (#277).
        //
        // Reading byte @57 ALONE and summing it (the old bug, #132/#276/#316: exzanimo saw ~24× too
        // many steps) both ignored the high byte and summed a running total — exploding the count to
        // ~10M/day. Decoding the full u16 and summing wrap-aware DELTAS yields a sane ~14k. ESTIMATE
        // only — not cloud/clinical parity.
        val stepsTotal: Int? = run {
            // Prefer the full-calendar-day stream for the additive total; fall back to the
            // night-window stream when the caller didn't supply one (pure-function callers/tests).
            val sorted = (daySteps ?: steps).filter { dayString(it.ts, tzOffsetSeconds) == day }.sortedBy { it.ts }
            if (sorted.size < 2) return@run null
            // A delta this large is a big time-gap / disconnect boundary between sync sessions (or a
            // firmware reboot, byte-indistinguishable from a wrap), NOT real steps — drop it so gaps
            // don't inflate the total. Real 1 Hz motion never ticks this fast between adjacent records.
            val maxStepDelta = 512
            var total = 0L
            for (i in 1 until sorted.size) {
                val delta = (sorted[i].counter - sorted[i - 1].counter) and 0xFFFF // wrap-aware u16 increment
                if (delta in 1 until maxStepDelta) total += delta // ignore a delta >= 512 (gap/reset)
            }
            if (total <= 0L) return@run null
            // @57 counts motion ticks, not validated steps — the 5/MG counter overcounts. Divide
            // by the user-calibrated ticks-per-step (default 1.0 = raw pass-through; floor 0.5 so
            // a bad pref can at most double, never explode, the total). (#139)
            val scaled = (total.toDouble() / max(profile.stepTicksPerStep, 0.5)).roundToLong()
                .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            if (scaled > 0) scaled else null
        }

        // ── Daily calories (APPROXIMATE, HR-only whole-day estimate) ──────────
        // Whole-day active+resting energy from the full HR window, using the same resting/active
        // per-second model the per-workout estimate uses (resting BMR below activeThreshold, Keytel
        // active above). effMaxHR + restingHRDaily are the same effective HRmax / resting baseline
        // strain uses. Null when there is no HR. A heart-rate ESTIMATE — not cloud/clinical parity.
        // Whole-day additive totals (steps above, calories here) are summed over the full LOCAL
        // calendar day supplied by the caller (dayHr / daySteps), NOT the ~42h sleep-detection
        // window — which, anchored to the current time-of-day, would drop a past day's late hours
        // and double-count seconds shared with adjacent days. The filter uses the LOCAL-day key
        // (dayString(ts, tzOffset)) so it agrees with the bucket (#277). Fall back to the
        // night-window hr for pure-function callers that don't supply dayHr. Strain keeps the full
        // window (bounded log).
        val dayHrFiltered = (dayHr ?: hr).filter { dayString(it.ts, tzOffsetSeconds) == day }
        val activeKcalEst: Double? = if (dayHrFiltered.isEmpty()) {
            null
        } else {
            Calories.estimateDayCalories(
                hrSamples = dayHrFiltered,
                profile = profile,
                hrmax = effMaxHR,
                restingHR = restingHRDaily?.toDouble(),
            )
        }

        // ── Assemble DailyMetric ──────────────────────────────────────────────
        // deviceId is stamped by the caller (IntelligenceEngine persists under
        // "<deviceId>-noop"); use the imported source id as a placeholder here so
        // the value type is complete. The caller copies with its computed id.
        val daily = DailyMetric(
            deviceId = "",
            day = day,
            totalSleepMin = if (matched.isEmpty()) null else tstS / 60.0,
            efficiency = if (matched.isEmpty()) null else efficiency,
            deepMin = if (matched.isEmpty()) null else deepS / 60.0,
            remMin = if (matched.isEmpty()) null else remS / 60.0,
            lightMin = if (matched.isEmpty()) null else lightS / 60.0,
            disturbances = if (matched.isEmpty()) null else disturbances,
            restingHr = restingHRDaily,
            avgHrv = avgHRVDaily,
            recovery = recovery,
            strain = strain,
            exerciseCount = workouts.size,
            spo2Pct = null,
            skinTempDevC = skinTempDevC,
            respRateBpm = respRateDaily,
            steps = stepsTotal,
            activeKcalEst = activeKcalEst,
        )

        // ── Per-score confidence tiers (mirror Swift ScoreConfidence.derive decisions) ──
        val chargeConfidence = ScoreConfidence.forCharge(recovery, baselines.hrv)
        val effortConfidence = ScoreConfidence.forEffort(strain, hr.size)
        // Rest confidence with H9: downgrade a high-efficiency night whose deep+REM share is implausibly low
        // to low-confidence (likely staging miss) — honest, no faked stages. tstS/efficiency are the
        // main-group totals computed above; restorative = deepS + remS. Mirrors Swift.
        val restConfidence = ScoreConfidence.forRest(
            hasSession = matched.isNotEmpty(),
            hasStagedSleep = (deepS + remS) > 0,
            asleepSeconds = tstS,
            restorativeSeconds = deepS + remS,
            efficiency = efficiency,
        )

        // ── Per-session per-epoch motion (H8) ─────────────────────────────────
        // The strap's per-epoch movement on the SAME 30 s grid as each session's stages, for the caller to
        // persist beside `stagesJSON`. A session that can't grid (too little gravity) is omitted, so the
        // caller persists NULL there rather than a fabricated zero series. Mirrors Swift.
        val sessionMotionByStart = HashMap<Long, List<Double>>()
        for (s in matched) {
            val motion = SleepStager.sessionEpochMotion(s.start, s.end, gravity)
            if (motion.isNotEmpty()) sessionMotionByStart[s.start] = motion
        }

        return DayResult(
            daily = daily,
            sleepSessions = matched,
            workouts = workouts,
            recovery = recovery,
            strain = strain,
            rest = rest,
            nightlySkinTempC = nightlySkinTempC,
            chargeConfidence = chargeConfidence,
            effortConfidence = effortConfidence,
            restConfidence = restConfidence,
            sessionMotionByStart = sessionMotionByStart,
        )
    }

    /** Round to 2 decimal places (matches the imported/demo skin-temp deviation precision). (PR #85) */
    private fun round2(v: Double): Double = kotlin.math.round(v * 100.0) / 100.0

    /** Min worn, in-bed skin-temp samples (1 Hz ⇒ seconds) before a nightly mean is trusted. ~5 min
     *  guards against a few stray samples fabricating a baseline value. (PR #85) */
    private const val MIN_SKIN_TEMP_SAMPLES_INLINE = 300

    /**
     * Wear-gated mean in-bed skin temperature (°C) for the night, or null when too few worn samples.
     * A sample counts when (a) its timestamp falls inside a detected in-bed [sessions] span, (b) a
     * concurrent HR sample reads a worn, alive BPM (the strap streams HR only on-wrist), and (c) the
     * value is in the plausible worn range — so an on-charger interval drifting to ambient (which still
     * passes the strap's looser 20–45 decode gate, e.g. the ~22 °C off-wrist decode fixture) can't
     * poison the nightly mean. Uses the decoder's /100 scale. All values APPROXIMATE. (PR #85)
     */
    internal fun wornNightlySkinTempC(
        sessions: List<DetectedSleep>,
        hr: List<HrSample>,
        skinTemp: List<SkinTempSample>,
        minSamples: Int = MIN_SKIN_TEMP_SAMPLES_INLINE,
    ): Double? {
        if (sessions.isEmpty() || skinTemp.isEmpty()) return null
        val wornSeconds = HashSet<Long>(hr.size)
        for (h in hr) if (h.bpm in 30..220) wornSeconds.add(h.ts)
        var sum = 0.0
        var n = 0
        for (t in skinTemp) {
            if (t.ts !in wornSeconds) continue
            if (sessions.none { t.ts in it.start..it.end }) continue
            val c = t.raw / 100.0
            if (c < SKIN_TEMP_MIN_C || c > SKIN_TEMP_MAX_C) continue
            sum += c
            n++
        }
        return if (n >= minSamples) sum / n else null
    }

    /** Plausible worn skin-temperature range (°C). Off-wrist/charging samples drift to ambient and are
     *  excluded; the strap's own decode gate is the looser 20–45. (PR #85) */
    private const val SKIN_TEMP_MIN_C: Double = 28.0
    private const val SKIN_TEMP_MAX_C: Double = 42.0
}

/*
 * RestScorer — NOOP "Rest" (sleep_performance) composite, 0–100.
 *
 * Faithful Kotlin mirror of the Swift Rest composite (AnalyticsEngine / RestScorer). Keep every
 * constant and the weight set byte-identical to Swift — parity tests enforce it.
 *
 *   Rest = 0.50·duration + 0.20·efficiency + 0.20·restorative + 0.10·consistency
 *
 * Each sub-component is itself on 0–100:
 *   duration     — asleep hours / personal need, clamped at 100 (8 h default, refined by recent avg).
 *   efficiency   — asleep / in-bed (0..1) × 100.
 *   restorative  — (deep + REM) / asleep share, normalized by a healthy target share, clamped 100.
 *   consistency  — sleep/wake regularity (0..1) × 100; when the caller has no history it is null and
 *                  the term DROPS, renormalizing the remaining weights (same discipline as recovery).
 *
 * Outputs APPROXIMATE — not WHOOP's proprietary Sleep Performance.
 */
object RestScorer {

    /** Component weights (sum 1.0 when all present). Byte-identical to Swift. */
    const val wDuration: Double = 0.50
    const val wEfficiency: Double = 0.20
    const val wRestorative: Double = 0.20
    const val wConsistency: Double = 0.10

    /** Default personal sleep need (hours) before any recent-average refinement. */
    const val defaultSleepNeedHours: Double = 8.0

    /**
     * Healthy restorative (deep + REM) share of asleep time. A share at/above this earns full
     * restorative credit; below it scales linearly. ~0.50 reflects ~20% deep + ~25–30% REM in a
     * well-structured night.
     */
    const val restorativeTargetShare: Double = 0.50

    /**
     * Deep-sleep share of asleep time that earns FULL restorative credit (~13% is the healthy floor
     * for adults; below it the restorative term scales down toward [deepFloorFactor]). DEEP honesty
     * (Reddit HRV/sleep report): pooling deep+REM let a night with normal REM but almost no DEEP earn
     * near-full restorative credit (Rest read 95+ with little deep). Byte-identical to Swift.
     */
    const val deepShareTarget: Double = 0.13

    /** Most the restorative term is scaled down when deep is ~absent — half, never zeroed, so a
     *  low-deep night reads honestly without the whole night tanking. Swift parity. */
    const val deepFloorFactor: Double = 0.5

    /** Neutral consistency (fraction) used when the caller supplies no regularity signal. Swift parity. */
    const val NEUTRAL_CONSISTENCY: Double = 0.5

    /**
     * Rest composite [0,100], or null when there is no asleep time.
     *
     * @param asleepSeconds total sleep time (TST) for the night, seconds.
     * @param efficiency asleep / in-bed in [0,1].
     * @param deepSeconds deep-stage seconds.
     * @param remSeconds REM-stage seconds.
     * @param sleepNeedHours personal need (hours); null → [defaultSleepNeedHours].
     * @param consistency sleep/wake regularity in [0,1]; null drops the term + renormalizes.
     */
    fun rest(
        asleepSeconds: Double,
        efficiency: Double,
        deepSeconds: Double,
        remSeconds: Double,
        sleepNeedHours: Double? = null,
        consistency: Double? = null,
    ): Double? {
        if (asleepSeconds <= 0.0) return null

        val asleepHours = asleepSeconds / 3600.0
        val needHours = (sleepNeedHours ?: defaultSleepNeedHours).coerceAtLeast(1e-9)

        // Duration vs personal need (clamped at 100 — sleeping past need does not over-credit).
        val durationScore = min(100.0, asleepHours / needHours * 100.0)
        // Efficiency (0..1 → 0..100), clamped.
        val efficiencyScore = (efficiency * 100.0).coerceIn(0.0, 100.0)
        // Restorative share vs healthy target (clamped at 100), then scaled by a gentle deep-adequacy
        // factor in [deepFloorFactor, 1]: full once deep ≥ target share, ramping to the floor as
        // deep → 0, so a near-zero-deep night loses up to half this term (~10 pts) — honest, not
        // tanking, no fabricated stages. Mirrors Swift Rest.composite EXACTLY.
        val restorativeShare = (deepSeconds + remSeconds) / asleepSeconds
        val deepAdequacy = ((deepSeconds / asleepSeconds) / deepShareTarget).coerceIn(0.0, 1.0)
        val deepFactor = deepFloorFactor + (1.0 - deepFloorFactor) * deepAdequacy
        val restorativeScore = min(100.0, restorativeShare / restorativeTargetShare * 100.0) * deepFactor

        // Consistency uses a NEUTRAL 0.5 (→50) when the caller supplies none — matching the Swift
        // Rest.composite EXACTLY (parity is required; Swift adds a neutral term, it does NOT drop +
        // renormalize). Weights sum to 1.0 so the weighted sum is already on 0..100.
        val consistencyScore = ((consistency ?: NEUTRAL_CONSISTENCY) * 100.0).coerceIn(0.0, 100.0)
        val weighted = wDuration * durationScore +
            wEfficiency * efficiencyScore +
            wRestorative * restorativeScore +
            wConsistency * consistencyScore
        return (weighted * 100.0).roundToInt() / 100.0
    }

    /**
     * Rest composite [0,100] derived from a persisted [DailyMetric] (the pass-2 / display path — raw
     * streams are gone but the night's totals remain). null when there's no sleep. Single source of
     * truth so the persisted sleep_performance series and the Charge "Rest quality" term agree. Mirrors
     * Swift `AnalyticsEngine.Rest.composite(daily:)`.
     */
    fun restFromDaily(daily: DailyMetric, consistency: Double? = null): Double? {
        val tstMin = daily.totalSleepMin ?: return null
        val eff = daily.efficiency ?: return null
        if (tstMin <= 0.0) return null
        return rest(
            asleepSeconds = tstMin * 60.0,
            efficiency = eff,
            deepSeconds = (daily.deepMin ?: 0.0) * 60.0,
            remSeconds = (daily.remMin ?: 0.0) * 60.0,
            sleepNeedHours = null,
            consistency = consistency,
        )
    }
}
