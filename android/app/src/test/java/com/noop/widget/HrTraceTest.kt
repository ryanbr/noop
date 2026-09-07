package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The heart-rate widget's pure half (#1957). Everything decidable without a Canvas is decided here,
 * because the Bitmap the renderer produces is not something a JVM test can assert about.
 *
 * The cases that carry weight are the DEGENERATE ones — a single point, a flat bpm, a clock that went
 * backwards — since those are ordinary on a home screen (a widget placed mid-afternoon, a resting arm)
 * and are exactly where a normalisation divides by zero.
 */
class HrTraceTest {

    private fun series(vararg pairs: Pair<Long, Int>) = pairs.map { HrPoint(it.first, it.second) }

    // --- retention -------------------------------------------------------------------------------

    @Test
    fun `one point per minute bucket, newest wins`() {
        var s = HrTrace.append(emptyList(), ts = 600, bpm = 60)
        s = HrTrace.append(s, ts = 620, bpm = 64)   // same minute bucket
        s = HrTrace.append(s, ts = 660, bpm = 70)   // next bucket
        assertEquals(2, s.size)
        assertEquals(64, s[0].bpm)   // newest within the bucket won
        assertEquals(600, s[0].ts)   // and the point is stamped at the bucket, not the sample
        assertEquals(70, s[1].bpm)
    }

    /** The headline number is the latest bpm; a trace ending on an average would disagree with it. */
    @Test
    fun `the last point equals the latest reading`() {
        var s = emptyList<HrPoint>()
        for (i in 0..5) s = HrTrace.append(s, ts = 600 + i * 60L, bpm = 60 + i)
        assertEquals(65, HrTrace.stats(s)!!.latest)
        assertEquals(65, s.last().bpm)
    }

    @Test
    fun `readings older than the window fall off`() {
        val now = 100_000L
        val s = series((now - HrTrace.WINDOW_SEC - 60) to 50, (now - 60) to 70)
        val kept = HrTrace.prune(s, now)
        assertEquals(1, kept.size)
        assertEquals(70, kept[0].bpm)
    }

    /** A clock that jumps backwards must not be able to grow the series without bound. */
    @Test
    fun `the point cap holds under a backwards clock`() {
        var s = emptyList<HrPoint>()
        for (i in 0 until HrTrace.MAX_POINTS + 50) s = HrTrace.append(s, ts = i * 60L, bpm = 60, nowSec = 0)
        assertTrue("size=${s.size}", s.size <= HrTrace.MAX_POINTS)
    }

    @Test
    fun `a non-positive bpm is not recorded`() {
        val s = HrTrace.append(emptyList(), ts = 600, bpm = 0)
        assertTrue(s.isEmpty())
    }

    // --- round trip ------------------------------------------------------------------------------

    @Test
    fun `encode and decode round trip`() {
        val s = series(600L to 60, 660L to 62, 720L to 58)
        assertEquals(s, HrTrace.decode(HrTrace.encode(s)))
    }

    /**
     * Decoding runs on the widget's render path, where the alternative to a partial trace is a crashed
     * home screen. Every malformed shape must be skipped rather than thrown.
     */
    @Test
    fun `a malformed series degrades instead of throwing`() {
        assertEquals(emptyList<HrPoint>(), HrTrace.decode(null))
        assertEquals(emptyList<HrPoint>(), HrTrace.decode(""))
        assertEquals(emptyList<HrPoint>(), HrTrace.decode("garbage"))
        val partial = HrTrace.decode("600:60,nope,700:,:70,800:x,900:64")
        assertEquals(series(600L to 60, 900L to 64), partial)
    }

    // --- geometry --------------------------------------------------------------------------------

    @Test
    fun `points span the box and flip bpm upward`() {
        val pts = HrTrace.points(series(0L to 60, 60L to 80), width = 100f, height = 50f)
        assertEquals(0f, pts[0].x, 0.001f)
        assertEquals(100f, pts[1].x, 0.001f)
        assertEquals(50f, pts[0].y, 0.001f)   // the LOW bpm sits at the BOTTOM
        assertEquals(0f, pts[1].y, 0.001f)    // the high bpm at the top
    }

    /** A resting arm holds one bpm for minutes. Range zero must not divide, and must not read as a
     *  flatlined or maxed-out heart, so the line runs along the middle. */
    @Test
    fun `a flat series draws down the middle`() {
        val pts = HrTrace.points(series(0L to 60, 60L to 60, 120L to 60), width = 90f, height = 40f)
        assertEquals(3, pts.size)
        for (p in pts) assertEquals(20f, p.y, 0.001f)
    }

    /** A widget placed mid-afternoon has exactly one point until the next minute ticks. */
    @Test
    fun `a single point sits at the left edge rather than at NaN`() {
        val pts = HrTrace.points(series(600L to 61), width = 100f, height = 50f)
        assertEquals(1, pts.size)
        assertEquals(0f, pts[0].x, 0.001f)
        assertTrue("y=${pts[0].y}", !pts[0].y.isNaN())
    }

    @Test
    fun `an empty series or a zero-size box draws nothing`() {
        assertTrue(HrTrace.points(emptyList(), 100f, 50f).isEmpty())
        assertTrue(HrTrace.points(series(0L to 60), 0f, 50f).isEmpty())
        assertTrue(HrTrace.points(series(0L to 60), 100f, 0f).isEmpty())
    }

    // --- ticks -----------------------------------------------------------------------------------

    @Test
    fun `bpm ticks run max, middle, min`() {
        assertEquals(listOf(84, 72, 59), HrTrace.bpmTicks(HrTrace.Stats(min = 59, max = 84, latest = 69)))
    }

    /** Three copies of one number is the honest reading of a steady heart; inventing a spread would put
     *  ticks on the chart that no sample supports. */
    @Test
    fun `a flat series labels one number three times`() {
        assertEquals(listOf(60, 60, 60), HrTrace.bpmTicks(HrTrace.Stats(min = 60, max = 60, latest = 60)))
    }

    @Test
    fun `time ticks anchor to the data, not the window`() {
        val ticks = HrTrace.timeTicks(series(1_000L to 60, 1_600L to 62, 2_200L to 64))
        assertEquals(listOf(1_000L, 1_600L, 2_200L), ticks)
    }

    @Test
    fun `time ticks degrade when there is not enough span to place three`() {
        assertEquals(emptyList<Long>(), HrTrace.timeTicks(emptyList()))
        assertEquals(listOf(600L), HrTrace.timeTicks(series(600L to 60)))
        assertEquals(listOf(600L, 601L), HrTrace.timeTicks(series(600L to 60, 601L to 61)))
    }

    @Test
    fun `stats over an empty series is null, not zero`() {
        assertNull(HrTrace.stats(emptyList()))
    }


    // --- the drawing box -------------------------------------------------------------------------

    /**
     * RemoteViews fails to render rather than degrading when its transaction is too big, so the box has
     * to be decided on AREA. The first version of this capped width and height independently, which let
     * 1080x480 through at 1.98 MB — nearly double the ceiling it was written to respect.
     */
    @Test
    fun `a box within budget is left alone`() {
        assertEquals(750 to 168, HrTrace.fitBox(750, 168))   // 250dp x 56dp at 3x, well inside budget
    }

    @Test
    fun `an oversized box is scaled down to fit the budget`() {
        val (w, h) = HrTrace.fitBox(1200, 224)               // 300dp x 56dp at 4x: 1.03 MB
        assertTrue("$w x $h", w.toLong() * h * HrTrace.BYTES_PER_PIXEL <= HrTrace.MAX_BITMAP_BYTES)
        assertTrue("must not collapse: $w x $h", w > 1 && h > 1)
    }

    /** Aspect must survive, or the trace is drawn into a box shaped unlike the slot it is stretched
     *  back into, and the stroke thickens on one axis only. */
    @Test
    fun `scaling preserves the aspect ratio`() {
        val (w, h) = HrTrace.fitBox(2000, 500)
        assertEquals(4.0, w.toDouble() / h.toDouble(), 0.05)
    }

    @Test
    fun `a degenerate box never returns zero`() {
        assertEquals(1 to 1, HrTrace.fitBox(0, 0))
        assertEquals(1 to 1, HrTrace.fitBox(-5, -5))
        val (w, h) = HrTrace.fitBox(100_000, 100_000)
        assertTrue("$w x $h", w >= 1 && h >= 1 && w.toLong() * h * HrTrace.BYTES_PER_PIXEL <= HrTrace.MAX_BITMAP_BYTES)
    }


    // --- bitmap width, given an exact height ------------------------------------------------------

    /**
     * Height must survive untouched. [HrTrace.fitBox] preserves aspect, so asking it for a wider box
     * would shrink the height and trade a horizontal stretch for a vertical one — which is why the
     * width is chosen separately once the height is fixed.
     */
    @Test
    fun `width gets headroom over the request`() {
        // 188dp of chart at 2.75x, 56dp tall: the case a One UI card actually produced.
        val w = HrTrace.widestAtHeight(requestedPx = 517, heightPx = 154)
        assertTrue("$w must exceed the request", w > 517)
        assertTrue("$w must stay in budget", w.toLong() * 154 * HrTrace.BYTES_PER_PIXEL <= HrTrace.MAX_BITMAP_BYTES)
    }

    /** The budget wins over the headroom, never the other way round: a bitmap that breaks the payload
     *  ceiling does not render at all, where a slightly stretched one merely looks soft. */
    @Test
    fun `the budget caps the headroom`() {
        val h = 400
        val w = HrTrace.widestAtHeight(requestedPx = 4000, heightPx = h)
        assertEquals(HrTrace.MAX_BITMAP_BYTES / (h * HrTrace.BYTES_PER_PIXEL), w)
        assertTrue(w.toLong() * h * HrTrace.BYTES_PER_PIXEL <= HrTrace.MAX_BITMAP_BYTES)
    }

    @Test
    fun `a degenerate request still yields a drawable width`() {
        assertTrue(HrTrace.widestAtHeight(0, 0) >= 1)
        assertTrue(HrTrace.widestAtHeight(-10, -10) >= 1)
    }
}
