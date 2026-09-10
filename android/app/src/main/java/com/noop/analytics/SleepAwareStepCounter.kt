package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.StepSample
import com.noop.data.V18AuxRow

/**
 * Sleep-context wrapper around [StepsCounter]. It keeps the incumbent counter/class/rate rules, but does
 * not accept an isolated strap "walk" tick as proof that a sleeping person walked. Inside a scored sleep
 * stage, valid locomotion deltas must form a short, temporally coherent bout. An explicitly scored wake
 * gap is intentionally treated like ordinary awake time, so getting up for a child or the toilet counts.
 *
 * This kernel returns raw counter ticks exactly as [StepsCounter] does. It deliberately applies neither a
 * learned conversion factor nor a fixed wrist orientation: a strap may be worn on either arm, a limb or
 * clothing. Gravity/dynamic-acceleration and v18 auxiliary data are accepted for observability and future
 * shadow validation, but are not yet trusted as production gates. When either stream is absent, the
 * conservative temporal bout rule remains deterministic and fail-safe.
 */
object SleepAwareStepCounter {
    /** A one- or two-second bed movement cannot satisfy all three bout floors. */
    const val MAX_SECONDS_BETWEEN_GAIT_DELTAS: Long = 3L
    const val MIN_GAIT_BOUT_DURATION_SECONDS: Long = 4L
    const val MIN_GAIT_BOUT_ACTIVE_SAMPLES: Int = 5
    const val MIN_GAIT_BOUT_TICKS: Int = 6

    data class Count(
        val totalTicks: Int,
        val acceptedOutsideSleepTicks: Int,
        val acceptedAwakeGapTicks: Int,
        val acceptedSleepBoutTicks: Int,
        val rejectedIsolatedSleepTicks: Int,
        val rejectedActivityClassTicks: Int,
        val rejectedImplausibleTicks: Int,
        /** Availability only; neither raw stream changes the production decision yet. */
        val gravitySamplesAvailable: Int,
        val auxSamplesAvailable: Int,
    ) {
        operator fun plus(other: Count): Count = Count(
            totalTicks + other.totalTicks,
            acceptedOutsideSleepTicks + other.acceptedOutsideSleepTicks,
            acceptedAwakeGapTicks + other.acceptedAwakeGapTicks,
            acceptedSleepBoutTicks + other.acceptedSleepBoutTicks,
            rejectedIsolatedSleepTicks + other.rejectedIsolatedSleepTicks,
            rejectedActivityClassTicks + other.rejectedActivityClassTicks,
            rejectedImplausibleTicks + other.rejectedImplausibleTicks,
            gravitySamplesAvailable + other.gravitySamplesAvailable,
            auxSamplesAvailable + other.auxSamplesAvailable,
        )

        companion object {
            val EMPTY = Count(0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
    }

    /** Preserve scored stages while edited leading/trailing edges remain conservatively inside sleep. */
    fun withBounds(session: DetectedSleep, start: Long, end: Long): DetectedSleep =
        session.copy(start = start, end = end)

    /** Effective bounds + stage content affecting exactly this cycle; unrelated sleep edits stay out. */
    fun contextSignature(sessions: List<DetectedSleep>, onset: Long, endExclusive: Long): String =
        sessions.asSequence()
            .filter { it.end > onset && it.start < endExclusive }
            .sortedWith(compareBy<DetectedSleep> { it.start }.thenBy { it.end })
            .joinToString("|") { session ->
                buildString {
                    append(session.start).append('-').append(session.end)
                    for (stage in session.stages.sortedBy { it.start }) {
                        append(':').append(stage.start).append('-').append(stage.end).append('=').append(stage.stage)
                    }
                }
            }

    /** Same nullable convention as [StepsCounter.stepsInWindow]: no accepted movement is `null`. */
    fun stepsInWindow(
        samples: List<StepSample>,
        sleepSessions: List<DetectedSleep>,
        gravity: List<GravitySample> = emptyList(),
        aux: List<V18AuxRow> = emptyList(),
    ): Int? = count(samples, sleepSessions, gravity, aux).totalTicks.takeIf { it > 0 }

    /** Detailed form intended for the Test Centre/shadow trace. */
    fun count(
        samples: List<StepSample>,
        sleepSessions: List<DetectedSleep>,
        gravity: List<GravitySample> = emptyList(),
        aux: List<V18AuxRow> = emptyList(),
    ): Count {
        val sorted = samples.sortedBy { it.ts }
        return Accumulator(sleepSessions, StepsCounter.hasActivityClasses(sorted))
            .observeMotionPage(gravity, aux)
            .acceptPage(sorted)
            .finish()
    }

    /**
     * Page-safe form for database windows larger than an in-memory query limit. The caller determines
     * [hasActivityClasses] once for the complete window (for example with an EXISTS query) and keeps one
     * accumulator for every ascending page. The previous counter sample and an unfinished in-sleep gait
     * bout survive page boundaries, so paging cannot change the answer.
     *
     * Pages may overlap at their boundary: timestamps already consumed are ignored. Calling [finish]
     * closes the last gait bout and makes the accumulator immutable.
     */
    class Accumulator(
        sleepSessions: List<DetectedSleep>,
        private val hasActivityClasses: Boolean,
    ) {
        private val sessions = sleepSessions.sortedBy { it.start }
        private var previous: StepSample? = null
        private var outside = 0
        private var awakeGap = 0
        private var sleepBout = 0
        private var rejectedSleep = 0
        private var rejectedClass = 0
        private var rejectedImplausible = 0
        private var gravityAvailable = 0
        private var auxAvailable = 0
        private var finished = false
        private val pendingSleepBout = ArrayList<Delta>()

        fun observeMotionPage(
            gravity: List<GravitySample> = emptyList(),
            aux: List<V18AuxRow> = emptyList(),
        ): Accumulator = apply {
            check(!finished) { "Accumulator is already finished" }
            gravityAvailable += gravity.size
            auxAvailable += aux.size
        }

        fun acceptPage(samples: List<StepSample>): Accumulator = apply {
            check(!finished) { "Accumulator is already finished" }
            for (current in samples.sortedBy { it.ts }) {
                val prior = previous
                if (prior != null && current.ts <= prior.ts) continue
                previous = current
                if (prior == null) continue

                val delta = (current.counter - prior.counter) and 0xFFFF
                if (!StepsCounter.shouldCountDelta(current.activityClass, hasActivityClasses)) {
                    rejectedClass += delta
                    continue
                }
                if (!StepsCounter.isPlausibleDelta(prior.ts, current.ts, delta)) {
                    rejectedImplausible += delta
                    continue
                }

                when (contextAt(current.ts, sessions)) {
                    Context.OUTSIDE_SLEEP -> {
                        flushSleepBout()
                        outside += delta
                    }
                    Context.AWAKE_GAP -> {
                        flushSleepBout()
                        awakeGap += delta
                    }
                    Context.SCORED_SLEEP -> {
                        val last = pendingSleepBout.lastOrNull()
                        if (last != null && current.ts - last.ts > MAX_SECONDS_BETWEEN_GAIT_DELTAS) {
                            flushSleepBout()
                        }
                        pendingSleepBout += Delta(current.ts, delta)
                    }
                }
            }
        }

        fun finish(): Count {
            if (!finished) {
                flushSleepBout()
                finished = true
            }
            return Count(
                totalTicks = outside + awakeGap + sleepBout,
                acceptedOutsideSleepTicks = outside,
                acceptedAwakeGapTicks = awakeGap,
                acceptedSleepBoutTicks = sleepBout,
                rejectedIsolatedSleepTicks = rejectedSleep,
                rejectedActivityClassTicks = rejectedClass,
                rejectedImplausibleTicks = rejectedImplausible,
                gravitySamplesAvailable = gravityAvailable,
                auxSamplesAvailable = auxAvailable,
            )
        }

        private fun flushSleepBout() {
            if (pendingSleepBout.isEmpty()) return
            val ticks = pendingSleepBout.sumOf { it.ticks }
            val duration = pendingSleepBout.last().ts - pendingSleepBout.first().ts
            val coherent = pendingSleepBout.size >= MIN_GAIT_BOUT_ACTIVE_SAMPLES &&
                duration >= MIN_GAIT_BOUT_DURATION_SECONDS &&
                ticks >= MIN_GAIT_BOUT_TICKS
            if (coherent) sleepBout += ticks else rejectedSleep += ticks
            pendingSleepBout.clear()
        }
    }

    private data class Delta(val ts: Long, val ticks: Int)
    private enum class Context { OUTSIDE_SLEEP, AWAKE_GAP, SCORED_SLEEP }

    private fun contextAt(ts: Long, sessions: List<DetectedSleep>): Context {
        val session = sessions.firstOrNull { ts >= it.start && ts < it.end } ?: return Context.OUTSIDE_SLEEP
        val stage = session.stages.firstOrNull { ts >= it.start && ts < it.end }
        return if (stage != null && SleepStageVocabulary.isWake(stage.stage)) {
            Context.AWAKE_GAP
        } else {
            // Missing/gapped staging is not evidence of wakefulness. This is intentionally conservative.
            Context.SCORED_SLEEP
        }
    }
}
