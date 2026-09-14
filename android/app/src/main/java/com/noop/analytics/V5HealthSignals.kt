package com.noop.analytics

import com.noop.data.DailyMetric
import kotlin.math.sqrt

/**
 * V5HealthSignals — the small, pure adapter that turns the app's cached merged [DailyMetric] history into
 * the per-night z-scored inputs the three v5 skin-temp-suite engines consume, and runs them once per
 * analytics pass. It owns NO I/O and NO state: the caller (AppViewModel) hands it the already-loaded
 * `recentDays` list + a few prefs/profile flags and gets back a [Snapshot] of engine RESULTS to publish.
 *
 * Why a lightweight z here (not the full [Baselines] EWMA): the cards only need a deviation-against-your-
 * own-recent-range read ("further from your baseline than usual"), and the cached daily columns already
 * carry RHR / HRV / skin-temp-deviation / respiration. A rolling mean+SD over the trailing window is the
 * honest, transparent statistic the spec asks for (an observation about your own number) and keeps this
 * pass cheap + DB-free. The engines themselves (CyclePhaseEngine / CircadianEngine / IllnessSignalEngine)
 * are the byte-for-byte cross-platform maths; this file is only the Android-side input plumbing.
 *
 * NON-CLINICAL: every output is an approximation about the user's own series — never a diagnosis. Cycle
 * awareness is OPT-IN (the caller gates on a default-OFF pref before reading [Snapshot.cycle]).
 *
 * See docs/superpowers/specs/2026-06-19-v5-skin-temp-suite-design.md and the umbrella IA (§2.4 Health hub).
 */
object V5HealthSignals {

    /** Trailing window (nights) for the rolling baseline used to z-score each signal. */
    private const val BASELINE_WINDOW = 30

    /** Minimum trailing nights before a z-score is trusted (mirrors Baselines.minNightsTrust intent). */
    private const val MIN_BASELINE_NIGHTS = 14

    /** The published engine results for the Health hub's skin-temp suite, all already decided. */
    data class Snapshot(
        val cycle: CyclePhaseEngine.Result,
        val bodyClock: CircadianEngine.PhaseEstimate?,
        val illness: IllnessSignalEngine.Result,
        /**
         * Parallel Mahalanobis illness-distance read (IllnessDistance), computed on the SAME illness-ward
         * z-vector as [illness] but NEVER gating the alert: [IllnessSignalEngine] stays the sole fire gate.
         * This only surfaces a "how strong" confidence readout in the Heads-Up card when the engine has
         * already raised. Nullable so an absent illness pass leaves it null. (Augment-only, Option A.)
         */
        val illnessDistance: IllnessDistance.Result?,
        /** True once an HRV or resting-HR baseline can honestly gate an illness heads-up. */
        val baselineTrusted: Boolean,
    )

    /**
     * Run the three engines over [days] (oldest→newest). [cycleOptedIn] gates whether the cycle classifier
     * is run at all (it returns a cheap LEARNING result when off, so the caller can publish unconditionally
     * and the UI's opt-in card still shows). [loggedPeriodStarts] are optional "yyyy-MM-dd" period-start
     * days. [journalContext] supplies the same-day confounder flags for illness suppression.
     */
    fun evaluate(
        days: List<DailyMetric>,
        cycleOptedIn: Boolean,
        loggedPeriodStarts: List<String> = emptyList(),
        journalContext: IllnessSignalEngine.Context = IllnessSignalEngine.Context(),
        habitualWakeHour: Double = 7.0,
        activityBins: List<CircadianEngine.ActivityBin> = emptyList(),
        daysObserved: Int = 0,
    ): Snapshot {
        // #2131: trust belongs to a SIGNAL, not to a row. Counting rows with any vital let fourteen
        // unrelated or mixed measurements lend confidence to an HRV/RHR illness claim even though no
        // one baseline had fourteen observations. Use the same trailing window zAgainst uses for the
        // newest night and mirror iOS's illness gate: a trusted RHR OR HRV baseline may raise. Keep the
        // cycle classifier's existing availability gate separate so this illness fix cannot change it.
        val cycleBaselineUsable = days.count { hasAnyVital(it) } >= MIN_BASELINE_NIGHTS
        val baselineWindow = days.dropLast(1).takeLast(BASELINE_WINDOW).filter { hasAnyVital(it) }
        val rhrBaselineTrusted =
            baselineWindow.count { it.restingHr != null } >= MIN_BASELINE_NIGHTS
        val hrvBaselineTrusted =
            baselineWindow.count { it.avgHrv != null } >= MIN_BASELINE_NIGHTS
        val baselineTrusted = rhrBaselineTrusted || hrvBaselineTrusted

        // ── Per-night z-scores against each signal's trailing rolling baseline ──
        val nights = ArrayList<CyclePhaseEngine.Night>(days.size)
        for ((i, d) in days.withIndex()) {
            val window = days.subList(maxOf(0, i - BASELINE_WINDOW), i)
            nights.add(
                CyclePhaseEngine.Night(
                    day = d.day,
                    tempZ = zAgainst(d.skinTempDevC, window) { it.skinTempDevC },
                    rhrZ = zAgainst(d.restingHr?.toDouble(), window) { it.restingHr?.toDouble() },
                    hrvZ = zAgainst(d.avgHrv, window) { it.avgHrv },
                )
            )
        }

        // ── Cycle awareness (opt-in) ──
        val cycle = if (cycleOptedIn) {
            CyclePhaseEngine.classify(
                nights,
                baselineUsable = cycleBaselineUsable,
                loggedPeriodStarts = loggedPeriodStarts,
            )
        } else {
            CyclePhaseEngine.Result(
                phase = CyclePhaseEngine.Phase.LEARNING,
                confidence = CyclePhaseEngine.Confidence.LEARNING,
                cycleDayLow = null, cycleDayHigh = null, cycleLengthDays = null,
                nextPeriodWindow = null, shiftMarkers = emptyList(),
                note = "Turn on cycle awareness to read a coarse phase from your nightly temperature.",
            )
        }

        // ── Illness heads-up (confounder-suppressed) ──
        val latest = nights.lastOrNull()
        val firedLabels = HashMap<String, String>()
        latest?.rhrZ?.let { if (it >= IllnessSignalEngine.signalZThreshold) firedLabels["restingHR"] = "RHR up" }
        latest?.tempZ?.let { if (it >= IllnessSignalEngine.signalZThreshold) firedLabels["skinTemp"] = "skin temp up" }
        latest?.hrvZ?.let { if (-it >= IllnessSignalEngine.signalZThreshold) firedLabels["hrv"] = "HRV down" }
        val respZ = days.lastOrNull()?.let { d ->
            zAgainst(d.respRateBpm, days.subList(maxOf(0, days.size - 1 - BASELINE_WINDOW), maxOf(0, days.size - 1))) { it.respRateBpm }
        }
        respZ?.let { if (it >= IllnessSignalEngine.signalZThreshold) firedLabels["respiration"] = "respiration up" }

        val illnessInputs = IllnessSignalEngine.Inputs(
            restingHR = latest?.rhrZ?.let { IllnessSignalEngine.SignalReading(it) },
            skinTemp = latest?.tempZ?.let { IllnessSignalEngine.SignalReading(it) },
            // HRV must be oriented illness-ward: HRV ↓ is illness-like, so negate the raw z.
            hrv = latest?.hrvZ?.let { IllnessSignalEngine.SignalReading(-it) },
            respiration = respZ?.let { IllnessSignalEngine.SignalReading(it) },
        )
        val illness = IllnessSignalEngine.evaluate(
            inputs = illnessInputs,
            context = journalContext.copy(baselineTrusted = baselineTrusted),
            firedLabels = firedLabels,
        )

        // PARALLEL Mahalanobis distance on the SAME illness-ward z-vector (RHR up, HRV negated, skin-temp
        // up, respiration up). This NEVER gates the alert: the IllnessSignalEngine above remains the sole
        // fire gate. Computed here only so the Heads-Up card can show a "how strong" confidence band when
        // the engine has already raised. null where a z is absent (dropped from the distance). correlation
        // = null (identity), validated to agree ~100% with the z-sum detector. Mirrors iOS exactly.
        val illnessDistance = IllnessDistance.evaluate(
            features = IllnessDistance.FeatureVector(
                restingHR = latest?.rhrZ,
                rmssd = latest?.hrvZ?.let { -it },   // orient illness-ward: HRV down is illness-like
                skinTemp = latest?.tempZ,
                respiration = respZ,
            ),
            correlation = null,
        )

        // ── Body clock (#852): the caller pools HR by local hour into [activityBins] — the same
        //    activity proxy the Swift twin uses in AppModel.computeCircadianPhase, which has shipped
        //    this card on iOS/macOS all along. Android had the engine, the tests and the card, and only
        //    ever lacked these twenty lines of input, behind a comment claiming the data did not exist.
        //
        //    Under six populated hours is too thin to fit, so it stays null and HealthScreen's `?.let`
        //    skips the card — no fabricated estimate. Both parameters default, so every existing caller
        //    is byte-identical. ──
        val bodyClock: CircadianEngine.PhaseEstimate? =
            if (activityBins.size >= MIN_CIRCADIAN_BINS) {
                CircadianEngine.estimatePhase(activityBins, daysObserved, habitualWakeHour)
            } else {
                null
            }

        return Snapshot(cycle = cycle, bodyClock = bodyClock, illness = illness,
            illnessDistance = illnessDistance, baselineTrusted = baselineTrusted)
    }

    /** Populated local hours needed before a cosinor fit is worth attempting. Mirrors the Swift
     *  twin's `guard bins.count >= 6` in AppModel.computeCircadianPhase. */
    internal const val MIN_CIRCADIAN_BINS = 6

    /** Whether a row can contribute to any signal's baseline; empty rows do not enter trust counts. */
    private fun hasAnyVital(d: DailyMetric): Boolean =
        d.restingHr != null || d.avgHrv != null || d.skinTempDevC != null || d.respRateBpm != null

    /**
     * Z-score [value] against the trailing [window]'s rolling mean + sample SD for [selector]. Returns
     * null when the value is absent or there isn't enough trailing data to trust the spread. A floor on
     * the SD prevents a near-constant series from exploding the z.
     */
    private inline fun zAgainst(
        value: Double?,
        window: List<DailyMetric>,
        selector: (DailyMetric) -> Double?,
    ): Double? {
        if (value == null) return null
        val xs = window.mapNotNull(selector)
        if (xs.size < MIN_BASELINE_NIGHTS) return null
        val mean = xs.average()
        val variance = xs.sumOf { (it - mean) * (it - mean) } / (xs.size - 1).coerceAtLeast(1)
        val sd = sqrt(variance).coerceAtLeast(1e-6)
        return (value - mean) / sd
    }
}
