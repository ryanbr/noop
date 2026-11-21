package com.noop.analytics

import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

// WeeklyDigest.kt — a deterministic, offline "week in review".
//
// Faithful Kotlin port of the Swift StrandAnalytics/WeeklyDigest.swift. Keep the two
// in lockstep — cross-platform parity is required.
//
// Pure, deterministic, DB-free. Given the daily series for each tracked metric
// (keyed by "yyyy-MM-dd"), it builds a Monday-anchored "this week" summary:
//   • per-metric this-week stats (mean / median / min / max / SD / OLS slope),
//   • week-over-week comparison (this week vs the immediately preceding Mon–Sun week),
//   • a "vs baseline" delta (this-week mean vs the trailing [baselineWeeks] weeks),
//   • sleep consistency (SD of this week's Rest values; lower = steadier),
//   • a strain-vs-recovery balance read, the biggest movers, and 1–2 plain-English
//     focal points.
//
// Consumes plain Map<String, Double> day→value series so it stays decoupled from the
// Room DailyMetric type (the UI extracts the metrics and hands them in). No AI required.
//
// Week math is timezone/locale-free: weekday is derived from the "yyyy-MM-dd" string
// with a pure Sakamoto day-of-week, week windows are inclusive ISO-string ranges
// (string comparison is chronological for ISO days), matching the day strings the
// engine emits exactly.

/** The five headline metrics a weekly digest reports on. */
enum class WeeklyMetric(val key: String) {
    CHARGE("charge"),  // recovery, 0–100
    EFFORT("effort"),  // strain / Effort, 0–100
    REST("rest"),      // sleep performance composite, 0–100
    RHR("rhr"),        // resting heart rate, bpm
    HRV("hrv");        // heart-rate variability, ms

    /** Human label (matches the rest of the app's naming). */
    val label: String
        get() = when (this) {
            CHARGE -> "Charge"
            EFFORT -> "Effort"
            REST -> "Rest"
            RHR -> "Resting HR"
            HRV -> "HRV"
        }

    /** Display unit suffix (empty for the unitless 0–100 scores). */
    val unit: String
        get() = when (this) {
            CHARGE, EFFORT, REST -> ""
            RHR -> "bpm"
            HRV -> "ms"
        }

    /** True when a HIGHER value is the better outcome. Resting HR is the lone exception. */
    val higherIsBetter: Boolean
        get() = this != RHR

    /**
     * A coarse "typical day-to-day range" used to normalise week-over-week deltas so
     * movers on different scales are rankable against each other. Deterministic constants
     * (not personal baselines), byte-identical to Swift.
     */
    val typicalSpread: Double
        get() = when (this) {
            CHARGE -> 12.0
            EFFORT -> 12.0
            REST -> 12.0
            RHR -> 4.0
            HRV -> 8.0
        }
}

/** Summary statistics for one slice of a daily series. Mirrors Swift SeriesStat. */
data class SeriesStat(
    val mean: Double,
    val median: Double,
    val min: Double,
    val max: Double,
    val stdev: Double,
    val n: Int,
    val slopePerDay: Double,
) {
    companion object {
        val EMPTY = SeriesStat(0.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0)
    }
}

/** The comparison of a `current` period against a `previous` one. Mirrors Swift PeriodComparison. */
data class PeriodComparison(
    val current: SeriesStat,
    val previous: SeriesStat,
    /** Signed change in mean: current.mean − previous.mean. */
    val delta: Double,
    /** Percent change vs previous.mean, or null when previous is empty / mean is 0. */
    val pctChange: Double?,
    /** Direction: -1 (down), 0 (flat / a period empty), +1 (up). */
    val direction: Int,
)

/** One metric's line in the weekly digest. */
data class WeeklyMetricSummary(
    val metric: WeeklyMetric,
    val thisWeek: SeriesStat,
    val weekOverWeek: PeriodComparison,
    val baselineMean: Double?,
    val vsBaseline: Double?,
) {
    /** Signed week-over-week change in the metric's own units (this − last). */
    val wowDelta: Double get() = weekOverWeek.delta

    /**
     * Week-over-week change as GOOD (+1) / BAD (-1) / FLAT (0), folding in
     * `higherIsBetter` (so a Resting-HR rise reads as worse). 0 when flat or a period empty.
     */
    val wowGoodness: Int
        get() {
            if (weekOverWeek.direction == 0) return 0
            val up = weekOverWeek.direction > 0
            return if (up == metric.higherIsBetter) 1 else -1
        }

    /** The week-over-week change scaled by the metric's typical spread. 0 when a period empty. */
    val normalisedMove: Double
        get() {
            if (weekOverWeek.current.n == 0 || weekOverWeek.previous.n == 0) return 0.0
            val s = metric.typicalSpread
            return if (s > 0) wowDelta / s else 0.0
        }

    /**
     * True when the week-over-week comparison rests on a sparse side: both weeks carry at
     * least one reading, but either has fewer than [WeeklyDigestEngine.MIN_DAYS_FOR_FOCUS]
     * days. A rough comparison still shows its raw arrow + %, but the UI shouldn't dress it
     * in a confident good/bad verdict — a 43% "drop" off 2 days isn't a trend (the #463
     * chips-vs-summary contradiction). Mirrors Swift `isRoughComparison`.
     */
    val isRoughComparison: Boolean
        get() {
            val cur = weekOverWeek.current.n
            val prev = weekOverWeek.previous.n
            if (cur == 0 || prev == 0) return false
            return cur < WeeklyDigestEngine.MIN_DAYS_FOR_FOCUS ||
                prev < WeeklyDigestEngine.MIN_DAYS_FOR_FOCUS
        }
}

/** How this week's Effort sat against this week's Charge. */
enum class BalanceRead {
    OVERREACHING, BALANCED, UNDERLOADED, INSUFFICIENT;

    /** Plain-English line for the UI. Byte-identical to Swift. */
    val sentence: String
        get() = when (this) {
            OVERREACHING ->
                "Your Effort outpaced your Charge this week: you leaned into the red. Watch for a recovery dip."
            BALANCED ->
                "Effort and Charge tracked together this week: a sustainable load."
            UNDERLOADED ->
                "You carried more Charge than you spent this week: there's room to push if you want it."
            INSUFFICIENT ->
                "Not enough Effort and Charge days this week to read your balance."
        }
}

/**
 * One weekly-digest focal point as data rather than prose, so the card can localize it. [englishText] is
 * the sentence [WeeklyDigest.focalPoints] carries, byte for byte. Mirrors Swift `DigestFocalLine`.
 */
sealed class DigestFocalLine {
    /**
     * How far a mover moved: a whole percentage, or (when the percentage is under 1 or undefined) an
     * absolute amount already rounded to one decimal, in the metric's unit (empty = Charge/Effort/Rest points).
     */
    sealed class Magnitude {
        data class Percent(val value: Int) : Magnitude()
        data class Amount(val value: Double, val unit: String) : Magnitude()
    }

    /** A week-over-week mover. [direction] is the sign of the move; [goodness] is `wowGoodness`. */
    data class Mover(
        val metric: WeeklyMetric,
        val direction: Int,
        val magnitude: Magnitude,
        val goodness: Int,
        val thisAverage: Int,
        val lastAverage: Int,
    ) : DigestFocalLine()

    /** A non-trivial strain-vs-recovery read ([BalanceRead.sentence]). */
    data class Balance(val read: BalanceRead) : DigestFocalLine()

    /** This week has fewer than MIN_DAYS_FOR_FOCUS days so far. */
    data class CurrentWeekSparse(val days: Int) : DigestFocalLine()

    /** Last week had fewer than MIN_DAYS_FOR_FOCUS days. */
    data class PreviousWeekSparse(val days: Int) : DigestFocalLine()

    /** Nothing moved and Rest held within the steadiness band (SD rounded to one decimal). */
    data class SteadyRest(val sd: Double) : DigestFocalLine()

    /** Nothing moved meaningfully. */
    object Steady : DigestFocalLine()

    val englishText: String
        get() = when (this) {
            is Mover -> {
                val directionWord = if (direction > 0) "up" else if (direction < 0) "down" else "flat"
                val magnitudeText = when (val m = magnitude) {
                    is Magnitude.Percent -> "${m.value}%"
                    is Magnitude.Amount -> "${m.value}${if (m.unit.isEmpty()) " pts" else " ${m.unit}"}"
                }
                val frame = when (goodness) {
                    1 -> ", a good sign"
                    -1 -> ", worth a look"
                    else -> ""
                }
                "${metric.label} is $directionWord $magnitudeText week over week " +
                    "(avg $thisAverage vs $lastAverage)$frame."
            }
            is Balance -> read.sentence
            is CurrentWeekSparse -> {
                val dayWord = if (days == 1) "day" else "days"
                "Only $days $dayWord into this week so far, too early to " +
                    "call a week-over-week trend yet."
            }
            is PreviousWeekSparse -> {
                val dayWord = if (days == 1) "day" else "days"
                "Last week only had $days $dayWord of data, so week-over-week " +
                    "changes are rough, not a trend."
            }
            is SteadyRest -> "A steady week: Rest held even (±$sd pts) and nothing moved much."
            Steady -> "A steady week: no metric moved meaningfully from last week."
        }
}

/** The complete week-in-review. */
data class WeeklyDigest(
    /** The Monday that anchors "this week" ("yyyy-MM-dd"). */
    val weekStart: String,
    /** The Sunday that ends "this week" ("yyyy-MM-dd"). */
    val weekEnd: String,
    /** Per-metric summaries, in WeeklyMetric.values() order. */
    val metrics: List<WeeklyMetricSummary>,
    /** Distinct days this week that carried at least one reading. */
    val daysWithData: Int,
    /** SD of this week's Rest values (lower = steadier), or null with < 2 Rest nights. */
    val sleepConsistencySD: Double?,
    /** Strain-vs-recovery balance read for the week. */
    val balance: BalanceRead,
    /** 1–2 plain-English focal points, most salient first. */
    val focalPoints: List<String>,
    /** The same focal points as structured values, in the same order (see [DigestFocalLine]). */
    val focalLines: List<DigestFocalLine> = emptyList(),
) {
    fun summary(metric: WeeklyMetric): WeeklyMetricSummary? = metrics.firstOrNull { it.metric == metric }

    /** True when no metric carried a single reading this week. */
    val isEmpty: Boolean get() = daysWithData == 0
}

object WeeklyDigestEngine {

    /** Complete weeks before "this week" forming the vs-baseline comparison. */
    const val BASELINE_WEEKS = 4
    /** Min days each side before a week-over-week move is "real" enough to surface. */
    const val MIN_DAYS_FOR_FOCUS = 3
    /** Effort−Charge gap (points) inside which the week is "balanced". */
    const val BALANCE_BAND = 10.0
    /** Normalised-move threshold (in "typical spreads") for a focal mover. */
    const val FOCUS_THRESHOLD = 0.5

    // MARK: - Entry point

    /**
     * Build the weekly digest anchored on the Monday of the week containing [anchorDay]
     * ("yyyy-MM-dd", typically today). A non-parseable string yields an all-empty digest.
     *
     * [effortDisplayFactor] is a multiplier applied to EFFORT averages (and the pts
     * fallback magnitude) in the rendered focal-point sentences ONLY, so a user on the
     * 0–21 Effort scale (#268) never reads a stored 0–100 mean in prose. Percent changes
     * are scale-invariant and stay untouched. Defaults to 1.0 (stored scale) so existing
     * callers are byte-identical. Display-only: no stat, delta or threshold changes.
     */
    fun build(
        byMetric: Map<WeeklyMetric, Map<String, Double>>,
        anchorDay: String,
        effortDisplayFactor: Double = 1.0,
    ): WeeklyDigest {
        val monday = mondayOfWeek(anchorDay) ?: return emptyDigest(anchorDay, anchorDay)
        val sunday = addDays(monday, 6)
        val lastMonday = addDays(monday, -7)
        val lastSunday = addDays(monday, -1)

        // Baseline: BASELINE_WEEKS complete weeks ending the day before last week starts.
        val baselineEnd = addDays(lastMonday, -1)
        val baselineStart = addDays(lastMonday, -7 * BASELINE_WEEKS)

        val summaries = mutableListOf<WeeklyMetricSummary>()
        val daysSeen = mutableSetOf<String>()

        for (metric in WeeklyMetric.values()) {
            val series = byMetric[metric] ?: emptyMap()

            val thisVals = valuesInRange(series, monday, sunday, daysSeen)
            val lastVals = valuesInRange(series, lastMonday, lastSunday, null)
            val baseVals = valuesInRange(series, baselineStart, baselineEnd, null)

            val thisStat = stat(thisVals)
            val wow = compare(thisVals, lastVals)
            val baseMean = if (baseVals.isEmpty()) null else baseVals.sum() / baseVals.size
            val vsBase = baseMean?.let { thisStat.mean - it }

            summaries.add(WeeklyMetricSummary(metric, thisStat, wow, baseMean, vsBase))
        }

        val restStat = summaries.firstOrNull { it.metric == WeeklyMetric.REST }?.thisWeek
        val restConsistency = if ((restStat?.n ?: 0) >= 2) restStat?.stdev else null

        val balance = balanceRead(summaries)
        val focal = focalLines(summaries, balance, restConsistency, effortDisplayFactor)

        return WeeklyDigest(
            weekStart = monday, weekEnd = sunday, metrics = summaries,
            daysWithData = daysSeen.size, sleepConsistencySD = restConsistency,
            balance = balance, focalPoints = focal.map { it.englishText }, focalLines = focal,
        )
    }

    // MARK: - Single-slice statistics (ported from ComparisonEngine.swift)

    /** Summarise a slice into a SeriesStat. Slope is OLS vs the 0-based index. EMPTY when empty. */
    fun stat(values: List<Double>): SeriesStat {
        val n = values.size
        if (n == 0) return SeriesStat.EMPTY

        val mean = values.sum() / n
        val med = median(values)
        val mn = values.min()
        val mx = values.max()

        val sd = if (n >= 2) {
            var ss = 0.0
            for (v in values) { val dd = v - mean; ss += dd * dd }
            sqrt(ss / (n - 1))
        } else 0.0

        return SeriesStat(mean, med, mn, mx, sd, n, leastSquaresSlope(values))
    }

    /** Compare a current slice to a previous slice (delta/direction on the means). */
    fun compare(current: List<Double>, previous: List<Double>): PeriodComparison {
        val cur = stat(current)
        val prev = stat(previous)
        val delta = cur.mean - prev.mean

        val pct = if (prev.n > 0 && prev.mean != 0.0) (cur.mean - prev.mean) / abs(prev.mean) * 100.0 else null

        val direction = when {
            cur.n == 0 || prev.n == 0 -> 0
            delta > 0 -> 1
            delta < 0 -> -1
            else -> 0
        }
        return PeriodComparison(cur, prev, delta, pct, direction)
    }

    private fun median(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        val s = values.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /** OLS slope of values vs their 0-based index. 0 when n < 2. */
    private fun leastSquaresSlope(values: List<Double>): Double {
        val n = values.size
        if (n < 2) return 0.0
        val meanX = (n - 1) / 2.0
        val meanY = values.sum() / n
        var sxy = 0.0
        var sxx = 0.0
        for (i in 0 until n) {
            val dx = i - meanX
            sxy += dx * (values[i] - meanY)
            sxx += dx * dx
        }
        return if (sxx > 0) sxy / sxx else 0.0
    }

    // MARK: - Balance read

    private fun balanceRead(summaries: List<WeeklyMetricSummary>): BalanceRead {
        val effort = summaries.firstOrNull { it.metric == WeeklyMetric.EFFORT }?.thisWeek
        val charge = summaries.firstOrNull { it.metric == WeeklyMetric.CHARGE }?.thisWeek
        if (effort == null || charge == null ||
            effort.n < MIN_DAYS_FOR_FOCUS || charge.n < MIN_DAYS_FOR_FOCUS
        ) {
            return BalanceRead.INSUFFICIENT
        }
        val gap = effort.mean - charge.mean
        return when {
            gap > BALANCE_BAND -> BalanceRead.OVERREACHING
            gap < -BALANCE_BAND -> BalanceRead.UNDERLOADED
            else -> BalanceRead.BALANCED
        }
    }

    // MARK: - Focal points

    /**
     * The 1–2 focal points as structured lines, most salient first (see [DigestFocalLine]).
     * Swift twin: `WeeklyDigestEngine.focalLines`.
     */
    internal fun focalLines(
        summaries: List<WeeklyMetricSummary>,
        balance: BalanceRead,
        consistencySD: Double?,
        effortDisplayFactor: Double = 1.0,
    ): List<DigestFocalLine> {
        val movers = summaries
            .filter {
                it.weekOverWeek.current.n >= MIN_DAYS_FOR_FOCUS &&
                    it.weekOverWeek.previous.n >= MIN_DAYS_FOR_FOCUS &&
                    abs(it.normalisedMove) >= FOCUS_THRESHOLD
            }
            .sortedByDescending { abs(it.normalisedMove) }

        val lines = mutableListOf<DigestFocalLine>()

        movers.firstOrNull()?.let { lines.add(moverLine(it, effortDisplayFactor)) }

        if (balance == BalanceRead.OVERREACHING || balance == BalanceRead.UNDERLOADED) {
            lines.add(DigestFocalLine.Balance(balance))
        } else if (movers.size >= 2) {
            lines.add(moverLine(movers[1], effortDisplayFactor))
        }

        // Nothing cleared the mover bar. Distinguish three very different reasons:
        //   • a SPARSE CURRENT week (too few days to call a week-over-week trend — saying
        //     "nothing moved" there contradicts the per-metric chips, the #463 report),
        //   • a SPARSE PREVIOUS week (typical new user in week 2): movers are gated on
        //     previous.n ≥ MIN_DAYS_FOR_FOCUS, so nothing can surface even when the chips
        //     show big raw %s off last week's 1–2 days — the same contradiction, mirrored,
        //   • a genuinely steady full week.
        if (lines.isEmpty()) {
            val currentDays = summaries.maxOfOrNull { it.weekOverWeek.current.n } ?: 0
            val prevDays = summaries.maxOfOrNull { it.weekOverWeek.previous.n } ?: 0
            if (currentDays in 1 until MIN_DAYS_FOR_FOCUS) {
                lines.add(DigestFocalLine.CurrentWeekSparse(currentDays))
            } else if (currentDays >= MIN_DAYS_FOR_FOCUS && prevDays in 1 until MIN_DAYS_FOR_FOCUS) {
                lines.add(DigestFocalLine.PreviousWeekSparse(prevDays))
            } else if (consistencySD != null && consistencySD <= 6.0) {
                lines.add(DigestFocalLine.SteadyRest(round1(consistencySD)))
            } else {
                lines.add(DigestFocalLine.Steady)
            }
        }

        return lines.take(2)
    }

    /**
     * Render one mover as a plain-English sentence with good/bad framing. Mirrors Swift.
     * [effortDisplayFactor] rescales the EFFORT averages (and its pts fallback) for
     * display only — % is scale-invariant.
     */
    private fun moverSentence(s: WeeklyMetricSummary, effortDisplayFactor: Double = 1.0): String =
        moverLine(s, effortDisplayFactor).englishText

    /**
     * [moverSentence] as a structured line (see [DigestFocalLine.Mover]).
     * Swift twin: `WeeklyDigestEngine.moverLine`.
     */
    private fun moverLine(s: WeeklyMetricSummary, effortDisplayFactor: Double = 1.0): DigestFocalLine {
        val f = if (s.metric == WeeklyMetric.EFFORT) effortDisplayFactor else 1.0
        val direction = if (s.wowDelta > 0) 1 else if (s.wowDelta < 0) -1 else 0
        val pct = s.weekOverWeek.pctChange
        val magnitude = if (pct != null && abs(pct) >= 1) {
            DigestFocalLine.Magnitude.Percent(abs(pct).roundToInt())
        } else {
            DigestFocalLine.Magnitude.Amount(round1(abs(s.wowDelta) * f), s.metric.unit)
        }
        return DigestFocalLine.Mover(
            metric = s.metric,
            direction = direction,
            magnitude = magnitude,
            goodness = s.wowGoodness,
            thisAverage = (s.thisWeek.mean * f).roundToInt(),
            lastAverage = (s.weekOverWeek.previous.mean * f).roundToInt(),
        )
    }

    // MARK: - Range extraction

    /**
     * Values of [series] whose day is within [start, end] inclusive (ISO string comparison is
     * chronological), ordered chronologically so the SeriesStat slope is meaningful. When
     * [daysSeen] is non-null, the days that carried a value are recorded into it.
     */
    private fun valuesInRange(
        series: Map<String, Double>,
        start: String,
        end: String,
        daysSeen: MutableSet<String>?,
    ): List<Double> {
        val inRange = series.filterKeys { it in start..end }
        daysSeen?.addAll(inRange.keys)
        return inRange.entries.sortedBy { it.key }.map { it.value }
    }

    // MARK: - Pure week math (timezone/locale-free)

    /** The Monday (ISO) of the week containing [day]. null if [day] is not a valid yyyy-MM-dd. */
    fun mondayOfWeek(day: String): String? {
        val ymd = parseYMD(day) ?: return null
        val w = weekday(ymd[0], ymd[1], ymd[2]) ?: return null
        // weekday: 0=Sun … 6=Sat. Days since Monday: Mon=0 … Sun=6.
        val sinceMonday = (w + 6) % 7
        return addDays(day, -sinceMonday)
    }

    /** Add [n] days (may be negative) to a "yyyy-MM-dd" day. Returns the input if unparseable. */
    fun addDays(day: String, n: Int): String {
        val ymd = parseYMD(day) ?: return day
        val jdn = julianDayNumber(ymd[0], ymd[1], ymd[2]) + n
        val out = fromJulianDayNumber(jdn)
        return formatYMD(out[0], out[1], out[2])
    }

    /** Sakamoto's day-of-week: 0=Sunday … 6=Saturday. null for an invalid date. */
    fun weekday(y: Int, m: Int, d: Int): Int? {
        if (m !in 1..12 || d < 1 || d > daysInMonth(y, m)) return null
        val t = intArrayOf(0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4)
        var yy = y
        if (m < 3) yy -= 1
        return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7
    }

    private fun daysInMonth(y: Int, m: Int): Int = when (m) {
        1, 3, 5, 7, 8, 10, 12 -> 31
        4, 6, 9, 11 -> 30
        2 -> if (isLeap(y)) 29 else 28
        else -> 0
    }

    private fun isLeap(y: Int): Boolean = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

    /** Parse "yyyy-MM-dd" into [y, m, d], validating the date is real. null otherwise. */
    fun parseYMD(s: String): IntArray? {
        val parts = s.split("-")
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (m !in 1..12 || d < 1 || d > daysInMonth(y, m)) return null
        return intArrayOf(y, m, d)
    }

    private fun formatYMD(y: Int, m: Int, d: Int): String {
        val yy = if (y < 1000) y.toString().padStart(4, '0') else y.toString()
        val mm = if (m < 10) "0$m" else "$m"
        val dd = if (d < 10) "0$d" else "$d"
        return "$yy-$mm-$dd"
    }

    /** Proleptic-Gregorian date → Julian Day Number (integer-only date arithmetic). */
    private fun julianDayNumber(y: Int, m: Int, d: Int): Int {
        val a = (14 - m) / 12
        val yy = y + 4800 - a
        val mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    /** Inverse of [julianDayNumber] → [y, m, d]. */
    private fun fromJulianDayNumber(jdn: Int): IntArray {
        val a = jdn + 32044
        val b = (4 * a + 3) / 146097
        val c = a - (146097 * b) / 4
        val dd = (4 * c + 3) / 1461
        val e = c - (1461 * dd) / 4
        val mm = (5 * e + 2) / 153
        val day = e - (153 * mm + 2) / 5 + 1
        val month = mm + 3 - 12 * (mm / 10)
        val year = 100 * b + dd - 4800 + mm / 10
        return intArrayOf(year, month, day)
    }

    // MARK: - Empty digest

    private fun emptyDigest(weekStart: String, weekEnd: String): WeeklyDigest {
        val summaries = WeeklyMetric.values().map { m ->
            WeeklyMetricSummary(m, SeriesStat.EMPTY, compare(emptyList(), emptyList()), null, null)
        }
        return WeeklyDigest(weekStart, weekEnd, summaries, 0, null, BalanceRead.INSUFFICIENT, emptyList())
    }

    // MARK: - Formatting helpers

    private fun round1(x: Double): Double = (x * 10).roundToInt() / 10.0
}
