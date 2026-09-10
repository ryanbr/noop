package com.noop.widget

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader

/**
 * Draws the stress trace to a Bitmap, because Glance cannot draw one.
 *
 * Kept as deliberately stupid as [HrTraceRenderer]: every decision worth testing was already made in
 * [StressTrace], and what remains is `moveTo`/`lineTo` over coordinates handed in. Nothing here chooses
 * a tick, a domain, or which hours are a gap.
 *
 * The one thing it does decide is how the ramp is applied, and that is a drawing detail rather than a
 * judgement: the line is coloured by a VERTICAL gradient. Because [StressTrace.segments] maps the score
 * onto Y off a fixed domain, height already encodes level, so a single top-to-bottom shader paints
 * every segment the colour its own score deserves, with no per-point work and no second pass. Amber at
 * the top, green through the middle, blue along the bottom, which is the screen's ramp read upward.
 *
 * Labels are not drawn here, though the design has them. They are Glance `Text` in the composable,
 * which keeps them crisp at any density, themeable with the rest of the widget, and legible to
 * TalkBack, none of which a label baked into a bitmap would be.
 */
internal object StressTraceRenderer {

    /**
     * @param segments from [StressTrace.segments], already normalised into the box, each a contiguous
     *        run of scored hours
     * @param movingMarks from [StressTrace.movingMarks], X centres of the hours masked as movement
     * @return the trace, or null when there is nothing to draw or the box is degenerate, so the caller
     *         shows the empty state rather than an empty image.
     */
    fun render(
        segments: List<List<StressTrace.Pt>>,
        movingMarks: List<Float>,
        /** from [StressTrace.highPoints], the scored hours sitting in the high band */
        highPoints: List<StressTrace.Pt>,
        widthPx: Int,
        heightPx: Int,
        calmColor: Int,
        steadyColor: Int,
        tenseColor: Int,
        /** The card underneath. Drawn as the ground, because an RGB_565 bitmap has no alpha. */
        backgroundColor: Int,
        /** Top of the area fill, already composited against the card. It fades DOWN into the card
         *  rather than fading out, because 565 has no alpha to fade into. */
        fillTopColor: Int,
        /** The faint marks along the base for the hours exertion masked. Already composited against
         *  the card: an RGB_565 bitmap has no alpha channel, so a translucent colour handed in here
         *  would draw at FULL strength. */
        markColor: Int,
        strokePx: Float,
    ): Bitmap? {
        if (segments.isEmpty() && movingMarks.isEmpty() && highPoints.isEmpty()) return null
        // The caller sized this with the shared payload budget; re-check it rather than re-decide it.
        val w = widthPx.coerceAtLeast(1)
        val h = heightPx.coerceAtLeast(1)
        if (w < 2 || h < 2) return null
        if (w.toLong() * h.toLong() * HrTrace.BYTES_PER_PIXEL > HrTrace.MAX_BITMAP_BYTES) return null

        val bmp = runCatching {
            Bitmap.createBitmap(w, h, Bitmap.Config.RGB_565)
        }.getOrNull() ?: return null
        val canvas = Canvas(bmp)
        canvas.drawColor(backgroundColor)

        // Reserve the bottom strip for the movement marks so a calm hour's line, which sits at the very
        // bottom of a fixed domain, cannot be confused with them.
        val markBand = if (movingMarks.isEmpty()) 0f else (strokePx * 2f).coerceAtMost(h / 6f)
        val chartH = (h - markBand).coerceAtLeast(1f)

        // Inset by the stroke so a point sitting exactly on the top or bottom edge is not shaved in half.
        val inset = strokePx / 2f
        val usableH = (chartH - strokePx).coerceAtLeast(1f)
        // Normalised by the FULL box height, because that is the height the caller built the
        // coordinates against. Dividing by the shortened band instead pushed a calm day, whose y sits
        // at the very bottom of the full box, past the bottom of the chart and into the marks.
        fun px(p: StressTrace.Pt) = p.x to (inset + p.y / h.toFloat() * usableH)

        // One shader for every segment: Y encodes the score, so vertical position IS the ramp.
        val ramp = LinearGradient(
            0f, 0f, 0f, chartH,
            intArrayOf(tenseColor, steadyColor, calmColor),
            floatArrayOf(0f, 0.5f, 1f),
            Shader.TileMode.CLAMP,
        )
        val stroke = Paint().apply {
            isAntiAlias = true
            isDither = true   // 565 bands a smooth ramp without it
            style = Paint.Style.STROKE
            strokeWidth = strokePx
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            shader = ramp
        }
        val dot = Paint().apply {
            isAntiAlias = true
            isDither = true
            shader = ramp
        }

        // Fill first, so every stroke sits on top of its own area rather than under the next one's.
        // Each run is closed to the baseline SEPARATELY: one path across the whole day would span the
        // gaps and fill under hours that were never scored, which is the thing the broken line exists
        // to avoid saying.
        val fill = Paint().apply {
            isAntiAlias = true
            isDither = true
            shader = LinearGradient(
                0f, 0f, 0f, chartH, fillTopColor, backgroundColor, Shader.TileMode.CLAMP,
            )
        }
        for (seg in segments) {
            if (seg.size < 2) continue
            val area = Path()
            seg.forEachIndexed { i, p ->
                val (x, y) = px(p)
                if (i == 0) area.moveTo(x, y) else area.lineTo(x, y)
            }
            area.lineTo(px(seg.last()).first, chartH)
            area.lineTo(px(seg.first()).first, chartH)
            area.close()
            canvas.drawPath(area, fill)
        }

        for (seg in segments) {
            if (seg.isEmpty()) continue
            // A run of one hour has no line to stroke, so give it a dot. Otherwise a day whose only
            // scored hours are isolated renders as an empty chart, which reads as "no data" rather than
            // as the sparse day it is.
            if (seg.size == 1) {
                val (x, y) = px(seg[0])
                canvas.drawCircle(x.coerceAtLeast(strokePx), y, strokePx, dot)
                continue
            }
            val path = Path()
            seg.forEachIndexed { i, p ->
                val (x, y) = px(p)
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            canvas.drawPath(path, stroke)
        }

        // The high-band hours, dotted above the line as the screen marks them. Drawn after the stroke
        // so a dot is never half-hidden under it, and in the tense colour because that is what being in
        // that band means.
        if (highPoints.isNotEmpty()) {
            val dotPaint = Paint().apply {
                isAntiAlias = true
                color = tenseColor
                style = Paint.Style.FILL
            }
            for (p in highPoints) {
                val (x, y) = px(p)
                canvas.drawCircle(
                    x.coerceIn(strokePx, w - strokePx),
                    (y - strokePx * 2f).coerceAtLeast(strokePx),
                    strokePx * 0.9f,
                    dotPaint,
                )
            }
        }

        if (movingMarks.isNotEmpty() && markBand > 0f) {
            val markPaint = Paint().apply {
                isAntiAlias = true
                color = markColor
                style = Paint.Style.FILL
            }
            val halfWidth = (strokePx * 1.5f).coerceAtLeast(1f)
            val top = h - markBand
            for (x in movingMarks) {
                canvas.drawRoundRect(
                    (x - halfWidth).coerceAtLeast(0f), top,
                    (x + halfWidth).coerceAtMost(w.toFloat()), h.toFloat(),
                    halfWidth, halfWidth, markPaint,
                )
            }
        }
        return bmp
    }
}
