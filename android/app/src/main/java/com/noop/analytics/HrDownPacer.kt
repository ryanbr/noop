package com.noop.analytics

import kotlin.math.roundToInt

/*
 * HrDownPacer.kt — the L2 "buzz-below-heart-rate" relaxation metronome. Give the heart a felt rhythm a few
 * bpm BELOW its current rate; HR tends to drift toward an external rhythmic cue (ISWC 2025). PURE +
 * unit-tested; the live controller reads smoothed HR, calls [next], fires ONE light buzz per returned
 * interval, and re-asks every recompute window. No I/O / BLE here.
 *
 * Faithful Kotlin mirror of StrandAnalytics/HRDownPacer.swift — keep the safety envelope + interval math
 * byte-identical to Swift (cross-platform parity is the contract, pinned by matching golden-vector tests).
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L2).
 *
 * SAFETY ENVELOPE (a relaxation metronome, NOT cardiac control — bounded, never therapeutic):
 *   • Target tempo T = smoothedHR − Δ, where Δ RAMPS from [Config.startDeltaBpm] to [Config.maxDeltaBpm]
 *     over the session so the cue trails the heart down rather than yanking it.
 *   • T never drops below [Config.hrFloorBpm] and never more than [Config.maxDeltaBpm] below live HR.
 *   • The cue TRAILS the heart: T is recomputed every [Config.recomputeSeconds] from fresh smoothed HR.
 *   • Auto-stops when HR settles near a calm target, on timeout, or on user stop.
 *   • If HR DIDN'T fall, the caller says so plainly — no fabricated success (evidence-first rule).
 *
 * We never claim it "lowers your heart rate" as a therapeutic outcome — it offers a rhythm to relax toward.
 */
object HrDownPacer {

    /**
     * The L2 safety + behaviour envelope. Defaults are conservative (spec §L2 / Open Q4). All bpm values
     * are beats/min; durations are seconds.
     */
    data class Config(
        /** Initial Δ below live HR at session start (gentle). */
        val startDeltaBpm: Double = 3.0,
        /** Maximum Δ below live HR (a felt cue, never a shock). */
        val maxDeltaBpm: Double = 8.0,
        /** Seconds over which Δ ramps from start → max. */
        val deltaRampSeconds: Double = 120.0,
        /** Absolute floor for the target tempo — never pace below this rate. */
        val hrFloorBpm: Double = 50.0,
        /** Recompute the target every this-many seconds from fresh smoothed HR (the cue trails the heart). */
        val recomputeSeconds: Double = 15.0,
        /** Stop once smoothed HR is at/under this calm target (the session has done its job). */
        val calmTargetBpm: Double = 60.0,
        /** Hard cap on session length. */
        val maxDurationSeconds: Double = 180.0,
    ) {
        companion object {
            /** The conservative shipped default envelope. */
            val DEFAULT = Config()
        }
    }

    /** Why an L2 session ended — drives the honest outcome copy. */
    enum class StopReason {
        /** HR reached the calm target — the session did its job. */
        SETTLED,

        /** The max-duration cap was hit. */
        TIMEOUT,

        /** Live HR was implausible / out of the resting band (caller should gate before starting). */
        INVALID_HR,
    }

    /**
     * The next step the metronome should take: either fire a pulse at [intervalMs] (one light buzz per
     * target beat), or [stop] with a reason. When [stop], [intervalMs] is null. [targetBpm] is the tempo
     * the controller settled on this step (for the live "78 → settling" UI / logs).
     */
    data class Step(
        /** Inter-pulse interval in ms (60000 / targetBpm), or null when stopping. */
        val intervalMs: Int?,
        /** True when the session should end now. */
        val stop: Boolean,
        /** The target tempo (bpm) chosen this step, or null when stopping with no tempo. */
        val targetBpm: Double?,
        /** Why we stopped (null while running) — for an honest outcome line. */
        val stopReason: StopReason?,
    )

    /**
     * Compute the next metronome step from the current smoothed HR and the elapsed session time.
     *
     * - [currentHR]: latest SMOOTHED live HR (bpm). The caller smooths; the pacer trusts it.
     * - [elapsed]: seconds since session start (drives both the Δ ramp and the timeout).
     *
     * Returns a [Step]: while running, [Step.intervalMs] paces one light pulse per target beat at a tempo
     * `currentHR − Δ(elapsed)`, BOUNDED below by [Config.hrFloorBpm] and by `currentHR − maxDeltaBpm`.
     * Stops (settled / timeout / invalidHR). Pure + monotone in the documented sense: for a given config a
     * non-increasing HR trajectory yields non-increasing target tempos, so the cue only ever trails down.
     */
    fun next(currentHR: Double, elapsed: Double, config: Config = Config.DEFAULT): Step {
        // Implausible HR (caller should gate on the resting band; this is the last-ditch guard).
        if (!currentHR.isFinite() || currentHR <= 0.0) {
            return Step(intervalMs = null, stop = true, targetBpm = null, stopReason = StopReason.INVALID_HR)
        }
        if (elapsed >= config.maxDurationSeconds) {
            return Step(intervalMs = null, stop = true, targetBpm = null, stopReason = StopReason.TIMEOUT)
        }
        if (currentHR <= config.calmTargetBpm) {
            return Step(intervalMs = null, stop = true, targetBpm = null, stopReason = StopReason.SETTLED)
        }

        // Δ ramps linearly start → max over `deltaRampSeconds`, then holds at max.
        val delta = rampedDelta(elapsed, config)

        // Target = HR − Δ, but never below the floor and never below the calm target either (we'd have
        // stopped). Clamp also guarantees we never pace *above* HR.
        var target = currentHR - delta
        if (target < config.hrFloorBpm) target = config.hrFloorBpm
        if (target > currentHR) target = currentHR   // defensive: never pace at/above live HR
        // Keep the cue meaningfully below the heart: at least 1 bpm under, so it's a "below-HR" metronome.
        if (target > currentHR - 1.0) target = maxOf(config.hrFloorBpm, currentHR - 1.0)

        val intervalMs = (60_000.0 / target).roundToInt()
        return Step(intervalMs = intervalMs, stop = false, targetBpm = target, stopReason = null)
    }

    /**
     * The Δ-below-HR for a given elapsed time: linear ramp `startDeltaBpm → maxDeltaBpm` over
     * `deltaRampSeconds`, clamped to `maxDeltaBpm` after. Exposed for tests / the UI ramp readout.
     */
    fun rampedDelta(elapsed: Double, config: Config = Config.DEFAULT): Double {
        if (config.deltaRampSeconds <= 0.0) return config.maxDeltaBpm
        val t = elapsed.coerceIn(0.0, config.deltaRampSeconds) / config.deltaRampSeconds
        return config.startDeltaBpm + (config.maxDeltaBpm - config.startDeltaBpm) * t
    }
}
