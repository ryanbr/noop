package com.noop.ui

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Regression tests for the App Notifications upgrade migration
 * ([NotifPrefs.seedLegacyCategoryPatternDefaults]).
 *
 * The removed category cards applied a per-category default buzz pattern (Messaging = Single,
 * Email/Calendar = Double, Meetings = Triple) to opted-in apps that never picked one — nothing
 * was persisted for them. The picker's package-keyed read defaults to Double for ALL apps, so an
 * unseeded upgrade silently changes a Messaging user's Single buzz into Double. These tests pin
 * the three properties the review asked about: carried-over opt-ins keep their old rhythm, an
 * explicit pattern choice is never overwritten, and disabled apps are left alone.
 */
@RunWith(RobolectricTestRunner::class)
class NotifPatternSeedTest {

    private val ctx: Context get() = RuntimeEnvironment.getApplication()

    private fun prefs() =
        ctx.getSharedPreferences("noop_notif_prefs", Context.MODE_PRIVATE)

    @Test
    fun `carried-over messaging opt-in keeps its Single rhythm after upgrade`() {
        // A user who switched Messaging on under the old cards, never picked a pattern.
        NotifPrefs.setAppEnabled(ctx, "com.whatsapp", true)
        NotifPrefs.seedLegacyCategoryPatternDefaults(ctx)
        assertEquals(BuzzPattern.Single, NotifPrefs.appPatternFor(ctx, "com.whatsapp"))
        // The listener's loop-count read must agree with the picker's.
        assertEquals(BuzzPattern.Single.loops, NotifPrefs.appLoops(ctx, "com.whatsapp"))
    }

    @Test
    fun `explicit pattern choices are never overwritten by the seed`() {
        NotifPrefs.setAppEnabled(ctx, "com.whatsapp", true)
        NotifPrefs.setAppPattern(ctx, "com.whatsapp", BuzzPattern.Long)
        NotifPrefs.seedLegacyCategoryPatternDefaults(ctx)
        assertEquals(BuzzPattern.Long, NotifPrefs.appPatternFor(ctx, "com.whatsapp"))
    }

    @Test
    fun `disabled curated apps get no seeded pattern`() {
        // No opt-in, nothing to preserve: writing a pattern for an app the user never enabled
        // would invent a preference the picker never showed.
        NotifPrefs.seedLegacyCategoryPatternDefaults(ctx)
        assertNull(prefs().getString("app.com.whatsapp.pattern", null))
    }

    @Test
    fun `seed runs once and never re-applies after a later user choice`() {
        NotifPrefs.setAppEnabled(ctx, "com.whatsapp", true)
        NotifPrefs.seedLegacyCategoryPatternDefaults(ctx)
        assertEquals(BuzzPattern.Single, NotifPrefs.appPatternFor(ctx, "com.whatsapp"))
        // The user changes their pattern; a later startup must not revert it.
        NotifPrefs.setAppPattern(ctx, "com.whatsapp", BuzzPattern.Triple)
        NotifPrefs.seedLegacyCategoryPatternDefaults(ctx)
        assertEquals(BuzzPattern.Triple, NotifPrefs.appPatternFor(ctx, "com.whatsapp"))
    }

    @Test
    fun `meetings default is Triple and email default is Double`() {
        // The seed table must match the removed category cards verbatim.
        NotifPrefs.setAppEnabled(ctx, "us.zoom.videomeetings", true)
        NotifPrefs.setAppEnabled(ctx, "com.google.android.gm", true)
        NotifPrefs.seedLegacyCategoryPatternDefaults(ctx)
        assertEquals(BuzzPattern.Triple, NotifPrefs.appPatternFor(ctx, "us.zoom.videomeetings"))
        assertEquals(BuzzPattern.Double, NotifPrefs.appPatternFor(ctx, "com.google.android.gm"))
    }
}
