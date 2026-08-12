package com.noop.analytics

import kotlin.math.ceil

/**
 * Build a GitHub-contribution-style heat grid from per-day values (e.g. daily active calories) — the pure,
 * cross-platform core of the Workouts "last 13 weeks" heatmap. Columns are calendar weeks (Monday-first),
 * rows are weekdays (0 = Mon … 6 = Sun); the LAST column is the current week and future days in it are
 * empty. Byte-for-byte twin of the Swift `ActivityHeatmap` in StrandAnalytics — the calendar arithmetic is
 * pure integer `days_from_civil`/`civil_from_days` on the `"yyyy-MM-dd"` day keys the app stores, so the
 * two platforms bucket identically. JVM-pure (JUnit-testable off-device).
 */
object ActivityHeatmap {

    const val DEFAULT_WEEKS = 13

    /** One grid cell. [day] = "yyyy-MM-dd" (null for a future pad cell); [value] = the metric (null = no
     *  data that day); [level] = 0 for no-data, 1..4 for intensity buckets. */
    data class Cell(val day: String?, val value: Double?, val level: Int)

    /**
     * [columns] is [weeks] lists of 7 cells (row 0 = Monday). [scale] is the ramp denominator: the
     * wearer's 90th-percentile ACTIVE day, floored at [RAMP_FLOOR_KCAL]. Scaling to the percentile (not
     * the raw max) stops one exceptional session flattening the whole grid to pale; the floor keeps a
     * beginner's low-calorie days appropriately cool instead of maxing them out.
     */
    data class Grid(val weeks: Int, val columns: List<List<Cell>>, val scale: Double) {
        val isEmpty: Boolean get() = columns.all { col -> col.all { it.value == null } }
    }

    /** The ramp denominator floor (kcal): days at/above this shade fullest. Mirrors OpenStrap's 250. */
    const val RAMP_FLOOR_KCAL = 250.0
    /** Percentile of the active days the ramp scales to (90th). */
    const val RAMP_PERCENTILE = 90.0

    /**
     * @param values day ("yyyy-MM-dd") → metric value. Missing days render as no-data cells.
     * @param today the "yyyy-MM-dd" anchoring the rightmost column.
     * @param weeks number of week columns (default 13).
     */
    fun build(values: Map<String, Double>, today: String, weeks: Int = DEFAULT_WEEKS): Grid {
        val e = epochDay(today) ?: return Grid(weeks, emptyList(), 0.0)
        val cols = weeks.coerceAtLeast(1)
        val todayWeekday = mondayFirstWeekday(e)
        val currentMonday = e - todayWeekday
        val firstMonday = currentMonday - (cols - 1).toLong() * 7L

        val active = ArrayList<Double>()   // present days with a positive value → the ramp's percentile basis
        val raw = ArrayList<List<Cell>>(cols)
        for (c in 0 until cols) {
            val col = ArrayList<Cell>(7)
            for (r in 0 until 7) {
                val d = firstMonday + c.toLong() * 7L + r.toLong()
                if (d > e) {
                    col.add(Cell(null, null, 0)) // future day in the current week
                } else {
                    val ds = civilDay(d)
                    val v = values[ds]
                    if (v != null && v > 0.0) active.add(v)
                    col.add(Cell(ds, v, 0))
                }
            }
            raw.add(col)
        }
        val scale = rampScale(active)
        val leveled = raw.map { col -> col.map { it.copy(level = levelFor(it.value, scale)) } }
        return Grid(cols, leveled, scale)
    }

    /**
     * Ramp denominator: the 90th-percentile ACTIVE day (nearest-rank, mirroring `deriveRestingHR`),
     * floored at [RAMP_FLOOR_KCAL]. No active days → the floor. Scaling to the percentile rather than
     * the max keeps one huge session from washing every other day out to level 1.
     */
    internal fun rampScale(active: List<Double>): Double {
        if (active.isEmpty()) return RAMP_FLOOR_KCAL
        val sorted = active.sorted()
        val rank = ceil(RAMP_PERCENTILE / 100.0 * sorted.size.toDouble()).toInt().coerceAtLeast(1)
        val p90 = sorted[minOf(rank, sorted.size) - 1]
        return maxOf(RAMP_FLOOR_KCAL, p90)
    }

    /** 0 = no data; otherwise 1..4 by fraction of [scale] (a present-but-zero day is still level 1). */
    internal fun levelFor(value: Double?, scale: Double): Int {
        if (value == null) return 0
        if (scale <= 0.0) return 1
        return ceil(value / scale * 4.0).toInt().coerceIn(1, 4)
    }

    /** Monday-first weekday (Mon = 0 … Sun = 6) of an epoch-day count. Epoch day 0 (1970-01-01) is a Thu. */
    internal fun mondayFirstWeekday(epochDay: Long): Int = (((epochDay + 3L) % 7L + 7L) % 7L).toInt()

    /** Parse "yyyy-MM-dd" → days since 1970-01-01 (proleptic Gregorian), or null if malformed. */
    internal fun epochDay(ymd: String): Long? {
        val p = ymd.split('-')
        if (p.size != 3) return null
        val y = p[0].toIntOrNull() ?: return null
        val m = p[1].toIntOrNull() ?: return null
        val d = p[2].toIntOrNull() ?: return null
        if (m < 1 || m > 12 || d < 1 || d > 31) return null
        return daysFromCivil(y, m, d)
    }

    /** days since 1970-01-01 → "yyyy-MM-dd". Inverse of [epochDay] (Howard Hinnant's civil_from_days). */
    internal fun civilDay(epochDay: Long): String {
        val z = epochDay + 719468L
        val era = (if (z >= 0) z else z - 146096L) / 146097L
        val doe = z - era * 146097L
        val yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
        val y0 = yoe + era * 400L
        val doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
        val mp = (5L * doy + 2L) / 153L
        val d = doy - (153L * mp + 2L) / 5L + 1L
        val m = if (mp < 10L) mp + 3L else mp - 9L
        val y = if (m <= 2L) y0 + 1L else y0
        return "%04d-%02d-%02d".format(y, m, d)
    }

    /** "yyyy-MM-dd" fields → days since 1970-01-01 (Howard Hinnant's days_from_civil). */
    private fun daysFromCivil(year: Int, month: Int, day: Int): Long {
        val y = if (month <= 2) year - 1 else year
        val era = (if (y >= 0) y else y - 399).toLong() / 400L
        val yoe = y.toLong() - era * 400L
        val mp = if (month > 2) month - 3 else month + 9
        val doy = (153L * mp + 2L) / 5L + day - 1L
        val doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
        return era * 146097L + doe - 719468L
    }
}
