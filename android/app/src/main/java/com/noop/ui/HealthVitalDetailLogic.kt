package com.noop.ui

import com.noop.data.Vo2MaxEstimator
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One windowed reading behind a vital's detail chart: its day ("YYYY-MM-DD"), the value, and the RAW
 *  source id it came from (a strap id, the "-noop" computed sibling, "apple-health", or "health-connect").
 *  The readings TABLE and the "N readings" header both derive from this ONE list, so they can never
 *  disagree; the raw source maps to a human label via [provenanceDisplayLabel] — the SAME resolver Today
 *  uses, so we never invent a source vocabulary (task #8). */
internal data class VitalReading(
    val day: String,
    val value: Double,
    val source: String,
)

internal const val VO2_MAX_ATTRIBUTION_PREFIX = "vo2max-estimator:"

/**
 * #103/queue-11a follow-up: display-source token for a `spo2` reading that came from the
 * `spo2_candidate` fallback (WHOOP `spo2_candidate_82` or Oura ceiling@100 `0x6F`, device-conditional)
 * rather than a calibrated `spo2Pct` day. Every OTHER surface with this fallback (the Key Metrics tile
 * via [vitalsFor]) already labels it via `R.string.spo2_strap_estimate_caption` — this vital-detail
 * screen (`VitalDetailScreen`/"Your Cards" drill-in) had no candidate fallback at all until now (found
 * 2026-08-24: an Oura-only or WHOOP-4.0-only install with the toggle ON saw a real number on the tile
 * but nothing here past the last calibrated import). Same prefix-token idiom as
 * [vo2MaxAttributionSource] just above.
 */
internal const val SPO2_CANDIDATE_ATTRIBUTION_SOURCE = "spo2-candidate-estimate"

/** Display-source token for a VO₂max reading. A missing legacy tag stays unknown; it must never inherit
 *  the method implied by today's profile because the waist measurement may have changed after scoring. */
internal fun vo2MaxAttributionSource(estimator: Vo2MaxEstimator?): String =
    VO2_MAX_ATTRIBUTION_PREFIX + (estimator?.provenanceId ?: "unknown")

/**
 * The y-domain a metric should be drawn against, or null to scale to the data.
 *
 * Auto-scaling makes a calm metric look exactly as violent as a wild one: Rest moving 46..93 on a 0..100
 * scale fills the same full height as Effort moving 0..42, and one low day rewrites the whole shape. For a
 * metric whose natural range IS its interesting range, anchoring is what makes the height mean something.
 *
 * Deliberately a small allow-list rather than "percentages get 0..100". Blood oxygen is a percentage whose
 * real movement lives in 90..100, so anchoring it to the nominal range would flatten the signal into a line
 * at the top: strictly worse than auto-scaling. Resting HR, HRV and skin temperature have no fixed range at
 * all.
 *
 * Effort is 0..100 here whatever the user's display scale says. The readings store the RAW 0-100 composite
 * and only `format()` converts to the 0..21 reading, so the chart plots the stored value. Taking the domain
 * from the display scale would have squashed every Effort chart on a WHOOP-scale install into the bottom
 * fifth of its height.
 */
internal fun vitalChartYDomain(key: String): ClosedFloatingPointRange<Double>? =
    when (key) {
        // "rest", NOT "sleep_performance": that is the SERIES name this detail reads underneath, and it is
        // never a detail key on Android. Writing the series name here compiled, passed a test asserting it,
        // and left the Rest chart auto-scaling exactly as before.
        // A ZERO-WIDTH domain at 0, not 0..100. The chart widens a domain to contain the data, so this
        // pins the FLOOR at zero while the ceiling follows the readings.
        //
        // Anchoring at 100 was the first attempt and it overcorrected: Effort peaks in the low forties, so
        // the top ~58% of the chart sat permanently empty, and Rest at 46..93 wasted the bottom half. A
        // zero floor keeps what actually mattered, that heights stay comparable and a 0.0 day reads as the
        // floor rather than as the middle, without spending most of the height on range nobody reaches.
        "recovery", "rest", "strain" -> 0.0..0.0
        else -> null
    }

/**
 * Per-reading epoch seconds from the day keys, or null when any day fails to parse.
 *
 * All-or-nothing on purpose: a partially-parsed list would position some points by time and the rest by a
 * fallback, which is a worse lie than either rule applied consistently. Returning null makes the chart use
 * index spacing, exactly as before.
 */
internal fun dayEpochSeconds(readings: List<VitalReading>): List<Long>? {
    val out = ArrayList<Long>(readings.size)
    for (r in readings) {
        val day = runCatching { java.time.LocalDate.parse(r.day) }.getOrNull() ?: return null
        out += day.toEpochDay() * 86_400L
    }
    return out
}

/**
 * Which metrics are drawn as BARS rather than as a line.
 *
 * A line asserts continuity between points: it says the value travelled from one reading to the next. For
 * a daily score that is false, and it is most of what makes a spiky series look chaotic. The reported
 * Effort swings 19.8 points a day on a 0..42 range, so a line spends the whole chart climbing and diving
 * through values that never existed.
 *
 * Bars claim nothing between slots. A zero day is a short bar beside a tall one instead of a plunge, and a
 * day with no reading is simply an empty slot.
 *
 * Only the daily SCORES. Resting HR, HRV, skin temperature, respiratory rate and blood oxygen are levels
 * that genuinely do vary continuously between measurements, so a line is the honest shape for them, and
 * Fitness Age and Vitality are too sparse to fill a bar chart.
 */
internal fun vitalChartIsBars(key: String): Boolean = key in setOf("recovery", "rest", "strain")

/**
 * One slot per DAY across the window, rather than one per reading.
 *
 * Bars are laid out evenly across their slots, so giving every day a slot is what positions them by date:
 * a missing day becomes an empty slot of the right width, with no separate spacing machinery. Days with no
 * reading carry NaN, which the bar chart already treats as nothing to draw.
 *
 * Returns null when a day key fails to parse, so the caller falls back to the per-reading form rather than
 * silently dropping readings into the wrong slots.
 */
internal fun densifyByDay(readings: List<VitalReading>): List<Pair<String, Double>>? {
    if (readings.isEmpty()) return emptyList()
    val byDay = LinkedHashMap<java.time.LocalDate, Double>()
    for (r in readings) {
        val day = runCatching { java.time.LocalDate.parse(r.day) }.getOrNull() ?: return null
        byDay[day] = r.value
    }
    val first = byDay.keys.min()
    val last = byDay.keys.max()
    val out = ArrayList<Pair<String, Double>>()
    var day = first
    while (!day.isAfter(last)) {
        out += day.toString() to (byDay[day] ?: Double.NaN)
        day = day.plusDays(1)
    }
    return out
}

/** Sequential ids for a method-aware trend. Nes → Uth → Nes becomes three segments rather than joining
 *  the non-adjacent Nes runs across an incompatible estimator. */
internal fun vo2MaxTrendSegmentIds(readings: List<VitalReading>): List<String> {
    var previous: String? = null
    var group = -1
    return readings.map { reading ->
        if (reading.source != previous) {
            group++
            previous = reading.source
        }
        "$group:${reading.source}"
    }
}

/**
 * Will the chart show a visible break in this VO2max trend?
 *
 * Derived from [vo2MaxTrendSegmentIds] rather than recomputed, so the caption and the segmentation can
 * never disagree: if the ids collapse to one group the line is continuous and there is nothing to
 * explain. Two readings from the SAME estimator with a gap in days are one segment and correctly get no
 * caption - a break means the readings were not produced alike, not that the data paused.
 *
 * Named for the BREAK, not for a method change: an untagged legacy reading resolves to
 * "...estimator:unknown" (see [vo2MaxAttributionSource]), so an unknown -> Nes transition also splits the
 * line while the method itself may never have changed. The caption is worded for both causes.
 */
internal fun vo2MaxTrendHasBreak(readings: List<VitalReading>): Boolean =
    vo2MaxTrendSegmentIds(readings).distinct().size > 1

/** #377: merge the three step stores into one per-day series with the SAME precedence as the Today
 *  Steps tile — a REAL on-device count ([real], WHOOP 5/MG @57 → DailyMetric.steps) wins, else an
 *  [imported] Health Connect / Apple Health count, else the motion-model [est] (`steps_est`). The three
 *  are disjoint stores so the `?:` chain never double-counts. Ascending by day. Pure for testability. */
internal fun mergeStepsReadings(
    real: Map<String, VitalReading>,
    imported: Map<String, VitalReading>,
    est: Map<String, VitalReading>,
): List<VitalReading> =
    (real.keys + imported.keys + est.keys).toSortedSet()
        .mapNotNull { d -> real[d] ?: imported[d] ?: est[d] }

/** #616: per-day precedence merge for a metric with disjoint stores (first non-null per day wins),
 *  ascending. The N-store generalisation of [mergeStepsReadings]; calories reuse it as the two-store
 *  on-device (`activeKcalEst`) ?: imported (Apple/Health-Connect `activeKcal`) union. Pure for testability. */
internal fun mergeReadings(vararg stores: Map<String, VitalReading>): List<VitalReading> =
    stores.flatMap { it.keys }.toSortedSet()
        .mapNotNull { day -> stores.firstNotNullOfOrNull { it[day] } }

/** The rows of a vital detail's readings table: each reading's day (localized), its formatted value with
 *  unit, and a human source label. Plain strings so the composable is a thin renderer and the projection
 *  stays unit-testable. */
internal data class VitalReadingRow(
    val time: String,
    val value: String,
    val source: DisplayText,
)

/**
 * Project a vital's windowed [readings] into table rows, NEWEST FIRST — the same list (so the same count)
 * the "N readings" header shows, guaranteeing the two never drift. Each row pairs the reading's DAY (these
 * vital series carry one aggregated reading per night, so a row's "time" is its calendar date, localized;
 * the date always shows since a charted window spans 2+ days) with the model's own [format]ted value +
 * [unit] and the source label resolved by [provenanceDisplayLabel] — no new source vocabulary (a strap id
 * → "Whoop", its "-noop" sibling → "On-device", "apple-health" → "Apple Health", "health-connect" →
 * "Health Connect"). [strapDeviceId] is the active strap id the label resolver needs.
 */
internal fun vitalReadingRows(
    readings: List<VitalReading>,
    unit: String,
    strapDeviceId: String,
    format: (Double) -> String,
): List<VitalReadingRow> =
    readings.asReversed().map { reading ->
        VitalReadingRow(
            time = vitalReadingDateLabel(reading.day),
            value = "${format(reading.value)} $unit".trim(),
            source = provenanceDisplayLabel(reading.source, strapDeviceId),
        )
    }

/** "9 Jun" for a "YYYY-MM-DD" reading day (today / yesterday read as words to match the hero "as of"
 *  line); the verbatim string if it doesn't parse. Locale.US month, matching [asOfLabel]. */
internal fun vitalReadingDateLabel(day: String): String {
    val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return day
    val today = LocalDate.now()
    return when (date) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> date.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }
}

internal enum class VitalDetailRange(val label: String, val days: Long?) {
    WEEK("W", 7),
    TWO_WEEK("2W", 14),
    THREE_WEEK("3W", 21),
    MONTH("M", 30),
    THREE_MONTH("3M", 90),
    SIX_MONTH("6M", 180),
    YEAR("1Y", 365),
    ALL("ALL", null),
}

/** Days spanned by a vital's history: last point's day minus first point's day in epoch days (0 for
 *  a single day or unparseable bounds). Points arrive oldest-first from buildVitalDetail. */
internal fun vitalHistorySpanDays(points: List<Pair<String, Double>>): Long {
    val first = points.firstOrNull()?.first?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return 0L
    val last = points.lastOrNull()?.first?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return 0L
    return (last.toEpochDay() - first.toEpochDay()).coerceAtLeast(0L)
}

/** #943 (ryanbr): which range chips have anything NEW to show. filterVitalPoints windows off the
 *  LATEST reading, so with under a week of history every window returned the identical full point set
 *  and all six chips drew the same line (a week of data stretched full-width under a "1Y" label). A
 *  range only differs from its predecessor once the data span EXCEEDS the predecessor's window, so the
 *  unlocked set is a contiguous prefix: W always, 2W once span > 7 days, 3W once > 14, M once > 21,
 *  3M once > 30, 6M once > 90, 1Y once > 180, ALL once > 365. (The 1D/2D experiment was dropped: daily
 *  metrics hold at most one point per day, so those windows could never draw a line.) Locked chips render
 *  disabled rather than hidden so a calibrating user still learns the longer views exist; W (the shortest)
 *  staying unconditional means nobody is ever stranded with zero ranges. */
/**
 * The range the chips + caption actually describe, resolved NON-DESTRUCTIVELY (Swift parity with
 * MetricExplorerView.coercedSelection). A locked selection renders as the largest unlocked range with
 * a real finite window that is <= the selection, else WEEK. NOT ALL: coercing a locked default to ALL
 * would jump a calibrating user to the everything view. An unlocked selection is used verbatim, so the
 * chip un-coerces on its own once history grows.
 */
internal fun coercedVitalRange(range: VitalDetailRange, unlocked: List<VitalDetailRange>): VitalDetailRange {
    if (range in unlocked) return range
    return VitalDetailRange.entries
        .filter { it.days != null && it.ordinal <= range.ordinal && it in unlocked }
        .maxByOrNull { it.ordinal }
        ?: VitalDetailRange.WEEK
}

internal fun unlockedVitalRanges(spanDays: Long): List<VitalDetailRange> {
    val ranges = VitalDetailRange.entries
    val unlocked = mutableListOf(ranges.first())
    for (i in 1 until ranges.size) {
        val previousWindow = ranges[i - 1].days ?: break
        if (spanDays > previousWindow) unlocked += ranges[i] else break
    }
    // ALL is never gated (Swift parity): a calibrating user can always see their full history,
    // even when it happens to draw the same points as a shorter window.
    val all = ranges.last()
    if (all.days == null && all !in unlocked) unlocked += all
    return unlocked
}

internal fun filterVitalPoints(
    points: List<Pair<String, Double>>,
    range: VitalDetailRange,
): List<Pair<String, Double>> {
    val windowDays = range.days ?: return points
    val latestDate = points.lastOrNull()?.first?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        ?: return points.takeLast(windowDays.toInt())
    val cutoff = latestDate.minusDays(windowDays - 1)
    val filtered = points.filter { (day, _) ->
        runCatching { LocalDate.parse(day) }.getOrNull()?.let { !it.isBefore(cutoff) } ?: false
    }
    return filtered.ifEmpty { points.takeLast(windowDays.toInt()) }
}

/** [filterVitalPoints] for the source-carrying [VitalReading] list — the SAME latest-relative window, so
 *  the readings table and the chart always agree on which readings are in view (task #8). Kept as a twin
 *  of the point filter (identical windowing) rather than shared-generic to preserve the pinned-test shape
 *  of [filterVitalPoints]. */
internal fun filterVitalReadings(
    readings: List<VitalReading>,
    range: VitalDetailRange,
): List<VitalReading> {
    val windowDays = range.days ?: return readings
    val latestDate = readings.lastOrNull()?.day?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        ?: return readings.takeLast(windowDays.toInt())
    val cutoff = latestDate.minusDays(windowDays - 1)
    val filtered = readings.filter { reading ->
        runCatching { LocalDate.parse(reading.day) }.getOrNull()?.let { !it.isBefore(cutoff) } ?: false
    }
    return filtered.ifEmpty { readings.takeLast(windowDays.toInt()) }
}
