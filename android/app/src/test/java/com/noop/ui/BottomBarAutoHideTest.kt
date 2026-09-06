package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1839: the auto-hide state machine, kept pure so it is testable without Compose.
 *
 * Design borrowed from the #90 prototype, which separated the same decision into plain functions with
 * their own test rather than burying it in composition. That is the part of #90 worth keeping.
 */
class BottomBarAutoHideTest {

    @Test fun hiddenOnlyWhileScrollingDownAndOnlyWhenEnabled() {
        // The feature does nothing unless it is switched on.
        assertFalse(shouldHideBar(autoHide = false, overlay = true, scrollingDown = true))
        // Enabled and scrolling down: hidden.
        assertTrue(shouldHideBar(autoHide = true, overlay = true, scrollingDown = true))
        // Enabled but scrolling up: shown again.
        assertFalse(shouldHideBar(autoHide = true, overlay = true, scrollingDown = false))
    }

    /**
     * The bar can only be hidden when it OVERLAYS content. In the slot layout the Scaffold has reserved
     * its space, so translating it away would leave an empty band rather than giving the space back —
     * worse than not hiding at all.
     */
    @Test fun neverHidesInTheSlotLayout() {
        assertFalse(shouldHideBar(autoHide = true, overlay = false, scrollingDown = true))
        assertFalse(shouldHideBar(autoHide = true, overlay = false, scrollingDown = false))
    }

    /** A drag has to exceed the threshold before it counts, or a fingertip tremor flickers the bar. */
    @Test fun tinyScrollsDoNotFlipTheDirection() {
        assertEquals(null, scrollDirectionChange(delta = -0.5f, threshold = 3f))
        assertEquals(null, scrollDirectionChange(delta = 2.9f, threshold = 3f))
        // Content moving UP (negative delta) is the user scrolling DOWN into the page.
        assertEquals(true, scrollDirectionChange(delta = -8f, threshold = 3f))
        assertEquals(false, scrollDirectionChange(delta = 8f, threshold = 3f))
    }

    /** Reduce Motion keeps the bar put: a bar that vanishes without animation reads as a glitch. */
    @Test fun reduceMotionPinsTheBarVisible() {
        assertEquals(0f, barCollapseFraction(hidden = true, reduceMotion = true), 0f)
        assertEquals(0f, barCollapseFraction(hidden = false, reduceMotion = true), 0f)
        assertEquals(1f, barCollapseFraction(hidden = true, reduceMotion = false), 0f)
        assertEquals(0f, barCollapseFraction(hidden = false, reduceMotion = false), 0f)
    }

    /**
     * The pin beats auto-hide. Reaching the transparency slider means scrolling DOWN, which auto-hide
     * reads as "hide the bar" - so without this the control's live preview was invisible at exactly the
     * moment it exists for, and touching a slider does not scroll, so nothing brought the bar back.
     */
    @Test
    fun `a pinned preview keeps the bar visible while scrolling down`() {
        assertTrue(shouldHideBar(autoHide = true, overlay = true, scrollingDown = true))
        assertFalse(shouldHideBar(autoHide = true, overlay = true, scrollingDown = true, pinned = true))
    }

    /** The pin only ever SHOWS the bar; it can never hide one that would otherwise be up. */
    @Test
    fun `pinning never hides a bar that would be visible`() {
        for (auto in listOf(true, false)) {
            for (overlay in listOf(true, false)) {
                for (down in listOf(true, false)) {
                    val unpinned = shouldHideBar(auto, overlay, down, pinned = false)
                    val pinned = shouldHideBar(auto, overlay, down, pinned = true)
                    assertFalse("pinned must never hide more than unpinned", pinned && !unpinned)
                }
            }
        }
    }

    /** The default argument keeps every existing caller and case unchanged. */
    @Test
    fun `omitting the pin matches the old behaviour`() {
        assertEquals(
            shouldHideBar(autoHide = true, overlay = true, scrollingDown = true, pinned = false),
            shouldHideBar(autoHide = true, overlay = true, scrollingDown = true),
        )
    }

}
