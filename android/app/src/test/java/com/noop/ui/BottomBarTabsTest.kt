package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bottom bar's tab set, and the one rule about it that nothing enforced (#2218).
 *
 * Promoting Coach to a tab was a four-part change, and the part that nearly shipped wrong was leaving
 * it in the More sheet as well, so one destination would have appeared in two places at once. That is
 * not a thing a reader spots: the two lists sit four hundred lines apart and neither mentions the
 * other. It is exactly a thing a test spots.
 *
 * Pure data, so this runs in the plain-JVM suite. There is no Compose-capable harness in this repo, so
 * nothing here can assert what the bar RENDERS; what it can assert is the rule the rendering depends on.
 */
class BottomBarTabsTest {

    private val barTabs = barLeadingTabs + barTrailingTabs

    /** The bar and the More sheet must be disjoint, which is the invariant the drawer's own note claims. */
    @Test
    fun noBarTabIsAlsoListedInTheMoreSheet() {
        val inDrawer = drawerGroups.flatMap { it.items }.toSet()
        val both = barTabs.map { it.dest }.filter { it in inDrawer }
        assertTrue("a bar tab must not also appear in the More sheet, found $both", both.isEmpty())
    }

    /** Matching iOS: Today, Trends, Sleep, Coach, then More, which the bar appends itself. */
    @Test
    fun theBarCarriesTheSameFourNamedTabsAsIOS() {
        assertEquals(
            listOf(Destination.Today, Destination.Trends, Destination.Sleep, Destination.Coach),
            barTabs.map { it.dest },
        )
    }

    /** A destination cannot occupy two slots; the More slot's selected state derives from this list. */
    @Test
    fun theBarHasNoDuplicateDestinations() {
        assertEquals(barTabs.map { it.dest }.distinct().size, barTabs.size)
    }

    /** Every tab carries a label, so no slot can render an empty word or an empty a11y description. */
    @Test
    fun everyTabHasALabelResource() {
        assertTrue(barTabs.all { it.labelRes != 0 })
    }
}
