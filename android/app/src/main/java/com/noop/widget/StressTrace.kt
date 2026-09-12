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
     * The moving hours grouped into CONTIGUOUS x ranges, for the marks along the base (#2106).
     *
     * A run rather than a mark per hour, because a run says which STRETCH of the day was masked, and
     * that is what a reader needs when they are looking at a hole in the trace and trying to work out
     * what put it there. The reason it matters was reported rather than theorised: a wearer saw the
     * gaps, read the evenly spaced marks along the zero line as axis ticks, concluded the data itself
     * was missing, and asked whether continuous HRV tracking would fill them in. One bar under the
     * stretch it explains cannot be mistaken for a scale, because a scale does not start and stop with
     * the data.
     *
     * Adjacency is by POSITION in the series, not by timestamp arithmetic: the series is already the
     * hour grid the chart draws, so two neighbouring entries are two neighbouring hours by construction.
     *
     * A span runs edge to edge of the hours it covers, NOT centre to centre. An hour is a stretch of the
     * day, not an instant, and the difference is the whole case for the change: centre to centre gives a
     * lone masked hour a width of zero, which is exactly the hour that most needs to be legible, since
     * there is no run of neighbours to make it obvious. Edges are taken as the MIDPOINT to each
     * neighbour rather than as a fixed slot, so an irregular series (a DST-long day, an hour missing
     * from the list entirely) still gets honest extents. At the ends of the series the territory stops
     * at the point itself: the day's extent is what was sampled, and nothing is invented past it, which
     * also keeps every span inside the box without a clamp.
     *
     * The upper edge is floored to the lower one. On a sorted series it never binds, but the two
     * platforms disagree about what an inverted range means, Kotlin yielding an empty one where Swift
     * traps, and a twin that crashes on one side and shrugs on the other is not a twin.
     */
    fun movingSpans(series: List<StressPoint>, width: Float): List<ClosedFloatingPointRange<Float>> {
        if (series.isEmpty() || width <= 0f) return emptyList()
        val t0 = series.first().ts
        val span = (series.last().ts - t0).toFloat()
        val xs = FloatArray(series.size) {
            if (span <= 0f) 0f else (series[it].ts - t0) / span * width
        }
        val last = series.lastIndex
        fun leftEdge(i: Int): Float = if (i == 0) xs[0] else (xs[i - 1] + xs[i]) / 2f
        fun rightEdge(i: Int): Float = if (i == last) xs[last] else (xs[i] + xs[i + 1]) / 2f
        val out = ArrayList<ClosedFloatingPointRange<Float>>()
        var runStart: Int? = null
        for (i in series.indices) {
            val moving = series[i].moving
            if (moving && runStart == null) runStart = i
            val from = runStart
            // A run closes at the first hour that is NOT moving, and also at the end of the series, or
            // a day whose last hours were all masked would be dropped for want of a terminator.
            if (from != null && (!moving || i == last)) {
                val lo = leftEdge(from)
                out.add(lo..maxOf(rightEdge(if (moving) i else i - 1), lo))
                runStart = null
            }
        }
        return out
    }

    /**
     * The labels up the left edge, top-down: the top of the domain down to zero.
     *
     * Fixed, not derived, for the same reason the domain is: these are the scale, and a chart whose
     * axis moved with the day would make two days impossible to compare at a glance.
     */
    fun levelTicks(): List<Int> = listOf(3, 2, 1, 0)

    /**
     * The three timestamps along the bottom: first, middle and last of the SERIES.
     *
     * The series, not the scored hours, because these label the AXIS, and the axis IS the series: every
     * placement in this file maps x across `first.ts .. last.ts`, and every renderer spreads these three
     * labels evenly across that same width. Anchoring them to the scored subset instead put the last
     * SCORED instant at the right-hand edge, so a day whose closing hours were all masked as movement
     * announced that it ended when scoring stopped rather than when the day did.
     *
     * That is the second half of #2106, and it was read exactly as it was drawn: a chart running to
     * 22:00 labelled "18:30" at its right edge, reported as the app having stopped updating. The
     * trailing hours were there the whole time, masked as exertion. Only the axis disagreed.
     *
     * The rationale this replaces was that an evening-only wearer would otherwise be labelled with a
     * morning that was never sampled. The buckets are built FROM the samples, so the series carries no
     * unsampled hours to begin with, and the trace was already spread across the series either way. The
     * labels were the only part that ever disagreed with the geometry.
     *
     * Fewer than three distinct instants returns what there is, so the renderer draws one label rather
     * than three copies of it.
     */
    fun timeTicks(series: List<StressPoint>): List<Long> {
        if (series.isEmpty()) return emptyList()
        val first = series.first().ts
        val last = series.last().ts
        if (first == last) return listOf(first)
        val mid = first + (last - first) / 2
        return if (mid == first || mid == last) listOf(first, last) else listOf(first, mid, last)
    }
}
