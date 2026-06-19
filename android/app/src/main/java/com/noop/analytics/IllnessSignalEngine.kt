package com.noop.analytics

// IllnessSignalEngine.kt — multi-signal "Heads-Up" early-warning with explicit false-positive suppression.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift.
//
// INDEPENDENT implementation of the published multi-parameter pre-symptomatic signature documented across
// the wearable literature (e.g. the Stanford/Snyder resting-HR-elevation work and successor studies):
// resting HR ↑, skin temperature ↑, HRV (RMSSD) ↓ and respiration ↑ move TOGETHER, days before symptoms.
// NOOP re-derives the PATTERN, transparently, against the user's OWN rolling baseline — never a population
// cutoff. Replaces the blunt 2-of-4 threshold rule with a calibrated 0–100 score, a ≥2-signal
// corroboration gate, and EXPLICIT confounder suppression cross-checked against the same-day journal tags.
//
// WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. Never names a condition; copy is always "a heads-up to
// rest" / "consider taking it easy".
object IllnessSignalEngine {

    // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──
    const val raiseThreshold: Double = 50.0
    const val mildThreshold: Double = 25.0
    const val minCorroboratingSignals: Int = 2
    const val signalZThreshold: Double = 2.0
    const val kZToScore: Double = 22.0
    const val perSignalCap: Double = 40.0
    const val confounderDampen: Double = 0.45

    /** Standing not-a-diagnosis tail reused verbatim from the shipped IllnessNotifier copy. */
    const val disclaimerTail = "On-device estimate — not a diagnosis."

    // ── Inputs ──

    /**
     * One signal's recent-vs-baseline reading, already z-scored against the personal baseline by the
     * caller. [zIllnessward] is the deviation ORIENTED so positive always means "more illness-like":
     * RHR ↑, skin-temp ↑, respiration ↑ pass their raw z; HRV ↓ passes the NEGATED z. [present] = false
     * means the signal had no usable data and is skipped (not counted as corroboration).
     */
    data class SignalReading(val zIllnessward: Double, val present: Boolean = true)

    /** All four signal readings for the recent window. Any may be absent (sparse 5/MG nights). */
    data class Inputs(
        val restingHR: SignalReading? = null,
        val skinTemp: SignalReading? = null,
        val hrv: SignalReading? = null,
        val respiration: SignalReading? = null,
    )

    /**
     * Same-day behaviour context that can explain an anomaly away. [travelPhaseJump] is the cross-feature
     * hook — CircadianEngine can flag a detected body-clock jump (jet lag). [baselineTrusted] = false →
     * the engine stays silent (don't warn off a cold-start baseline).
     */
    data class Context(
        val alcohol: Boolean = false,
        val stress: Boolean = false,
        val sauna: Boolean = false,
        val hardOrLateWorkout: Boolean = false,
        val travelPhaseJump: Boolean = false,
        val alreadyUnwell: Boolean = false,
        val baselineTrusted: Boolean = true,
    )

    // ── Output ──

    enum class Level(val raw: String) {
        QUIET("quiet"),
        MILD("mild"),
        RAISED("raised"),
        SUPPRESSED("suppressed"),
        ALREADY_UNWELL("alreadyUnwell"),
    }

    data class Result(
        val score: Double,
        val level: Level,
        val firedSignals: List<String>,
        val suppressedBy: List<String>,
        val signalCount: Int,
        val copy: String,
    )

    // ── Evaluate ──

    /**
     * Score the recent window and decide the heads-up level + copy. [firedLabels] maps a signal key to
     * the caller-rendered phrase shown when that signal fires (e.g. {"restingHR": "RHR +6"}). Only keys
     * for signals that clear [signalZThreshold] are surfaced.
     */
    fun evaluate(inputs: Inputs, context: Context, firedLabels: Map<String, String> = emptyMap()): Result {
        // Order is fixed so firedSignals is deterministic across platforms.
        val ordered: List<Pair<String, SignalReading?>> = listOf(
            "restingHR" to inputs.restingHR,
            "skinTemp" to inputs.skinTemp,
            "hrv" to inputs.hrv,
            "respiration" to inputs.respiration,
        )

        var rawScore = 0.0
        val firedKeys = mutableListOf<String>()
        for ((key, reading) in ordered) {
            if (reading == null || !reading.present) continue
            val over = reading.zIllnessward - signalZThreshold
            if (over <= 0) continue
            firedKeys.add(key)
            rawScore += minOf(perSignalCap, kZToScore * over)
        }
        val score = minOf(100.0, rawScore)
        val signalCount = firedKeys.size
        val firedSignals = firedKeys.mapNotNull { firedLabels[it] }

        // Gate 0: untrusted baseline → silent.
        if (!context.baselineTrusted) {
            return Result(score, Level.QUIET, firedSignals, emptyList(), signalCount,
                "Still learning your baseline — keeping an eye out.")
        }

        // Already-unwell path: switch from "early warning" to a gentle "rest up".
        if (context.alreadyUnwell) {
            val agreeing = score >= mildThreshold && signalCount >= 1
            val copy = if (agreeing)
                "Rest up — you logged feeling unwell, and your numbers agree. $disclaimerTail"
            else
                "Rest up — you logged feeling unwell. Take it easy today. $disclaimerTail"
            return Result(score, Level.ALREADY_UNWELL, firedSignals, emptyList(), signalCount, copy)
        }

        // Corroboration + magnitude gate.
        if (signalCount < minCorroboratingSignals || score < mildThreshold) {
            return Result(score, Level.QUIET, firedSignals, emptyList(), signalCount,
                "Nothing notable — your signals look like your normal range.")
        }

        // Confounder suppression — the differentiating part.
        val suppressedBy = mutableListOf<String>()
        if (context.alcohol) suppressedBy.add("alcohol")
        if (context.stress) suppressedBy.add("stress")
        if (context.sauna) suppressedBy.add("sauna")
        if (context.hardOrLateWorkout) suppressedBy.add("a hard or late workout")
        if (context.travelPhaseJump) suppressedBy.add("travel")

        val signalsPhrase = if (firedSignals.isEmpty()) "Some signals are up" else firedSignals.joinToString(", ")

        if (suppressedBy.isNotEmpty()) {
            val dampened = score * confounderDampen
            val reason = joinReasons(suppressedBy)
            val copy = "Some signals are up ($signalsPhrase), but you logged $reason — likely that, " +
                "not illness. $disclaimerTail"
            return Result(dampened, Level.SUPPRESSED, firedSignals, suppressedBy, signalCount, copy)
        }

        // No confounder. Mild stays in the detail view; a strong composite raises.
        if (score < raiseThreshold) {
            val copy = "A few signals are mildly up ($signalsPhrase). Nothing alarming — worth a calmer " +
                "day. $disclaimerTail"
            return Result(score, Level.MILD, firedSignals, emptyList(), signalCount, copy)
        }

        val ruledOut = "no alcohol or travel logged"
        val copy = "Heads-up — your body looks strained. $signalsPhrase. With $ruledOut, consider " +
            "taking it easy. $disclaimerTail"
        return Result(score, Level.RAISED, firedSignals, emptyList(), signalCount, copy)
    }

    // ── Helpers ──

    /** Join named confounders into a natural list ("alcohol", "alcohol and stress", "a, b and c"). */
    internal fun joinReasons(reasons: List<String>): String = when (reasons.size) {
        0 -> "something"
        1 -> reasons[0]
        2 -> "${reasons[0]} and ${reasons[1]}"
        else -> {
            val head = reasons.dropLast(1).joinToString(", ")
            "$head and ${reasons.last()}"
        }
    }
}
