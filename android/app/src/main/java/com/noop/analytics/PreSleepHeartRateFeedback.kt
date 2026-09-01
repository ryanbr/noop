package com.noop.analytics

import com.noop.data.JournalEntry
import com.noop.protocol.HrSample
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * An opt-in, descriptive pre-sleep heart-rate reading for the following morning.
 *
 * Kotlin twin of `StrandAnalytics.PreSleepHeartRateFeedback` (#1784). The caller supplies a
 * timestamp-coalesced HR timeline: the repository's existing HR reads already coalesce measured and
 * PPG-derived samples, with measured data taking precedence. This object selects the longest supplied
 * sleep session, reads the declared half-open window immediately before it, and compares that
 * observation with a personal rolling baseline. It neither diagnoses nor recommends an action. Journal
 * answers are returned only as facts from the same day; one night cannot establish an association, so
 * they never alter the reading or become an insight.
 *
 * PARITY, and the two places this deliberately differs from the Swift original:
 *
 *  - Apple's `SleepSession` is this side's [DetectedSleep] — same shape, the naming divergence that
 *    already exists between the two analytics layers.
 *  - Apple carries session timestamps as `Int`; [DetectedSleep] carries `Long`, so the window
 *    arithmetic here is `Long` and sample timestamps widen at the comparison. The overflow guard is
 *    therefore `Math.subtractExact` rather than `subtractingReportingOverflow`, which is the same
 *    contract — fail closed, never trap — expressed in the idiom each language actually has.
 *
 * Everything that produces a NUMBER is byte-identical by construction: the same [MetricCfg], the same
 * [Baselines.rollingMeanSD], the same [Baselines.computeStatus], and the same HR plausibility range.
 */
object PreSleepHeartRateFeedback {

    /**
     * Baseline configuration deliberately shares the existing HR plausibility range while keeping a
     * small floor spread for transparent personal comparison. `rollingMeanSD` is the existing auditable
     * baseline primitive; this is not a new scoring model.
     */
    val baselineCfg = MetricCfg(
        minVal = SleepHeartRateContrast.VALID_MIN_BPM,
        maxVal = SleepHeartRateContrast.VALID_MAX_BPM,
        floorSpread = 2.0,
        halfLifeB = 14.0,
        halfLifeS = 21.0,
    )
    const val DEFAULT_PRE_SLEEP_WINDOW_SECONDS: Int = 30 * 60
    const val DEFAULT_MINIMUM_VALID_SAMPLES: Int = 10
    val minimumBaselineNights: Int = Baselines.minNightsSeed

    /**
     * A prior eligible pre-sleep observation. Callers persist/assemble history; this pure slice does
     * not write, schedule a prompt, or penalize a missing night.
     */
    data class HistoricalReading(val day: String, val meanBpm: Double)

    /**
     * Why a morning reading is or is not available. Every non-eligible state is recoverable on a
     * later, sufficiently covered night; none creates a streak, goal, or obligation.
     */
    sealed class Eligibility {
        object Disabled : Eligibility()
        object InvalidDay : Eligibility()
        object InvalidWindow : Eligibility()
        object MissingPrimarySleep : Eligibility()
        data class InsufficientPreSleepSamples(val valid: Int, val required: Int) : Eligibility()
        data class InsufficientBaseline(val validNights: Int, val required: Int) : Eligibility()
        data class StaleBaseline(val daysSinceUpdate: Int) : Eligibility()
        object Eligible : Eligibility()
    }

    /**
     * The observed, un-imputed pre-sleep data. Completeness is stated as a sample count because raw
     * HR cadence can vary; this slice does not pretend a count is a percentage of time covered.
     */
    data class Observation(
        val primarySleepStartTs: Long,
        val primarySleepEndTs: Long,
        val windowStartTs: Long,
        val windowEndTs: Long,
        val meanBpm: Double,
        val validSamples: Int,
        val totalTimestampSamples: Int,
    )

    /** A personal comparison only, never a population norm or a health classification. */
    data class Comparison(
        val baselineBpm: Double,
        val deltaBpm: Double,
        val baselineNights: Int,
        val baselineStatus: BaselineStatus,
    )

    /** Explicit limits that a presentation layer must keep visible rather than turning into certainty. */
    sealed class Uncertainty {
        /** The first eligible personal baseline is usable but not yet trusted by [Baselines]. */
        object ProvisionalBaseline : Uncertainty()
        /** There are not yet enough valid historical nights to make any personal comparison. */
        object NoPersonalComparison : Uncertainty()
        /** A mature personal baseline has not received a plausible value recently enough to compare. */
        data class StaleBaseline(val daysSinceUpdate: Int) : Uncertainty()
    }

    /** This slice intentionally makes no causal inference from a single observation or its journal facts. */
    enum class Inference { NOT_ESTABLISHED }

    /** This slice intentionally cannot support a behavior, treatment, or other recommendation. */
    enum class Recommendation { UNSUPPORTED }

    /**
     * A projection of a same-day [JournalEntry]. It preserves what was logged without exposing notes or
     * claiming that the entry explains this reading.
     */
    data class JournalFact(
        val day: String,
        val question: String,
        val answeredYes: Boolean,
        val numericValue: Double?,
    )

    data class Feedback(
        val eligibility: Eligibility,
        val observation: Observation?,
        val comparison: Comparison?,
        val uncertainty: List<Uncertainty>,
        val inference: Inference,
        val recommendation: Recommendation,
        /** Same-day journal facts only. They are deliberately not treated as a causal insight. */
        val journalContext: List<JournalFact>,
    )

    /**
     * Produce the next-morning reading from existing timestamped HR and sleep primitives.
     *
     * [hr] is expected to be the repository's measured/PPG-coalesced timeline. To remain safe for other
     * callers, duplicate timestamps are also ignored after the first element, preserving the caller's
     * precedence order. Both window bounds are transparent and half-open:
     * `[sleep.start - window, sleep.start)`.
     */
    fun evaluate(
        enabled: Boolean,
        sessions: List<DetectedSleep>,
        hr: List<HrSample>,
        history: List<HistoricalReading>,
        journalEntries: List<JournalEntry>,
        day: String,
        minimumValidSamples: Int = DEFAULT_MINIMUM_VALID_SAMPLES,
        preSleepWindowSeconds: Int = DEFAULT_PRE_SLEEP_WINDOW_SECONDS,
    ): Feedback {
        fun closed(e: Eligibility, obs: Observation? = null, unc: List<Uncertainty> = emptyList(),
                   ctx: List<JournalFact> = emptyList()) =
            Feedback(e, obs, null, unc, Inference.NOT_ESTABLISHED, Recommendation.UNSUPPORTED, ctx)

        if (!enabled) return closed(Eligibility.Disabled)
        val evaluationDate = canonicalDay(day) ?: return closed(Eligibility.InvalidDay)
        if (minimumValidSamples <= 0 || preSleepWindowSeconds <= 0) return closed(Eligibility.InvalidWindow)

        val sessionsWithDuration = sessions.mapNotNull { session ->
            val duration = subtractOrNull(session.end, session.start)
            if (duration != null && duration > 0L) session to duration else null
        }
        val primary = sessionsWithDuration.maxByOrNull { it.second }?.first
            ?: return closed(Eligibility.MissingPrimarySleep)

        val start = subtractOrNull(primary.start, preSleepWindowSeconds.toLong())
            ?: return closed(Eligibility.InvalidWindow)
        val inWindow = deduplicated(hr).filter { it.ts.toLong() >= start && it.ts.toLong() < primary.start }
        val valid = inWindow.filter {
            baselineCfg.minVal <= it.bpm.toDouble() && it.bpm.toDouble() <= baselineCfg.maxVal
        }
        if (valid.size < minimumValidSamples) {
            return closed(Eligibility.InsufficientPreSleepSamples(valid.size, minimumValidSamples))
        }
        // `toLong()` before summing, not after: `sumOf { it.bpm }` accumulates in Int and would WRAP
        // silently, where Apple's `reduce` accumulates in 64-bit and cannot. Unreachable with a real
        // window — 220 bpm needs ~9.7M samples to overflow — but a wrapped sum produces a plausible
        // wrong mean rather than a failure, and this file guards its other arithmetic explicitly
        // (`subtractOrNull`). Exact integer sum then divide, which is Apple's order too.
        val mean = valid.sumOf { it.bpm.toLong() }.toDouble() / valid.size.toDouble()
        val observation = Observation(
            primarySleepStartTs = primary.start, primarySleepEndTs = primary.end,
            windowStartTs = start, windowEndTs = primary.start, meanBpm = mean,
            validSamples = valid.size, totalTimestampSamples = inWindow.size,
        )
        // Baselines use prior nights only and `rollingMeanSD` requires oldest-to-newest input. Retain the
        // first caller-supplied reading for a repeated canonical day; one day contributes at most one
        // night and no synthetic average is invented.
        val seenDays = mutableSetOf<String>()
        val priorHistory = history
            .mapNotNull { reading ->
                val date = canonicalDay(reading.day)
                if (date != null && date.isBefore(evaluationDate) && seenDays.add(reading.day)) {
                    reading to date
                } else {
                    null
                }
            }
            .sortedBy { it.second }
        val rollingBaseline = Baselines.rollingMeanSD(priorHistory.map { it.first.meanBpm }, baselineCfg)
        val latestContributingDate = priorHistory.lastOrNull {
            baselineCfg.minVal <= it.first.meanBpm && it.first.meanBpm <= baselineCfg.maxVal
        }?.second
        val nightsSinceUpdate = latestContributingDate
            ?.let { maxOf(0L, ChronoUnit.DAYS.between(it, evaluationDate)).toInt() } ?: 0
        val baseline = BaselineState(
            baseline = rollingBaseline.baseline,
            spread = rollingBaseline.spread,
            nValid = rollingBaseline.nValid,
            nightsSinceUpdate = nightsSinceUpdate,
            status = Baselines.computeStatus(rollingBaseline.nValid, nightsSinceUpdate),
        )
        val context = journalEntries.filter { it.day == day }.map {
            JournalFact(it.day, it.question, it.answeredYes, it.numericValue)
        }
        if (baseline.nValid < minimumBaselineNights) {
            return closed(
                Eligibility.InsufficientBaseline(baseline.nValid, minimumBaselineNights),
                obs = observation, unc = listOf(Uncertainty.NoPersonalComparison), ctx = context,
            )
        }
        if (!baseline.usable) {
            return closed(
                Eligibility.StaleBaseline(baseline.nightsSinceUpdate), obs = observation,
                unc = listOf(Uncertainty.StaleBaseline(baseline.nightsSinceUpdate)), ctx = context,
            )
        }
        val comparison = Comparison(
            baselineBpm = baseline.baseline, deltaBpm = mean - baseline.baseline,
            baselineNights = baseline.nValid, baselineStatus = baseline.status,
        )
        val uncertainty =
            if (baseline.status == BaselineStatus.TRUSTED) emptyList()
            else listOf(Uncertainty.ProvisionalBaseline)
        return Feedback(
            eligibility = Eligibility.Eligible, observation = observation, comparison = comparison,
            uncertainty = uncertainty, inference = Inference.NOT_ESTABLISHED,
            recommendation = Recommendation.UNSUPPORTED, journalContext = context,
        )
    }

    /**
     * `a - b`, or null when it would overflow.
     *
     * NOT a twin claim, though it reads like one and originally said so. Apple expresses the same
     * contract with `subtractingReportingOverflow`, which is Swift STDLIB on `FixedWidthInteger` and
     * therefore not a declaration in this repository at all — so a reader chasing the reference finds
     * nothing, and a parity audit resolves it to nothing either.
     */
    private fun subtractOrNull(a: Long, b: Long): Long? =
        try { Math.subtractExact(a, b) } catch (_: ArithmeticException) { null }

    /**
     * A calendar day, or null when the string is not a canonical `YYYY-MM-DD`.
     *
     * The shape check alone is not enough: it accepts `2026-02-31`. [LocalDate.of] rejects an impossible
     * day, which is what the Swift twin's round-trip through `Calendar` is doing.
     */
    private fun canonicalDay(day: String): LocalDate? {
        val bytes = day.toByteArray(Charsets.UTF_8)
        if (bytes.size != 10 || bytes[4] != '-'.code.toByte() || bytes[7] != '-'.code.toByte()) return null
        val digitPositions = intArrayOf(0, 1, 2, 3, 5, 6, 8, 9)
        if (!digitPositions.all { bytes[it] in 48..57 }) return null
        val year = (bytes[0] - 48) * 1_000 + (bytes[1] - 48) * 100 + (bytes[2] - 48) * 10 + (bytes[3] - 48)
        val month = (bytes[5] - 48) * 10 + (bytes[6] - 48)
        val dayOfMonth = (bytes[8] - 48) * 10 + (bytes[9] - 48)
        return try { LocalDate.of(year, month, dayOfMonth) } catch (_: java.time.DateTimeException) { null }
    }

    /**
     * One sample per timestamp, FIRST occurrence wins.
     *
     * First-wins is the caller's precedence order, not an arbitrary pick: [evaluate]'s contract is an
     * already-coalesced timeline where measured data outranks PPG-derived, so the first element for a
     * timestamp is the one the repository chose. Stated here as well as on [evaluate] because the rule
     * is invisible at this call site, and a later reader changing it to last-wins would silently invert
     * that precedence (#1784).
     */
    private fun deduplicated(hr: List<HrSample>): List<HrSample> {
        val seen = mutableSetOf<Int>()
        return hr.filter { seen.add(it.ts) }
    }
}
