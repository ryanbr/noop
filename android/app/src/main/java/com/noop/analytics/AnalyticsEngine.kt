package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.EventRow
import com.noop.data.GravitySample
import com.noop.data.V18AuxRow
import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.data.Spo2Sample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.StepSample
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Whoop4SkinTemp
import com.noop.protocol.skinTempCelsius
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

    // Locale.ROOT so the stored day-key stays ASCII yyyy-MM-dd regardless of the app-language selection
    // (#1004): the six shipped languages already emit Latin digits, but pinning keeps this the primary
    // DailyMetric.day writer's numerals stable if a non-Latin-digit locale is ever added — and keeps it
    // byte-identical to Swift AnalyticsEngine.isoDay.
    private val isoDay: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC).withLocale(java.util.Locale.ROOT)

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
     * Inverse of [encodeStages]: decode a stored `stagesJSON` back to a list of [StageSegment]. Only the
     * on-device SEGMENT-ARRAY shape (`[{start,end,stage}]`) decodes; the imported minute-dict shape
     * (`{light,deep,rem,awake}`) is not a segment timeline and yields an empty list. Mirrors Swift
     * `AnalyticsEngine.decodeStages`. (#804)
     */
    fun decodeStages(json: String?): List<StageSegment> {
        if (json == null) return emptyList()
        return try {
            val arr = org.json.JSONArray(json)
            val out = ArrayList<StageSegment>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (!o.has("start") || !o.has("end")) continue
                val stage = o.optString("stage", "")
                if (stage.isEmpty()) continue
                out.add(StageSegment(o.getLong("start"), o.getLong("end"), stage))
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /**
     * Reconstruct the [DetectedSleep] the analyzer stages from a persisted, device-PROVIDED [SleepSession]
     * row — e.g. an Oura ring's own SleepNet hypnogram (#773), whose `stagesJSON` uses the same
     * deep/light/rem/wake vocabulary the stager reads. Uses the effective (edit-aware) onset, preserves the
     * stored efficiency (deriving it from the decoded stage minutes only when the row stored none), and
     * passes restingHr/avgHrv through as stored — null for a ring night, which [analyzeDay] then re-derives
     * from that day's hr/rr. Returns null when the row has no decodable stage timeline, so a non-hypnogram
     * (minute-dict) row is never injected. Mirrors Swift `sleepSession(fromProvided:)`. (#804 Fix A)
     */
    fun sleepSessionFromProvided(c: com.noop.data.SleepSession): DetectedSleep? {
        val stages = decodeStages(c.stagesJSON)
        if (stages.isEmpty()) return null
        val efficiency = c.efficiency
            ?: SleepStageTotals.minutes(c.stagesJSON)?.let { if (it.inBed > 0) it.asleep / it.inBed else null }
            ?: 0.0
        return DetectedSleep(
            start = c.effectiveStartTs, end = c.endTs, efficiency = efficiency,
            stages = stages, restingHR = c.restingHr, avgHRV = c.avgHrv,
        )
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
    @Suppress("UNUSED_PARAMETER") // sleepNeedNights kept for signature stability (unused in the current body)
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
        // Device family that wrote [skinTemp], so the raw→°C conversion picks the right scale (#938):
        // 5/MG banks CENTIDEGREES (raw/100), the WHOOP 4.0 v24 field is a RAW ADC on a different scale.
        // Default WHOOP5 keeps every 5/MG + pure-function caller byte-identical; IntelligenceEngine passes
        // the day owner's real family.
        skinTempFamily: DeviceFamily = DeviceFamily.WHOOP5,
        // Per-device WHOOP 4.0 worn anchor raw (#938 second capture): the raw that maps to 33.0 °C for THIS
        // device. The @72 skin-temp ADC's register offset is per-device — a second real 4.0 strap shares the
        // floor (~509) + saturation (2047) but has a worn band ~1100–1600, which the global 826 anchor maps
        // to 47–72 °C, failing 100% of the worn gate. IntelligenceEngine learns it once per run from the
        // owner's own worn median. null → the family-aware conversion uses the global Whoop4SkinTemp.ANCHOR_RAW,
        // so every 5/MG + pure-function caller stays byte-identical (WHOOP5 ignores the anchor entirely).
        skinTempAnchorRaw: Double? = null,
        // WHOOP 4.0 raw SpO2 PPG ADC samples (red/IR) for the night window (#93). The nightly red/IR
        // means over detected sleep are banked on the DailyMetric as RAW ADC — honest "the sensor
        // decoded" data, NOT a calibrated blood-oxygen % (that needs WHOOP's proprietary curve). Default
        // empty keeps pure-function callers/tests + non-4.0 nights null.
        spo2: List<Spo2Sample> = emptyList(),
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
        // Which sleep-staging recipe runs (V2 vs V1). When true, detected nights are staged by
        // [SleepStagerV2] instead of V1. This PARAMETER defaults false to keep pure-function callers/tests
        // byte-identical — it is NOT the product default. IntelligenceEngine threads
        // PuffinExperiment.from(context).experimentalSleepV2, which is default TRUE (#277/#351), so the
        // shipped app stages with V2. Mirrors Swift. (7.0.0)
        useSleepStagerV2: Boolean = false,
        // Opt-in motion-aware wake refinement (#364 "Proposal 2" follow-up; density gate precedent #345).
        // When true, [WakeMotionRefinement] re-derives each detected session's stages, reclassifying a
        // hot-but-still WAKE segment to `light` when it shows no locomotion and a stable posture outside
        // isolated burst minutes; it only ever runs AFTER V1/V2 staging and self-gates on the observed
        // gravity + step density, so it is a no-op on a sparse (e.g. WHOOP 4.0) night regardless of this
        // flag. Default false keeps every pure-function caller/test byte-identical; IntelligenceEngine
        // threads PuffinExperiment.from(context).motionAwareWake. Mirrors Swift.
        useMotionAwareWake: Boolean = false,
        // Caller-supplied, already-staged sessions to fold in ALONGSIDE the motion detector's — the day
        // owner's OWN device-provided hypnogram (an Oura ring's SleepNet night, #773), reconstructed via
        // [sleepSessionFromProvided]. The fix for #804: a ring sends no gravity vector, so detectSleep stages
        // nothing and the night scored blank even though the ring's hypnogram was persisted + shown on the
        // timeline. Provided sessions are PRE-staged: they bypass detectSleep AND wake refinement. Where a
        // provided session overlaps a detected one the PROVIDED session wins; a non-overlapping detected nap
        // survives. Each provided session's nightly restingHR/avgHRV is re-derived here from this day's hr/rr
        // when the stored row carried none. Default empty (every WHOOP / pure caller) = motion-only path.
        providedSleep: List<DetectedSleep> = emptyList(),
        // Sleep & Rest test-mode trace sink (E11). null = byte-identical default. When non-null the gate
        // trace from detectSleep and the Rest sub-score line are forwarded line-by-line. Mirrors Swift.
        traceSink: ((String) -> Unit)? = null,
        // HRV & Autonomic test-mode sink (#141). null = byte-identical default. When non-null, the nightly
        // per-5-min-window RMSSDs (tagged by sleep stage) + a whole-night vs deep-only vs last-SWS summary
        // are forwarded so an "HRV reads ~2x higher than WHOOP" report shows WHICH stages lift it.
        hrvTraceSink: ((String) -> Unit)? = null,
        // Whether to emit the ~90 per-window `hrv window …` lines (vs just the 1-line summary). The caller
        // sets it TRUE only for the most-recent night so the 5000-line ring buffer isn't flooded (21 nights ×
        // ~90 windows would evict the always-on diagnostics); the 1-line `hrv nightSummary` is kept for EVERY
        // night so the whole-night-vs-deep pattern is still visible across the week.
        hrvWindowDetail: Boolean = false,
        // #141: when true, the nightly HRV is RMSSD over DEEP-sleep windows only (WHOOP-style), instead of
        // the whole-night mean. Display-only preference threaded from the caller (UnitPrefs.hrvWindow). The
        // default (false) is byte-identical to the historical whole-night value.
        deepHrvWindow: Boolean = false,
    ): DayResult {

        // ── Sleep detection + staging ─────────────────────────────────────────
        val detectedSessions = SleepStager.detectSleep(
            hr = hr, rr = rr, resp = resp, gravity = gravity, tzOffsetSeconds = tzOffsetSeconds,
            wristOff = wristOff, bandSleepState = bandSleepState,
            useSleepStagerV2 = useSleepStagerV2,
            traceSink = traceSink,
        )
        // Motion-aware wake refinement (#364 follow-up) runs AFTER V1/V2 staging, over every detected
        // session (naps included — the same eligibility gates apply). `steps` is the SAME calendar-day/
        // night-window stream the caller passed for the rest of this analysis; the pass self-gates on its
        // observed density, so an empty/sparse `steps` (e.g. a WHOOP 4.0, which never emits a step sample
        // at all) is a no-op regardless of `useMotionAwareWake`.
        val refinedSessions = if (useMotionAwareWake) {
            detectedSessions.map { WakeMotionRefinement.refine(it, gravity, steps) }
        } else {
            detectedSessions
        }
        // #804 Fix A: fold in the caller's device-provided hypnogram (see [providedSleep]). Empty = the
        // byte-identical motion-only path. Otherwise enrich each provided session's nightly restingHR/avgHRV
        // from THIS day's hr/rr over its window (the stored ring row carries neither), using the SAME helpers
        // detectSleep populates a session with, then keep only the detected sessions that DON'T overlap a
        // provided one (provided is authoritative where they collide; a separate nap survives).
        val allSessions: List<DetectedSleep> = if (providedSleep.isEmpty()) {
            refinedSessions
        } else {
            val rrSorted = rr.sortedBy { it.ts }
            val enrichedProvided = providedSleep.map { s ->
                if (s.restingHR != null && s.avgHRV != null) s
                else s.copy(
                    restingHR = s.restingHR ?: SleepStager.sessionRestingHR(s.start, s.end, hr),
                    avgHRV = s.avgHRV ?: SleepStager.sessionAvgHRV(s.start, s.end, rrSorted),
                )
            }
            val keptDetected = refinedSessions.filter { d ->
                enrichedProvided.none { it.start < d.end && d.start < it.end }
            }
            keptDetected + enrichedProvided
        }
        // Sessions attributed to `day` = those whose end falls on `day` (LOCAL day, #277). `day` is
        // the caller's local-day key; attribute by the same offset so the bucket and the key agree.
        val matched = allSessions.filter { dayString(it.end, tzOffsetSeconds) == day }

        // ── The day's MAIN night (#525) ───────────────────────────────────────
        // A day can hold an overnight AND a daytime nap (both end on `day`, so both are in `matched`).
        // The canonical sleep-DURATION figures (total sleep / stage minutes / efficiency / disturbances,
        // hence the Rest composite and dashboard card) describe the MAIN night — the SAME block the Sleep
        // tab's hero shows (longest, preferring an overnight-anchored onset). They must NOT silently sum the
        // nap in, or the "your night" number disagrees across screens (the #525 report). Naps stay their OWN
        // session rows in `sleepSessions`, where the Sleep tab lists and labels them separately. The Sleep
        // tab's debt calculation deliberately adds those rows' actual asleep minutes as repayment credit;
        // it does not mutate this canonical main-night aggregate. [SleepStageTotals.mainNightIndex] is the
        // single shared selector so the analytics rollup and Sleep tab classify the same blocks.
        // Pick by the LEARNED-TIMING score, threading the user's learned habitual midsleep so a
        // late/shift sleeper's real night out-scores a daytime nap (null = cold-start overnight band).
        // BIPHASIC GAP-BRIDGE (#561): a main sleep briefly interrupted by a short wake (a fragment the
        // detector left split because the wake gap was longer than its sparse-gravity bridge, or a true
        // biphasic night) is scored as ONE night via [SleepStageTotals.mainNightGroupIndices]: it bridges
        // adjacent blocks whose gap is < `gapBridgeMaxMin`, scores the bridged span, and returns ALL the
        // fragments in the winning group. The AASM aggregate below then SUMS the group's stages — in-bed is
        // the SUM of each fragment's own in-bed span (the inter-fragment wake gap is NOT part of any fragment,
        // so it is excluded and we do NOT invent WASO for it). A day with no bridgeable gap collapses to the
        // single block the bare [mainNightIndex] would pick. Intelligence and the Sleep headline read this
        // SAME group; the debt ledger starts with it and separately credits naps, so #525 does not regress.
        // Mirrors Swift. (#525 / #561)
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
            inBedS += inBed                       // each fragment's own in-bed span (the gap is added below)
            effWeighted += s.efficiency * inBed   // in-bed-weighted efficiency across the group
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        // OUT-OF-BED time BETWEEN bridged fragments is AWAKE (#777/#705): a main night bridged from two
        // fragments split by a 20-min wake gap was reporting that gap as nowhere (it is in no fragment's
        // [start,end) span), so 20+ min of real awake read as ~4 min - a v7.1 regression, multi-reporter.
        // Fold the gap into AWAKE by extending the in-bed denominator (in-bed = asleep + awake; tstS is
        // unchanged), so efficiency and the Rest composite both reflect it. ONE shared definition with the
        // edit/recompute seam ([SleepStageTotals.interFragmentAwakeSeconds]), so the two paths agree and the
        // denominator is never double-counted. A bridged gap also counts as one disturbance. Mirrors Swift.
        val gapAwakeS = SleepStageTotals.interFragmentAwakeSeconds(mainGroup.map { it.start to it.end })
        if (gapAwakeS > 0.0) {
            inBedS += gapAwakeS                   // the gap is fully awake: extends in-bed, adds 0 to effWeighted
            disturbances += 1
        }
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
        val avgHRVDaily: Double? = if (deepHrvWindow) {
            // #141: WHOOP-style HRV — pool RMSSD over DEEP-stage 5-min windows only (slow-wave sleep),
            // instead of the whole-night mean below. Reuses the SAME sessionHrvWindows the HRV trace is
            // built from, so the displayed value equals the `deepOnly` figure the trace logs. rr is sorted
            // (RMSSD = successive diffs). null when the night has no detected deep sleep (WHOOP-4.0 staging
            // can be sparse) — the caller then shows calibrating, never a fabricated number.
            val rrSorted = rr.sortedBy { it.ts }
            val deep = matched.flatMap { s ->
                SleepStager.sessionHrvWindows(s.start, s.end, rrSorted, s.stages)
                    .filter { it.stage == "deep" }.mapNotNull { it.rmssd }
            }
            if (deep.isEmpty()) null else deep.sum() / deep.size
        } else run {
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

        // ── HRV & Autonomic nightly trace (#141) ──────────────────────────────
        // Per-5-min-window RMSSD tagged by the sleep stage at its center, then a night summary comparing
        // NOOP's whole-night mean (what it reports) against a deep-only mean and a WHOOP-style
        // last-slow-wave-sleep value — so an "HRV reads ~2x higher than WHOOP" report shows WHICH stages
        // lift it, and lets a deep-sleep-windowed fix be validated before it ships. Reuses the SAME
        // sessionHrvWindows the value is built from (can't diverge). Zero cost when the sink is null.
        if (hrvTraceSink != null) {
            // sessionHrvWindows requires ts-sorted rr (RMSSD = successive diffs); the value path passes the
            // stager's pre-sorted rrS, so sort our own copy of the day's raw rr once here for the re-window.
            val rrSorted = rr.sortedBy { it.ts }
            val allWin = ArrayList<SleepStager.HrvWindow>()
            for (s in matched) {
                val wins = SleepStager.sessionHrvWindows(s.start, s.end, rrSorted, s.stages)
                if (hrvWindowDetail) {
                    for (w in wins) {
                        hrvTraceSink(
                            "hrv window t=${(w.startTs - s.start) / 60}min stage=${w.stage} " +
                                "beats=${w.cleanBeats} rmssd=${w.rmssd?.let { "${round2(it)}ms" } ?: "nil"}",
                        )
                    }
                }
                allWin.addAll(wins)
            }
            fun meanMs(ws: List<SleepStager.HrvWindow>): String {
                val v = ws.mapNotNull { it.rmssd }
                return if (v.isEmpty()) "nil" else "${round2(v.sum() / v.size)}ms"
            }
            val withR = allWin.filter { it.rmssd != null }
            val deepW = withR.filter { it.stage == "deep" }
            val lastSws = SleepStager.lastDeepRun(allWin).filter { it.rmssd != null }
            // `reported` is the value NOOP actually displays (duration-weighted session-mean-of-means);
            // `wholeNight` is the pooled-window mean it equals on single-session nights and the apples-to-
            // apples baseline for the deepOnly/lastSWS comparison (all three are pooled window means).
            hrvTraceSink(
                "hrv nightSummary reported=${avgHRVDaily?.let { "${round2(it)}ms" } ?: "nil"} " +
                    "wholeNight=${meanMs(withR)} deepOnly=${meanMs(deepW)} " +
                    "lastSWS=${meanMs(lastSws)} nWin=${withR.size} nDeep=${deepW.size}",
            )
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
        val nightlySkinTempC = wornNightlySkinTempC(matched, hr, skinTemp, skinTempFamily, skinTempAnchorRaw)
        val skinTempDevC: Double? = nightlySkinTempC?.let { v ->
            baselines.skinTemp?.takeIf { it.usable }?.let { round2(Baselines.deviation(v, it).delta) }
        }

        // ── Raw SpO2 (WHOOP 4.0 v24 PPG ADC) ──────────────────────────────────
        // Nightly red/IR ADC means over the detected in-bed spans, or null when the night carried no raw
        // SpO2 samples in any span. Baseline-independent (unlike skin temp): a RAW device reading banked
        // as-is for the Health "Raw SpO2" tile — NOT a calibrated blood-oxygen %. (#93)
        val nightlySpo2Raw = nightlySpo2RawMeans(matched, spo2)

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
        // #345: gravity-sparse computed ONCE — reused by the sleep-motion trace below AND the Rest
        // confidence guard, so the two can never diverge and isGravitySparse runs only once per day.
        val gravitySparse = SleepStager.isGravitySparse(gravity, hr)
        // Sleep & Rest test mode (E11): emit the Rest sub-score breakdown for this night, reusing the
        // IDENTICAL inputs `rest` consumed above so the trace can never disagree with the score. Emitted
        // only when a trace is requested and this day scored a night. Mirrors Swift.
        if (traceSink != null && matched.isNotEmpty()) {
            traceSink(RestScorer.subScoreLine(
                tstSeconds = tstS, inBedSeconds = inBedS, efficiency = efficiency,
                restorativeSeconds = deepS + remS,
                needHours = sleepNeedHours ?: RestScorer.defaultSleepNeedHours,
                consistency = sleepConsistency, deepSeconds = deepS,
                groupFragments = mainGroup.size, groupInBedSeconds = inBedS))
            // #319: the motion-coverage + staging context behind the Rest number, so a high score on a poor
            // night can be explained from an export — WHOOP 4.0 banks motion coarsely (sparse=true), so most
            // epochs default to sleep → over-counted duration → high Rest; `stager` says whether V1/V2 ran.
            traceSink(RestScorer.sleepMotionLine(day, gravity.size, hr.size,
                gravitySparse, useSleepStagerV2, skinTempFamily))
            // #271: the ONSET decision — did HR dip when the window opened, or did it open on a still-but-
            // awake stretch (HR still ~baseline)? Both the day-median baseline AND the at-onset window read
            // from the SAME HR that DETECTION ran over (`dayHr ?: hr` — the full calendar day when the caller
            // supplies it, else the night window), so the onset instant is guaranteed inside it and the
            // baseline reads as a real DAY median (a real onset sits BELOW it, matching the daytime/re-onset
            // guards). Emitted only when both have HR, so a motion-only night stays silent.
            val onsetHr = dayHr ?: hr
            val onsetTs = (mainGroup.minOfOrNull { it.start } ?: matched.minOfOrNull { it.start }) ?: 0L
            val baselineHr = RestScorer.medianBpm(onsetHr.map { it.bpm })
            val hrAtOnset = RestScorer.medianBpm(
                onsetHr.filter { it.ts >= onsetTs && it.ts < onsetTs + RestScorer.onsetTraceWindowSec }.map { it.bpm })
            if (onsetTs > 0 && baselineHr != null && hrAtOnset != null) {
                traceSink(RestScorer.sleepOnsetLine(onsetTs, hrAtOnset, baselineHr))
            }
        }

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
            // night-window stream when the caller didn't supply one (pure-function callers/tests). The
            // day's read window may include adjacent-day samples, so filter to the LOCAL-day key first
            // (#277); the wrap-aware tick math itself lives in the shared StepsCounter kernel so the daily
            // and per-workout (#398) totals can never disagree.
            val inDay = (daySteps ?: steps).filter { dayString(it.ts, tzOffsetSeconds) == day }
            val ticks = StepsCounter.stepsInWindow(inDay) ?: return@run null
            // @57 counts motion ticks, not validated steps — the 5/MG counter overcounts. Divide
            // by the user-calibrated ticks-per-step (default 1.0 = raw pass-through; floor 0.5 so
            // a bad pref can at most double, never explode, the total). (#139)
            val scaled = (ticks.toDouble() / max(profile.stepTicksPerStep, 0.5)).roundToLong()
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
            spo2Red = nightlySpo2Raw?.first,
            spo2Ir = nightlySpo2Raw?.second,
        )

        // ── Per-score confidence tiers (mirror Swift ScoreConfidence.derive decisions) ──
        val chargeConfidence = ScoreConfidence.forCharge(recovery, baselines.hrv)
        val effortConfidence = ScoreConfidence.forEffort(strain, hr.size)
        // Rest confidence with H9 + the #345 sparse-motion guard: downgrade to low-confidence a night whose
        // deep+REM share is implausibly low on a high-efficiency night (H9 staging miss) OR that was staged
        // on sparse gravity (WHOOP 4.0 coarse-banked motion can't reliably stage sleep — a confident 85–100
        // Rest is unearned however the engine filled it). Confidence-only, no faked stages. tstS/efficiency
        // are the main-group totals above; restorative = deepS + remS. Mirrors Swift.
        val restConfidence = ScoreConfidence.forRest(
            hasSession = matched.isNotEmpty(),
            hasStagedSleep = (deepS + remS) > 0,
            asleepSeconds = tstS,
            restorativeSeconds = deepS + remS,
            efficiency = efficiency,
            gravitySparse = gravitySparse,
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

        // ── Per-session per-epoch BAND sleep_state (#175) ─────────────────────
        // Grid the strap's OWN band sleep_state (the SAME [bandSleepState] samples the H7 guard consumes)
        // onto each matched session's 30 s epochs, for the caller to persist beside `stagesJSON`. This is the
        // source the band-state chain lacked (persist → next pass's H7 re-onset CONFIRM). A session whose
        // window carries no band samples is omitted (no key) → the caller persists NULL, an absent signal
        // stays absent. Empty on a WHOOP 4.0. The band code is carried verbatim; it NEVER overrides the
        // derived hypnogram, only confirms a borderline morning re-onset. Mirrors Swift.
        val sessionSleepStateByStart = HashMap<Long, List<Int>>()
        if (bandSleepState.isNotEmpty()) {
            for (s in matched) {
                val states = SleepStager.sessionEpochSleepState(s.start, s.end, bandSleepState)
                if (states.isNotEmpty()) sessionSleepStateByStart[s.start] = states
            }
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
            sessionSleepStateByStart = sessionSleepStateByStart,
            gravitySparse = gravitySparse,
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
     * poison the nightly mean.
     *
     * The raw→°C conversion is DEVICE-FAMILY-AWARE (#938): 5/MG stores CENTIDEGREES (°C = raw/100), but
     * the WHOOP 4.0 v24 field@72 is a RAW ADC on a different scale — running it through /100 read every
     * worn 4.0 night ~8 °C, below the 28 °C worn gate, so kept=0 and skin temp + the illness signal
     * vanished (issue #938). The shared [skinTempCelsius] picks the right scale; [family] defaults to
     * WHOOP5 so every existing 5/MG + pure-function caller is byte-identical. All values APPROXIMATE.
     */
    internal fun wornNightlySkinTempC(
        sessions: List<DetectedSleep>,
        hr: List<HrSample>,
        skinTemp: List<SkinTempSample>,
        family: DeviceFamily = DeviceFamily.WHOOP5,
        // Per-device WHOOP 4.0 worn anchor raw (#938); null → the global Whoop4SkinTemp.ANCHOR_RAW, keeping
        // 5/MG + pure-function callers byte-identical. Threaded straight to the funnel's conversion.
        anchorRaw: Double? = null,
        minSamples: Int = MIN_SKIN_TEMP_SAMPLES_INLINE,
    ): Double? = skinTempFunnel(sessions, hr, skinTemp, family, anchorRaw, minSamples).mean

    /**
     * Nightly means of the WHOOP 4.0 raw SpO2 PPG channels (red/IR ADC) over the detected in-bed
     * [sessions], or null when no raw SpO2 sample fell inside any span. A sample counts when its
     * timestamp lies within a session's [start, end]. WHOOP 4.0 banks these as raw PPG ADC values
     * (spo2_red@68 / spo2_ir@70 on the v24 historical layout) but NOT a calibrated blood-oxygen % —
     * computing one needs WHOOP's proprietary curve, so we surface the RAW means only. Deliberately NO
     * wear gate (unlike skin temp): the strap only streams SpO2 on-wrist, so there is no off-charger
     * drift to exclude, and the value is surfaced honestly as raw ADC — never scored — so there is
     * nothing to poison into a fake %. Pure + deterministic; twin of the Swift `nightlySpo2RawMeans`. (#93)
     */
    internal fun nightlySpo2RawMeans(
        sessions: List<DetectedSleep>,
        spo2: List<Spo2Sample>,
    ): Pair<Int, Int>? {
        if (sessions.isEmpty() || spo2.isEmpty()) return null
        var redSum = 0L
        var irSum = 0L
        var kept = 0
        for (s in spo2) {
            if (sessions.none { s.ts in it.start..it.end }) continue
            redSum += s.red
            irSum += s.ir
            kept++
        }
        if (kept == 0) return null
        return (redSum / kept).toInt() to (irSum / kept).toInt()
    }

    /**
     * Nightly gated mean of the 5/MG SpO2 **candidate** byte (`@82`) over the detected in-bed [sessions],
     * paired with the sample count it rests on — or null when no in-band reading fell inside any span.
     * (#112, tracking #103.)
     *
     * WHY THIS EXISTS. The candidate is decoded and stored but deliberately never scored: `@82` looks like
     * a strap-computed SpO2 %, and on one independent 8-night check it tracked the WHOOP app almost
     * exactly, but on the two nights from the strap it was found on it moved the OPPOSITE way. Two
     * devices, contradictory answers, so it cannot be promoted. Breaking that tie needs a third strap —
     * and until now the only way to read the candidate was to scroll the Deep Timeline chart and eyeball
     * it, which is a poor instrument to hand a volunteer and produces a number nobody can check.
     *
     * This makes the comparison one number against one number: the wearer reads this and the figure the
     * WHOOP app reports for the same night. The count travels with the mean on purpose — a mean over 11
     * readings and a mean over 1100 are not the same evidence.
     *
     * Gated to `70..100`, the SAME in-band window the decoder applies when it emits `spo2_candidate_82`:
     * sub-70 nonzero values are diagnostic codes and bit-7 values are saturation sentinels, so averaging
     * them in would produce a number that is not a percentage of anything.
     *
     * DIAGNOSTIC ONLY. Nothing scores this and it never writes `spo2Pct`. Byte-parity twin of the Swift
     * `nightlySpo2CandidateMean`.
     */
    internal fun nightlySpo2CandidateMean(
        sessions: List<DetectedSleep>,
        aux: List<V18AuxRow>,
    ): Pair<Int, Int>? {
        if (sessions.isEmpty() || aux.isEmpty()) return null
        var sum = 0L
        var kept = 0
        for (a in aux) {
            val v = a.auxByte82 ?: continue
            if (v < 70L || v > 100L) continue
            if (sessions.none { a.ts in it.start..it.end }) continue
            sum += v
            kept += 1
        }
        if (kept == 0) return null
        return Pair((sum / kept).toInt(), kept)
    }

    /**
     * #1169 SHADOW METRIC: the primary-session MEAN resting HR — window each detected sleep session's HR
     * samples to `[start, end)` and delegate to the #1174-defined [PrimarySessionRestingHR.meanHR] (that
     * definition is UNCHANGED). IntelligenceEngine stores the result beside the shipped nightly HR FLOOR
     * (`daily.restingHr`) as "rhr_primary_session" — instrumentation only, never shown, never scored — so
     * the mean-vs-floor comparison #1169 asks for can be evaluated from exports without a headline switch.
     * Byte-parity twin of the Swift `primarySessionRestingHR`.
     */
    internal fun primarySessionRestingHR(
        sessions: List<DetectedSleep>,
        hr: List<HrSample>,
        validBpm: IntRange = PrimarySessionRestingHR.DEFAULT_VALID_BPM,
        minValidSamples: Int = PrimarySessionRestingHR.DEFAULT_MIN_VALID_SAMPLES,
    ): Double? = PrimarySessionRestingHR.meanHR(
        sessions.map { s ->
            PrimarySessionRestingHR.Session(
                durationSec = (s.end - s.start).toDouble(),
                bpm = hr.filter { it.ts >= s.start && it.ts < s.end }.map { it.bpm },
            )
        },
        validBpm,
        minValidSamples,
    )

    /** Plausible worn skin-temperature range (°C). Off-wrist/charging samples drift to ambient and are
     *  excluded; the strap's own decode gate is the looser 20–45. (PR #85) */
    private const val SKIN_TEMP_MIN_C: Double = 28.0
    private const val SKIN_TEMP_MAX_C: Double = 42.0

    // ── Skin-temp funnel diagnostic (#752) ──────────────────────────────────────────────────────────

    /**
     * Why nightly skin temp funneled toward absent for one night. Counts are over the night's raw skin-temp
     * samples; each sample is attributed to the FIRST gate that dropped it, in the SAME order
     * [wornNightlySkinTempC] applies (not-worn → out-of-window → out-of-range → kept), so the four drop
     * buckets plus [kept] sum to [totalSamples]. Pure + deterministic; shares the exact gate logic with the
     * real computation, so it explains the SAME mean the app uses. Mirrors Swift `SkinTempFunnelDiagnostic`.
     * (#752)
     */
    data class SkinTempFunnelDiagnostic(
        val totalSamples: Int,
        val droppedNotWorn: Int,
        val droppedOutOfWindow: Int,
        val droppedOutOfRange: Int,
        val kept: Int,
        val minSamples: Int,
        val mean: Double?,
        // #skin-diag: raw-ADC visibility so an absent WHOOP 4.0 skin temp explains WHY (anchor mis-map
        // vs genuinely no worn data). Pure observations of the input — they do NOT affect mean/gates.
        /** Min / median / max of the night's RAW skin-temp ADC values (null when no samples). */
        val rawMin: Int? = null,
        val rawMedian: Int? = null,
        val rawMax: Int? = null,
        /** Raw samples inside the worn ADC band (WORN_MIN..WORN_MAX_RAW); ≥100 lets the per-device anchor learn. */
        val inBandCount: Int = 0,
        /** The anchor raw actually used for the °C map (caller's per-device anchor, else the global 826). null on 5/MG. */
        val resolvedAnchorRaw: Double? = null,
        /** What °C the median raw maps to under [resolvedAnchorRaw]; outside 28–42 °C ⇒ every worn sample gated out. */
        val medianMappedC: Double? = null,
    ) {
        /** True when the night produced no usable mean - the case this diagnostic exists to triage. */
        val isAbsent: Boolean get() = mean == null

        /** Human-readable line(s) for the caller to LOG. No I/O here - the engine stays pure. When raw
         *  samples exist, a second `skin-temp-raw:` line surfaces the ADC band + resolved anchor mapping. */
        val summary: String
            get() {
                var s = "skin-temp-funnel: $totalSamples samples → kept $kept/$minSamples " +
                    "(mean=${mean?.let { String.format(java.util.Locale.US, "%.2f°C", it) } ?: "absent"}); " +
                    "dropped[notWorn=$droppedNotWorn, outOfWindow=$droppedOutOfWindow, " +
                    "outOfRange=$droppedOutOfRange]"
                if (rawMin != null && rawMedian != null && rawMax != null) {
                    s += "\nskin-temp-raw: raw[min=$rawMin p50=$rawMedian max=$rawMax] inBand=$inBandCount/$totalSamples"
                    if (resolvedAnchorRaw != null && medianMappedC != null) {
                        s += String.format(
                            java.util.Locale.US,
                            "; anchor=%.0f → p50 maps %.1f°C (worn gate 28–42°C, ADC band 550–2040)",
                            resolvedAnchorRaw, medianMappedC,
                        )
                    }
                }
                return s
            }
    }

    /**
     * Read-only skin-temp funnel for one night (#752). Re-runs the SAME wear/window/range gates
     * [wornNightlySkinTempC] uses (and produces the IDENTICAL mean), additionally counting where each
     * sample dropped, so an absent skin temp is self-explaining. [wornNightlySkinTempC] is a thin wrapper
     * over this, so the two can never disagree. Pure + deterministic. Mirrors Swift `skinTempFunnel`. (#752)
     */
    fun skinTempFunnel(
        sessions: List<DetectedSleep>,
        hr: List<HrSample>,
        skinTemp: List<SkinTempSample>,
        family: DeviceFamily = DeviceFamily.WHOOP5,
        // Per-device WHOOP 4.0 worn anchor raw (#938 second capture); null → the global
        // Whoop4SkinTemp.ANCHOR_RAW, so 5/MG + pure-function callers are byte-identical.
        anchorRaw: Double? = null,
        minSamples: Int = MIN_SKIN_TEMP_SAMPLES_INLINE,
    ): SkinTempFunnelDiagnostic {
        val total = skinTemp.size
        // #skin-diag: raw-ADC band + resolved anchor — PURE observation of the input, computed once and
        // reported on both return paths. Never touches the mean/gate logic below (byte-parity preserved).
        val sortedRaws = skinTemp.map { it.raw }.sorted()
        val rawMin = sortedRaws.firstOrNull()
        val rawMax = sortedRaws.lastOrNull()
        val rawMedian = if (sortedRaws.isEmpty()) null else sortedRaws[sortedRaws.size / 2]
        val inBandCount = if (family == DeviceFamily.WHOOP4) {
            sortedRaws.count { it in Whoop4SkinTemp.WORN_MIN_RAW..Whoop4SkinTemp.WORN_MAX_RAW }
        } else {
            total
        }
        val usedAnchor: Double? = if (family == DeviceFamily.WHOOP4) (anchorRaw ?: Whoop4SkinTemp.ANCHOR_RAW) else null
        val medianMappedC: Double? = if (usedAnchor != null && rawMedian != null) {
            skinTempCelsius(rawMedian, family, usedAnchor)
        } else {
            null
        }
        // No sessions ⇒ every sample is out of window; no samples ⇒ an empty funnel. Either way the mean is
        // null, exactly as [wornNightlySkinTempC]'s early return produced before.
        if (sessions.isEmpty() || skinTemp.isEmpty()) {
            return SkinTempFunnelDiagnostic(
                totalSamples = total, droppedNotWorn = 0,
                droppedOutOfWindow = if (sessions.isEmpty()) total else 0,
                droppedOutOfRange = 0, kept = 0, minSamples = minSamples, mean = null,
                rawMin = rawMin, rawMedian = rawMedian, rawMax = rawMax,
                inBandCount = inBandCount, resolvedAnchorRaw = usedAnchor, medianMappedC = medianMappedC,
            )
        }
        val wornSeconds = HashSet<Long>(hr.size)
        for (h in hr) if (h.bpm in 30..220) wornSeconds.add(h.ts)
        var sum = 0.0
        var kept = 0
        var notWorn = 0
        var outOfWindow = 0
        var outOfRange = 0
        for (t in skinTemp) {
            if (t.ts !in wornSeconds) { notWorn++; continue }
            if (sessions.none { t.ts in it.start..it.end }) { outOfWindow++; continue }
            // WHOOP 4.0 ONLY (#938 second capture): drop raws outside the plausible worn ADC band BEFORE the
            // anchor map. The no-contact floor (~509) and the 11-bit saturation ceiling (2047) are doff /
            // charging transients, not worn skin — with a per-device anchor a floor or pegged raw could
            // otherwise map into the 28–42 °C window and poison the mean. Attributed to the SAME `outOfRange`
            // bucket the °C gate uses ("out of plausible range"), so the four drop buckets + kept still sum to
            // totalSamples. WHOOP5 is untouched here → its centidegree path stays byte-identical.
            if (family == DeviceFamily.WHOOP4 &&
                t.raw !in Whoop4SkinTemp.WORN_MIN_RAW..Whoop4SkinTemp.WORN_MAX_RAW
            ) { outOfRange++; continue }
            // Per-device anchor (#938): null anchorRaw → the global Whoop4SkinTemp.ANCHOR_RAW (826), byte-
            // identical to the pre-change conversion; WHOOP5 ignores the anchor.
            val c = skinTempCelsius(t.raw, family, anchorRaw ?: Whoop4SkinTemp.ANCHOR_RAW)
            if (c < SKIN_TEMP_MIN_C || c > SKIN_TEMP_MAX_C) { outOfRange++; continue }
            sum += c
            kept++
        }
        val mean = if (kept >= minSamples) sum / kept else null
        return SkinTempFunnelDiagnostic(
            totalSamples = total, droppedNotWorn = notWorn, droppedOutOfWindow = outOfWindow,
            droppedOutOfRange = outOfRange, kept = kept, minSamples = minSamples, mean = mean,
            rawMin = rawMin, rawMedian = rawMedian, rawMax = rawMax,
            inBandCount = inBandCount, resolvedAnchorRaw = usedAnchor, medianMappedC = medianMappedC,
        )
    }
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
     * Sleep & Rest test-mode (E11) diagnostic line for the Rest composite. Recomputes the four weighted
     * sub-scores from the SAME inputs `rest()` reads (on the 0..1 scale, byte-aligned with the Swift
     * `Rest.subScoreLine`), and reuses `rest()` for the final `composite=` value so the trace can never
     * disagree with the score. `groupFragments` / `groupInBedSeconds` describe the main-night GROUP
     * composition (#525/#561). Pure, side-effect-free, no em-dashes. Mirrors Swift exactly.
     */
    /**
     * #319 diagnostic (Sleep & Rest test mode): the motion-coverage + staging context behind the Rest
     * number, so a high score on a poor night can be explained straight from an export. `grav`/`hr` are the
     * night-window sample counts; `sparse` is the gravity-sparse gate (WHOOP 4.0 banks motion coarsely, so
     * most epochs default to sleep → over-counted duration → high Rest); `stager` says which engine ran;
     * `family` the day's owner. Pure, no em-dashes; byte-identical to Swift `AnalyticsEngine.sleepMotionLine`.
     */
    fun sleepMotionLine(
        day: String, grav: Int, hr: Int, sparse: Boolean, useSleepStagerV2: Boolean, family: DeviceFamily,
    ): String = "sleep-motion day=$day grav=$grav hr=$hr sparse=$sparse " +
        "stager=${if (useSleepStagerV2) "V2" else "V1"} family=${family.name.lowercase()}"

    /**
     * How long AFTER the detected onset to sample HR for the #271 onset trace (seconds). The first several
     * minutes of the window: if onset opened on a still-but-awake stretch, HR here is still near baseline; a
     * real onset has already dipped. 10 min is long enough to average out beat noise. Long for `ts` math.
     */
    const val onsetTraceWindowSec: Long = 600L

    /**
     * Median of a bpm list — the deterministic "sorted, element at size/2" rule (upper-middle on an even
     * count) so Swift and Kotlin agree byte-for-byte. null on an empty list. Byte-identical to Swift
     * `AnalyticsEngine.medianBpm`.
     */
    fun medianBpm(bpms: List<Int>): Int? {
        if (bpms.isEmpty()) return null
        val s = bpms.sorted()
        return s[s.size / 2]
    }

    /**
     * #271 diagnostic (Sleep & Rest test mode): the ONSET decision behind an over-early WHOOP 4.0 bedtime.
     * `onsetTs` is where the detected window OPENED; `hrAtOnsetBpm` is the median HR in the first
     * `onsetTraceWindowSec` of it; `baselineHrBpm` is the day's median HR. `hrRatio` = atOnset / baseline:
     * near 1.0 means HR had NOT dipped when the window opened — the pre-onset-awake over-staging this tracks
     * (sparse 4.0 motion classifies "lying still, awake" as sleep); a real onset dips well below baseline
     * (cf. the wake-side `morningReonsetRestingHRMult` = 0.90). Byte-identical to Swift `sleepOnsetLine`.
     */
    fun sleepOnsetLine(onsetTs: Long, hrAtOnsetBpm: Int, baselineHrBpm: Int): String {
        val ratio = if (baselineHrBpm > 0) hrAtOnsetBpm.toDouble() / baselineHrBpm.toDouble() else 0.0
        val r2 = Math.round(ratio * 100.0) / 100.0
        return "sleep-onset onsetTs=$onsetTs hrAtOnset=$hrAtOnsetBpm baselineHr=$baselineHrBpm hrRatio=$r2"
    }

    @Suppress("UNUSED_PARAMETER") // inBedSeconds mirrors the Swift subScoreLine signature (parity)
    fun subScoreLine(
        tstSeconds: Double, inBedSeconds: Double, efficiency: Double, restorativeSeconds: Double,
        needHours: Double, consistency: Double?, deepSeconds: Double?,
        groupFragments: Int, groupInBedSeconds: Double,
    ): String {
        fun clamp01(x: Double) = maxOf(0.0, minOf(1.0, x))
        fun r2(x: Double) = Math.round(x * 100.0) / 100.0
        val needSeconds = maxOf(needHours, 0.1) * 3600.0
        val durationScore = clamp01(tstSeconds / needSeconds)
        val efficiencyScore = clamp01(efficiency)
        val deepFactor = if (deepSeconds != null && tstSeconds > 0 && deepShareTarget > 0) {
            val adequacy = clamp01((deepSeconds / tstSeconds) / deepShareTarget)
            deepFloorFactor + (1.0 - deepFloorFactor) * adequacy
        } else 1.0
        val restorativeScore = if (tstSeconds > 0)
            clamp01((restorativeSeconds / tstSeconds) / restorativeTargetShare) * deepFactor else 0.0
        val consistencyScore = clamp01(consistency ?: NEUTRAL_CONSISTENCY)
        // Reuse the real scorer for the composite (cannot diverge). `rest()` takes deep + REM separately;
        // restorative = deep + REM, so REM = restorative - deep. null deep -> 0 deep (no-adequacy path).
        val composite = rest(
            asleepSeconds = tstSeconds, efficiency = efficiency,
            deepSeconds = deepSeconds ?: 0.0,
            remSeconds = restorativeSeconds - (deepSeconds ?: 0.0),
            sleepNeedHours = needHours, consistency = consistency,
        ) ?: 0.0
        return "rest composite=${r2(composite)} " +
            "dur=${r2(durationScore)}*wDur=$wDuration " +
            "eff=${r2(efficiencyScore)}*wEff=$wEfficiency " +
            "restor=${r2(restorativeScore)}*wRestor=$wRestorative deepFactor=${r2(deepFactor)} " +
            "consist=${r2(consistencyScore)}*wConsist=$wConsistency " +
            "group=$groupFragments groupInBedMin=${(groupInBedSeconds / 60).toInt()}"
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
