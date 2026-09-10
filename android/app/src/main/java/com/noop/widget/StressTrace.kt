package com.noop.widget

import com.noop.analytics.DaytimeStress

/**
 * One hour on the widget's stress trace.
 *
 * [level] is the shared 0-3 proxy, null when the hour was not scored. [moving] separates the two
 * reasons it can be null: the motion gate masked an AMBULATORY hour (exertion raises heart rate on
 * its own, so it is deliberately not scored as stress), or there simply was not enough signal. Both
 * break the line; only the first earns a mark along the base.
 */
data class StressPoint(val ts: Long, val level: Double?, val moving: Boolean = false)

/**
 * The pure half of the stress widget: what the trace CONTAINS and where its ink goes.
 *
 * Split from the drawing for the same reason as [HrTrace] — Glance compiles to RemoteViews, which has
 * no Canvas, so a chart can only reach a widget as a Bitmap, and a Bitmap is not something a JVM test
 * can meaningfully assert about. Everything decidable without a Canvas lives here and is unit-tested.
 *
 * TWO THINGS DIFFER FROM [HrTrace], and both are deliberate.
 *
 * The domain is FIXED at 0-3, not normalised to the day's own min and max. Heart rate has no absolute
 * meaning at widget size, so its trace spreads whatever range it has across the full box. A stress
 * score does have one: the bands are what the number means, and [DOMAIN_MAX] is the top of the scale
 * the app scores against everywhere else. Normalising here would redraw a flat calm day as a dramatic
 * one, which is precisely the lie the fixed domain exists to prevent.
 *
 * And the series is REPLACED rather than appended to. The HR trace folds a live push into a rolling
 * window; today's stress is a whole scored day that arrives complete each time analysis runs, so there
 * is no retention rule to get right, no clock-jump guard, and no cap. Yesterday's trace is not merged
 * into today's, it is simply overwritten.
 *
 * Also the shape an iOS twin would share. SwiftUI draws directly so the renderer will not port, but the
 * domain, the gap rule and the tick choices are the same decisions on both platforms and should not be
 * made twice.
 */
object StressTrace {

    /** Top of the scored range. The 0-3 proxy is the same scale the gauge and the screen use. */
    const val DOMAIN_MAX: Double = 3.0

    /** A day of hourly buckets, with slack for a DST-long day. Nothing here folds, so this only guards
     *  a malformed payload from growing the list without bound. */
    const val MAX_POINTS: Int = 26

    /** `ts:level:moving`, comma separated, with `-` for an unscored hour. Compact enough for a prefs
     *  string at a day's length, and readable in a bug report, which a binary blob would not be. */
    fun encode(series: List<StressPoint>): String =
        series.joinToString(",") { p ->
            val level = p.level?.let { String.format(java.util.Locale.US, "%.2f", it) } ?: "-"
            "${p.ts}:$level:${if (p.moving) 1 else 0}"
        }

    /** Tolerant by design: a malformed triple is skipped rather than throwing. This runs on the widget's
     *  render path, where the alternative to a partial trace is a crashed home screen. */
    fun decode(s: String?): List<StressPoint> {
        if (s.isNullOrBlank()) return emptyList()
        val out = ArrayList<StressPoint>()
        for (part in s.split(',')) {
            val bits = part.split(':')
            if (bits.size != 3) continue
            val ts = bits[0].toLongOrNull() ?: continue
            val level = if (bits[1] == "-") null else bits[1].toDoubleOrNull() ?: continue
            if (level != null && (level < 0.0 || level > DOMAIN_MAX)) continue
            out.add(StressPoint(ts, level, bits[2] == "1"))
        }
        out.sortBy { it.ts }
        return if (out.size <= MAX_POINTS) out else out.subList(out.size - MAX_POINTS, out.size)
    }

    /** The numbers the header shows. Null when no hour was scored. */
    data class Stats(
        /** Mean across SCORED hours, the same figure the screen prints as the day's average. */
        val mean: Double,
        /** Highest scored hour. */
        val peak: StressPoint,
        /** How many hours carry a score. */
        val scoredHours: Int,
        /** How many were masked as movement rather than scored. */
        val movingHours: Int,
    )

    fun stats(series: List<StressPoint>): Stats? {
        val scored = series.filter { it.level != null }
        if (scored.isEmpty()) return null
        var peak = scored[0]
        var sum = 0.0
        for (p in scored) {
            sum += p.level!!
            if (p.level > peak.level!!) peak = p
        }
        return Stats(
            mean = sum / scored.size,
            peak = peak,
            scoredHours = scored.size,
            movingHours = series.count { it.moving },
        )
    }

    /** A point in the trace's pixel box, origin top-left, as the renderer wants it. */
    data class Pt(val x: Float, val y: Float)

    /**
     * The trace as CONTIGUOUS RUNS of scored hours, each already in pixels.
     *
     * Runs rather than one list because an unscored hour is a hole in the day, and a polyline drawn
     * straight across it would invent a reading for an hour that has none. The screen's own caption
     * promises bare gaps, so the widget owes the same. Each returned run is drawn as its own path.
     *
     * X is placed on the hour's position in the day's SPAN, so an afternoon hole leaves a hole of the
     * right width rather than closing up. A single scored hour, or a day whose hours all share one
     * timestamp, has no span to spread across and sits at the left edge rather than at x=NaN.
     *
     * Y comes off the FIXED domain, so an empty-ish calm day draws along the bottom where it belongs.
     * Y is flipped on the way out: stress rises upward, pixels rise downward.
     */
    fun segments(series: List<StressPoint>, width: Float, height: Float): List<List<Pt>> {
        if (series.isEmpty() || width <= 0f || height <= 0f) return emptyList()
        val t0 = series.first().ts
        val t1 = series.last().ts
        val span = (t1 - t0).toFloat()
        val out = ArrayList<List<Pt>>()
        var run = ArrayList<Pt>()
        for (p in series) {
            val level = p.level
            if (level == null) {
                if (run.isNotEmpty()) { out.add(run); run = ArrayList() }
                continue
            }
            run.add(place(p.ts, level, t0, span, width, height))
        }
        if (run.isNotEmpty()) out.add(run)
        return out
    }

    /**
     * The scored hours sitting in the HIGH band, as pixels, for the dots the screen puts above the line.
     *
     * The threshold is read from [DaytimeStress.highBandFloor] rather than restated here. It is the same
     * cutoff the sustained-stress check uses, and a second copy of it would drift the day the band moves,
     * leaving the widget dotting hours the app no longer calls high.
     *
     * Mapped through the same placement as [segments], so a dot lands exactly on its own vertex.
     */
    fun highPoints(series: List<StressPoint>, width: Float, height: Float): List<Pt> {
        if (series.isEmpty() || width <= 0f || height <= 0f) return emptyList()
        val t0 = series.first().ts
        val span = (series.last().ts - t0).toFloat()
        return series.mapNotNull { p ->
            val level = p.level ?: return@mapNotNull null
            if (level < DaytimeStress.highBandFloor) return@mapNotNull null
            place(p.ts, level, t0, span, width, height)
        }
    }

    /** The one placement rule, shared so a dot and its vertex cannot land apart. */
    private fun place(ts: Long, level: Double, t0: Long, span: Float, width: Float, height: Float): Pt {
        val x = if (span <= 0f) 0f else (ts - t0) / span * width
        val y = height - (level / DOMAIN_MAX).toFloat().coerceIn(0f, 1f) * height
        return Pt(x, y)
    }

    /**
     * X positions of the hours masked as movement, for the faint marks along the base.
     *
     * Returned as bare X centres rather than as spans: the mark's thickness is a drawing decision and
     * belongs to the renderer, while WHERE the moving hours were is a fact about the day.
     */
    fun movingMarks(series: List<StressPoint>, width: Float): List<Float> {
        if (series.isEmpty() || width <= 0f) return emptyList()
        val t0 = series.first().ts
        val span = (series.last().ts - t0).toFloat()
        return series.filter { it.moving }.map { p ->
            if (span <= 0f) 0f else (p.ts - t0) / span * width
        }
    }

    /**
     * The labels up the left edge, top-down: the top of the domain down to zero.
     *
     * Fixed, not derived, for the same reason the domain is: these are the scale, and a chart whose
     * axis moved with the day would make two days impossible to compare at a glance.
     */
    fun levelTicks(): List<Int> = listOf(3, 2, 1, 0)

    /**
     * The three timestamps along the bottom: first, middle, last of the SCORED data, not of the day.
     *
     * Anchored to scored hours because a day that only has an evening's worth of signal would otherwise
     * label its axis with a morning that was never sampled, and the trace would sit crushed into the
     * right-hand end of a mostly empty chart. Fewer than three distinct instants returns what there is,
     * so the renderer draws one label rather than three copies of it.
     */
    fun timeTicks(series: List<StressPoint>): List<Long> {
        val scored = series.filter { it.level != null }
        if (scored.isEmpty()) return emptyList()
        val first = scored.first().ts
        val last = scored.last().ts
        if (first == last) return listOf(first)
        val mid = first + (last - first) / 2
        return if (mid == first || mid == last) listOf(first, last) else listOf(first, mid, last)
    }
}
