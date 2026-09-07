package com.noop.widget

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader

/**
 * Draws the heart-rate trace to a Bitmap, because Glance cannot draw one.
 *
 * Glance compiles to RemoteViews, which has no Canvas and no arbitrary shapes — a sparkline can only
 * reach a widget as an Image. So this exists, and it is kept deliberately STUPID: every decision worth
 * testing was already made in [HrTrace], and what remains is `moveTo`/`lineTo` over coordinates handed
 * in. Nothing here chooses a tick, a range, or a point.
 *
 * The LABELS are not drawn here either, though the design has them. They are Glance `Text` in the
 * composable instead, which keeps them crisp at any density, themeable with the rest of the widget, and
 * legible to TalkBack — none of which a label baked into a bitmap would be.
 */
internal object HrTraceRenderer {

    /**
     * @param points from [HrTrace.points], already normalised into the box
     * @return the trace, or null when there is nothing to draw or the box is degenerate — the caller
     *         shows the empty state rather than an empty image.
     */
    fun render(
        points: List<HrTrace.Pt>,
        widthPx: Int,
        heightPx: Int,
        lineColor: Int,
        fillTopColor: Int,
        strokePx: Float,
    ): Bitmap? {
        if (points.isEmpty()) return null
        // The caller sized this with [HrTrace.fitBox], which owns the payload budget. Clamping to a
        // DIFFERENT ceiling here is what previously let the geometry and the bitmap disagree, so this
        // only guards against a nonsense box, and re-checks the budget rather than re-deciding it.
        val w = widthPx.coerceAtLeast(1)
        val h = heightPx.coerceAtLeast(1)
        if (w < 2 || h < 2) return null
        if (w.toLong() * h.toLong() * 4L > HrTrace.MAX_BITMAP_BYTES) return null

        val bmp = runCatching {
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        }.getOrNull() ?: return null
        val canvas = Canvas(bmp)

        // Inset by the stroke so a point sitting exactly on the top or bottom edge is not shaved in
        // half. The geometry maps the extremes to 0 and `height`, which is correct for a line of zero
        // width and half a stroke short of it for a real one.
        val inset = strokePx / 2f
        val usableH = (h - strokePx).coerceAtLeast(1f)
        fun px(p: HrTrace.Pt) = p.x to (inset + p.y / h * usableH)

        val line = Path()
        points.forEachIndexed { i, p ->
            val (x, y) = px(p)
            if (i == 0) line.moveTo(x, y) else line.lineTo(x, y)
        }

        // A single point has no line to stroke, so give it a dot — otherwise a widget placed this
        // minute renders as an empty chart, which reads as "no data" rather than "one reading".
        if (points.size == 1) {
            val (x, y) = px(points[0])
            canvas.drawCircle(x.coerceAtLeast(strokePx), y, strokePx, Paint().apply {
                isAntiAlias = true
                color = lineColor
            })
            return bmp
        }

        // Fill first, so the stroke sits on top of its own gradient rather than under it.
        val fill = Path(line)
        fill.lineTo(points.last().x, h.toFloat())
        fill.lineTo(points.first().x, h.toFloat())
        fill.close()
        canvas.drawPath(fill, Paint().apply {
            isAntiAlias = true
            shader = LinearGradient(
                0f, 0f, 0f, h.toFloat(), fillTopColor, fillTopColor and 0x00FFFFFF, Shader.TileMode.CLAMP,
            )
        })

        canvas.drawPath(line, Paint().apply {
            isAntiAlias = true
            style = Paint.Style.STROKE
            strokeWidth = strokePx
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            color = lineColor
        })
        return bmp
    }
}
