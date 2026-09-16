package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import android.content.Context
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

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

}

/**
 * The stored default, which is the invariant that actually matters on upgrade.
 *
 * Separate from the filter tests because it needs a Context. The first version of this asserted
 * `BottomBarStyleStore.coachEnabled`, which is an in-memory singleton seeded to true -- that passes
 * whatever the PREF does, so it would not have noticed the one mistake worth catching here: a pref
 * default of false, which silently removes the Coach tab from every existing install on upgrade.
 */
@RunWith(RobolectricTestRunner::class)
class CoachEnabledPrefDefaultTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Test
    fun `an install that never touched the toggle has coach enabled`() {
        NoopPrefs.of(context).edit().remove(NoopPrefs.KEY_COACH_ENABLED).commit()
        assertTrue("unset must read as ON, or upgrades lose the tab", NoopPrefs.coachEnabled(context))
    }

    @Test
    fun `the stored value round-trips in both directions`() {
        NoopPrefs.setCoachEnabled(context, false)
        assertFalse(NoopPrefs.coachEnabled(context))
        NoopPrefs.setCoachEnabled(context, true)
        assertTrue(NoopPrefs.coachEnabled(context))
    }
}
