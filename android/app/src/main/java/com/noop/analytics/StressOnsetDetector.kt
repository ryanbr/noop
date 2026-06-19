package com.noop.analytics

/*
 * StressOnsetDetector.kt — the L3 closed-loop JITAI ("just-in-time adaptive intervention") detector.
 * Generalises the math currently inline in AppModel.evaluateStress() into an EDGE-triggered, motion-gated,
 * REPLAY-SAFE detector that decides — at the moment it matters — whether to offer a 60-s guided breathing
 * cue. PURE + DB-free, carrying its OWN de-dup state exactly like [SedentaryDetector.evaluate]: the caller
 * persists [Decision.nextState] and feeds it back, so a replayed window can't re-fire. No I/O / BLE here.
 *
 * Faithful Kotlin mirror of StrandAnalytics/StressOnsetDetector.swift — keep the EMA baseline, the drop
 * threshold, the edge trigger, the exercise gate, and the rate-limit/quiet-hours suppressors byte-identical
 * to Swift (cross-platform parity is the contract, pinned by matching golden-vector tests).
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
 *
 * WHAT IT GENERALISES (from AppModel.evaluateStress): a rolling clean-R-R buffer → a SLOW RMSSD baseline
 * (the shipped 0.98/0.02 EMA) + a resting-HR band gate (55–100 bpm) + a `rmssd < baseline × 0.6` drop +
 * a once-per-15-min limiter + a single confirming buzz. What this engine ADDS, per spec:
 *   1. A FAST short-window RMSSD (the latest beats) vs the slow baseline.
 *   2. EDGE trigger: fire ONCE on the fresh crossing (was-above → now-below), not every tick.
 *   3. The EXERCISE GATE (the credibility line): suppress when HR is out of the resting band AND/OR recent
 *      motion says "metabolic, not stress". A brisk walk's HRV dip must NOT fire a "you're stressed" cue.
 *   4. Rate-limit + quiet hours + master toggle, and never while a manual Breathe/L1/L2 session runs.
 *
 * HONEST / NON-CLINICAL: "stress" is an autonomic PROXY (HRV-down vs the user's OWN baseline), never a
 * diagnosis. The card the caller shows says "HRV dipped while you were still" — never "you are stressed".
 * On fire: a single confirming buzz + a passive in-app card; NEVER a push notification unless the user
 * opted into notifications (matches DaytimeStress's "passive suggestion, never a notification" stance).
 *
 * All `ts`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.
 */
object StressOnsetDetector {

    // ── Tunables (evaluateStress parity + the new fast/gate pieces) ────────────
    /** Slow-baseline EMA weight on the prior value (the shipped 0.98). New RMSSD gets `1 − this`. */
    const val BASELINE_EMA_ALPHA: Double = 0.98

    /** Fast RMSSD must drop below `baseline × this` to count as a dip (the shipped 0.6 threshold). */
    const val DROP_RATIO: Double = 0.6

    /** Resting HR band — outside it the dip is treated as metabolic (workout), not stress (shipped gate). */
    const val RESTING_HR_LOW: Double = 55.0
    const val RESTING_HR_HIGH: Double = 100.0

    /** Beats in the FAST short window (the latest clean beats) used for the momentary RMSSD. */
    const val FAST_WINDOW_BEATS: Int = 60

    /** Minimum clean beats before either RMSSD is trusted (mirrors [HrvAnalyzer.MIN_BEATS]). */
    val MIN_BEATS: Int = HrvAnalyzer.MIN_BEATS

    /** Rate limit — at most one fire per this many seconds (the shipped 900 s = 15 min). */
    const val MIN_SECONDS_BETWEEN_FIRES: Long = 900L

    /** Recent smoothed wrist-motion (g) at/above this means "moving" → exercise gate suppresses the fire
     *  (reuses the [SedentaryDetector] move threshold so the two gates agree on what "moving" is). */
    val MOTION_GATE_G: Double = SedentaryDetector.DEFAULT_MOVE_THRESHOLD_G

    // ── Config ────────────────────────────────────────────────────────────────

    /**
     * The L3 master/sub toggles + quiet-hours window, passed in as plain values so the engine stays pure.
     * All default OFF / safe — manual-first ethos (the feature is opt-in per layer).
     */
    data class Config(
        /** Master "stress check-ins (haptic)" toggle (default OFF). Inert when off. */
        val enabled: Boolean = false,
        /** Auto-nudge sub-toggle (default OFF) — when off the detector still reports state but never fires. */
        val autoNudge: Boolean = false,
        /** Suppress fires during quiet hours. */
        val quietHoursEnabled: Boolean = false,
        /** Quiet-hours window, local minute-of-day [0,1440) (defaults 22:00 → 07:00). */
        val quietStartMinutes: Int = SedentaryDetector.DEFAULT_QUIET_START_MIN,
        val quietEndMinutes: Int = SedentaryDetector.DEFAULT_QUIET_END_MIN,
        /** Buzz strength (loops) for the confirming buzz — one light pulse, like evaluateStress. */
        val buzzLoops: Int = 1,
    )

    // ── State (de-dup / EMA carry — persisted verbatim, replay-safe) ───────────

    /**
     * The persisted state the detector carries between evaluations (restart-safe). The caller stores this
     * verbatim and feeds the prior value back in, exactly like [SedentaryState]. A fresh user starts from
     * [INITIAL]. Carries the slow EMA baseline (so it survives relaunch), the edge state (was the fast
     * RMSSD below the threshold on the previous tick?), and the rate-limit clock.
     */
    data class State(
        /** Slow RMSSD baseline (EMA), ms. 0 = uninitialised (seeds from the first trusted fast RMSSD). */
        val baselineRMSSD: Double = 0.0,
        /** Whether the fast RMSSD was BELOW the drop threshold on the previous evaluation — drives the
         *  EDGE (we fire only on a fresh above→below crossing, not every tick it stays below). */
        val wasBelow: Boolean = false,
        /** Unix-seconds of the last fire (0 = never) — the rate limiter. */
        val lastFireAt: Long = 0L,
    ) {
        companion object {
            /** Cold-start state (no baseline, not below, never fired). */
            val INITIAL = State()
        }
    }

    // ── Decision ──────────────────────────────────────────────────────────────

    /** Why the detector did / didn't nudge — drives logs and the honest card copy. */
    enum class Reason {
        /** A fresh non-metabolic HRV dip — offer a minute to breathe. */
        ONSET,

        /** Disabled / auto-nudge off. */
        DISABLED,

        /** Too few clean beats to judge honestly. */
        INSUFFICIENT_DATA,

        /** Fast RMSSD is at/above the threshold — no dip. */
        NO_DIP,

        /** The dip isn't a fresh edge (already below last tick). */
        NOT_AN_EDGE,

        /** Suppressed by the exercise gate (HR out of band and/or recent motion = metabolic, not stress). */
        EXERCISE_GATED,

        /** Inside the rate-limit window or quiet hours, or a manual session is running. */
        SUPPRESSED,
    }

    /**
     * The decision returned each evaluation: whether to nudge, why, and the next state to persist. Mirrors
     * [SedentaryDecision]: the caller acts on [shouldNudge] and stores [nextState] (always advanced) so a
     * replayed window can't re-fire.
     */
    data class Decision(
        /** True if the app should offer the breathing cue now (single confirming buzz + passive card). */
        val shouldNudge: Boolean,
        /** Why (whether or not it nudged). */
        val reason: Reason,
        /** Buzz loops to play when [shouldNudge] (the confirming buzz). */
        val buzzLoops: Int,
        /** The fast short-window RMSSD this tick (ms), or null when insufficient — for logs / the card. */
        val fastRMSSD: Double?,
        /** The slow baseline RMSSD this tick (ms), or null when uninitialised. */
        val baselineRMSSD: Double?,
        /** The state to persist for the next evaluation (always carries the advanced EMA / edge / clock). */
        val nextState: State,
    )

    // ── The detector ──────────────────────────────────────────────────────────

    /**
     * Evaluate the live window and decide whether to fire a JITAI nudge.
     *
     * - [rrBuffer]: the rolling clean-able R-R buffer (rrMs, newest LAST). The fast RMSSD is taken over the
     *   latest [FAST_WINDOW_BEATS] clean beats; the slow baseline EMA absorbs each trusted fast value.
     * - [currentHR]: latest smoothed live HR (bpm), or null if unknown (then the HR half of the gate can't
     *   pass and we treat HR as out-of-band — conservative).
     * - [recentMotionG]: recent smoothed wrist-motion (g) from `collector.recentGravity`, or null if no
     *   recent gravity (then the motion half of the gate is inconclusive — see below).
     * - [sessionActive]: true if a manual Breathe/L1/L2 session is already running (never nudge over it).
     * - [state]: the prior persisted state; [nowSec] / [tzOffsetSec] passed IN (never read a clock).
     *
     * The EXERCISE GATE suppresses when EITHER signal says metabolic: HR outside [55,100], OR recent motion
     * at/above [MOTION_GATE_G]. A missing HR is treated as out-of-band (can't confirm resting); missing
     * motion alone does NOT gate (HR-band can carry it — gravity is offloaded and lags, spec Q3), so the
     * resting-HR band is the real-time gate and motion is a secondary confirm when present.
     */
    fun evaluate(
        rrBuffer: List<Int>,
        currentHR: Double?,
        recentMotionG: Double?,
        sessionActive: Boolean,
        state: State,
        config: Config,
        nowSec: Long,
        tzOffsetSec: Long,
    ): Decision {

        // 1) Master gates: off / auto-nudge off → never nudge, state untouched.
        if (!config.enabled || !config.autoNudge) {
            return Decision(
                shouldNudge = false, reason = Reason.DISABLED, buzzLoops = config.buzzLoops,
                fastRMSSD = null, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // 2) Fast RMSSD over the latest clean beats. Clean first (range + Malik), then take the tail.
        val cleanAll = HrvAnalyzer.cleanRR(rrBuffer.map { it.toDouble() })
        val fastWindow = if (cleanAll.size > FAST_WINDOW_BEATS) cleanAll.takeLast(FAST_WINDOW_BEATS) else cleanAll
        val fast = if (fastWindow.size >= MIN_BEATS) HrvAnalyzer.rmssdRaw(fastWindow) else null
        if (fast == null || fast <= 0.0) {
            // Not enough signal — report, don't guess. Edge state is preserved (no crossing observed).
            return Decision(
                shouldNudge = false, reason = Reason.INSUFFICIENT_DATA, buzzLoops = config.buzzLoops,
                fastRMSSD = null, baselineRMSSD = state.baselineRMSSD.takeIf { it > 0.0 },
                nextState = state,
            )
        }

        // 3) Advance the slow baseline EMA (seed on first trusted value), exactly like evaluateStress.
        val newBaseline = if (state.baselineRMSSD == 0.0) {
            fast
        } else {
            state.baselineRMSSD * BASELINE_EMA_ALPHA + fast * (1.0 - BASELINE_EMA_ALPHA)
        }
        var next = state.copy(baselineRMSSD = newBaseline)
        val baseline = newBaseline

        // 4) Is the fast RMSSD below the drop threshold? (the dip test)
        val threshold = baseline * DROP_RATIO
        val isBelow = fast < threshold
        // The edge: a FRESH crossing (above on the previous tick → below now). Always record the new
        // below-state so the NEXT tick can edge-detect, regardless of whether we fire.
        val isEdge = isBelow && !state.wasBelow
        next = next.copy(wasBelow = isBelow)

        fun decide(nudge: Boolean, reason: Reason) = Decision(
            shouldNudge = nudge, reason = reason, buzzLoops = config.buzzLoops,
            fastRMSSD = fast, baselineRMSSD = baseline, nextState = next,
        )

        if (!isBelow) return decide(false, Reason.NO_DIP)
        if (!isEdge) return decide(false, Reason.NOT_AN_EDGE)

        // 5) Exercise gate (the credibility line). HR out of the resting band (or unknown) → metabolic.
        //    Recent motion at/above the gate → metabolic. Either suppresses.
        val hrInBand = currentHR != null && currentHR >= RESTING_HR_LOW && currentHR <= RESTING_HR_HIGH
        val moving = recentMotionG != null && recentMotionG >= MOTION_GATE_G
        if (!hrInBand || moving) return decide(false, Reason.EXERCISE_GATED)

        // 6) Suppressors: a manual session is running, the rate limit, or quiet hours.
        if (sessionActive) return decide(false, Reason.SUPPRESSED)
        if (state.lastFireAt != 0L && (nowSec - state.lastFireAt) < MIN_SECONDS_BETWEEN_FIRES) {
            return decide(false, Reason.SUPPRESSED)
        }
        if (config.quietHoursEnabled) {
            val mod = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec)
            if (SedentaryDetector.windowContains(mod, config.quietStartMinutes, config.quietEndMinutes)) {
                return decide(false, Reason.SUPPRESSED)
            }
        }

        // 7) Fire — a fresh, non-metabolic HRV dip while still. Stamp the rate-limit clock.
        next = next.copy(lastFireAt = nowSec)
        return decide(true, Reason.ONSET)
    }
}
