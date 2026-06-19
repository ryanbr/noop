package com.noop.analytics

import java.time.LocalDate

/*
 * LabBookProjection.kt — value-for-value Kotlin twin of
 * StrandAnalytics/LabBookProjection.swift (Health Records "Lab Book" pillar,
 * spec 2026-06-19-v5-health-records-design.md).
 *
 * The two clients MUST produce identical daily projections and windowed pairs for the
 * same readings — this is the project's standard Swift/Kotlin parity footgun, pinned by
 * LabBookProjectionTest.kt against the same fixtures as the Swift LabBookProjectionTests.
 *
 * There is NO new statistics here: a marker is just another (day, value) series, and the
 * windowed-aggregate pairing is a disclosed trailing-exposure-window (the same idea as a
 * moving-average feature). Pure, deterministic, DB-free.
 *
 * Timezone-free by construction: it operates on PRE-DERIVED yyyy-MM-dd day strings (the
 * store derives the day from a reading's takenAt), so there is no Calendar/ZoneId
 * divergence between Swift and Kotlin. The trailing-window day arithmetic uses
 * java.time.LocalDate.minusDays — the calendar-correct, timezone-free equivalent of the
 * Swift UTC-calendar shiftDay.
 *
 * NON-CLINICAL: folds and lines up the user's own numbers. Never judges a value
 * normal/abnormal and ships no thresholds.
 */

/** One numeric reading reduced to what the projection needs. Mirrors Swift `LabReading`.
 *  Non-numeric (valueText-only) readings are simply not represented here. */
data class LabReading(
    val markerKey: String,
    /** Pre-derived yyyy-MM-dd day key (the store derived this from takenAt). */
    val day: String,
    val value: Double,
    /** The reading's instant (epoch seconds), used ONLY to order same-day readings for the
     *  latest-per-day rule; never re-derives the day. */
    val takenAtEpoch: Double,
)

/** A projected daily point for one marker — what gets upserted into `metricSeries` under
 *  the `lab-book` source. Mirrors Swift `ProjectedPoint`. */
data class ProjectedPoint(
    val markerKey: String,
    val day: String,
    val value: Double,
)

/** How to collapse several same-day readings of a marker into one daily value. Mirrors
 *  Swift `DailyFold`. */
enum class DailyFold { LATEST, MEAN }

/** One windowed-aggregate pair: a marker reading lined up against the trailing-window mean
 *  of a wearable series. Mirrors Swift `WindowedPair`. */
data class WindowedPair(
    val day: String,
    val markerValue: Double,
    val wearableMean: Double,
    val wearableN: Int,
)

object LabBookProjection {

    /** The constant device-id every projected marker day is written under (single-source).
     *  Matches Swift LabBookProjection.sourceId / WhoopDao.LAB_BOOK_SOURCE_ID. */
    const val SOURCE_ID = "lab-book"

    /** The two keys a blood-pressure pair is stored as (two keys for clean correlation). */
    const val BP_SYSTOLIC_KEY = "bp_systolic"
    const val BP_DIASTOLIC_KEY = "bp_diastolic"

    /** Default trailing window (days, inclusive of the reading day). */
    const val DEFAULT_WINDOW_DAYS = 14

    /** Cell-key separator: a control char (matches the Swift \u{1}) so "ab"+"c" can't
     *  collide with "a"+"bc" when grouping by (markerKey, day). */
    private const val CELL_SEP = ""

    // MARK: - Daily projection

    /**
     * Fold readings into one daily point per (markerKey, day). LATEST = most-recent takenAt
     * wins; MEAN = arithmetic mean. Output sorted by markerKey then day ascending so it is
     * deterministic across platforms. Byte-identical to Swift LabBookProjection.project.
     */
    fun project(readings: List<LabReading>, fold: DailyFold = DailyFold.LATEST): List<ProjectedPoint> {
        // Group by (markerKey, day), preserving first-seen order of the cells.
        val cells = LinkedHashMap<String, MutableList<LabReading>>()
        for (r in readings) {
            val cellKey = r.markerKey + CELL_SEP + r.day
            cells.getOrPut(cellKey) { ArrayList() }.add(r)
        }

        val out = ArrayList<ProjectedPoint>(cells.size)
        for ((_, group) in cells) {
            if (group.isEmpty()) continue
            val value: Double = when (fold) {
                DailyFold.LATEST -> {
                    // Most recent takenAt wins; a tie keeps the last in input order (>=),
                    // matching the Swift loop.
                    var best = group[0]
                    for (i in 1 until group.size) {
                        if (group[i].takenAtEpoch >= best.takenAtEpoch) best = group[i]
                    }
                    best.value
                }
                DailyFold.MEAN -> {
                    var sum = 0.0
                    for (r in group) sum += r.value
                    sum / group.size
                }
            }
            out.add(ProjectedPoint(group[0].markerKey, group[0].day, value))
        }

        // Deterministic order: markerKey asc, then day asc.
        out.sortWith(compareBy({ it.markerKey }, { it.day }))
        return out
    }

    // MARK: - Windowed-aggregate pairing

    /**
     * Pair each marker reading with the trailing-window mean of a wearable series. Each marker
     * day D is paired with the mean of all wearable values whose day is within the trailing
     * `windowDays` INCLUSIVE of D: `D - (windowDays - 1) .. D`. Days with NO wearable coverage
     * are dropped; result sorted by day ascending; window clamped to >= 1.
     * Byte-identical to Swift LabBookProjection.pairMarkerToWearable.
     */
    fun pairMarkerToWearable(
        marker: List<Pair<String, Double>>,
        wearable: List<Pair<String, Double>>,
        windowDays: Int = DEFAULT_WINDOW_DAYS,
    ): List<WindowedPair> {
        val width = maxOf(1, windowDays)

        // Last-write-wins per day for both series (matches alignByDay semantics).
        val markerByDay = LinkedHashMap<String, Double>()
        for ((d, v) in marker) markerByDay[d] = v
        val wearableByDay = LinkedHashMap<String, Double>()
        for ((d, v) in wearable) wearableByDay[d] = v

        val pairs = ArrayList<WindowedPair>()
        for (day in markerByDay.keys.sorted()) {
            val mv = markerByDay[day] ?: continue
            var sum = 0.0
            var n = 0
            for (back in 0 until width) {
                val wDay = shiftDay(day, -back) ?: continue
                val wv = wearableByDay[wDay]
                if (wv != null) {
                    sum += wv
                    n += 1
                }
            }
            if (n == 0) continue // no coverage → drop the reading
            pairs.add(WindowedPair(day = day, markerValue = mv, wearableMean = sum / n, wearableN = n))
        }
        return pairs
    }

    /** Reduce windowed pairs to the (x, y) tuples Pearson consumes (x = marker, y = wearable
     *  trailing-window mean), ordered by day. Mirrors Swift LabBookProjection.correlationInput. */
    fun correlationInput(pairs: List<WindowedPair>): List<Pair<Double, Double>> =
        pairs.map { it.markerValue to it.wearableMean }

    /**
     * Shift a yyyy-MM-dd day string by `delta` days (can be negative), returning a normalised
     * yyyy-MM-dd string, or null if the input can't be parsed. Calendar-correct and
     * timezone-free — the Kotlin equivalent of the Swift UTC-calendar CorrelationEngine.shiftDay.
     */
    fun shiftDay(day: String, delta: Int): String? {
        if (delta == 0) return day
        val base = runCatching { LocalDate.parse(day) }.getOrNull() ?: return null
        return base.plusDays(delta.toLong()).toString() // LocalDate.toString() is ISO yyyy-MM-dd
    }
}
