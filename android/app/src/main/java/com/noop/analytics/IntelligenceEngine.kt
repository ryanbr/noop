package com.noop.analytics

import java.util.Locale
import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.ScoreInputProvenanceRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Whoop4SkinTemp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/*
 * IntelligenceEngine.kt , on-device "intelligence": computes recovery / day-strain /
 * sleep from the raw strap streams using the same model shape WHOOP uses (HRV vs
 * personal baseline ~60%, resting HR ~20%, sleep ~15%, respiration ~5%; strain 0–21
 * from cardiovascular load).
 *
 * Faithful Kotlin port of Strand/Data/IntelligenceEngine.swift (verified on macOS).
 * Same windows, same thresholds, same persistence model:
 *   - For each recent day with >= MIN_HR_SAMPLES (200) HR samples, read a generous
 *     window of raw streams from the imported source ("my-whoop"), run
 *     AnalyticsEngine.analyzeDay against baselines folded from repo.days, and PERSIST
 *     the DailyMetric + sleep sessions under "<deviceId>-noop" (the computed source).
 *   - The repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP
 *     import always wins; this only fills the days the strap collected but no import
 *     covered.
 *
 * This is what makes NOOP independent of WHOOP's cloud , for any day the strap
 * collected raw data with NOOP connected, NOOP scores it itself rather than relying on
 * the values WHOOP computed in the imported CSV.
 *
 * Stateless object (no ObservableObject equivalent here): the Compose layer observes
 * the repository's reactive day flow, so this engine just computes + persists, then the
 * caller (AppViewModel) lets the flow refresh the UI. All `ts` are unix SECONDS (Long).
 */
object IntelligenceEngine {

    /**
     * Serialises [analyzeRecent] against itself. The pass is launched from four independent coroutines: the
     * 15-min backstop loop and rescoreAfterEdit (both AppViewModel), the post-offload analyze
     * (WhoopBleClient), plus the one-shot Effort rescore ([runEffortRescoreIfNeeded]). These can overlap:
     * two parallel 21-night passes double the CPU/battery AND race the #899 self-heal, whose concurrent
     * overlapping-session deletes can pick different survivors. This mirrors the intent of the Swift
     * `computing` guard, but SERIALISES rather than coalesces on purpose: Android's callers pass
     * heterogeneous windows , the Effort rescore uses maxDays=4000, not 21, and can overlap the *independent*
     * BLE-offload analyze. A drop-guard would skip that full-history rescore while its unconditional flagSet
     * marks it permanently done, and would re-run the holder's 21-day window in its place. withLock lets
     * every caller run its OWN pass, queued and never parallel, so nothing is dropped and no window is
     * silently lost. Suspending (not thread-blocking) and cancellation-cooperative, matching the callers'
     * #125 CancellationException handling. No re-entrancy: nothing analyzeRecent calls re-enters it
     * ([runEffortRescoreIfNeeded] delegates to analyzeRecent and does NOT take the lock itself, so the
     * Mutex is acquired exactly once per Effort pass, never nested).
     */
    private val analyzeGate = Mutex()

    /**
     * Per-day owner resolution source (invariant I2 , a day's scores come from exactly ONE device).
     * Pure abstraction so [analyzeRecent] resolves the owning device without taking an Android Context
     * or a Room dependency (mirrors how the engine already stays pure-JVM testable). A null source
     * (the default) preserves the legacy single-source path BYTE-FOR-BYTE: every day reads from
     * [importedDeviceId]. A DeviceRegistry-backed implementation lives in the app layer and is passed
     * in by the UI scoring pass. Mirrors the Swift IntelligenceEngine.resolveDayOwner read-through (1B-4).
     */
    interface DayOwnerSource {
        /** Non-archived paired devices, each as a [DayOwnerResolver.Candidate] WITHOUT its hasData flag
         *  resolved yet (priority only: 0 = active strap, 1 = other live straps, 2 = imports). */
        suspend fun candidatePriorities(): List<Pair<String, Int>>

        /** A locked owner override for [day] from the dayOwnership table, or null. Wins outright. */
        suspend fun lockedOwner(day: String): String?

        /** The registry's currently-active strap id (CAPTURE-B universal `writeActiveId`). The default
         *  returns null so legacy/test sources are unaffected; [RegistryDayOwnerSource] supplies the real
         *  active id so the universal dayOwner diagnostic can name where new data is being WRITTEN, which
         *  is the read-vs-write mismatch the #814/#799 spine bug was about. */
        suspend fun activeWriteId(): String? = null

        /** The strap family that wrote [deviceId]'s rows (#938), so the nightly skin-temp funnel converts
         *  the raw register on the right scale (5/MG centidegrees vs a WHOOP 4.0 v24 raw ADC). The default
         *  returns WHOOP5 (the prior /100 behaviour), so legacy/test sources are byte-identical;
         *  [RegistryDayOwnerSource] resolves a positively-identified 4.0 to WHOOP4. */
        suspend fun skinTempFamily(deviceId: String): DeviceFamily = DeviceFamily.WHOOP5
    }

    /** Minimum HR samples in a day's window before it is worth scoring. */
    const val MIN_HR_SAMPLES: Int = 200

    /** Read cap per stream read , matches the Swift 200_000 bound. */
    const val STREAM_LIMIT: Int = 200_000

    private const val SECONDS_PER_DAY: Long = 86_400L

    /** Imported wearable-export source ids whose DAILY aggregates can be scored for a NOOP Charge/Rest on
     *  an import-only day (#823). Matches WearableExportImporter.Brand.deviceId. Mirrors the Swift
     *  Repository.wearableImportSources. */
    private val WEARABLE_IMPORT_SOURCES = listOf("oura-import", "fitbit-import", "garmin-import")

    /** CAPTURE-B: a day's resolved read owner + the HR-row count read for it, captured in pass 1 and
     *  consumed by pass 2's universal dayOwner emit. */
    private data class OwnerRead(val owner: String, val hrRows: Int)

    /** Summary of one scored day (for logging / a future on-device intelligence screen). */
    data class Computed(
        val day: String,
        val recovery: Double?,
        val strain: Double?,
        val sleepMin: Double?,
        val hrv: Double?,
        val rhr: Int?,
    )

    /**
     * Compute on-device scores for each of the last [maxDays] that actually has raw HR
     * data, persisting them under the computed "<importedDeviceId>-noop" source.
     *
     * Personal baselines (HRV / resting HR) are folded from the imported nightly history
     * (via [WhoopRepository.days]), so even the first live night can be scored against
     * the user's norm.
     *
     * @param repo the local store.
     * @param profile body profile (age/sex/weight/height + HRmax override) for HRmax,
     *   zones, calories. Defaults to a neutral [UserProfile] when the caller has none.
     * @param maxDays number of trailing days to consider (default 21).
     * @param importedDeviceId the source id the raw strap data is stored under
     *   ("my-whoop"). Computed scores are written under "<importedDeviceId>-noop".
     * @param maxHROverride explicit HRmax (bpm); null → Tanaka from profile.age.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests/determinism.
     * @return the per-day [Computed] summaries (newest first), mirroring the Swift `out`.
     */
    /**
     * Public entry: hop OFF the caller's thread before the CPU-heavy scoring. The AppViewModel 15-min
     * loop launches from viewModelScope (Dispatchers.Main), so without this hop the whole pass —
     * SleepStager / StrainScorer over up to 21 nights of 1 Hz data , ran on the MAIN THREAD and
     * ANR-killed the app once a few nights had accumulated. Dispatchers.Default is the CPU pool; Room's
     * suspend DAO calls are main-safe under any dispatcher. (#125)
     */
    suspend fun analyzeRecent(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        maxDays: Int = 21,
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
        ownerSource: DayOwnerSource? = null,
        // Steps-estimate calibration I/O (kept pure-JVM, mirroring the Effort-rescore flagGet/flagSet):
        // [manualStepCoefficient] is the user's persisted manual override (null/0 = auto-fit), fed into
        // StepsEstimateEngine.calibrate. [persistStepsCalibration] receives the fitted (or manual) model
        // each pass so the caller (AppViewModel) can mirror it into ProfileStore for the Settings/Steps
        // screen. Both default to no-op so existing callers / tests are unaffected.
        manualStepCoefficient: Double? = null,
        persistStepsCalibration: (StepsEstimateEngine.Calibration) -> Unit = {},
        // Manual "Recalibrate baseline" anchor (noop.hrvBaselineEpoch, epoch SECONDS; 0 = none). The
        // analytics layer is Context-free, so the caller reads it from SharedPreferences and passes it
        // down to the HRV foldHistory. Default 0.0 → no recalibration, so other callers are unaffected.
        baselineEpoch: Double = 0.0,
        // The Charge-wide recalibration anchor (noop.recoveryBaselineEpoch); re-anchors resting HR / resp /
        // skin-temp the same way baselineEpoch re-anchors HRV, so a manual Recalibrate restarts all of
        // Charge. Read from SharedPreferences by the caller. Default 0.0 → no recalibration.
        recoveryEpoch: Double = 0.0,
        // Per-day scoring diagnostic sink (Sleep overhaul §2.5). Each scored day emits ONE concise,
        // privacy-safe line ("sleep day=… totalSleepMin=… matched=… source=…") so a shared strap log
        // ships PROOF of what was computed per day , the project's log-failures-not-successes blind spot,
        // and the data to settle "Rest repeats across days". Defaults to no-op so tests / other callers
        // are unaffected; the AppViewModel wires it to the BLE client's strap log (ble.externalLog),
        // which PII-scrubs every line at the sink. Pure-JVM (a closure), matching persistStepsCalibration.
        diag: (String) -> Unit = {},
        // "Experimental sleep staging (V2)" flag (Settings → Experimental · Sleep staging). The analytics
        // layer is Context-free, so the Context-aware caller (AppViewModel / WhoopBleClient) reads it off
        // SharedPreferences (PuffinExperiment.experimentalSleepV2) and threads it down to the sleep
        // self-heal, which re-stages with SleepStagerV2 when true.
        // The stored preference is default TRUE (getBoolean(KEY, true)) — V2 was promoted over V1 in #277
        // and extended to every strap family in #351 — so the SHIPPED app stages with V2. This PARAMETER
        // defaults false only so existing callers / tests are unaffected; it is not the product default.
        // (V7 Pillar 3b)
        useExperimentalSleepV2: Boolean = false,
        // Opt-in "Motion-aware wake refinement" flag (#364 "Proposal 2" follow-up; density gate precedent
        // #345). Same Context-free threading as [useExperimentalSleepV2]: the Context-aware caller reads
        // PuffinExperiment.from(context).motionAwareWake and passes it down to AnalyticsEngine.analyzeDay
        // and the sleep self-heal. Default false, and even when true the pass self-gates on the night's
        // OWN observed gravity + step density (see [WakeMotionRefinement]), so existing callers / tests
        // and any night too sparse to trust (e.g. a WHOOP 4.0) are unaffected either way.
        useMotionAwareWake: Boolean = false,
        // Sleep & Rest test-mode trace sink (Test Centre E5). The analytics layer is Context-free, so the
        // Context-aware caller (AppViewModel / WhoopBleClient) reads TestCentre.active(SLEEP) and passes a
        // non-null sink ONLY when the mode is on, routing each line to the .sleep-tagged strap log. null (the
        // default) = byte-identical default path , analyzeDay then runs its untraced staging. Mirrors the
        // Swift sleepTraceActive wiring in IntelligenceEngine.swift.
        sleepTraceSink: ((String) -> Unit)? = null,
        // Recovery (Charge) test-mode trace sink (Test Centre Group G). The analytics layer is Context-free,
        // so the Context-aware caller (AppViewModel / WhoopBleClient) reads TestCentre.active(RECOVERY) and
        // passes a non-null sink ONLY when the mode is on, routing each Charge term-breakdown line to the
        // .recovery-tagged strap log. null (the default) = byte-identical default path; the Charge score is
        // unchanged because the trace reuses RecoveryScorer.recovery verbatim. Mirrors the Swift
        // recoveryTraceActive wiring in IntelligenceEngine.swift.
        recoveryTraceSink: ((String) -> Unit)? = null,
        // Steps test-mode trace sink (Test Centre). The analytics layer is Context-free, so the Context-aware
        // caller (AppViewModel / WhoopBleClient) reads TestCentre.active(STEPS) and passes a non-null sink ONLY
        // when the mode is on, routing each line to the .steps-tagged strap log. null (the default) =
        // byte-identical default path: the trace recomputes the SAME wrap-aware @57 sum analyzeDay already did,
        // and reuses StepsEstimateEngine.calibrate/estimate verbatim, so the steps total is unchanged. Mirrors
        // the Swift stepsTraceActive wiring.
        stepsTraceSink: ((String) -> Unit)? = null,
        // CAPTURE-B universal diagnostic sink (Test Centre, domain .universal). When non-null, EACH scored
        // day emits one verbatim `dayOwner day=… readId=… writeActiveId=… hrRows=… provenance=…` line so
        // EVERY Test Centre export self-diagnoses the read-vs-write identity and the day's data provenance,
        // byte-identical to the iOS lanes' format. null (the default) = zero lines, byte-identical default
        // path. The Context-aware caller (AppViewModel) reads TestCentre.active(UNIVERSAL) and passes a
        // non-null sink ONLY when any test mode is on, routing each line to the .universal-tagged strap log.
        universalSink: ((String) -> Unit)? = null,
        // Workouts & GPS test-mode trace sink (Test Centre, #975). Context-free layer, so the caller reads
        // TestCentre.active(WORKOUTS) and passes a non-null sink ONLY when the mode is on, routing each
        // detected-bout persist/drop decision to the .workouts-tagged strap log. null (the default) =
        // byte-identical default path (no lines). Mirrors the Swift workoutsTraceActive wiring.
        workoutsTraceSink: ((String) -> Unit)? = null,
        // HRV & Autonomic test-mode sink (#141). Context-free layer, so the caller reads TestCentre.active(HRV)
        // and passes a non-null sink ONLY when the mode is on, routing the nightly per-5-min-window RMSSD (by
        // sleep stage) + the whole-night/deep-only/last-SWS summary to the .hrv-tagged strap log. null (the
        // default) = byte-identical default path (no lines). Mirrors the Swift hrvTraceActive wiring.
        hrvTraceSink: ((String) -> Unit)? = null,
        // #141: nightly HRV over DEEP-sleep windows only (WHOOP-style) when true; whole-night mean (the
        // historical default) when false. The Context-aware caller reads UnitPrefs.hrvWindow and passes it.
        deepHrvWindow: Boolean = false,
        // #103: SpO₂ candidate @82 display toggle. When ON, the nightly `spo2_candidate_82` mean is
        // computed from the V18AuxSample stream and persisted as "spo2_candidate" in metricSeries so the
        // Blood Oxygen tile can surface it as a "strap estimate (unverified)" fallback. Display-only.
        // The Context-aware caller reads NoopPrefs.spo2CandidateDisplay(context) and passes it down.
        spo2CandidateDisplay: Boolean = false,
    ): List<Computed> = withContext(Dispatchers.Default) {
        // #1005: time the whole pass so a re-score STORM is visible in the strap log (the trigger lines
        // record WHY each pass runs; this records how many nights and how long — the CPU cost per run).
        val reScoreStart = System.nanoTime()
        // Serialise the whole pass so overlapping callers never run two rescores in parallel (see
        // [analyzeGate]). The heavy scoring already ran off the caller's thread via withContext above; the
        // lock is held only for this engine's own passes, never across an unrelated suspension.
        val scored = analyzeGate.withLock {
            val (out, healed) = analyzeRecentOnCpu(repo, profile, maxDays, importedDeviceId, maxHROverride,
                nowSeconds, ownerSource, manualStepCoefficient, persistStepsCalibration, baselineEpoch,
                recoveryEpoch, diag, useExperimentalSleepV2, useMotionAwareWake, sleepTraceSink, recoveryTraceSink,
                stepsTraceSink, universalSink, workoutsTraceSink, hrvTraceSink, deepHrvWindow, spo2CandidateDisplay)
            if (healed == 0) out
            // #899 heal re-pass: the pass above deleted overlapping duplicate sleep sessions AFTER its days
            // were scored, and the read-side dedup those days consumed had no bank-recency witness (the fresh
            // detections weren't banked yet), so its survivor can differ from the heal's. ONE bounded re-pass
            // re-scores the window against the cleaned store; its own heal then finds nothing (the duplicates
            // are gone), so this can never loop. Mirrors the Swift pendingForcedRescore re-arm.
            else analyzeRecentOnCpu(repo, profile, maxDays, importedDeviceId, maxHROverride,
                nowSeconds, ownerSource, manualStepCoefficient, persistStepsCalibration, baselineEpoch,
                recoveryEpoch, diag, useExperimentalSleepV2, useMotionAwareWake, sleepTraceSink, recoveryTraceSink,
                stepsTraceSink, universalSink, workoutsTraceSink, hrvTraceSink, deepHrvWindow, spo2CandidateDisplay).first
        }
        diag("re-score: done — scored ${scored.size} night(s) in ${(System.nanoTime() - reScoreStart) / 1_000_000} ms (#1005)")
        scored
    }

    /** History span for the one-shot Effort rescore , large enough to cover any real wear history,
     *  matching the Swift `historyDays` default. */
    const val EFFORT_RESCORE_HISTORY_DAYS: Int = 4000

    /**
     * One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
     * moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.0 already
     * store 0–100, but rows the engine computed on an OLDER build (capped at [maxDays] per run, so deep
     * history was never revisited) may still hold 0–21 strain.
     *
     * The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR , those regenerate at
     * 0–100 with NO double-rescale risk , rather than a blind `strain*100/21` multiply that would
     * double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
     * [analyzeRecent] once with the [maxDays] cap lifted to the full history, then persist a flag (via the
     * injected [flagGet]/[flagSet]) so it runs exactly once. IMPORTED rows are never rewritten here (the
     * engine only ever writes under the "-noop" computed source) , those are handled by re-import. A day
     * already on 0–100 is recomputed from the same raw HR and lands on 0–100 again: UNCHANGED axis.
     *
     * The flag get/set are passed in so this stays a pure-JVM analytics object (no Android Context). The
     * caller (AppViewModel) wires them to [com.noop.ui.NoopPrefs]. Mirrors Swift
     * IntelligenceEngine.runEffortRescoreIfNeeded.
     */
    suspend fun runEffortRescoreIfNeeded(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        flagGet: () -> Boolean,
        flagSet: () -> Unit,
        historyDays: Int = EFFORT_RESCORE_HISTORY_DAYS,
    ) {
        if (flagGet()) return
        analyzeRecent(
            repo = repo,
            profile = profile,
            maxDays = historyDays,
            importedDeviceId = importedDeviceId,
            maxHROverride = maxHROverride,
        )
        flagSet()
    }

    private suspend fun analyzeRecentOnCpu(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        maxDays: Int = 21,
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
        ownerSource: DayOwnerSource? = null,
        manualStepCoefficient: Double? = null,
        persistStepsCalibration: (StepsEstimateEngine.Calibration) -> Unit = {},
        baselineEpoch: Double = 0.0,
        recoveryEpoch: Double = 0.0,
        diag: (String) -> Unit = {},
        // Experimental staging (V2), threaded down to the sleep self-heal. This PARAMETER defaults false so
        // existing callers / tests are unaffected; the STORED PREFERENCE the app threads in is default TRUE,
        // so the shipped app stages with V2. Not the same default — see [analyzeRecent]'s note. (3b)
        useExperimentalSleepV2: Boolean = false,
        // Opt-in motion-aware wake refinement (#364 follow-up), threaded the same way. Default false.
        useMotionAwareWake: Boolean = false,
        // Sleep & Rest test-mode trace sink (Test Centre E5). null = byte-identical default; when non-null
        // each scored day threads it into AnalyticsEngine.analyzeDay so detectSleep's gate trace + the Rest
        // sub-score line forward line-by-line to the .sleep-tagged strap log. Mirrors Swift.
        sleepTraceSink: ((String) -> Unit)? = null,
        // Recovery (Charge) test-mode trace sink (Test Centre Group G). null = byte-identical default; when
        // non-null each scored night emits its Charge term-breakdown to the .recovery-tagged strap log via
        // RecoveryScorerTrace.recoveryTrace, whose score is RecoveryScorer.recovery verbatim. Mirrors Swift.
        recoveryTraceSink: ((String) -> Unit)? = null,
        // Steps test-mode trace sink (Test Centre). null = byte-identical default; when non-null each scored
        // day emits its 5/MG raw-counter trace and (after the fit) the WHOOP-4 calibration trace to the
        // .steps-tagged strap log. The trace recomputes the SAME wrap-aware sum + reuses calibrate verbatim,
        // so the steps total is unchanged. Mirrors Swift.
        stepsTraceSink: ((String) -> Unit)? = null,
        // CAPTURE-B universal diagnostic sink. null = byte-identical default (no lines); when non-null each
        // scored day emits the verbatim `dayOwner …` line. See the public overload's doc.
        universalSink: ((String) -> Unit)? = null,
        // Workouts & GPS test-mode trace sink (#975). null = byte-identical default (no lines); when non-null
        // each detected bout emits a `detectedBout verdict=persisted|droppedOverlap …` line to the .workouts-
        // tagged strap log, so an "auto workout appeared then vanished" is explainable from an export. Swift twin.
        workoutsTraceSink: ((String) -> Unit)? = null,
        // HRV & Autonomic test-mode sink (#141). null = byte-identical default (no lines); when non-null,
        // analyzeDay forwards the nightly per-window RMSSD (by stage) + the whole-night/deep-only/last-SWS
        // summary to the .hrv-tagged strap log. Swift twin.
        hrvTraceSink: ((String) -> Unit)? = null,
        // #141: nightly HRV over DEEP-sleep windows only (WHOOP-style) when true; whole-night default when
        // false. Threaded into analyzeDay per scored night.
        deepHrvWindow: Boolean = false,
        // #103: SpO₂ candidate @82 display toggle. When ON, the nightly candidate mean is computed and
        // persisted as "spo2_candidate" in metricSeries. Default false — the @82 candidate has split
        // cross-device evidence and ships behind a default-off toggle (CLAUDE.md derived-biosignal rule).
        spo2CandidateDisplay: Boolean = false,
        // #899 heal re-pass: the second component of the return is how many overlapping duplicate sleep
        // sessions the heal below deleted this pass. The public wrapper re-runs ONCE when it is non-zero
        // so the affected days re-score against the cleaned store.
    ): Pair<List<Computed>, Int> {
        val hrvCfg = Baselines.metricCfg["hrv"] ?: return emptyList<Computed>() to 0
        val rhrCfg = Baselines.metricCfg["resting_hr"] ?: return emptyList<Computed>() to 0
        val skinCfg = Baselines.metricCfg["skin_temp"] ?: return emptyList<Computed>() to 0
        val respCfg = Baselines.metricCfg["resp"] ?: return emptyList<Computed>() to 0

        val computedId = importedDeviceId + "-noop"

        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock so
        // only genuinely-daytime windows face the stricter nap bar. getOffset(nowMillis) folds in
        // the current DST state (a DST boundary inside a single window is a negligible edge case
        // for an hour-of-day band). Computed once per run.
        val tzOffsetSeconds =
            java.util.TimeZone.getDefault().getOffset(nowSeconds * 1_000L) / 1_000L

        // Device-registry snapshot for per-day owner resolution (invariant I2 , a day's scores come from
        // exactly ONE source). Read ONCE before the loop: the paired-device list is stable for the run.
        // With only the seeded 'my-whoop' row paired (the default and every single-WHOOP install) the
        // active strap == [importedDeviceId], so [resolveDayOwner] returns [importedDeviceId] for every
        // day and the per-day reads are BYTE-IDENTICAL to the pre-I2 path. A null [ownerSource] (the
        // default, e.g. the backfill-triggered pass) skips resolution entirely. Mirrors the Swift
        // IntelligenceEngine.analyzeRecent registry snapshot + resolveDayOwner. (1B-4)
        val candidatePriorities = ownerSource?.candidatePriorities().orEmpty()

        // CAPTURE-B: the registry's active strap id (the universal `writeActiveId`). Resolved ONCE; falls
        // back to [importedDeviceId] so a single-WHOOP install (or a null/legacy ownerSource) names the same
        // id the read path resolves to, and the universal line proves read == write rather than diverging.
        val activeWriteId = (universalSink?.let { ownerSource?.activeWriteId() }) ?: importedDeviceId

        // ── Pass 1: detect + aggregate each offloaded night, scoring against the
        // imported-only baseline. For a BLE-only user repo.days(importedDeviceId) is
        // empty, so the HRV baseline is NOT usable and res.recovery is null here , but
        // the per-night avgHrv/restingHr are computed WITHOUT any baseline dependency
        // (SleepStager + AnalyticsEngine), so we harvest them to SEED the baseline and
        // re-score in pass 2. Collected oldest-first to match foldHistory's replay order.
        // foldHistory winsorizes outliers. days() is oldest-first (Swift ascending).
        val hist = repo.days(importedDeviceId)
        // CAPTURE-B: per-day resolved read owner + HR-row count, captured in pass 1, consumed by pass 2's
        // universal dayOwner emit (which reuses the SAME importedWhoopDays / appleHealthDays sets pass 2
        // builds for daySourceToken, so there is no extra read). Only populated when the universal sink is
        // on. Keyed by the local day.
        val readOwnerByDay = LinkedHashMap<String, OwnerRead>()
        val resolvedScoreOwnerByDay = LinkedHashMap<String, String>()
        // HRV baseline honours the manual "Recalibrate baseline" epoch (noop.hrvBaselineEpoch): pass the
        // per-value "yyyy-MM-dd" day keys (parallel to the values) so foldHistory drops every night before
        // the epoch. baselineEpoch is threaded down from the Context-aware caller (0.0 = no recalibration).
        // rhr/resp/skin stay on the 2-arg fold , recalibration is HRV-only.
        val hrvBase1 = Baselines.foldHistory(hist.map { it.avgHrv }, hist.map { it.day }, hrvCfg, baselineEpoch)
        val rhrBase1 = Baselines.foldHistory(hist.map { it.restingHr?.toDouble() }, hist.map { it.day }, rhrCfg, recoveryEpoch)
        val baselines1 = ProfileBaselines(hrv = hrvBase1, restingHR = rhrBase1)

        // Keep each night's small DayResult (daily metrics + detected sessions), NOT the raw
        // streams: every field except recovery is baseline-independent, so pass 2 only re-scores
        // the cheap recovery composite. The raw hr/rr/... lists are freed after each analyzeDay,
        // keeping memory bounded over a full multi-night offload history.
        val scoredNights = ArrayList<DayResult>()
        // #103: SpO₂ candidate @82 nightly mean per day, carried from pass 1 for metricSeries persistence.
        val spo2CandidateByDay = LinkedHashMap<String, Int>()
        // #1118: per-day HRV over-count flag, carried for metricSeries persistence. Absent for a night with
        // no in-sleep R-R (no HRV to caveat); otherwise true/false, so a re-score always overwrites the row.
        val hrvOverCountByDay = LinkedHashMap<String, Boolean>()
        // #1169: primary-session mean RHR shadow metric per day, carried from pass 1 for persistence.
        val primarySessionRHRByDay = LinkedHashMap<String, Double>()
        // #1169: its coverage inputs (valid-sample count + primary-session duration), same lifetime as the mean.
        val primarySessionRHRCoverageByDay = LinkedHashMap<String, PrimarySessionRestingHR.Coverage>()

        // In-memory nightly values harvested in pass 1, used to seed the pass-2 baseline.
        // Keyed by day so the union with imported history de-dupes cleanly per UTC day.
        val nightlyHrvByDay = LinkedHashMap<String, Double?>()
        val nightlyRhrByDay = LinkedHashMap<String, Double?>()
        // Wear-gated nightly skin-temp means (on-device only , imported rows carry the deviation, not
        // the raw mean, so the skin-temp baseline is seeded purely from these). (PR #85)
        val nightlySkinByDay = LinkedHashMap<String, Double?>()
        // On-device RSA respiration estimates, unioned with imported respRateBpm below to seed the
        // resp baseline the recovery composite's wResp=0.05 term scores against.
        val nightlyRespByDay = LinkedHashMap<String, Double?>()

        // Floor `now` to LOCAL midnight (#277) so each `dayStart` lands on a local-day boundary and the
        // day keys are LOCAL calendar days, consistent with the dashboard's local "today" lookup. A
        // west-of-UTC user's evening crosses midnight UTC; bucketing by UTC put it in the next UTC day,
        // which the local read never found (Toronto/UTC-4 report).
        val nowLocalMidnight = midnightLocal(nowSeconds, tzOffsetSeconds)

        // ── Learned habitual midsleep (#547) ──────────────────────────────────
        // Compute the user's habitual midsleep ONCE per run from the trailing sleep history so the
        // main-night scored pick aligns to their REAL bedtime (a late/shift sleeper), not a fixed clock
        // band. Read the stored sleep sessions (imported WHOOP-export + computed "-noop") over the
        // analysis window, make one HistoryBlock per session keyed by the LOCAL calendar day of its
        // midpoint, and let the learner keep the longest block per day (so naps drop out automatically).
        // null under HABITUAL_MIN_DAYS of history → cold-start: every analyzeDay/sleepEditedDaily call
        // below stays on the overnight-band bonus. The same value threads into both seams so analytics and
        // the Sleep tab resolve to the identical block. Mirrors Swift. (#547)
        val (habitualMidsleepSec, nightlyHours) = computeHabitualSleep(
            repo, importedDeviceId, computedId,
            nowLocalMidnight - maxDays * SECONDS_PER_DAY - 30 * 3_600L, nowSeconds, tzOffsetSeconds,
        )
        // Wave 0 (SL1/T1): personal sleep REGULARITY + population-anchored NEED, computed ONCE from the
        // trailing per-night durations and threaded to every analyzeDay below (mirrors the midsleep
        // learner just above — one personal trait per run, applied to the whole re-scored history so
        // Rest stops running on a flat neutral-0.5 consistency and a fixed 8 h need). Recent 28-night
        // window for regularity (a recent-behaviour signal); full history for the need's upper-quartile
        // "unrestricted nights" estimate. Both degrade honestly on thin history (consistency → null →
        // neutral term; need → population default), so cold-start is unchanged. Mirrors Swift.
        val sleepConsistency = VitalityEngine.sleepConsistency(nightlyHours.takeLast(28))
        // Two spelling differences from Swift, neither of which changes a number: Swift's
        // `AnalyticsEngine.Rest` is Kotlin's top-level `RestScorer` object, and Kotlin's
        // `UserProfile.age` is a Double where Swift's `ProfileStore.age` is already floored whole
        // years — `toInt()` truncates to the same integer, and the need floor only branches on
        // `<= 0` / `< 18`, so the two platforms land on the identical floor.
        val sleepNeedHours = RestScorer.personalizedNeedHours(nightlyHours, profile.age.toInt())

        // #970 read efficiency, skin-temp leg: [RegistryDayOwnerSource.skinTempFamily] resolves the family
        // via registry.all() — a Room query — and the loop below wants it once per DAY, so a 21-day scan
        // re-read the paired-devices table ~21× for what is almost always ONE owner. Swift never paid this:
        // it resolves the family from the in-memory regDevices snapshot loaded once per run
        // (skinTempFamily(forOwner:devices:)). Memoise per owner across the scan so the DB read happens once
        // per DISTINCT owner (once total on the common single-WHOOP install). A pure read-through — the
        // registry is stable for the run (same assumption [candidatePriorities] above already makes), so
        // every day sees the exact value the per-day call would have returned: byte-identical scoring.
        val skinFamilyByOwner = HashMap<String, DeviceFamily>()
        // #938: the WHOOP 4.0 ADC offset is per-device, not per-night. Learn one anchor per owner from the
        // whole scan window and reuse it for every night so cross-night deviations survive.
        val skinAnchorScanFrom = nowLocalMidnight - (maxDays - 1).toLong() * SECONDS_PER_DAY - 30 * 3_600L
        val skinAnchorScanTo = nowLocalMidnight + 18 * 3_600L
        val skinAnchorByOwner = HashMap<String, Double>()
        val skinAnchorResolvedOwners = HashSet<String>()

        for (offset in 0 until maxDays) {
            val dayStart = nowLocalMidnight - offset * SECONDS_PER_DAY
            val day = AnalyticsEngine.dayString(dayStart, tzOffsetSeconds)
            // Read a generous window around the night that ends on `day`; the stager finds the span.
            val from = dayStart - 30 * 3_600L
            // Sleep read-window END. For a PAST day the night may end any time before the NEXT local
            // midnight (late sleepers / weekend lie-ins / shift workers wake well after noon), so a
            // hard `dayStart + 18h` (6 PM) bound TRUNCATED the read at exactly 18:00 , and a real wake
            // past it was reported as a flat 18:00 wake (#500). Read a PAST day through to the next
            // local midnight so the stager sees the whole night; TODAY keeps the 18:00 cap (the DAO
            // clamps to now anyway, and an in-progress nap shouldn't be read as a finished night).
            // Matches the Swift window.
            val nextMidnight = dayStart + SECONDS_PER_DAY
            val to = if (dayStart < nowLocalMidnight) nextMidnight else dayStart + 18 * 3_600L

            // I2: pick the single device that OWNS this day, and read ITS streams below. With one device
            // this resolves to [importedDeviceId] (active strap, has data → priority 0), so nothing
            // changes; with multiple sources the day is scored from exactly one (active strap > other
            // live straps > imports, or a locked override). Falls back to [importedDeviceId] when no
            // owner source is supplied or the registry yields no owner.
            val owner = resolveDayOwner(repo, ownerSource, candidatePriorities, day, from, to, importedDeviceId)

            val hr = repo.hrSamples(owner, from, to, STREAM_LIMIT)
            // CAPTURE-B: capture this day's resolved read owner + HR-row count so PASS 2 can emit the
            // verbatim universal `dayOwner …` line per SCORED day (matching the iOS emit, which is in the
            // scored-days loop, NOT here). Only when the universal sink is on. A day skipped below for too
            // few rows is never scored, so it emits no line, byte-identical to the iOS behaviour.
            if (universalSink != null) readOwnerByDay[day] = OwnerRead(owner, hr.size)
            if (hr.size < MIN_HR_SAMPLES) {
                diag("sleep day=$day SKIPPED hrSamples=${hr.size} (need ≥$MIN_HR_SAMPLES)")
                continue
            }
            val rr = repo.rrIntervals(owner, from, to, STREAM_LIMIT)
            val resp = repo.respSamples(owner, from, to, STREAM_LIMIT)
            val grav = repo.gravitySamples(owner, from, to, STREAM_LIMIT)
            val steps = repo.stepSamples(owner, from, to, STREAM_LIMIT)
            val skin = repo.skinTempSamples(owner, from, to, STREAM_LIMIT)
            // #93: WHOOP 4.0 raw SpO2 PPG samples for the night; analyzeDay banks the nightly red/IR ADC
            // means on the DailyMetric. Empty on a 5/MG (no v24 spo2 channels) → the raw means stay null.
            val spo2 = repo.spo2Samples(owner, from, to, STREAM_LIMIT)
            // #938: the strap family that WROTE this owner's skin-temp rows, so analyzeDay converts the raw
            // register on the right scale (5/MG banks centidegrees, a WHOOP 4.0 v24 banks a raw ADC). The
            // owner source resolves it from the registry; unknown/non-WHOOP owners fall back to WHOOP5 (the
            // prior /100 behaviour), so only a device positively identified as a 4.0 changes scale.
            // Resolved once per DISTINCT owner via [skinFamilyByOwner] (#970 read efficiency, see above).
            val skinFamily = skinFamilyByOwner.getOrPut(owner) {
                ownerSource?.skinTempFamily(owner) ?: DeviceFamily.WHOOP5
            }
            // #938 (second capture): learn THIS device's worn skin-temp anchor raw ONCE, WINDOW-WIDE (the
            // whole scan window's skin samples), not per-night. The @72 skin-temp ADC's register offset is
            // per-device — a second real 4.0 strap shares the no-contact floor (~509) + 11-bit saturation
            // (2047) but a worn band ~1100–1600 (nightly mean raw ~1290), which the global 826 anchor maps to
            // 47–72 °C, so 100% of its worn samples fail the 28–42 °C gate (kept=0, no baseline, no signal).
            // WINDOW-WIDE, not per-night: a per-night re-centre would subtract each night's own mean and ERASE
            // the cross-night deviation the skinTempDevC signal exists to carry. Deterministic per run; SAFE
            // because the skin baseline is re-folded from the SAME window's nightly means every run, so this
            // constant offset cancels in the deviation. null for a non-4.0 owner (WHOOP5 ignores the anchor)
            // or when <100 in-band samples exist → the conversion falls back to the global anchor (byte-
            // identical to today). Computed here once per owner alongside the family resolution.
            val skinAnchorRaw = if (skinFamily == DeviceFamily.WHOOP4) {
                if (!skinAnchorResolvedOwners.contains(owner)) {
                    val windowSkin = repo.skinTempSamples(owner, skinAnchorScanFrom, skinAnchorScanTo, STREAM_LIMIT)
                    Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { it.raw })?.let { skinAnchorByOwner[owner] = it }
                    skinAnchorResolvedOwners.add(owner)
                }
                skinAnchorByOwner[owner]
            } else {
                null
            }
            // Wrist-wear events in the night window, paired into off-wrist [start, end) intervals for the
            // off-wrist sleep backstop (#500). The HR-gap proxy in the stager is the always-on guard;
            // these explicit intervals sharpen it under the FRACTIONAL rule (#504) , a session is dropped
            // only when its off-wrist coverage reaches maxOffWristSleepFraction, so a real night with a
            // short off-wrist tail survives. Pairing needs WRIST_ON too (to bound each interval); a span
            // still open at the window end closes at `to`. Empty when the strap emitted no wrist events.
            val wristOff = AnalyticsEngine.offWristIntervals(repo.events(owner, from, to, STREAM_LIMIT), to)

            // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
            // above is anchored to the current time-of-day and ends at dayStart+12h, so for a PAST
            // day whose late hours sit after that bound those hours are never read and the totals
            // undercount. Read exactly [localMidnight(day), localMidnight(day)+86400) and hand it to
            // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. Same STREAM_LIMIT; the
            // MIN_HR_SAMPLES gate above stays on the night window so empty days are still skipped.
            // `dayStart` is already a LOCAL midnight; midnightLocal is idempotent on it (the DAO range
            // is inclusive, so end at +86400-1s; analyzeDay also filters to the day). (#277)
            val dayMidnight = midnightLocal(dayStart, tzOffsetSeconds)
            val dayEnd = dayMidnight + SECONDS_PER_DAY - 1
            // Same [owner] as the night window above (I2): the additive day totals must come from the one
            // device that owns the day, never a mix.
            // #997: for a PAST day the [from, to] night read above already spans this calendar day (to =
            // nextMidnight ≥ dayEnd), so derive the day streams by filtering the in-memory night lists
            // instead of re-reading them from the store (~60 redundant reads/pass, incl. the big HR ones).
            // TODAY (dayEnd past the 18 h cap) and a limit-truncated night read DECLINE (null) → direct
            // read, so the shortcut only ever skips work, never changes data. Twin of Swift's #997.
            val dayHr = AnalyticsEngine.daySliceFromNight(hr, from, to, dayMidnight, dayEnd) { it.ts.toLong() }
                ?: repo.hrSamples(owner, dayMidnight, dayEnd, STREAM_LIMIT)
            val daySteps = AnalyticsEngine.daySliceFromNight(steps, from, to, dayMidnight, dayEnd) { it.ts }
                ?: repo.stepSamples(owner, dayMidnight, dayEnd, STREAM_LIMIT)
            // Full calendar-day gravity for WORKOUT detection. For a PAST day the night window runs to the
            // next local midnight so the afternoon/evening is already in `grav`; only TODAY (18 h cap) reads
            // directly, which the slice's `dayHi > nightHi` guard handles — a 5 pm run still shows up the
            // same day.
            val dayGrav = AnalyticsEngine.daySliceFromNight(grav, from, to, dayMidnight, dayEnd) { it.ts }
                ?: repo.gravitySamples(owner, dayMidnight, dayEnd, STREAM_LIMIT)

            // CONSUME (#531 / #175): the strap's OWN band sleep_state for the night window as (ts, state)
            // samples, so the H7 morning-stillness guard can confirm a borderline re-onset against the strap's
            // OWN scored band, AND analyzeDay can grid it per session for persistence. #175 wired the RAW
            // `sleepStateSample` stream end to end: read it directly from [owner] (the strap that owns this
            // night) so it is available THIS pass, not one pass behind, and it comes from the real offload
            // rather than a read-its-own-write of the per-session JSON. Empty on a WHOOP 4.0 (no band stream)
            // or an unbanded window → the guard falls back to the HR bar and no per-session state is persisted.
            // Fall back to the prior pass's persisted per-session state when the raw stream is absent (an older
            // DB banded before the v15 stream landed), so a legacy install keeps the H7 confirm. Mirrors Swift.
            var bandSleepState = repo.sleepStateSamples(owner, from, to).map { it.ts to it.state }
            if (bandSleepState.isEmpty()) {
                bandSleepState = bandSleepStateSamples(repo, computedId, from, to)
            }

            // #804 Fix A: when this day's owner sends NO usable gravity vector — so the motion detector can't
            // stage the night and it scored blank — AND it persisted its OWN hypnogram under its device
            // namespace (an Oura ring's SleepNet night, #773), hand that hypnogram to analyzeDay so the night
            // scores. Gated on absent gravity (`grav.size < 2` — a ring streams zero; a WHOOP always streams a
            // gravity vector) plus a non-canonical-WHOOP-import owner, so WHOOP straps and the "my-whoop"
            // import namespace are untouched; analyzeDay still lets a DETECTED session win where they overlap.
            val providedSleep: List<DetectedSleep> =
                if (owner != importedDeviceId && grav.size < 2) {
                    repo.sleepSessions(owner, from, to, 4000)
                        .mapNotNull { AnalyticsEngine.sleepSessionFromProvided(it) }
                } else {
                    emptyList()
                }

            val res = AnalyticsEngine.analyzeDay(
                day = day,
                hr = hr,
                rr = rr,
                resp = resp,
                gravity = grav,
                steps = steps,
                dayHr = dayHr,
                daySteps = daySteps,
                dayGravity = dayGrav,
                skinTemp = skin,
                skinTempFamily = skinFamily,   // #938
                skinTempAnchorRaw = skinAnchorRaw,   // #938 second capture: per-device worn anchor
                spo2 = spo2,                   // #93
                profile = profile,
                baselines = baselines1,
                maxHROverride = maxHROverride,
                tzOffsetSeconds = tzOffsetSeconds,
                wristOff = wristOff,
                sleepNeedHours = sleepNeedHours,
                sleepConsistency = sleepConsistency,
                habitualMidsleepSec = habitualMidsleepSec,
                bandSleepState = bandSleepState,
                // 7.0.0: thread the V2 toggle into the NORMAL staging path so it affects detected nights,
                // not just the userEdited self-heal restage. The Context-aware caller (AppViewModel/
                // WhoopBleClient) supplied it from PuffinExperiment.from(context).experimentalSleepV2.
                // V2 is the default staging engine for EVERY strap (toggle defaults on); turn it off for V1.
                // WHOOP 4.0 is unvalidated either way — V2 can over-stage on sparse motion (#319), V1 can
                // badly UNDER-stage deep/REM (kavemang, #347) — so the toggle is the escape until real 4.0
                // ground truth settles it (#271/#319). Matches the self-heal restage, which reads the toggle.
                useSleepStagerV2 = useExperimentalSleepV2,
                // #364 follow-up: same threading for the motion-aware wake refinement post-pass.
                useMotionAwareWake = useMotionAwareWake,
                // #804 Fix A: the owner's own device-provided hypnogram (empty for WHOOP/non-ring days).
                providedSleep = providedSleep,
                // Sleep & Rest test mode (Test Centre E5): thread the trace sink straight through. null (the
                // default) keeps analyzeDay's byte-identical untraced path; when the caller passed a non-null
                // sink (mode on), detectSleep's gate trace + the Rest sub-score line route to the .sleep-tagged
                // strap log. The sink is already the routing closure, so there is no per-day collect/replay.
                traceSink = sleepTraceSink,
                hrvTraceSink = hrvTraceSink,
                // Per-window HRV detail ONLY for the most-recent night (dayStart == today's local midnight),
                // so the 5000-line ring buffer isn't flooded; every night still emits the 1-line summary.
                hrvWindowDetail = dayStart == nowLocalMidnight,
                deepHrvWindow = deepHrvWindow,
            )

            // #195: whole-night HRV cleaning-pipeline summary to the always-on strap log, so a "reads ~2x too
            // high" report is triageable without the HRV test mode: RMSSD vs SDNN (rmssd >> sdnn = beat-to-beat
            // jitter surviving the ectopic filter, not real HRV), meanNN as an HR sanity-check, and how many R-R
            // intervals survived cleaning (a low count also flags the sparse-capture / calibration side —
            // `nInput` is set before the min-beats gate, so a sparse night still shows its count with
            // rmssd=nil). A SEPARATE analyzeRaw pass over the in-sleep R-R — does NOT touch the shipped
            // windowed avgHrv. Emitted here where `rr` is in scope; byte-identical to the Swift line.
            val sleepRrRows = rr.filter { r -> res.sleepSessions.any { r.ts >= it.start && r.ts < it.end } }
            val sleepRr = sleepRrRows.map { it.rrMs.toDouble() }
            if (sleepRr.isNotEmpty()) {
                val h = HrvAnalyzer.analyzeRaw(sleepRr)
                val ms = { v: Double? -> v?.let { String.format(java.util.Locale.US, "%.0f", it) } ?: "nil" }
                val rej = if (h.nInput > 0) String.format(java.util.Locale.US, "%.0f", 100.0 * (1.0 - h.nClean.toDouble() / h.nInput)) else "0"
                // #257: coverage (sum of NN ÷ wall-clock span; > 1.0 is impossible without double-counted
                // R-R) + exact-duplicate beat count, so a "reads ~2x too high" report is self-diagnosing
                // from the always-on log instead of hand-computing beat density.
                val ts = sleepRrRows.map { it.ts }
                // Computed ONCE and reused for both the formatted field and the verdict below:
                // collapsedCoverage sorts and de-dups the whole night's R-R (tens of thousands of rows on a
                // dense capture), and this runs per day across a full re-score.
                val covVal = HrvAnalyzer.rrCoverage(ts, sleepRr)
                val cov = String.format(java.util.Locale.US, "%.2f", covVal)
                // #550: collapsedCov previews a same-second R-R de-dup — well below `coverage` ⇒ the
                // over-count is same-second (a dedup fix would work); still high ⇒ cross-second overlap.
                val colCovVal = HrvAnalyzer.collapsedCoverage(ts, sleepRr)
                val colCov = String.format(java.util.Locale.US, "%.2f", colCovVal)
                val dup = HrvAnalyzer.duplicateBeatCount(ts, sleepRr)
                // #550: state the CONCLUSION, not just the evidence. Reading coverage against collapsedCov
                // is what distinguishes a same-second over-count (a de-dup would fix it) from a cross-second
                // one (it would not) — a rule that lived only in the comments above, so triaging an
                // "HRV reads ~2x high" report required knowing it. Now the line says which.
                val verdict = HrvAnalyzer.classifyCoverage(covVal, colCovVal)
                // #550 follow-up: having stated the conclusion, ACT on it. SDNN is a spread over every
                // interval, so an over-counted night inflates it directly — a ring whose banked R-R covers
                // 1.25x its wall-clock reads ~197 ms across a sleeping night, against a 40-100 ms
                // physiological range. Printing that number beside the verdict that says it cannot be
                // trusted invites it to be read as a measurement, so it is withheld instead; the
                // `rrIntegrity=` field on the same line says why. RMSSD/meanNN are NOT withheld — mean rate
                // survives an over-count, and RMSSD's dominant error was the emission order fixed at the
                // write path (#1072). Twin of the Swift line.
                // P7' follow-up: the over-count verdict is necessary but NOT sufficient. The 2026-08-06
                // Oura night measured coverage 1.03 / PLAUSIBLE — no duplication at all, its records
                // tiling the timeline at a fill ratio of 0.990 — and still printed SDNN 174 ms. A BANKED
                // stream stamps a whole record of intervals on one timestamp, so its stored values are a
                // decomposition of a record period, not beat-to-beat measurements: the per-record SUM is
                // right to ~1% (meanNN and RHR stay correct and WHOOP-validated) while the individual
                // intervals are not. Gate on that too. Twin of the Swift line.
                val accVal = HrvAnalyzer.beatAccurateFraction(ts, sleepRr)
                val acc = String.format(java.util.Locale.US, "%.2f", accVal)
                val sdnnField =
                    if (HrvAnalyzer.beatSpreadIsTrustworthy(verdict) &&
                        HrvAnalyzer.beatValuesAreTrustworthy(accVal)) "${ms(h.sdnn)}ms" else "withheld"
                diag("hrv diag day=${res.daily.day} rmssd=${ms(h.rmssd)}ms sdnn=$sdnnField meanNN=${ms(h.meanNN)}ms " +
                    "rr=${h.nInput}/${h.nClean} rejected=$rej% coverage=$cov collapsedCov=$colCov dupBeats=$dup " +
                    "beatAccurate=$acc " +
                    "rrIntegrity=${verdict.raw}")
                // #1008: on an OVER-COUNT night only, dump a raw-row sample around the densest second so the
                // over-count's MECHANISM is readable from the always-on log (near-equal copies vs distinct
                // trains vs a tagged channel) — clean nights stay quiet. srcChannel rides from the read model.
                // #1118: flag this night's HRV as over-counted (same verdict the diag logs) so the HRV
                // card can mark the reading unverified until the two-channel de-dup lands.
                hrvOverCountByDay[res.daily.day] =
                    (verdict == HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT ||
                        verdict == HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT)
                if (verdict == HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT ||
                    verdict == HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT) {
                    val sample = HrvAnalyzer.densestSecondWindowSample(
                        ts, sleepRr, sleepRrRows.map { it.srcChannel },
                    )
                    if (sample.isNotEmpty()) diag("hrv rrsample day=${res.daily.day} $sample")
                    // #1331/#1008/#1118 SHADOW: log the DEDUPED stream's HRV + coverage + beat-accuracy
                    // beside the raw so the candidate de-dup can be validated vs WHOOP + @artemc's Polar
                    // before it becomes the read path. Instrumentation only — shipped HRV/resp unchanged.
                    // If de-dup works: coverage→~1.0, beatAccurate high (would pass #1127's RSA gate →
                    // resp returns = the #1331 fix), rmssd/sdnn physiological. Twin of the Swift line.
                    // Two candidates so validation isn't confounded: EXACT-dup collapse (rrTolMs 0 — same
                    // ts AND value, no real-beat loss) is the safe floor; the ~40 ms collapse is the
                    // aggressive UPPER BOUND (catches the two-channel twins but can over-merge two real
                    // neighbours within 40 ms). Log both so we can see where the real de-dup sits. Twin.
                    val ex = HrvAnalyzer.collapseOverCount(ts, sleepRr, 0.0)
                    val dd = HrvAnalyzer.collapseOverCount(ts, sleepRr)
                    val hDd = HrvAnalyzer.analyzeRaw(dd.second)
                    val covEx = HrvAnalyzer.rrCoverage(ex.first, ex.second)
                    val covDd = HrvAnalyzer.rrCoverage(dd.first, dd.second)
                    val accDd = HrvAnalyzer.beatAccurateFraction(dd.first, dd.second)
                    diag("hrv dedup day=${res.daily.day} exactN=${ex.second.size}/${sleepRr.size} " +
                        "covExact=${String.format(java.util.Locale.US, "%.2f", covEx)} | ch40N=${dd.second.size} " +
                        "cov40=${String.format(java.util.Locale.US, "%.2f", covDd)} " +
                        "beatAcc40=${String.format(java.util.Locale.US, "%.2f", accDd)} " +
                        "rmssd40=${ms(hDd.rmssd)}ms sdnn40=${ms(hDd.sdnn)}ms meanNN40=${ms(hDd.meanNN)}ms")
                }
            } else if (res.sleepSessions.isEmpty()) {
                // #1244: no in-sleep R-R AND no detected session (past the >=200-HR gate) = the "HR tracked,
                // no sleep" case. Emit a counts-only reason line naming the inputs the stager had, so the
                // report says WHY nothing staged. `window` is the read span in whole hours (30 h back → next
                // local midnight, or +18 h for today). Byte-identical to the Swift line.
                val windowHours = ((to - from) / 3_600L).toInt()
                diag(
                    sleepDetectNoNightLogLine(
                        day = day, hrCount = hr.size, rrCount = rr.size, respCount = resp.size,
                        gravCount = grav.size, stepCount = steps.size, providedCount = providedSleep.size,
                        windowHours = windowHours,
                    ),
                )
            }

            // Steps test mode: emit the 5/MG raw-counter trace for this day (cumulative @57 series +
            // wrap-aware deltas + dropped deltas), tagged .steps. Only when the mode is on (the sink is
            // non-null), so the default path emits zero .steps lines. The trace recomputes the SAME
            // wrap-aware sum analyzeDay just ran over the SAME `daySteps`, so the steps total is unchanged.
            //
            // #810: GUARD on daySteps being non-empty. A WHOOP 4.0 sends no raw step counter, so its
            // `daySteps` is empty and the raw-counter trace is the wrong path (its steps are
            // motion-estimated, surfaced by the calibration/estimate trace below). Skipping the call here
            // stops the 4.0 export carrying a "counterSamples=0 ... need >=2" line that read as broken; a
            // 5/MG always banks counter rows so this never suppresses its real trace.
            if (stepsTraceSink != null && daySteps.isNotEmpty()) {
                for (line in StepsEstimateEngineTrace.rawCounterTrace(
                    daySteps = daySteps, dayKey = day, tzOffsetSeconds = tzOffsetSeconds,
                    ticksPerStep = profile.stepTicksPerStep,
                )) {
                    stepsTraceSink(line)
                }
            }

            // Harvest the baseline-independent nightly aggregates (a day with no detected
            // sleep yields null → recorded as a missing night, i.e. skip-and-hold). The raw
            // streams (hr/rr/...) go out of scope here and are freed before the next night.
            nightlyHrvByDay[day] = res.daily.avgHrv
            nightlyRhrByDay[day] = res.daily.restingHr?.toDouble()
            nightlySkinByDay[day] = res.nightlySkinTempC
            nightlyRespByDay[day] = res.daily.respRateBpm
            // #1331 respiratory diagnostic: log each night's breaths/min (or "nil") so a "respiratory not
            // showing" report is explainable from the strap log — a run of nil nights localises when it
            // stopped. Logging only; no scoring change. The Swift diag twin lands with the iOS carry (#1331 follow-up).
            diag(respRateLogLine(day, res.daily.respRateBpm))
            // ── RHR floor-vs-mean diagnostic (#691) ────────────────────────────────────────────────
            // Make the recurring "NOOP's resting HR reads LOWER than my sleeping-HR app" reports
            // explainable from the strap log instead of a guess. The two numbers measure different
            // things BY DESIGN, not a bug: NOOP's restingHr is the WHOOP-style FLOOR (the lowest
            // sustained 5-min in-bed level , SleepStager picks the min 5-min rolling-mean HR per session,
            // and the day takes the min across them), whereas a "sleeping HR" app reports the night MEAN
            // over the whole asleep span. The mean always sits above the floor, so NOOP looking lower is
            // correct. Log BOTH so a report ships proof of the gap. Mean is computed over the SAME matched
            // in-bed span the floor came from (so they're directly comparable); a night with no banked
            // floor (no matched sleep) logs nil and the line is skipped. Logging only , no scoring change.
            // Counts/bpm only; no timestamps or PII (the diag sink also scrubs). Byte-identical to Swift.
            val rhrFloor = res.daily.restingHr
            if (rhrFloor != null) {
                val inBedBpms = hr.filter { s -> res.sleepSessions.any { s.ts >= it.start && s.ts < it.end } }
                    .map { it.bpm }
                diag(rhrFloorMeanLogLine(day, rhrFloor, inBedBpms))
            }
            // #103: SpO₂ candidate @82 nightly mean. Only computed when the display toggle is ON.
            // Reads the V18AuxSample stream for this night's owner and averages the in-band (70–100)
            // @82 readings that fall inside a detected sleep session. null on a WHOOP 4.0 (no v18 aux
            // stream), a night with no in-band readings, or when the toggle is OFF. Persisted to
            // metricSeries as "spo2_candidate" in pass 2, never to `spo2Pct`.
            if (spo2CandidateDisplay) {
                val auxSamples = repo.v18AuxSamples(owner, from, to, STREAM_LIMIT)
                if (auxSamples.isNotEmpty()) {
                    val cand = AnalyticsEngine.nightlySpo2CandidateMean(res.sleepSessions, auxSamples)
                    if (cand != null) {
                        spo2CandidateByDay[res.daily.day] = cand.first
                    }
                }
            }
            // #1169 SHADOW METRIC (instrumentation only): the primary-session MEAN resting HR, recorded
            // beside the shipped nightly HR FLOOR (daily.restingHr = min per session) so the mean-vs-floor
            // comparison the issue asks for accrues on real devices. NEVER shown and NEVER fed to any score;
            // #1174's definition is unchanged. The windowing + delegation lives in the byte-identical,
            // tested AnalyticsEngine.
            val (primaryRhr, primaryRhrCoverage) = AnalyticsEngine.primarySessionRestingHRWithCoverage(res.sleepSessions, hr)
            primaryRhr?.let { primarySessionRHRByDay[res.daily.day] = it }
            primaryRhrCoverage?.let { primarySessionRHRCoverageByDay[res.daily.day] = it }
            scoredNights.add(res)
            resolvedScoreOwnerByDay[res.daily.day] = owner
        }

        // ── Seed the baseline from the UNION of imported nightly history + the nightly
        // values just computed. This is the recovery fix: the "-noop" nightly avgHrv/
        // restingHr that already exist (and are re-derived identically here) finally feed
        // the baseline, so a BLE-only user crosses Baselines.minNightsSeed (4 valid nights)
        // and recovery lights up. We fold over the in-memory pass-1 values rather than
        // re-reading repo.days(computedId) to avoid a read-before-persist ordering hazard.
        // Chronological (oldest-first) replay: a day present in both takes the computed value.
        val histHrvByDay = LinkedHashMap<String, Double?>()
        val histRhrByDay = LinkedHashMap<String, Double?>()
        val histRespByDay = LinkedHashMap<String, Double?>()
        for (d in hist) {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr?.toDouble()
            histRespByDay[d.day] = d.respRateBpm
        }
        // Imported (cloud) nightly values WIN per day: the on-device estimate only fills days the
        // import doesn't cover AT ALL, so an import user's baseline is unchanged. Use a key-absence
        // check, NOT putIfAbsent: Java's putIfAbsent treats a key mapped to NULL as absent, so an
        // imported day whose avgHrv/restingHr is blank would be REPLACED by the computed estimate —
        // diverging from the Swift mirror (`histHrvByDay[day] == nil` is true only when the KEY is
        // absent), which keeps that imported day as a missing night. HRV/RHR are the dominant
        // recovery drivers (~60%/~20%), so this substitution skewed Charge vs iOS. (The author already
        // fixed this for the low-weight resp term below; HRV/RHR were missed.)
        mergeNightlyIntoHistory(histHrvByDay, nightlyHrvByDay)
        mergeNightlyIntoHistory(histRhrByDay, nightlyRhrByDay)
        mergeNightlyIntoHistory(histRespByDay, nightlyRespByDay)
        // Sort once so the HRV values + their "yyyy-MM-dd" day keys stay parallel (same order/length) for
        // the recalibration-aware foldHistory below.
        val hrvSorted = histHrvByDay.entries.sortedBy { it.key }
        val hrvSeq = hrvSorted.map { it.value }
        val hrvDayKeys = hrvSorted.map { it.key }
        val rhrSorted = histRhrByDay.entries.sortedBy { it.key }
        val rhrSeq = rhrSorted.map { it.value }
        val rhrDayKeys = rhrSorted.map { it.key }
        val respSorted = histRespByDay.entries.sortedBy { it.key }
        val respSeq = respSorted.map { it.value }
        val respDayKeys = respSorted.map { it.key }
        // HRV baseline honours noop.hrvBaselineEpoch; rhr/resp/skin honour noop.recoveryBaselineEpoch via
        // their parallel day keys, so the manual Recalibrate restarts the whole Charge build-up together.
        // A 0.0 epoch is byte-identical to the plain fold, so scoring is unchanged until the user taps it.
        val hrvBase2 = Baselines.foldHistory(hrvSeq, hrvDayKeys, hrvCfg, baselineEpoch)
        val rhrBase2 = Baselines.foldHistory(rhrSeq, rhrDayKeys, rhrCfg, recoveryEpoch)
        // Resp baseline mixes imported (cloud) values with on-device RSA estimates , acceptable: the
        // z-score is scale-tolerant, foldHistory winsorizes, and respRateBpm already carries no source
        // flag anywhere else (the illness gate treats it the same way). Gated on `usable` because
        // RecoveryScorer includes the resp term whenever a baseline object is present , a CALIBRATING
        // (<4-night) baseline would let one noisy RSA night move recovery (mirrors the skin-temp
        // use-site gate; honest cold-start).
        val respBase2 = Baselines.foldHistory(respSeq, respDayKeys, respCfg, recoveryEpoch).takeIf { it.usable }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order. (PR #85)
        // Gated on `usable` for consistency with the resp baseline above AND the Swift reference
        // (IntelligenceEngine.swift:162 `skinFold.usable ? skinFold : nil`) , the use-site re-checks
        // `usable` too, so this is belt-and-suspenders, but it keeps the platforms byte-aligned.
        val skinSorted = nightlySkinByDay.entries.sortedBy { it.key }
        val skinSeq = skinSorted.map { it.value }
        val skinDayKeys = skinSorted.map { it.key }
        val skinBase2 = Baselines.foldHistory(skinSeq, skinDayKeys, skinCfg, recoveryEpoch).takeIf { it.usable }
        val baselines2 = ProfileBaselines(
            hrv = hrvBase2, restingHR = rhrBase2, resp = respBase2, skinTemp = skinBase2,
        )

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day mergeDaily precedence does not cover the workout table). Covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both under [importedDeviceId]); apple-health / health-connect carry Health
        // imports , a detected bout overlapping ANY of them is skipped below.
        val windowStart = nowSeconds - maxDays.toLong() * SECONDS_PER_DAY - 30 * 3_600L
        val realWorkouts = repo.workouts(importedDeviceId, windowStart, nowSeconds) +
            repo.workouts("apple-health", windowStart, nowSeconds) +
            repo.workouts("health-connect", windowStart, nowSeconds)

        // ── Pass 2: re-score every offloaded night against the now-seeded baseline. Only the
        // recovery composite is recomputed (cheap, baseline-dependent); every other field was
        // already computed in pass 1 and is baseline-independent, so the heavy sleep / strain /
        // workout / RSA analysis runs ONCE per night. recovery stays null until the HRV
        // baseline is usable (>= minNightsSeed valid nights) , honest cold-start.
        val out = ArrayList<Computed>()
        val dailies = ArrayList<DailyMetric>()
        val sleepRows = ArrayList<SleepSession>()
        val workoutRows = ArrayList<WorkoutRow>()
        // Rest composite (0–100) per night → persisted as the sleep_performance metric series so the
        // dashboard Rest score reflects the new composite, not raw efficiency. Swift parity.
        val restRows = ArrayList<MetricSeriesRow>()

        // User-corrected sleep windows for the COMPUTED source over the recompute window. They override
        // the detected sleep when scoring a day's sleep aggregates (so Rest + recovery honor the edit,
        // not just the Sleep tab's session view) AND gate the sleepRows upsert below (so a re-detected
        // night can't re-insert over the edit). Mirrors iOS IntelligenceEngine editsByStart /
        // sleepEditedDaily / cachedSleepKept. SCOPE (#318/PR #395): COMPUTED ("-noop") source only , an
        // edit to an IMPORTED (WHOOP-export) night updates the displayed session, but its dashboard
        // recovery/performance come verbatim from the export and are NOT recomputed here. Same honest
        // scope as iOS. Keyed by the IMMUTABLE detected `startTs` (never `effectiveStartTs`), so an
        // edited block lands exactly on its detected twin.
        //
        // Self-heal any night edited before its raw streams synced (port of iOS PR #449, see
        // [SleepStageHealer.selfHealEditedStages]): re-derive stages from the now-available raw over the
        // night's LOCKED bounds, rewrite the stage breakdown ONLY (userEdited=1 rows, bounds untouched),
        // and return the refreshed edited rows so `editsByStart` below carries the REAL staging into the
        // daily aggregate this same pass. A no-op for nights already staged from raw (idempotent) and for
        // imported nights (raw never dense). MUST run before `editsByStart` so healed stages flow into
        // Rest/recovery this run. Raw streams are read under the STRAP id; edited rows under COMPUTED.
        val editedRows = SleepStageHealer.selfHealEditedStages(
            repo = repo,
            computedDeviceId = computedId,
            strapDeviceId = importedDeviceId,
            windowStart = windowStart,
            windowEnd = nowSeconds,
            useExperimentalSleepV2 = useExperimentalSleepV2,
            useMotionAwareWake = useMotionAwareWake,
        )
        // #299: [editsByStart] / [editOnsetByStart] are now built PER DAY inside the scoring loop (scoped to
        // the day each edit belongs to), NOT window-wide here. sleepEditedDaily folds any edited row that
        // isn't a twin of THIS day's detected sessions in as a "manual" block, so a window-wide edit set let
        // ONE user edit / hand-logged nap substitute its total onto EVERY night in the window (incl.
        // matched=0 nights) — pinning totalSleepMin to a constant. See the loop below.

        // Provenance sets for the per-day diagnostic source token (Sleep overhaul §2.5). `hist` is the
        // imported daily rows under [importedDeviceId] (the WHOLE imported history, read above for the
        // baseline) , a row means a WHOOP export covers that day and WINS the dashboard merge over our
        // computed row (mergeDaily: imports win field-by-field). Apple-Health daily rows are the same for
        // the Apple brand. Both are key-presence sets only (no values leave), so the lookup is O(1) per day
        // and nothing about the imported numbers is exposed. WHOOP wins over Apple, matching the merge's
        // source priority. Mirrors the Swift `importedWhoopDays` / `appleHealthDays` sets.
        val importedWhoopDays = hist.map { it.day }.toHashSet()
        val appleHealthDays = repo
            .appleDaily(WhoopRepository.APPLE_HEALTH_SOURCE, "0000-01-01", "9999-12-31")
            .map { it.day }.toHashSet()

        for (res in scoredNights) {
            // #299: scope the edits to THIS day before folding. A userEdited row / hand-logged nap belongs
            // to exactly ONE day — the day its night ENDS on, matching the daily's end-day bucket
            // (AnalyticsEngine's `matched` filters sleep sessions by end-day). endTs is stable under a
            // bedtime edit (only the onset/startTsAdjusted moves), so end-day is the right key. Filtering
            // here keeps a single-night edit overriding only its OWN night instead of every night. The
            // #547 effective-onset detail is preserved: editOnsetByStart still carries the user-CORRECTED
            // bedtime (startTsAdjusted ?: startTs) for this day's edited/manual blocks.
            val dayEditedRows = editedRowsForDay(editedRows, res.daily.day, tzOffsetSeconds)
            val editsByStart: Map<Long, String?> = dayEditedRows.associate { it.startTs to it.stagesJSON }
            val editOnsetByStart: Map<Long, Long> = dayEditedRows.associate { it.startTs to it.effectiveStartTs }
            // Substitute an edited block's (reshaped) stages for its detected twin before the daily
            // sleep aggregate feeds Rest + recovery. No edit touching this night → `daily` is unchanged.
            val daily = sleepEditedDaily(
                res.daily, res.sleepSessions, editsByStart, editOnsetByStart,
                tzOffsetSeconds, habitualMidsleepSec,
            )
            val recovery = recomputeRecovery(daily, baselines2)
            // Charge term-breakdown trace (Test Centre Group G): only when the Recovery test mode is on
            // (recoveryTraceSink non-null). Emits which term moved Charge and which was nil and forced the
            // renorm, tagged .recovery. The trace's score is RecoveryScorer.recovery verbatim, so the
            // `recovery` written above is unchanged. Zero cost when off (the sink stays null, this branch
            // is skipped, recoveryTraceLines is never built). Mirrors the Swift recoveryTraceActive wiring.
            if (recoveryTraceSink != null) {
                for (line in recoveryTraceLines(daily, baselines2)) recoveryTraceSink(line)
            }
            val skinTempDevC = recomputeSkinTempDev(res.nightlySkinTempC, baselines2.skinTemp)
            RestScorer.restFromDaily(daily)?.let { rest ->
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "sleep_performance", value = rest))
            }
            // #103: persist the SpO₂ candidate @82 nightly mean to metricSeries as "spo2_candidate" so the
            // Blood Oxygen tile can surface it as a "strap estimate (unverified)" fallback when the toggle
            // is ON. Written under the "-noop" computed device ID, never to `spo2Pct`.
            spo2CandidateByDay[daily.day]?.let { cand ->
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "spo2_candidate", value = cand.toDouble()))
            }
            // #1118: persist the HRV over-count flag (1/0) so the HRV card can mark an over-counted 4.0
            // night's reading "unverified" until the two-channel de-dup lands. 0 written on a clean night
            // (not just absent) so a night that flips clean on re-score clears its prior flag.
            hrvOverCountByDay[daily.day]?.let { oc ->
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "hrv_rr_overcount", value = if (oc) 1.0 else 0.0))
            }
            // #1169 shadow metric: the primary-session mean RHR, stored beside the shipped floor
            // (daily.restingHr) under the "-noop" computed ID. Instrumentation only — never shown, never
            // scored — for later mean-vs-floor evaluation from exports.
            primarySessionRHRByDay[daily.day]?.let { v ->
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "rhr_primary_session", value = v))
            }
            // #1169: its coverage inputs beside the mean — valid-sample count + primary-session duration (s)
            // — so a thin-coverage night can be down-weighted in the later holdout. Raw inputs, not a fraction.
            primarySessionRHRCoverageByDay[daily.day]?.let { cov ->
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "rhr_primary_session_valid_samples", value = cov.validSamples.toDouble()))
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "rhr_primary_session_duration_s", value = cov.durationSec))
            }

            out.add(
                Computed(
                    day = daily.day,
                    recovery = recovery,
                    strain = daily.strain,
                    sleepMin = daily.totalSleepMin,
                    hrv = daily.avgHrv,
                    rhr = daily.restingHr,
                ),
            )
            // ── Per-day scoring diagnostic (Sleep overhaul §2.5) ──────────────────────────────────────
            // ONE concise, privacy-safe line per scored day into the shareable strap log: the day key, the
            // FINAL computed total-sleep minutes (after any edit substitution), how many sleep blocks the
            // detector matched on the day, and the provenance of the dashboard headline. Counts + a rounded
            // minute only , no HR/HRV/timestamps , so the next report ships PROOF of what was computed per
            // day (the project's log-failures-not-successes blind spot) and lets us settle the "Rest repeats
            // across days" question with data. Gated by the existing strap-log export. Mirrors the Swift line.
            val tsmLog = daily.totalSleepMin?.let { Math.round(it).toString() } ?: "nil"
            // #386: the banked stage split + efficiency ride beside the rollup, so a "homepage disagrees
            // with the Sleep tab" report is self-diagnosing from the export alone — totalSleepMin vs the
            // deep+rem+light sum is the identity both screens must agree on, now verifiable per pass, per
            // day, without screenshots. Rounded minutes only (same privacy class as the rest of the line);
            // stages=nil when the day has no banked stage split (an unstaged or imported-total-only day).
            val effLog = daily.efficiency?.let { String.format(java.util.Locale.US, "%.2f", it) } ?: "nil"
            diag(
                "sleep day=${daily.day} totalSleepMin=$tsmLog " +
                    "stages=${sleepStagesLogToken(daily.deepMin, daily.remMin, daily.lightMin)} " +
                    "eff=$effLog " +
                    "matched=${res.sleepSessions.size} " +
                    "source=${daySourceToken(daily.day, importedWhoopDays, appleHealthDays)}",
            )
            // #674/#1244: flag a COMPUTED day carrying a sleep total with NO matched session — the folded
            // edited/hand-logged block on a day the detector staged nothing (see sleepDivergenceLogLine).
            // Scoped to computed days: an imported-total-only day legitimately has a total without our
            // sessions, so it is NOT a divergence.
            val imported = daily.day in importedWhoopDays || daily.day in appleHealthDays
            if (!imported && daily.totalSleepMin != null && res.sleepSessions.isEmpty()) {
                diag(sleepDivergenceLogLine(daily.day, Math.round(daily.totalSleepMin).toInt(), dayEditedRows.size))
            }
            // #195: one always-on line per scored night with the computed HRV value + the window it used,
            // so an "HRV reads high / deep-sleep window not changing" report is self-diagnosing straight
            // from the strap log — the whole-night vs deep-sleep value, and `avgHrv=nil window=deep` when a
            // deep-window night has no detected deep sleep — without needing the HRV & Autonomic test mode.
            // Counts-only (a rounded ms + the window), PII-free; byte-identical to the Swift line.
            val hrvLog = daily.avgHrv?.let { String.format(java.util.Locale.US, "%.1f", it) } ?: "nil"
            diag("hrv day=${daily.day} window=${if (deepHrvWindow) "deep" else "whole"} avgHrv=$hrvLog")
            // ── CAPTURE-B: universal dayOwner self-diagnostic (#814/#799) ────────────────────────────────
            // ONE line per SCORED day, tagged .universal so it rides EVERY Test Centre export regardless of
            // which mode is on. It pins the read/write split #814 is about: readId is the owner this day was
            // read+scored from (captured in pass 1), writeActiveId is the registry's active id; a divergence
            // on a day with HR rows is the symptom. provenance says what backed the day. Verbatim format so
            // the export parser reads it; byte-identical to the iOS emit (same scored-days loop, same shape).
            // Only when the universal sink is on (the gate is the sink's nullness, set by the caller).
            if (universalSink != null) {
                val read = readOwnerByDay[daily.day]
                universalSink(
                    dayOwnerLine(
                        day = daily.day,
                        readId = read?.owner ?: activeWriteId,
                        writeActiveId = activeWriteId,
                        hrRows = read?.hrRows ?: 0,
                        importedWhoopDays = importedWhoopDays,
                        appleHealthDays = appleHealthDays,
                    ),
                )
            }
            // Stamp the computed source id + the re-scored recovery & skin-temp deviation onto the row.
            dailies.add(daily.copy(deviceId = computedId, recovery = recovery, skinTempDevC = skinTempDevC))
            // Map the rich DetectedSleep sessions → Room SleepSession cache rows.
            for (s in res.sleepSessions) {
                sleepRows.add(
                    SleepSession(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        efficiency = s.efficiency,
                        restingHr = s.restingHR,
                        avgHrv = s.avgHRV,
                        stagesJSON = AnalyticsEngine.encodeStages(s.stages),
                        // #345 follow-up: stamp the day's motion-coverage verdict so the Sleep tab can
                        // caption a sparse (likely under-detected) night. Twin of Swift analyzeDay.
                        stagingSparse = res.gravitySparse,
                    ),
                )
            }
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported/manual workout so import+wear users don't
            // double-count. sport="detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for (s in res.workouts) {
                val durMin = maxOf(0L, (s.end - s.start) / 60L).toInt()
                val avgBpm = s.avgHR.toInt()
                // Bare time overlap (any source), so a detected bout collapses against a manual session even
                // though their sports differ , the #975 "two workouts, one vanished" seam. Name the collider.
                val collider = realWorkouts.firstOrNull { w -> s.start < w.endTs && w.startTs < s.end }
                if (collider != null) {
                    // #510: the detected bout's own avgHR/calories/maxHR/strain come from the SAME
                    // motion+HR trace the detector used to find this activity's actual boundaries —
                    // often a tighter match than the colliding row's own [startTs,endTs] (e.g. a manual
                    // entry typed in afterward, whose guessed boundaries can clip most of the real
                    // HR-rich period and leave WhoopRepository.fillWorkoutHrFromStrap's raw window read
                    // too thin, silently showing no HR/calories). Same natural key (deviceId, startTs,
                    // sport), so the upsert below updates the existing row in place rather than
                    // duplicating it.
                    val backfilled = backfillWorkoutFromDetectedBout(
                        collider, avgBpm = avgBpm, peakHR = s.peakHR, caloriesKcal = s.caloriesKcal, strain = s.strain,
                    )
                    val didBackfill = backfilled != collider
                    if (didBackfill) workoutRows.add(backfilled)
                    workoutsTraceSink?.invoke(
                        WorkoutsTrace.detectedBoutLine(
                            verdict = if (didBackfill) "droppedOverlapBackfilled" else "droppedOverlap",
                            durMin = durMin, avgBpm = avgBpm,
                            overlapSource = colliderSourceLabel(collider.source),
                        ),
                    )
                    continue
                }
                workoutRows.add(
                    WorkoutRow(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        sport = "detected",
                        source = computedId,
                        durationS = s.durationS,
                        energyKcal = s.caloriesKcal,
                        avgHr = avgBpm,
                        maxHr = s.peakHR,
                        strain = s.strain,
                    ),
                )
                workoutsTraceSink?.invoke(
                    WorkoutsTrace.detectedBoutLine(verdict = "persisted", durMin = durMin, avgBpm = avgBpm),
                )
            }
        }

        // #277 migration: the loop now keys days by the LOCAL calendar day. A prior run (before this
        // fix) wrote the SAME period under UTC-day keys, so without a cleanup an off-by-one UTC row and
        // the new local row would coexist as duplicate days. Delete the COMPUTED ("-noop") daily rows
        // across the recompute window [oldest enumerated local day, newest] BEFORE re-upserting, then
        // re-insert the local-keyed rows. Scoped to the computed source only , imported "my-whoop" rows
        // are never touched (a BLE-only WHOOP 4.0 user has no import fallback). Rows older than the
        // window keep their old keys (cosmetic off-by-one, acceptable). yyyy-MM-dd sorts
        // chronologically, so the string range IS a date range.
        val oldestDay = AnalyticsEngine.dayString(
            nowLocalMidnight - (maxDays - 1) * SECONDS_PER_DAY, tzOffsetSeconds,
        )
        val newestDay = AnalyticsEngine.dayString(nowLocalMidnight, tzOffsetSeconds)

        // ── Source-only Charge/Rest fold for imported-only days (#823) ──────────────────────────────────
        // A user who ONLY imports (Health Connect, or an Oura/Fitbit/Garmin export, or Apple Health) has
        // DAILY aggregates (HRV + resting HR) but no raw HR stream, so the raw-HR scoring loop above never
        // touched their days and the import left recovery null , Today/Recovery show a blank Charge. Score it
        // from the daily aggregate vs the person's own baseline with the [watchRecoveries] engine (which
        // reuses RecoveryScorer.recovery verbatim), then write the score under the COMPUTED ("-noop") source
        // so it merges onto Today exactly like a live day. The imported daily row keeps its raw values
        // untouched; the computed row carries the NOOP-derived Charge + the Rest composite. HONEST DATA: the
        // engine returns null + calibrating until the HRV baseline is usable, so an import-only day stays
        // calibrating rather than faking a number. Strap/WHOOP-import days keep winning , we skip any day
        // already scored this pass. Health Connect writes its DailyMetric rows under the strap source
        // ("my-whoop"), so importedDeviceId is included; a row already carrying its OWN recovery is left
        // alone. Mirrors the Swift fold.
        val importScoredDays = HashSet<String>().apply { addAll(dailies.map { it.day }) }
        val healthConnectDays = repo.appleDaily(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            oldestDay,
            newestDay,
        ).mapTo(HashSet()) { it.day }
        val importSourceIds = buildList {
            add(importedDeviceId) // Health Connect imports its DailyMetric rows under the strap source.
            add(WhoopRepository.APPLE_HEALTH_SOURCE)
            add(WhoopRepository.HEALTH_CONNECT_SOURCE)
            addAll(WEARABLE_IMPORT_SOURCES)
        }.distinct()
        for (source in importSourceIds) {
            val rows = repo.dailyMetrics(source, oldestDay, newestDay)
            // A real export that already carries its OWN recovery WINS , never overwrite a verbatim imported
            // score; those days also pre-claim the slot so the fold doesn't re-score them.
            val byDay = rows.associateBy { it.day }
            for (r in rows) if (r.recovery != null) importScoredDays.add(r.day)
            for (w in watchRecoveries(rows, importScoredDays)) {
                val recovery = w.recovery ?: continue
                val row = byDay[w.day] ?: continue
                val scored = row.copy(deviceId = computedId, recovery = recovery)
                dailies.add(scored)
                importScoredDays.add(w.day)
                // Health Connect's compatibility DailyMetric row lives under `my-whoop`, while its
                // AppleDaily row retains the real source. Preserve that provider fact without changing
                // ingestion or score precedence.
                resolvedScoreOwnerByDay[w.day] =
                    if (source == importedDeviceId && w.day in healthConnectDays) {
                        WhoopRepository.HEALTH_CONNECT_SOURCE
                    } else {
                        source
                    }
                RestScorer.restFromDaily(scored)?.let { rest ->
                    restRows.add(MetricSeriesRow(deviceId = computedId, day = w.day, key = "sleep_performance", value = rest))
                }
                out.add(
                    Computed(
                        day = w.day,
                        recovery = recovery,
                        strain = scored.strain,
                        sleepMin = scored.totalSleepMin,
                        hrv = scored.avgHrv,
                        rhr = scored.restingHr,
                    ),
                )
            }
        }
        // Snapshot the persisted/merged daily history BEFORE the delete+re-upsert below rewrites the
        // computed window. This is the accumulated view the readiness card + dashboard read ("N of 7
        // nights"); captured here so the Fitness Age gate (further down) can't be undercut by this pass's
        // OWN pruning , a recompute only re-scores nights whose raw HR still lives in the store, so reading
        // after the rewrite would see only the freshly scorable subset. Windowed to the recompute range so
        // it stays bounded (daysMerged is full-history) and can't drag in stale nights older than the window.
        val faPriorDaily = repo.daysMerged(importedDeviceId).filter { it.day in oldestDay..newestDay }

        // Persist the computed scores under the dedicated "-noop" source so the WHOLE
        // dashboard (Today / Recovery / Strain / Sleep / Trends) reads them. The repository
        // merges these UNDER any imported "my-whoop" rows, so a real WHOOP import always wins;
        // this only fills the days the strap collected but no import covered.
        // Persist metric-level input provenance in the SAME Room transaction. dayOwnership remains
        // exclusively a resolver override, and a failed write can never relabel an older score.
        val provenanceByCell = LinkedHashMap<Pair<String, String>, ScoreInputProvenanceRow>()
        for (daily in dailies) {
            val source = resolvedScoreOwnerByDay[daily.day] ?: continue
            if (daily.recovery != null) {
                provenanceByCell[daily.day to "recovery"] =
                    ScoreInputProvenanceRow(computedId, daily.day, "recovery", source)
            }
            if (daily.strain != null) {
                provenanceByCell[daily.day to "strain"] =
                    ScoreInputProvenanceRow(computedId, daily.day, "strain", source)
            }
        }
        for (point in restRows) {
            val source = resolvedScoreOwnerByDay[point.day] ?: continue
            provenanceByCell[point.day to point.key] =
                ScoreInputProvenanceRow(computedId, point.day, point.key, source)
        }
        repo.replaceComputedScoreWindow(
            deviceId = computedId,
            from = oldestDay,
            to = newestDay,
            dailyMetrics = dailies,
            metricPoints = restRows,
            provenance = provenanceByCell.values.toList(),
        )

        // ── Fitness Age (Phase 2) , weekly, keyed to the week's Saturday ──
        val fa7 = dailies.sortedBy { it.day }.takeLast(7)
        val faRHRs = fa7.mapNotNull { it.restingHr }.map { it.toDouble() }
        // Gate + compute Fitness Age on the UNION of the pre-rewrite persisted history and THIS pass's
        // fresh scores (by day, fresh wins) , so an RHR night counts whether it survives in the store OR was
        // just scored, whether it sits under this id or a re-added strap's sibling id, or came from an
        // import. Kept SEPARATE from `fa7` so Vitality (below), which already computes, is untouched. The
        // gate + compute live in [fitnessAgeRows] so the manual "refresh Fitness Age" button applies the
        // SAME rule (no drift).
        val faGateByDay = LinkedHashMap<String, DailyMetric>()
        for (d in faPriorDaily) faGateByDay[d.day] = d
        for (d in dailies) faGateByDay[d.day] = d
        val faGate7 = faGateByDay.values.sortedBy { it.day }.takeLast(7)
        val faPts = fitnessAgeRows(faGate7, profile, computedId, saturdayKeyOnOrBefore(newestDay))
        // Strap-log proof: the RHR-night count the engine sees for the gate , should equal the "N of last 7
        // nights" the readiness card shows; `computed` says whether the value was (re)written this pass.
        diag("fitnessAge gate day=$newestDay rhrNights=${faGate7.mapNotNull { it.restingHr }.size} activityDays=${faGate7.mapNotNull { it.strain }.size} computed=${faPts.isNotEmpty()}")
        if (faPts.isNotEmpty()) repo.upsertMetricSeries(faPts)

        // ── Vitality / Body Age (Phase 7) , weekly, keyed to the week's Saturday ──
        // Roll the last 7 days' wearable signals into the mortality-hazard model; VitalityEngine gates on
        // ≥3 inputs. VO₂max is omitted (fitness is Fitness Age's headline); Vitality leans on resting HR,
        // sleep duration + regularity, HRV-vs-age-norm, and steps.
        val vNights = fa7.mapNotNull { it.totalSleepMin }.map { it / 60.0 }.filter { it > 0 }
        val vHRVs = fa7.mapNotNull { it.avgHrv }
        val vSteps = fa7.mapNotNull { it.steps }.map { it.toDouble() }
        val vInputs = VitalityEngine.Inputs(
            chronoAge = profile.age,
            restingHR = if (faRHRs.isEmpty()) null else medianOfDoubles(faRHRs),
            sleepHours = if (vNights.isEmpty()) null else vNights.average(),
            sleepConsistency = VitalityEngine.sleepConsistency(vNights),
            rmssd = if (vHRVs.isEmpty()) null else medianOfDoubles(vHRVs),
            rmssdNorm = VitalityEngine.rmssdNorm(profile.age),
            steps = if (vSteps.isEmpty()) null else vSteps.average())
        VitalityEngine.compute(vInputs)?.let { vRes ->
            val satKey = saturdayKeyOnOrBefore(newestDay)
            repo.upsertMetricSeries(listOf(
                MetricSeriesRow(deviceId = computedId, day = satKey, key = "vitality", value = vRes.vitality),
                MetricSeriesRow(deviceId = computedId, day = satKey, key = "body_age", value = vRes.bodyAge)))
        }

        // ── Steps ESTIMATE (WHOOP 4.0) , DAILY, keyed to each strap-only day ──
        // A WHOOP 4.0 sends no step count over BLE, so for days the phone DIDN'T also count steps we
        // estimate them: calibrate the strap's daily MOTION VOLUME against the phone's real step count on
        // the days both exist, then apply that personal coefficient to the strap-only days. Engine =
        // StepsEstimateEngine (fully unit-tested); this block is pure orchestration , gather points, fit,
        // store under the same "-noop" source, and hand the fit back to the caller for ProfileStore.
        // Idempotent: re-upserts the same (computedId, day, "steps_est") rows. Inert until there's a
        // calibration , a single-source / no-phone user sees no estimate until they set a manual `k`.
        // Mirrors the Swift IntelligenceEngine steps-estimate block byte-for-byte (60-day window, the
        // apple-health daily `steps` reference, the [localMidnight,+24h) motion volume).
        val stepsCalDays = 60
        val calOldest = AnalyticsEngine.dayString(
            nowLocalMidnight - (stepsCalDays - 1) * SECONDS_PER_DAY, tzOffsetSeconds)
        // Phone reference steps per day, from the apple-health daily rows (steps > 0 only). On Android the
        // Apple-Health importer banks `steps` in AppleDaily (DailyMetric holds only sleep/HR/HRV , see
        // AppleHealthImporter), so read appleDaily here, not dailyMetrics, or the reference is always empty
        // and NO phone-step calibration ever fits (the cause of the "Not calibrated" reports on #37).
        val appleRows = repo.appleDaily(WhoopRepository.APPLE_HEALTH_SOURCE, calOldest, newestDay)
        val refStepsByDay = HashMap<String, Double>()
        for (r in appleRows) { val s = r.steps; if (s != null && s > 0) refStepsByDay[r.day] = s.toDouble() }
        // #37: Health Connect steps (imported under "health-connect", also in appleDaily) are a phone
        // reference too , union them in so HC-only users get a step calibration. Apple-health WINS on a
        // same-day overlap (only fill days apple didn't already supply).
        val hcStepRows = repo.appleDaily(WhoopRepository.HEALTH_CONNECT_SOURCE, calOldest, newestDay)
        for (r in hcStepRows) {
            val s = r.steps
            if (s != null && s > 0 && !refStepsByDay.containsKey(r.day)) refStepsByDay[r.day] = s.toDouble()
        }
        // Per-day motion volume over the calibration window, read from the owner-resolved strap streams.
        // (Owner resolution mirrors the scoring loop; a single-device install resolves to importedDeviceId.)
        val motionByDay = HashMap<String, Double>()
        for (off in 0 until stepsCalDays) {
            val dayMid = midnightLocal(nowLocalMidnight - off * SECONDS_PER_DAY, tzOffsetSeconds)
            val dayEnd = dayMid + SECONDS_PER_DAY - 1
            val dayKey = AnalyticsEngine.dayString(dayMid, tzOffsetSeconds)
            val owner = resolveDayOwner(repo, ownerSource, candidatePriorities, dayKey, dayMid, dayEnd, importedDeviceId)
            val grav = repo.gravitySamples(owner, dayMid, dayEnd, STREAM_LIMIT)
            val m = StepsEstimateEngine.dayMotionIntensity(grav)
            if (m > 0) motionByDay[dayKey] = m
        }
        // Build calibration points only for days with BOTH a motion volume and a real phone step count.
        val calPoints = motionByDay.mapNotNull { (day, motion) ->
            refStepsByDay[day]?.let { StepsEstimateEngine.CalibrationPoint(motion = motion, steps = it) }
        }
        val stepsCal = StepsEstimateEngine.calibrate(calPoints, manualOverride = manualStepCoefficient)
        if (stepsCal != null) {
            // Estimate + upsert for each recent scored day that has motion but NO real phone step count.
            val estRows = ArrayList<MetricSeriesRow>()
            for (dm in dailies) {
                if (refStepsByDay.containsKey(dm.day)) continue
                val motion = motionByDay[dm.day] ?: continue
                val est = StepsEstimateEngine.estimate(motion, stepsCal) ?: continue
                estRows.add(MetricSeriesRow(deviceId = computedId, day = dm.day, key = "steps_est", value = est.toDouble()))
            }
            if (estRows.isNotEmpty()) repo.upsertMetricSeries(estRows)
            // Hand the fit back so the caller mirrors it into ProfileStore for the Settings/Steps screen.
            persistStepsCalibration(stepsCal)
        }
        // Steps test mode: emit the WHOOP-4 motion-volume calibration trace (per-day points + the fitted /
        // manual / withheld calibration state) and a per-day estimate line, tagged .steps. Only when the mode
        // is on (the sink is non-null), so the default path emits zero .steps lines here. The trace reuses
        // StepsEstimateEngine.calibrate/estimate VERBATIM, so it cannot diverge from the coefficient + steps_est.
        if (stepsTraceSink != null) {
            for (line in StepsEstimateEngineTrace.calibrationTrace(calPoints, manualStepCoefficient)) {
                stepsTraceSink(line)
            }
            if (stepsCal != null) {
                for (dm in dailies) {
                    if (refStepsByDay.containsKey(dm.day)) continue
                    val motion = motionByDay[dm.day] ?: continue
                    val est = StepsEstimateEngine.estimate(motion, stepsCal) ?: continue
                    stepsTraceSink(
                        "stepsEst day=${dm.day} steps=$est " +
                            "motion=${Math.round(motion * 100.0) / 100.0} (motion-volume estimate)",
                    )
                }
            }
        }
        // DURABILITY GUARD (iOS PR #395 cachedSleepKept): drop any freshly-detected session that
        // time-overlaps a night the user has already hand-corrected. A detected onset can drift
        // second-to-second as more raw data arrives, so without this the re-detected night would upsert
        // as a SECOND row beside the edited one (different startTs ⇒ no ON CONFLICT match), and the
        // mergeSleep / daily aggregate would DOUBLE-COUNT both into an inflated time-in-bed AND the edit
        // would visually revert. The edited row is already stored (it carries userEdited=1 and is never
        // re-emitted here , the engine only writes detected twins), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this IS the
        // idempotency guard for the edited case. Overlap uses the edit's EFFECTIVE window. (#318)
        val editedWindows = editedRows.map { it.effectiveStartTs to it.endTs }
        // #33: also drop any re-detected night the user has DELETED: a dismissedSleep tombstone keeps it
        // from regenerating, mirroring the dismissedWorkout guard. Overlap (not exact startTs) because a
        // re-detected onset drifts as more raw data arrives.
        // #65 3A: dismissedSleeps now reads the UNION of the imported + computed ids, so a tombstone
        // written under EITHER namespace (an imported night writes "my-whoop", a computed one writes
        // "my-whoop-noop") is found. The overlap-suppression predicate lives in DismissedSleepGuard,
        // the JVM-tested twin of Swift's DismissedSleepSpans.
        val dismissedWindows = repo.dismissedSleeps(importedDeviceId).map { it.startTs to it.endTs }
        val skipWindows = editedWindows + dismissedWindows
        val sleepKept = DismissedSleepGuard.keeping(sleepRows, skipWindows) { it.startTs to it.endTs }
        if (sleepKept.isNotEmpty()) repo.upsertSleepSessions(sleepKept)
        // ── Persist per-epoch motion (H8) beside each kept session's stagesJSON ──────────────────────────
        // The sleepSession rows exist now (just upserted), so the targeted motion UPDATE lands. Persist ONLY
        // for the sessions actually kept (not edited/dismissed), keyed by the detected start analyzeDay
        // returned. A session whose gravity wouldn't grid was omitted from the map and is left as NULL , an
        // absent motion series stays absent, never a fabricated zero array. Mirrors Swift.
        val keptStarts = sleepKept.map { it.startTs }.toHashSet()
        val motionByStart = HashMap<Long, List<Double>>()
        for (res in scoredNights) {
            for ((start, motion) in res.sessionMotionByStart) {
                if (start in keptStarts) motionByStart[start] = motion
            }
        }
        for ((start, motion) in motionByStart) {
            repo.persistSessionMotion(computedId, start, motion)
        }
        // ── Persist per-epoch BAND sleep_state (#175) beside each kept session's stagesJSON ──────────────
        // This is the source `sleepStateJSON` lacked (the write path had no producer because the raw stream
        // was dropped at extraction). Now analyzeDay grids the RAW `sleepStateSample` stream per session;
        // persist it here so the NEXT pass's bandSleepStateSamples read (the H7 confirm) and the display can
        // see the strap's OWN scored band. ONLY for kept (not edited/dismissed) sessions; a session with no
        // band samples was omitted (no key) and stays NULL — an absent signal stays absent. Mirrors Swift.
        val sleepStateByStart = HashMap<Long, List<Int>>()
        for (res in scoredNights) {
            for ((start, states) in res.sessionSleepStateByStart) {
                if (start in keptStarts) sleepStateByStart[start] = states
            }
        }
        for ((start, states) in sleepStateByStart) {
            repo.persistSessionSleepState(computedId, start, states)
        }
        // ── Overlap-aware banked-sleep heal (#899) ────────────────────────────────────────────────────
        // An unstable strap clock re-banks the SAME night under a shifted timebase, so successive passes
        // detect it at shifted bounds and the upsert above lands a SECOND row beside the stale one (the
        // (deviceId, startTs) key differs, and sleep has no delete-reinsert reconcile like dailyMetric /
        // workout). Collapse the window's stored sessions with the overlap rule, treating the rows THIS
        // pass just banked as the bank-recency witness (the strap's current timebase), and delete the
        // stale copies. Scoped to sessions whose wake day lies inside the [oldestDay, newestDay] daily
        // reconcile window: exactly the days this pass re-scored/evicted, so a session row is never
        // deleted out from under a daily row the pass did not refresh. Edited rows are never dropped.
        // Mirrors the Swift analyzeRecent heal.
        // #1248: heal EVERY device that banks sleep in this window, not just `computedId`. A live source
        // (an Oura ring) banks its OWN hypnogram under its device id; a night re-banked there accumulates
        // overlapping copies the computedId-only heal never saw — and, worse, those un-healed ring rows are
        // re-read as `providedSleep` and re-detected every pass, so one night ballooned to 14 rows / 9
        // "naps". Dedup each device's rows AMONG THEMSELVES and delete stale copies under that SAME id
        // (deleteSleepSessionRowOnly deletes under the row's own deviceId), never across ids, so a survivor
        // is never orphaned under an id the day-owner read skips. `freshStarts` (this pass's computed bank
        // witness) only matches the computedId rows; the others fall back to longest-wins, the read-side
        // dedup's own default. Sorted for a deterministic order. Mirrors the Swift analyzeRecent heal.
        val healDeviceIds = healDeviceIds(computedId, candidatePriorities.map { it.first })
        val healDropped = ArrayList<SleepSession>()
        for (healId in healDeviceIds) {
            val storedSessions = repo.sleepSessions(healId, windowStart, nowSeconds, 4000)
            val healable = storedSessions.filter {
                AnalyticsEngine.dayString(it.endTs, tzOffsetSeconds) in oldestDay..newestDay
            }
            val dropped = SleepSessionDedup.dedupe(healable, freshStarts = keptStarts).dropped
            // Row-only delete: the user-facing deleteSleepSession writes a #33 dismissal tombstone, which
            // would overlap the SURVIVING night's window and permanently suppress its re-detection.
            for (stale in dropped) repo.deleteSleepSessionRowOnly(stale)
            healDropped.addAll(dropped)
        }
        // #1284: log the sweep ALWAYS, even at zero removals — a heal that collapsed rows was previously
        // silent (the line below only fired on a non-empty drop), so from the strap log alone it was
        // indistinguishable from never having run. Counts only, no PII. Twin of the Swift line.
        diag(
            "Dedup(#899): swept ${healDeviceIds.size} device id(s), removed " +
                "${healDropped.size} overlapping duplicate session(s).",
        )
        if (healDropped.isNotEmpty()) {
            diag(
                "Dedup(#899): removed ${healDropped.size} overlapping duplicate sleep " +
                    "session(s) re-banked under a shifted strap timebase; re-scoring the affected days.",
            )
        }
        // Make re-detection idempotent across runs: clear the prior computed detected workouts
        // in the scored window (a bout's startTs can drift as more HR arrives, which would
        // otherwise orphan stale rows under the (deviceId,startTs,sport) key), then re-insert.
        repo.deleteComputedWorkouts(computedId, "detected", windowStart, nowSeconds)
        if (workoutRows.isNotEmpty()) repo.upsertWorkouts(workoutRows)

        // #137: a manually-started workout is scored from sparse live HR at save time , near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        // #950: score the workout against the wearer's MEASURED resting HR, not the hardcoded 60 —
        // the day total two lines up already uses the measured value, and the mismatch is what made a
        // workout's Effort incomparable to its own day's. The most recent scored day that has one is the
        // best available estimate; null (cold start) keeps the old default.
        // FIRST, not last: `out` is NEWEST-FIRST, because the scoring loop counts backwards from today
        // (`for (offset in 0 until maxDays)` with `dayStart = nowLocalMidnight - offset * SECONDS_PER_DAY`),
        // so out[0] is today and the tail is the oldest day in the window. Taking the last match would have
        // scored today's workout against a resting HR up to `maxDays` old.
        val measuredResting = out.firstOrNull { it.rhr != null }?.rhr?.toDouble()
        rescoreManualWorkouts(repo, profile, importedDeviceId, maxHROverride, nowSeconds, measuredResting)

        return out to healDropped.size
    }

    /**
     * The source-only label for a detected-bout overlap collider in the #975 workouts trace, computed WITHOUT
     * reaching into the UI-layer WorkoutEditing (the analytics layer must not depend on com.noop.ui). Mirrors
     * WorkoutEditing.sourceLabel / the Swift WorkoutSource.sourceLabel token set. No PII (a source class only).
     */
    private fun colliderSourceLabel(source: String): String {
        val s = source.lowercase()
        return when {
            s.endsWith("-noop") -> "detected"
            s == "manual" -> "manual"
            s == "lifting" -> "lifting"
            s == "activity-file" -> "activityFile"
            s == "apple-health" || s == "apple_health" || s == "health-connect" -> "apple"
            s.contains("whoop") -> "strap"
            else -> "apple"
        }
    }

    /**
     * #510: backfill ONLY the avgHr/maxHr/energyKcal/strain fields [real] doesn't already have, from a
     * detected bout's own computed values — never touching a field that's already present, whether
     * typed by the user, imported, or filled by an earlier pass. Returns [real] unchanged (`==`) when it
     * already had everything, so the caller can tell whether a write is actually needed.
     */
    internal fun backfillWorkoutFromDetectedBout(
        real: WorkoutRow,
        avgBpm: Int,
        peakHR: Int,
        caloriesKcal: Double?,
        strain: Double?,
    ): WorkoutRow = real.copy(
        avgHr = real.avgHr ?: avgBpm,
        maxHr = real.maxHr ?: peakHR,
        energyKcal = real.energyKcal ?: caloriesKcal,
        strain = real.strain ?: strain,
    )

    /**
     * #137: re-score under-sampled manual workouts. Conservative + idempotent: only `manual` rows that
     * look under-scored (negligible calories), and only when the recompute from the now-denser HR
     * window is a genuine improvement , so a well-scored 4.0 workout is never touched and a still-sparse
     * window is a no-op. Manual workouts + live/offloaded HR both live under [deviceId] ("my-whoop").
     */
    private suspend fun rescoreManualWorkouts(
        repo: WhoopRepository,
        profile: UserProfile,
        deviceId: String,
        maxHROverride: Double?,
        nowSeconds: Long,
        // #950: the wearer's measured resting HR (most recent scored day), threaded into scored() so the
        // rescore uses the same %HRR denominator as the day total. null → the scorer's default.
        restingHR: Double? = null,
    ) {
        val since = nowSeconds - 14L * 86_400L
        val rows = runCatching { repo.workouts(deviceId, since, nowSeconds) }.getOrNull() ?: return
        val hrMax = maxHROverride ?: (208.0 - 0.7 * profile.age)   // Tanaka, matching endWorkout
        val updated = ArrayList<WorkoutRow>()
        for (row in rows) {
            if (row.source != "manual") continue
            // Eligible when it looks under-scored (negligible kcal, #137) OR it's missing strain (the
            // merged-workout case, where kcal is the SUM of inputs so it never looks under-scored yet
            // Effort stays blank forever). improves() then accepts a strain-only gain for the latter.
            if (!ManualWorkoutRescore.looksUnderScored(row.energyKcal) && row.strain != null) continue
            val samples = runCatching { repo.hrSamples(deviceId, row.startTs, row.endTs, 20_000) }
                .getOrNull() ?: continue
            val s = ManualWorkoutRescore.scored(samples, profile, hrMax, restingHR) ?: continue
            if (!ManualWorkoutRescore.improves(s, row.energyKcal, row.strain, allowStrainOnlyFill = true)) continue
            // Never lower a summed kcal: only take the recomputed kcal when it genuinely beats the stored
            // value; a strain-only fill (merged row) keeps the existing summed energyKcal.
            val kcalBeatsStored = (s.kcal ?: 0.0) > (row.energyKcal ?: 0.0) + ManualWorkoutRescore.IMPROVEMENT_MARGIN_KCAL
            val energyKcal = if (kcalBeatsStored) s.kcal else row.energyKcal
            updated.add(row.copy(energyKcal = energyKcal, avgHr = s.avgHr, maxHr = s.maxHr, strain = s.strain))
        }
        if (updated.isNotEmpty()) repo.upsertWorkouts(updated)
    }

    /**
     * Recompute ONLY the recovery composite for an already-analyzed day against a (possibly
     * freshly-seeded) baseline. Inputs are the baseline-independent values already on [daily]
     * (avgHrv / restingHr / efficiency == sleepPerf), so pass 2 avoids re-running the expensive
     * sleep / strain / workout / RSA pipeline. Mirrors the recovery gate in
     * AnalyticsEngine.analyzeDay exactly (null on missing HRV/RHR or an unusable HRV baseline).
     */
    private fun recomputeRecovery(daily: DailyMetric, baselines: ProfileBaselines): Double? {
        val hrvVal = daily.avgHrv ?: return null
        val rhrVal = daily.restingHr ?: return null
        val hrvBase = baselines.hrv ?: return null
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation (both from persisted daily fields).
        // Mirrors the Swift recomputeRecovery. (Charge/Effort/Rest scoring redesign.)
        val restQuality = RestScorer.restFromDaily(daily)?.let { it / 100.0 } ?: daily.efficiency
        return RecoveryScorer.recovery(
            hrv = hrvVal,
            rhr = rhrVal.toDouble(),
            resp = daily.respRateBpm, // term drops + renormalizes when null / no usable baseline
            hrvBaseline = hrvBase,
            rhrBaseline = baselines.restingHR,
            respBaseline = baselines.resp,
            sleepPerf = restQuality,
            skinTempDev = daily.skinTempDevC,
        )
    }

    /** One day's source-only (daily-aggregate) recovery output, keyed by day. Mirrors Swift WatchScoredDay. */
    data class WatchScoredDay(val day: String, val recovery: Double?, val confidence: ScoreConfidence)

    /**
     * Score Charge for daily-aggregate (import-only) days that the raw-HR loop never touched (#823). For
     * each row it folds the TRAILING HRV + RHR history (every earlier row's avgHrv / restingHr) into the
     * cross-lane [WatchRecovery] engine, which mirrors our Charge shape but reads daily values. Stays null +
     * CALIBRATING until there are enough usable nights, so we never fabricate a number. [strapRecoveryDays]
     * are days a strap / WHOOP import already scored , those are SKIPPED so the strap keeps winning. Pure (no
     * store) so it is unit-tested directly. [rows] need not be ordered (it sorts). Mirrors Swift
     * `IntelligenceEngine.watchRecoveries`.
     */
    fun watchRecoveries(
        rows: List<DailyMetric>,
        strapRecoveryDays: Set<String> = emptySet(),
    ): List<WatchScoredDay> {
        val sorted = rows.sortedBy { it.day }
        val out = ArrayList<WatchScoredDay>()
        for ((i, row) in sorted.withIndex()) {
            if (row.day in strapRecoveryDays) continue
            val prior = sorted.subList(0, i)
            val hrvHistory = prior.mapNotNull { it.avgHrv }
            val rhrHistory = prior.mapNotNull { it.restingHr?.toDouble() }
            val res = WatchRecovery.compute(
                todayHrv = row.avgHrv,
                todayRhr = row.restingHr,
                hrvHistory = hrvHistory,
                rhrHistory = rhrHistory,
            )
            out.add(WatchScoredDay(row.day, res.recovery, res.confidence))
        }
        return out
    }

    /**
     * The Charge term-breakdown trace lines for one day (Recovery test mode, Group G). Pure: it feeds the
     * SAME inputs [recomputeRecovery] does (the SAME [restQuality] derivation) into the side-effect-free
     * [RecoveryScorerTrace.recoveryTrace], whose returned score IS [RecoveryScorer.recovery] verbatim, so
     * the trace can never diverge from the Charge number written for the day. Empty when a hard input
     * (HRV / RHR / HRV-baseline) is missing, mirroring [recomputeRecovery]'s own early-null. Only CALLED
     * when the Recovery test mode is on, so it costs nothing when the mode is off. Mirrors the Swift
     * recoveryTraceLines.
     */
    private fun recoveryTraceLines(daily: DailyMetric, baselines: ProfileBaselines): List<String> {
        val hrvVal = daily.avgHrv
        val rhrVal = daily.restingHr
        val hrvBase = baselines.hrv
        if (hrvVal == null || rhrVal == null || hrvBase == null) {
            return listOf(
                "charge day=${daily.day} nilScore reason=missingInput (hrv/rhr/hrvBaseline required)",
            )
        }
        val restQuality = RestScorer.restFromDaily(daily)?.let { it / 100.0 } ?: daily.efficiency
        val (_, trace) = RecoveryScorerTrace.recoveryTrace(
            hrv = hrvVal,
            rhr = rhrVal.toDouble(),
            resp = daily.respRateBpm,
            hrvBaseline = hrvBase,
            rhrBaseline = baselines.restingHR,
            respBaseline = baselines.resp,
            sleepPerf = restQuality,
            skinTempDev = daily.skinTempDevC,
        )
        // Prefix each line with the day key so a multi-night export stays parseable, matching the sleep
        // trace's per-day shape.
        return trace.map { "charge day=${daily.day} " + it.removePrefix("charge ") }
    }

    /**
     * The user's habitual midsleep (local time-of-day seconds), or null under HABITUAL_MIN_DAYS of
     * history (cold-start). Reads the stored sleep sessions (imported + computed) over the window, makes
     * one HistoryBlock per session , start/end are the EFFECTIVE (edited) bounds so a corrected bedtime is
     * learned, dayKey is the LOCAL calendar day of the midpoint , and defers to
     * [SleepStageTotals.habitualMidsleepSec], which keeps the longest block per day (naps drop out). The
     * imported + computed sets can overlap; both are unioned and the learner de-dupes per day by length.
     * Mirrors Swift `IntelligenceEngine.computeHabitualSleep`. (#547)
     */
    /**
     * CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for sessions overlapping
     * [from, to], expanded to timestamped (ts, state) samples on the 30 s epoch grid, for the H7
     * morning-stillness guard's re-onset confirmation. Reads the computed sessions in the window, then each
     * one's persisted per-epoch sleep_state (null when never banded , first pass / imported night), and maps
     * epoch `i` to `startTs + i*30`. Empty when nothing is banded yet, so the guard simply falls back to the
     * HR bar. Honest: only real banded states are surfaced, never a fabricated reading. The grid here mirrors
     * SleepStager's 30 s epoch grid, so an epoch's timestamp lands inside the candidate run it scores. Mirrors
     * Swift `IntelligenceEngine.bandSleepStateSamples`. (#531 / H8 consume)
     */
    private suspend fun bandSleepStateSamples(
        repo: WhoopRepository,
        computedId: String,
        from: Long,
        to: Long,
    ): List<Pair<Long, Int>> {
        val epochS = 30L
        // #899: collapse overlapping timebase-shifted duplicates BEFORE consuming band state. A stale
        // re-banked copy of the night would otherwise feed "asleep" epochs at the OLD times into the H7
        // re-onset guard, letting the stale block keep confirming itself. Read-side only (no bank-recency
        // witness here); the store itself is healed post-upsert in analyzeRecentOnCpu. Mirrors Swift.
        val sessions = SleepSessionDedup.dedupe(repo.sleepSessions(computedId, from, to, 4000)).kept
        val samples = ArrayList<Pair<Long, Int>>()
        for (s in sessions) {
            val states = repo.sessionSleepState(computedId, s.startTs) ?: continue
            if (states.isEmpty()) continue
            for ((i, st) in states.withIndex()) {
                samples.add((s.startTs + i * epochS) to st)
            }
        }
        return samples
    }

    /**
     * Habitual midsleep (local seconds) AND the trailing per-night sleep DURATIONS (hours,
     * chronological) from the stored sessions over the window — the longest block per LOCAL day, so
     * naps drop out. One read serves both the main-night midsleep learner (#547) and the personal
     * sleep-need + regularity that thread into `analyzeDay` (Wave 0 · SL1/T1). The midsleep result is
     * byte-identical to before; the nightly-hours output is the extension. Mirrors Swift
     * `IntelligenceEngine.computeHabitualSleep`.
     */
    private suspend fun computeHabitualSleep(
        repo: WhoopRepository,
        importedId: String,
        computedId: String,
        windowStart: Long,
        windowEnd: Long,
        offsetSec: Long,
    ): Pair<Long?, List<Double>> {
        val imported = repo.sleepSessions(importedId, windowStart, windowEnd, 4000)
        val computed = repo.sleepSessions(computedId, windowStart, windowEnd, 4000)
        // #899: collapse overlapping timebase-shifted duplicates BEFORE the learner sees the history.
        // A stale re-banked copy of a night lands on a DIFFERENT day key, so the per-day longest-block
        // de-dup below never caught it and the learned midsleep drifted toward the stale timing, which
        // then steered the main-night pick (day assignment) to the stale block. The same collapse also
        // covers an imported night and its computed twin (the longest capture wins, exactly what the
        // per-day length rule chose anyway). Mirrors Swift.
        val merged = SleepSessionDedup.dedupe(imported + computed).kept
        // Longest block per LOCAL day (naps drop out), chosen by in-bed SPAN — reused for BOTH the
        // midsleep learner and the per-night durations (Wave 0 · SL1/T1), so the two can never read a
        // different history. For the DURATIONS we keep TST (span × efficiency), NOT the in-bed span:
        // the need/regularity estimate must be in the same asleep-time units as the `tstSeconds` Rest
        // scores against, or need reads systematically high (an in-bed span over-counts ~0.85 h vs
        // TST). Efficiency is 0..1 (post the v26 unit-heal); a rare null main night falls back to a
        // typical 0.9. Byte-identical to the Swift twin, same operation order.
        val longestByDay = HashMap<String, Pair<Long, Double>>()   // dayKey -> (span, tstHours)
        val blocks = merged.mapNotNull { s ->
            val start = s.effectiveStartTs
            val end = s.endTs
            if (end <= start) {
                null
            } else {
                val mid = start + (end - start) / 2
                val dayKey = AnalyticsEngine.dayString(mid, offsetSec)
                val span = end - start
                if (span > (longestByDay[dayKey]?.first ?: 0L)) {
                    val eff = s.efficiency?.takeIf { it > 0.0 && it <= 1.0 } ?: 0.9
                    longestByDay[dayKey] = span to (span.toDouble() / 3600.0 * eff)
                }
                SleepStageTotals.HistoryBlock(start, end, dayKey)
            }
        }
        val midsleep = SleepStageTotals.habitualMidsleepSec(blocks, offsetSec)
        // Chronological (day-key string sort == date order) so a recent-window suffix is well-defined.
        val nightlyHours = longestByDay.keys.sorted().mapNotNull { longestByDay[it]?.second }
        return midsleep to nightlyHours
    }

    /**
     * Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
     * night's blocks was edited. Substitutes each edited block (matched by its stable detected startTs)
     * for its detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped
     * stages, so the Rest composite and recovery score the corrected sleep , not the auto-detected
     * window. No edit touching the night → the detected daily is returned unchanged. Faithful twin of
     * Swift `IntelligenceEngine.sleepEditedDaily`. (#318 / PR #395)
     */
    /**
     * #299: the edited / hand-logged sleep rows that belong to [day] — the ones whose edits may be folded
     * into THAT day's sleep total. An edit belongs to the day its night ENDS on (`dayString(endTs)`),
     * matching AnalyticsEngine's end-day session bucket; `endTs` is stable under a bedtime edit (only the
     * onset moves). Scoping this per day is the fix: the edit set was built window-wide and
     * [sleepEditedDaily] folds any row that isn't a twin of a day's detected sessions in as a "manual"
     * block, so one edit / nap leaked its total onto EVERY night. Pure + internal so it's unit-testable.
     * Byte-identical twin of Swift `IntelligenceEngine.editedRowsForDay`.
     */
    internal fun editedRowsForDay(
        editedRows: List<SleepSession>,
        day: String,
        tzOffsetSeconds: Long,
    ): List<SleepSession> = editedRows.filter { AnalyticsEngine.dayString(it.endTs, tzOffsetSeconds) == day }

    private fun sleepEditedDaily(
        daily: DailyMetric,
        detected: List<DetectedSleep>,
        editsByStart: Map<Long, String?>,
        // Each EDITED block's EFFECTIVE onset (startTsAdjusted ?: startTs) keyed by its stable detected
        // startTs , audit finding C / #8. A detected-but-unedited block isn't in here and falls back to its
        // own detected start (DetectedSleep carries no adjustment). (#547)
        editOnsetByStart: Map<Long, Long>,
        tzOffsetSeconds: Long,
        // The learned habitual midsleep (local time-of-day seconds) so the edited recompute picks the SAME
        // main night the Sleep tab shows; null = cold-start. (#547)
        habitualMidsleepSec: Long?,
    ): DailyMetric {
        if (editsByStart.isEmpty()) return daily
        // Match the Swift seam: detected blocks keyed by their stable startTs + their re-encoded stages.
        val detectedTuples = detected.map { it.start to AnalyticsEngine.encodeStages(it.stages) }
        // A hand-logged nap is a userEdited row with NO detected twin , pass those twinless rows through
        // the union channel so the seam KNOWS about them (they stay their own session row, shown
        // separately; the main-night pick below decides the headline total). (#518/#508)
        val detectedStarts = detected.map { it.start }.toHashSet()
        val manual = editsByStart.filter { it.key !in detectedStarts }.map { it.key to it.value }
        // #525/#547: supply each block's EFFECTIVE onset (audit finding C / #8) keyed by its stable
        // detected startTs, plus the device tz offset + learned habitual midsleep, so the edited recompute
        // picks the SAME MAIN NIGHT the Sleep tab shows. The onset must be the user-CORRECTED bedtime
        // (`startTsAdjusted ?: startTs`) when a block was edited, NOT the immutable detected start , a
        // bedtime edit crossing the overnight boundary would otherwise let the seam and the Sleep tab pick
        // different blocks. `editOnsetByStart` holds the corrected onset for edited/manual blocks; an
        // unedited detected block falls back to its own detected start. Without these the seam falls back
        // to the legacy SUM and an overnight+nap day would re-include the nap in the headline total.
        val editStarts = detectedTuples.map { it.first } + manual.map { it.first }
        val onsetByStart = editStarts.associateWith { start -> editOnsetByStart[start] ?: start }
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detectedTuples, editsByStart, manual, onsetByStart, tzOffsetSeconds, habitualMidsleepSec,
        ) ?: return daily
        if (!r.editApplied) return daily
        val agg = r.sleep
        // Substitute ONLY the sleep-derived fields; every non-sleep field is left untouched.
        return daily.copy(
            totalSleepMin = agg.totalSleepMin,
            efficiency = agg.efficiency,
            deepMin = agg.deepMin,
            remMin = agg.remMin,
            lightMin = agg.lightMin,
        )
    }

    /**
     * Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
     * baseline, mirroring the avgHrv→recovery re-score. Null when the night had no wear-gated mean or
     * the skin-temp baseline isn't usable yet (< minNightsSeed) , honest cold-start. Rounded to 2 dp
     * to match the imported/demo precision. APPROXIMATE. (PR #85)
     */
    /** Assess Fitness Age readiness from [gateDays] (the merged last-7 the readiness card counts) and,
     *  when ready, build the fitness_age (+ optional vo2max) rows keyed to [satKey]. Empty when not ready.
     *  The SINGLE source of the gate + compute , shared by the recompute pass and the manual "refresh
     *  Fitness Age" button so the two can never drift. */
    fun fitnessAgeRows(
        gateDays: List<DailyMetric>, profile: UserProfile, computedId: String, satKey: String,
    ): List<MetricSeriesRow> {
        val rhrs = gateDays.mapNotNull { it.restingHr }.map { it.toDouble() }
        val strains = gateDays.mapNotNull { it.strain }.filter { it >= 30.0 }
        val meanStrain = if (strains.isEmpty()) 0.0 else strains.average()
        val waist = if (profile.waistCm > 0) profile.waistCm else null
        val ready = FitnessAgeEngine.assessReadiness(
            hasAge = profile.age > 0, hasSex = profile.sex.isNotEmpty(),
            rhrDays = rhrs.size, activityDays = gateDays.mapNotNull { it.strain }.size,
            hasHeightWeight = profile.heightCm > 0 && profile.weightKg > 0, hasWaist = waist != null)
        if (!ready.canCompute) return emptyList()
        val res = FitnessAgeEngine.compute(
            age = profile.age, sex = profile.sex,
            restingHR = medianOfDoubles(rhrs),
            paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(strains.size, meanStrain),
            waistCm = waist) ?: return emptyList()
        val rows = mutableListOf(MetricSeriesRow(deviceId = computedId, day = satKey, key = "fitness_age", value = res.fitnessAge))
        res.vo2max?.let { rows.add(MetricSeriesRow(deviceId = computedId, day = satKey, key = "vo2max_est", value = it)) }
        return rows
    }

    /** Manual "refresh Fitness Age" (the button on the not-ready card): recompute the weekly Fitness Age
     *  NOW from the PERSISTED merged daily history , NO raw-HR rescoring , and upsert it. Uses the same gate
     *  ([fitnessAgeRows]) and the same date/window logic as the recompute pass, so it reads exactly what the
     *  readiness card shows. Light + connection-independent (stored data only), so it works even when the
     *  strap is offline. Returns true if a value was written. */
    suspend fun recomputeFitnessAgeOnly(
        repo: WhoopRepository, profile: UserProfile, importedDeviceId: String, maxDays: Int = 21,
    ): Boolean {
        val computedId = importedDeviceId + "-noop"
        val nowSeconds = System.currentTimeMillis() / 1_000L
        val tzOffsetSeconds = java.util.TimeZone.getDefault().getOffset(nowSeconds * 1_000L) / 1_000L
        val nowLocalMidnight = midnightLocal(nowSeconds, tzOffsetSeconds)
        val newestDay = AnalyticsEngine.dayString(nowLocalMidnight, tzOffsetSeconds)
        val oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * SECONDS_PER_DAY, tzOffsetSeconds)
        val gate7 = repo.daysMerged(importedDeviceId)
            .filter { it.day in oldestDay..newestDay }.sortedBy { it.day }.takeLast(7)
        val rows = fitnessAgeRows(gate7, profile, computedId, saturdayKeyOnOrBefore(newestDay))
        if (rows.isNotEmpty()) repo.upsertMetricSeries(rows)
        return rows.isNotEmpty()
    }

    private fun recomputeSkinTempDev(nightly: Double?, base: BaselineState?): Double? {
        val v = nightly ?: return null
        val b = base?.takeIf { it.usable } ?: return null
        // Round HALF-AWAY-FROM-ZERO to 2 dp to match Swift's Double.rounded()
        // (IntelligenceEngine.swift:291). Math.round() is half-UP and would diverge on negative
        // .5 ties (e.g. −2.5 → −2 here vs Swift's −3). (Cross-platform parity.)
        val scaled = Baselines.deviation(v, b).delta * 100.0
        val r = if (scaled >= 0) Math.floor(scaled + 0.5) else Math.ceil(scaled - 0.5)
        return r / 100.0
    }

    private fun medianOfDoubles(xs: List<Double>): Double {
        if (xs.isEmpty()) return 0.0
        val s = xs.sorted(); val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
    private fun saturdayKeyOnOrBefore(dayStr: String): String = try {
        val d = java.time.LocalDate.parse(dayStr)               // yyyy-MM-dd
        val back = (d.dayOfWeek.value + 1) % 7                  // SAT->0, SUN->1, MON->2 ... FRI->6
        d.minusDays(back.toLong()).toString()
    } catch (e: Exception) { dayStr }

    /**
     * Resolve the SINGLE device that owns [day] (invariant I2), so the day is scored from exactly one
     * source , never a mix. A locked override (dayOwnership) wins outright and skips the presence checks.
     * Otherwise builds one [DayOwnerResolver.Candidate] per device from [candidatePriorities] with a CHEAP
     * per-day presence flag (one `LIMIT 1` HR read per device over the night window), and returns the
     * lowest-priority candidate that has data. Returns [importedDeviceId] when [ownerSource] is null or
     * the resolver yields no owner , so the legacy single-source path is preserved.
     *
     * Single-device install: the only paired row is the seeded active 'my-whoop' (== [importedDeviceId]).
     * Its candidate is priority 0 with hasData==true for any day the strap collected HR, so the resolver
     * returns [importedDeviceId] and the caller's reads are byte-identical to the pre-I2 code. The presence
     * check is the same `LIMIT 1` over the same window the caller already reads. Mirrors the Swift
     * IntelligenceEngine.resolveDayOwner.
     */
    private suspend fun resolveDayOwner(
        repo: WhoopRepository,
        ownerSource: DayOwnerSource?,
        candidatePriorities: List<Pair<String, Int>>,
        day: String,
        from: Long,
        to: Long,
        importedDeviceId: String,
    ): String {
        if (ownerSource == null) return importedDeviceId
        // A locked override wins outright and skips the presence checks entirely.
        ownerSource.lockedOwner(day)?.let { return it }
        if (candidatePriorities.isEmpty()) return importedDeviceId
        // #970: on the default single-WHOOP install the registry holds exactly ONE live candidate and it
        // IS the fallback id, so the owner is a foregone conclusion — with data the resolver returns the
        // candidate's own id; with none it returns null and the caller's fallback applies; both are
        // [importedDeviceId] here. Skip the per-candidate LIMIT-1 HR probe in that case: this function
        // runs once per scanned day, so the probe cost ~maxDays tiny reads per analyzeRecent for a
        // question with one possible answer. Deliberately gated on `== importedDeviceId`, NOT just
        // size == 1: a lone IMPORT candidate under a DIFFERENT id is not equivalent (its no-data day must
        // fall back to [importedDeviceId], not resolve to its own id), so it still takes the probe path.
        // Byte-identical to the loop below. Mirrors the Swift IntelligenceEngine.resolveDayOwner #970 fix.
        if (candidatePriorities.size == 1 && candidatePriorities.first().first == importedDeviceId) {
            return importedDeviceId
        }
        val candidates = candidatePriorities.map { (id, priority) ->
            // Cheap presence check: a single HR row for this device in the night window marks it a
            // candidate. (LIMIT 1 , not the full pull the caller does once an owner is chosen.)
            val hasData = repo.hrSamples(id, from, to, 1).isNotEmpty()
            DayOwnerResolver.Candidate(deviceId = id, priority = priority, hasData = hasData)
        }
        return DayOwnerResolver.resolve(day, lockedOwner = null, candidates = candidates) ?: importedDeviceId
    }

    /**
     * Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. AnalyticsEngine.dayString
     * uses UTC, so UTC midnight = ts - floorMod(ts, 86400). floorMod is correct for any sign.
     */
    /**
     * Merge one metric's on-device pass-1 nightly values into the imported-history map.
     * Imported (cloud) values WIN per day; the computed estimate only fills days the import
     * does not cover at all (key absent). Mirrors the Swift `mergeNightlyIntoHistory`.
     */
    internal fun mergeNightlyIntoHistory(
        hist: LinkedHashMap<String, Double?>,
        nightly: Map<String, Double?>,
    ) {
        // `day !in hist` only checks KEY presence — an imported row with a null
        // value would shadow the real computed night forever, starving the
        // baseline (the "Needs the strap" bug). `hist[day] == null` is true for
        // both absent keys and null values: imported non-null wins, a null (or
        // absent) slot is backfilled by the computed value.
        for ((day, v) in nightly) if (hist[day] == null) hist[day] = v
    }

    internal fun midnightUtc(ts: Long): Long = ts - Math.floorMod(ts, SECONDS_PER_DAY)

    /**
     * Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). [offsetSec] is
     * seconds EAST of UTC. Shift into local time, floor to the local day, shift back:
     * `ts - floorMod(ts + offsetSec, 86400)`. Math.floorMod keeps the floor correct for negative
     * offsets and negative timestamps. [offsetSec] == 0 reduces exactly to [midnightUtc]. Mirrors the
     * Swift IntelligenceEngine.midnightLocal byte-for-byte.
     */
    internal fun midnightLocal(ts: Long, offsetSec: Long): Long =
        ts - Math.floorMod(ts + offsetSec, SECONDS_PER_DAY)

    /**
     * The per-day diagnostic source token from the imported day-key sets. A WHOOP export covering [day]
     * WINS the dashboard merge over our computed row (imports win field-by-field , mergeDaily), so it
     * takes precedence; Apple Health is next; otherwise the day is purely computed. WHOOP-over-Apple
     * matches the merge's source priority. Pure + set-based so it's unit-tested directly and is the SAME
     * logic the analyzeRecent diagnostic ships. Mirrors Swift `IntelligenceEngine.DaySource.classify`
     * (.logToken). (Sleep overhaul §2.5/§2.6.)
     */
    internal fun daySourceToken(
        day: String,
        importedWhoopDays: Set<String>,
        appleHealthDays: Set<String>,
    ): String = when {
        day in importedWhoopDays -> "imported:whoop"
        day in appleHealthDays -> "imported:apple"
        else -> "computed"
    }

    /**
     * The `stages=` token of the per-day sleep diagnostic line (#386): `<deep>+<rem>+<light>=<sum>` in
     * rounded minutes when the day carries a full banked stage split, `nil` when any component is
     * absent (an unstaged night, or an imported day that only brought a total). The sum is printed
     * rather than left to the reader so a rollup-vs-stages divergence — the exact identity a "homepage
     * disagrees with the Sleep tab" report hinges on — is a one-line visual check against the
     * `totalSleepMin=` field beside it. Pure + unit-tested; mirrors the Swift twin.
     */
    internal fun sleepStagesLogToken(deep: Double?, rem: Double?, light: Double?): String {
        if (deep == null || rem == null || light == null) return "nil"
        return "${Math.round(deep)}+${Math.round(rem)}+${Math.round(light)}=${Math.round(deep + rem + light)}"
    }

    /**
     * CAPTURE-B universal provenance token for the dayOwner diagnostic. Distinct from [daySourceToken]:
     * the universal line reports what the day's data ACTUALLY is, so a day with no HR rows reads `none`
     * (nothing measured or imported), an imported day names its brand, and a day scored from real strap
     * HR reads `measured` (the `computed` token's universal-vocabulary name). An import is named even on a
     * day that also has HR, matching the dashboard merge precedence (imports win). Pure so it's unit-tested.
     */
    internal fun universalProvenanceToken(
        day: String,
        hrRows: Int,
        importedWhoopDays: Set<String>,
        appleHealthDays: Set<String>,
    ): String = when {
        day in importedWhoopDays -> "imported:whoop"
        day in appleHealthDays -> "imported:apple"
        hrRows > 0 -> "measured"
        else -> "none"
    }

    /**
     * The verbatim universal dayOwner diagnostic line (CAPTURE-B). Byte-identical to the iOS lanes' shared
     * contract so a Test Centre export self-diagnoses the read-vs-write identity (the #814/#799 spine bug)
     * and each day's data provenance, and parses the same on either platform. [readId] is the device the
     * day was READ from (the resolved owner); [writeActiveId] is the registry's active strap (where new
     * data is WRITTEN); a mismatch is the spine symptom. Pure so it's unit-tested directly and is the SAME
     * line analyzeRecent ships. No PII (device ids are registry tokens, not addresses; the strap log sink
     * also scrubs). No em-dashes.
     */
    internal fun dayOwnerLine(
        day: String,
        readId: String,
        writeActiveId: String,
        hrRows: Int,
        importedWhoopDays: Set<String>,
        appleHealthDays: Set<String>,
    ): String {
        val provenance = universalProvenanceToken(day, hrRows, importedWhoopDays, appleHealthDays)
        return "dayOwner day=$day readId=$readId writeActiveId=$writeActiveId " +
            "hrRows=$hrRows provenance=$provenance"
    }

    /** #1331 diagnostic line: the night's computed respiratory rate (breaths/min) or "nil". Format kept
     *  simple so the planned Swift twin (iOS #1331 follow-up) can match it byte-for-byte. */
    internal fun respRateLogLine(day: String, respRateBpm: Double?): String =
        "resp day=$day rpm=${respRateBpm?.let { String.format(Locale.US, "%.1f", it) } ?: "nil"}"

    /**
     * The per-day RHR floor-vs-mean diagnostic line (#691). NOOP's [floor] is the WHOOP-style resting
     * HR , the lowest SUSTAINED 5-min in-bed level (SleepStager picks the min 5-min rolling-mean HR per
     * session, the day takes the min across them) , whereas a "sleeping HR" app reports the night MEAN
     * over the whole asleep span. The mean always sits at-or-above the floor, so NOOP reading lower is
     * BY DESIGN, not a bug; logging both makes a "NOOP RHR is lower than my other app" report explainable
     * from the strap log. [inBedBpms] is the bpm of every HR sample inside a matched in-bed session (the
     * SAME span the floor came from, so the two numbers are directly comparable). Empty in-bed → nightMean
     * is "nil". Counts/bpm only , no timestamps or PII. Pure so it's unit-tested directly and is the SAME
     * line analyzeRecent ships. Byte-identical to the Swift `rhrFloorMeanLogLine`.
     */
    internal fun rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: List<Int>): String {
        val meanLog = if (inBedBpms.isEmpty()) "nil"
            else Math.round(inBedBpms.sum().toDouble() / inBedBpms.size).toString()
        return "rhr day=$day floor=$floor nightMean=$meanLog inBedSamples=${inBedBpms.size} " +
            "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)"
    }

    /**
     * #1244: one line for a day that CLEARED the >=200-HR gate yet detected NO in-bed session, so the
     * dashboard shows "HR tracked but no sleep". Today only the summary `sleep day=... totalSleepMin=nil`
     * rides the log — with no clue WHY, since every other night trace (`rhr`/`rrsample`/`hrv diag`) only
     * emits once a session exists. This names the raw inputs the stager was handed so the next capture
     * separates the causes: `grav=0` = no motion offloaded (the in-bed detector can't gate — the WHOOP
     * 4.0 sparse-motion path has no HR-only fallback); a large `hr` with a night still empty = coverage
     * gap or the sleep hours fell outside `window`; `provided=` = a persisted hypnogram was (not) available.
     * Counts + a window length only — same privacy class as the sibling `sleep day=` line, no PII. Pure so
     * it's unit-tested directly; byte-identical to the Swift `sleepDetectNoNightLogLine`.
     */
    internal fun sleepDetectNoNightLogLine(
        day: String, hrCount: Int, rrCount: Int, respCount: Int, gravCount: Int,
        stepCount: Int, providedCount: Int, windowHours: Int,
    ): String {
        return "sleep-detect day=$day NO-NIGHT hr=$hrCount rr=$rrCount resp=$respCount " +
            "grav=$gravCount steps=$stepCount provided=$providedCount window=${windowHours}h"
    }

    /**
     * #674/#1244: the "sleep total with no matched session" divergence line. A COMPUTED day whose fresh
     * scoring pass matched ZERO detected sleep sessions yet still carries a non-null totalSleepMin — the
     * value comes from a folded edited/hand-logged block (sleepEditedDaily) on a day the detector staged
     * nothing (often a day absorbed into a neighbour's coupled window, so it never got its own pass). That
     * total leaks to Today/Coupled while the Sleep tab (session-backed) shows nothing. [editFold] = how
     * many edited/manual rows folded a total onto this session-less day, so the next capture proves whether
     * it's an orphaned edit. Counts only, no PII. Pure; byte-identical to the Swift `sleepDivergenceLogLine`.
     */
    internal fun sleepDivergenceLogLine(day: String, totalSleepMin: Int, editFold: Int): String =
        "sleep divergence day=$day totalSleepMin=$totalSleepMin matched=0 editFold=$editFold"

    /**
     * #1248: the device ids the banked-sleep heal (#899) must sweep — the computed-scores id AND every
     * registered device id. A live source (an Oura ring) banks its OWN hypnogram under its OWN device id,
     * so a computedId-only heal never sees (or collapses) those rows, and they are re-read as
     * `providedSleep` and re-detected every pass — one night ballooned to 14 stored rows / 9 phantom
     * "naps". The de-duplicated union, sorted for a deterministic sweep order. Pure so it's unit-tested
     * directly; byte-identical to the Swift `healDeviceIds`.
     */
    internal fun healDeviceIds(computedId: String, registeredIds: List<String>): List<String> =
        (listOf(computedId) + registeredIds).toSortedSet().toList()
}
