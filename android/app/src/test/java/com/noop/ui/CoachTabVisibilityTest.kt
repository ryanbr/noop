package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Coach master switch decides which trailing tabs the bar draws.
 *
 * Why this is a test rather than a filter trusted in place: #2218's note at the More slot records that
 * spelling the tab set out twice is what once lit Coach and More together, because the second copy had
 * never heard of the new tab. A CONDITIONAL tab makes that failure available again to anyone who filters
 * in one of the two places and not the other, so the shared helper is pinned here and both call sites are
 * required to come through it.
 */
class CoachTabVisibilityTest {

    @Test
    fun `coach enabled keeps the shipped trailing tabs`() {
        assertEquals(barTrailingTabs, barTrailingTabsFor(coachEnabled = true))
    }

    @Test
    fun `coach disabled drops the coach tab and nothing else`() {
        val visible = barTrailingTabsFor(coachEnabled = false)
        assertFalse("coach tab must not be drawn", visible.any { it.dest == Destination.Coach })
        assertEquals(
            "only Coach may be removed",
            barTrailingTabs.filterNot { it.dest == Destination.Coach },
            visible,
        )
    }

    @Test
    fun `sleep survives the filter`() {
        // A filter written against the wrong predicate (index, label, icon) could empty the list and still
        // satisfy "coach is absent". Pin a survivor so removal has to be specific.
        assertTrue(barTrailingTabsFor(coachEnabled = false).any { it.dest == Destination.Sleep })
    }

    @Test
    fun `the default is coach enabled`() {
        // The shipped install has the tab. A default flip would silently remove a tab from every existing
        // wearer on upgrade, which is the one outcome this feature must not produce by accident.
        assertTrue(BottomBarStyleStore.coachEnabled)
    }
}
