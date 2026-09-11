package com.noop.widget

/** One point on the widget's heart-rate trace: when it was taken, and the bpm. */
data class HrPoint(val ts: Long, val bpm: Int)

/**
 * The pure half of the heart-rate widget: what the trace CONTAINS and where its ink goes.
 *
 * Split from the drawing because Glance cannot draw. A sparkline has to be rendered to a Bitmap and
 * handed over as an Image, and a Bitmap is not something a JVM test can meaningfully assert about — so
 * everything decidable without a Canvas lives here, unit-tested, and the renderer is left with nothing
 * but `moveTo`/`lineTo` over coordinates this file produced.
 *
 * Also the shape an iOS twin would share. SwiftUI can draw the trace directly, so the renderer will not
 * port, but the retention rule, the tick choices and the normalisation are the same decisions on both
 * platforms and should not be made twice.
 */
object HrTrace {

    /** How much history the trace shows. Three hours matches what fits legibly at widget width. */
    const val WINDOW_SEC: Long = 3 * 60 * 60

    /** One point per minute. The strap streams ~1/s; keeping every sample would put 10 800 points behind
     *  a trace 300 pixels wide, which costs prefs space and buys nothing the eye can resolve. */
    const val BUCKET_SEC: Long = 60

    /** What counts as a GAP. Deliberately NOT the Today chart's "more than one bucket": that chart reads
     *  a fixed DB grid, where a missing bucket really is missing data, while this series only gains a
     *  point when the app PUBLISHES one, and background scheduling routinely skips a minute. At a
     *  one-bucket threshold that ordinary jitter would shatter a healthy trace into dots, which is a
     *  worse lie than the joined line being fixed.
     *
     *  Set to [HrDisplay.STALE_CAP_MS] rather than to a number picked here, so the line breaks exactly
     *  where the widget would already have dropped the headline reading for being too old to represent
     *  HR at all. `theGapThresholdMatchesTheStaleCap` pins the two together. */
    const val GAP_SEC: Long = 15 * BUCKET_SEC

    /** Hard cap, so a clock jump backwards cannot grow the series without bound. WINDOW_SEC/BUCKET_SEC
     *  is 180; the slack absorbs a boundary point without letting the list run away. */
    const val MAX_POINTS: Int = 200

    /**
     * Fold a fresh reading into the series: one point per minute bucket, newest wins within a bucket.
     *
     * Newest-wins rather than an average because the widget's headline number is the LATEST bpm, and a
     * trace whose last point disagreed with the number printed above it would read as a bug. Within a
     * minute the difference is a beat or two.
     */
    fun append(series: List<HrPoint>, ts: Long, bpm: Int, nowSec: Long = ts): List<HrPoint> {
        if (bpm <= 0) return prune(series, nowSec)
        val bucket = ts / BUCKET_SEC * BUCKET_SEC
        val out = ArrayList<HrPoint>(series.size + 1)
        for (p in series) if (p.ts != bucket) out.add(p)
        out.add(HrPoint(bucket, bpm))
        // No sort here: [prune] sorts on the way out, and it has to anyway because [decode] feeds it
        // untrusted input. Appending at the end is already in order for every sample that is not a clock
        // jump backwards, and prune's sort is what makes even that case correct.
        return prune(out, nowSec)
    }

    /** Drop anything older than the window, then anything beyond the cap (oldest first). */
    fun prune(series: List<HrPoint>, nowSec: Long): List<HrPoint> {
        val floor = nowSec - WINDOW_SEC
        val kept = series.filter { it.ts >= floor }.sortedBy { it.ts }
        return if (kept.size <= MAX_POINTS) kept else kept.subList(kept.size - MAX_POINTS, kept.size)
    }

    /** `ts:bpm` pairs, comma separated. Compact enough that 200 points sit well inside a prefs string,
     *  and readable in a bug report, which a binary blob would not be. */
    fun encode(series: List<HrPoint>): String =
        series.joinToString(",") { "${it.ts}:${it.bpm}" }

    /** Tolerant by design: a malformed pair is skipped rather than throwing. This runs on the widget's
     *  render path, where the alternative to a partial trace is a crashed home screen. */
    fun decode(s: String?): List<HrPoint> {
        if (s.isNullOrBlank()) return emptyList()
        val out = ArrayList<HrPoint>()
        for (part in s.split(',')) {
            val i = part.indexOf(':')
            if (i <= 0 || i == part.length - 1) continue
            val ts = part.substring(0, i).toLongOrNull() ?: continue
            val bpm = part.substring(i + 1).toIntOrNull() ?: continue
            if (bpm > 0) out.add(HrPoint(ts, bpm))
        }
        out.sortBy { it.ts }
        return out
    }

    /** The three numbers the header shows. Null when there is nothing to describe. */
    data class Stats(val min: Int, val max: Int, val latest: Int)

    fun stats(series: List<HrPoint>): Stats? {
        if (series.isEmpty()) return null
        var lo = series[0].bpm
        var hi = series[0].bpm
        for (p in series) {
            if (p.bpm < lo) lo = p.bpm
            if (p.bpm > hi) hi = p.bpm
        }
        return Stats(min = lo, max = hi, latest = series.last().bpm)
    }


    /**
     * The largest drawing box that fits the widget payload budget, keeping the requested aspect.
     *
     * RemoteViews travels to the launcher over a BINDER TRANSACTION with a hard size ceiling, and a
     * widget that exceeds it does not degrade — it fails to render at all. An ARGB_8888 bitmap costs
     * four bytes a pixel, so a 300dp-wide chart on a 4x screen is already about a megabyte on its own,
     * before the rest of the RemoteViews. Dimension caps alone do not express that: the constraint is
     * AREA, and a wide-and-short box and a tall-and-narrow one can both be legal while their product
     * is not.
     *
     * Downscaling is nearly free here in a way it would not be for text or an icon: a sparkline is a
     * smooth line, and the `Image` stretches the result back to the same slot, so the only cost is a
     * fractionally softer stroke.
     *
     * Returned as the box BOTH [points] and the renderer must use. They used to disagree — geometry ran
     * at the requested width while the renderer clamped its own — which silently clipped the right-hand
     * end of the trace on any screen large enough to hit the cap.
     */
    fun fitBox(widthPx: Int, heightPx: Int, maxBytes: Int = MAX_BITMAP_BYTES): Pair<Int, Int> {
        val w = widthPx.coerceAtLeast(1)
        val h = heightPx.coerceAtLeast(1)
        val bytes = w.toLong() * h.toLong() * BYTES_PER_PIXEL
        if (bytes <= maxBytes) return w to h
        val scale = Math.sqrt(maxBytes.toDouble() / bytes.toDouble())
        return (w * scale).toInt().coerceAtLeast(1) to (h * scale).toInt().coerceAtLeast(1)
    }

    /** The bitmap's byte budget. Half a megabyte leaves the rest of the RemoteViews comfortable inside
     *  the transaction ceiling, and still affords a full-density chart on an ordinary phone. */
    const val MAX_BITMAP_BYTES: Int = 512 * 1024

    /** Bytes per pixel the renderer actually spends. The trace is one hue over an opaque card, so it is
     *  drawn RGB_565 rather than ARGB_8888 — there is no transparency to preserve, and at four bytes a
     *  pixel the budget could not afford both a taller chart and a width that avoids stretching it. */
    const val BYTES_PER_PIXEL: Int = 2

    /**
     * The widest bitmap the budget allows at an EXACT height, with headroom over what the caller asked.
     *
     * Two things force this. `LocalSize` under-reports on some launchers — a One UI card reported about
     * 60% of its true width — so a bitmap rendered at the reported width is UPSCALED to fill, and only
     * horizontally, which turns a round stroke elliptical and soft. And [fitBox] preserves aspect, so
     * simply asking for a wider box would shrink the height too and trade a horizontal stretch for a
     * vertical one.
     *
     * So: height is taken as given and never scaled, and the width gets what is left of the budget, up
     * to [WIDTH_HEADROOM] times the request so a small widget does not allocate a huge strip for
     * nothing. Downscaling is the cheap direction — a smooth line loses nothing to it.
     */
    fun widestAtHeight(requestedPx: Int, heightPx: Int, maxBytes: Int = MAX_BITMAP_BYTES): Int {
        val h = heightPx.coerceAtLeast(1)
        val budgetWidth = (maxBytes / (h * BYTES_PER_PIXEL)).coerceAtLeast(1)
        val want = (requestedPx.coerceAtLeast(1) * WIDTH_HEADROOM).toInt()
        return want.coerceAtMost(budgetWidth).coerceAtLeast(requestedPx.coerceAtLeast(1).coerceAtMost(budgetWidth))
    }

    /**
     * How much wider than the reported width to draw, to cover a launcher that under-reports.
     *
     * NOTE THAT THIS CEILING IS RARELY THE ONE THAT BINDS. [MAX_BITMAP_BYTES] runs out first at any
     * realistic widget size: at 420dpi a 300dp-wide card gets 1.66x, a 380dp one 1.26x, and at 480dpi
     * a 380dp card gets 0.96x — narrower than the reported width, so the bitmap is UPSCALED, which is
     * the artefact this constant exists to prevent. Raising this number changes nothing on a real
     * phone; the byte budget is the lever, and it trades directly against horizontal resolution.
     *
     * Kept at two because it is the correct intent and it still binds on a small widget. The gap
     * between the intent and what the budget allows is measured rather than papered over — see the
     * widget cost counters.
     */
    const val WIDTH_HEADROOM: Float = 2f

    /** A point in the trace's pixel box, origin top-left, as the renderer wants it.
     *
     *  [startsRun] means LIFT THE PEN before this point: nothing was recorded for [GAP_SEC] before it.
     *  The renderer joined every point unconditionally, and because x is mapped by TIME rather than by
     *  index, a 90-minute disconnect inside the 3-hour window drew as one confident diagonal across
     *  half the widget. The gap was already the right width; it was the line across it that was never
     *  measured: the same defect #2082 describes on the Today sparkline, on a second surface. */
    data class Pt(val x: Float, val y: Float, val startsRun: Boolean = false)

    /** The trace split into runs of consecutive readings: each range is a stretch the strap recorded
     *  without a break, and the pen lifts between one run and the next. A series with no gaps is one
     *  run, which is the common case and draws exactly as it always did. */
    fun runs(points: List<Pt>): List<IntRange> {
        if (points.isEmpty()) return emptyList()
        val out = mutableListOf<IntRange>()
        var start = 0
        for (i in 1 until points.size) {
            if (points[i].startsRun) {
                out.add(start..(i - 1))
                start = i
            }
        }
        out.add(start..(points.size - 1))
        return out
    }

    /**
     * The trace as pixels inside a `width` x `height` box.
     *
     * Two degenerate shapes decide most of this, and both are ordinary rather than exotic — a widget
     * placed mid-afternoon has one point, and a resting arm holds one bpm for minutes at a time:
     *
     *  - ONE point, or every point at the same instant: there is no time axis to spread across, so it
     *    sits at the left edge rather than at x=NaN.
     *  - every bpm equal: there is no range to scale into, so the line runs along the VERTICAL MIDDLE.
     *    Pinning it to the top or bottom would read as a maxed-out or flatlined heart.
     *
     * Y is flipped on the way out: bpm rises upward, pixels rise downward.
     */
    fun points(series: List<HrPoint>, width: Float, height: Float): List<Pt> {
        if (series.isEmpty() || width <= 0f || height <= 0f) return emptyList()
        val t0 = series.first().ts
        val t1 = series.last().ts
        val span = (t1 - t0).toFloat()
        var lo = series[0].bpm
        var hi = series[0].bpm
        for (p in series) {
            if (p.bpm < lo) lo = p.bpm
            if (p.bpm > hi) hi = p.bpm
        }
        val range = (hi - lo).toFloat()
        return series.mapIndexed { i, p ->
            val x = if (span <= 0f) 0f else (p.ts - t0) / span * width
            val y = if (range <= 0f) height / 2f else height - (p.bpm - lo) / range * height
            Pt(x, y, startsRun = i > 0 && p.ts - series[i - 1].ts > GAP_SEC)
        }
    }

    /**
     * The three bpm labels down the right edge: max, midpoint, min, exactly as they are stacked in the
     * chart. Returned high-to-low so the caller can lay them out top-down without re-sorting.
     *
     * A flat series returns the same number three times rather than an invented spread — the honest
     * reading of a steady heart is one number, and manufacturing 58/59/60 around it would put ticks on
     * the chart that no sample supports.
     */
    fun bpmTicks(stats: Stats): List<Int> =
        listOf(stats.max, (stats.min + stats.max + 1) / 2, stats.min)

    /**
     * The three timestamps along the bottom: first, middle, last of the DATA, not of the window.
     *
     * Anchored to the data because a widget holding forty minutes of history would otherwise label its
     * axis with two hours that were never sampled, and the trace would appear crushed into the right
     * third of a mostly empty chart. Fewer than three distinct instants returns what there is, so the
     * renderer draws one label rather than three copies of it.
     */
    fun timeTicks(series: List<HrPoint>): List<Long> {
        if (series.isEmpty()) return emptyList()
        val first = series.first().ts
        val last = series.last().ts
        if (first == last) return listOf(first)
        val mid = first + (last - first) / 2
        return if (mid == first || mid == last) listOf(first, last) else listOf(first, mid, last)
    }
}
