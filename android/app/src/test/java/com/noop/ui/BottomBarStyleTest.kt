package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The bottom bar's size and transparency options. */
class BottomBarStyleTest {

    /**
     * The property that makes this safe to ship: the DEFAULT step reproduces the alpha the bar has
     * always drawn, so an install that never opens the setting looks identical.
     */
    @Test fun `the default step is the shipped alpha`() {
        assertEquals(0.80f, alphaForOpacityStep(DEFAULT_OPACITY_STEP), 0.0001f)
    }

    @Test fun `the eight steps run from faint to solid`() {
        assertEquals(0.30f, alphaForOpacityStep(MIN_OPACITY_STEP), 0.0001f)
        assertEquals(1.00f, alphaForOpacityStep(MAX_OPACITY_STEP), 0.0001f)
        val all = (MIN_OPACITY_STEP..MAX_OPACITY_STEP).map { alphaForOpacityStep(it) }
        assertEquals(8, all.size)
        assertEquals(all.sorted(), all)
        assertEquals(all.distinct().size, all.size)
    }

    /**
     * A bar can never become invisible-but-tappable, which would hide the navigation with no way back
     * to the setting that hid it.
     */
    @Test fun `the faintest step is still visible`() {
        assertTrue(alphaForOpacityStep(MIN_OPACITY_STEP) >= 0.30f)
    }

    /** Out-of-range input is clamped, not honoured - including values a downgrade could leave behind. */
    @Test fun `steps outside the range clamp`() {
        assertEquals(alphaForOpacityStep(MIN_OPACITY_STEP), alphaForOpacityStep(-4), 0.0001f)
        assertEquals(alphaForOpacityStep(MAX_OPACITY_STEP), alphaForOpacityStep(99), 0.0001f)
    }

    @Test fun `the offered sizes are the requested ones`() {
        assertEquals(listOf(1f, 1.25f, 1.5f, 1.75f, 2f), BOTTOM_BAR_SCALES)
    }

    /**
     * A stored size from another build - or a hand-edited pref - snaps to something the dropdown can
     * show, so the UI can always leave the state it is in.
     */
    @Test fun `an unoffered size snaps to the nearest offered one`() {
        assertEquals(1.25f, nearestScale(1.3f), 0.0001f)
        assertEquals(2f, nearestScale(5f), 0.0001f)
        assertEquals(1f, nearestScale(0f), 0.0001f)
        assertTrue(nearestScale(1.37f) in BOTTOM_BAR_SCALES)
    }

    @Test fun `scale labels read as multipliers`() {
        assertEquals("1x", scaleLabel(1f))
        assertEquals("1.25x", scaleLabel(1.25f))
        assertEquals("2x", scaleLabel(2f))
    }

    /**
     * The rounding the slider relies on. A snapped slider value can arrive as 5.9999998; truncation
     * reads that as step 5, so the bar lands one stop below where the thumb is sitting.
     */
    @Test fun `a snapped slider value rounds to its own step`() {
        assertEquals(6, 5.9999998f.let { Math.round(it) })
        assertEquals(alphaForOpacityStep(6), alphaForOpacityStep(Math.round(5.9999998f)), 0.0001f)
        assertEquals(alphaForOpacityStep(5), alphaForOpacityStep(Math.round(5.4f)), 0.0001f)
    }

}
