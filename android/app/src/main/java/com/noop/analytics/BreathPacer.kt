package com.noop.analytics

import kotlin.math.roundToInt

/*
 * BreathPacer.kt — turn a breathing pace into a deterministic inhale/exhale haptic cue list you can
 * "feel" with your eyes closed, screen-off. PURE + unit-tested; the BLE layer maps each [BreathCue] onto
 * the strap's actual haptic command ([WhoopBleClient.buzz]) and schedules the gaps. No I/O here.
 *
 * Faithful Kotlin mirror of StrandAnalytics/BreathPacer.swift — keep the cue list byte-identical to Swift
 * (cross-platform parity is the contract, pinned by matching golden-vector tests).
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L1 "Act (the pacer)").
 *
 * Felt language (identical to the shipped Breathe screen, so existing users already know it):
 *   • Inhale onset → ONE light pulse  (loops: 1)
 *   • Exhale onset → TWO pulses       (loops: 2)
 * Each WHOOP notification buzz is a FIXED-LENGTH motor pulse — we can't vary on-time per pulse, only the
 * *count* (stacked loops) and the *timing*. So the cue is encoded purely as "fire N loops at offset T".
 *
 * A breath cycle of `bpm` breaths/min lasts 60000/bpm ms; `inhaleFraction` splits it into inhale vs
 * exhale (the calming long-exhale ratio Breathe's "Relax" preset uses is ~0.4 inhale : 0.6 exhale).
 */

/** Which phase of the breath a cue marks. The on-screen orb is driven by the same phase clock. */
enum class BreathPhase {
    /** The start of an inhale — a single light pulse. */
    INHALE,

    /** The start of an exhale — a heavier (two-pulse) cue. */
    EXHALE,
}

/**
 * One element of a paced-breathing haptic schedule: fire [loops] buzz loops at [offsetMs] from session
 * start, marking the onset of [phase]. The BLE layer schedules the wait then calls the proven buzz.
 */
data class BreathCue(
    /** Milliseconds from the start of the session at which to fire this cue. */
    val offsetMs: Int,
    /** Which breath phase this cue marks (inhale = light, exhale = heavy). */
    val phase: BreathPhase,
    /** How many buzz loops to play — the felt-strength language (1 = inhale, 2 = exhale). */
    val loops: Int,
)

object BreathPacer {

    // ── Tunables (Breathe parity) ────────────────────────────────────────────
    /** Loops for an inhale onset — one light pulse, as Breathe fires today. */
    const val INHALE_LOOPS: Int = 1

    /** Loops for an exhale onset — two pulses (heavier), as Breathe fires today. */
    const val EXHALE_LOOPS: Int = 2

    /** Default inhale fraction of the cycle — the calming long-exhale ratio (≈40:60) the "Relax" preset
     *  uses. Exhale gets the remaining 0.6. */
    const val DEFAULT_INHALE_FRACTION: Double = 0.4

    /** Slowest / fastest paces we ever schedule (the resonance sweep band, 4.5–7 br/min). Out-of-range
     *  `bpm` is clamped so the pacer never traps or emits absurd offsets. */
    const val MIN_BPM: Double = 3.0
    const val MAX_BPM: Double = 12.0

    // ── Pacer ────────────────────────────────────────────────────────────────

    /**
     * Build the haptic cue list for [cycles] full breaths at [bpm] breaths/min, splitting each cycle into
     * inhale ([inhaleFraction]) and exhale (the remainder). One inhale cue + one exhale cue per cycle, in
     * time order. Pure: identical inputs → identical list (the HapticClock precedent).
     *
     * [bpm] is clamped to [MIN_BPM, MAX_BPM] and [inhaleFraction] to a safe (0.1…0.9) interior so each
     * phase always carries some duration. [cycles] below 1 yields an empty schedule.
     */
    fun schedule(bpm: Double, inhaleFraction: Double = DEFAULT_INHALE_FRACTION, cycles: Int): List<BreathCue> {
        if (cycles < 1) return emptyList()
        val safeBpm = bpm.coerceIn(MIN_BPM, MAX_BPM)
        val frac = inhaleFraction.coerceIn(0.1, 0.9)

        // Cycle length in ms; integer so offsets are exact and platform-identical (no float drift).
        val cycleMs = (60_000.0 / safeBpm).roundToInt()
        val inhaleMs = (cycleMs.toDouble() * frac).roundToInt()

        val out = ArrayList<BreathCue>(cycles * 2)
        for (c in 0 until cycles) {
            val base = c * cycleMs
            out.add(BreathCue(offsetMs = base, phase = BreathPhase.INHALE, loops = INHALE_LOOPS))
            out.add(BreathCue(offsetMs = base + inhaleMs, phase = BreathPhase.EXHALE, loops = EXHALE_LOOPS))
        }
        return out
    }

    /**
     * Total scheduled duration (ms) of a [cycles]-breath session at [bpm] — [cycles] whole cycles. Handy
     * for the keep-awake / session-length UI without re-deriving the cycle math.
     */
    fun sessionDurationMs(bpm: Double, cycles: Int): Int {
        if (cycles < 1) return 0
        val safeBpm = bpm.coerceIn(MIN_BPM, MAX_BPM)
        val cycleMs = (60_000.0 / safeBpm).roundToInt()
        return cycleMs * cycles
    }
}
