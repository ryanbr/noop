package com.noop.ui

import android.content.Context
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The Today gauge-style preference: rings by default, vessels when turned off.
 *
 * The default is the load-bearing part. #2311 made the rings what Today draws, so an install that has
 * never opened Settings has to get rings, and a pref that defaulted the other way would silently undo a
 * shipped change for everyone. Asserting the absent-key case is what pins that, since reading a key
 * nobody has written is exactly the state most installs are in.
 *
 * The key is deliberately NOT Apple's `noop.liquidTodayEnabled`. That one switches between two whole
 * Today screens there; this chooses a gauge inside the single Android one, and binding the two together
 * would make a later divergence on either platform quietly wrong.
 */
@RunWith(RobolectricTestRunner::class)
class TodayGaugeStylePrefTest {

    private fun ctx(): Context = RuntimeEnvironment.getApplication()

    @Test
    fun `an install that never opened settings gets the rings`() {
        val c = ctx()
        NoopPrefs.of(c).edit().remove(NoopPrefs.KEY_TODAY_RING_GAUGES).apply()
        assertTrue("rings are what #2311 shipped, so the absent key must read as true",
                   NoopPrefs.todayRingGauges(c))
    }

    @Test
    fun `turning it off selects the vessels and survives a read`() {
        val c = ctx()
        NoopPrefs.setTodayRingGauges(c, false)
        assertFalse(NoopPrefs.todayRingGauges(c))
        NoopPrefs.setTodayRingGauges(c, true)
        assertTrue(NoopPrefs.todayRingGauges(c))
    }

    @Test
    fun `the key is its own, not Apple's whole-screen toggle`() {
        // Sharing `noop.liquidTodayEnabled` would tie a gauge choice here to a screen choice there.
        assertTrue(NoopPrefs.KEY_TODAY_RING_GAUGES == "noop.todayRingGauges")
        assertFalse(NoopPrefs.KEY_TODAY_RING_GAUGES == "noop.liquidTodayEnabled")
    }
}
