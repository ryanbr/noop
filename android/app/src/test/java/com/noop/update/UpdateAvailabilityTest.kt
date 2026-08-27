package com.noop.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The #1659 automatic update check.
 *
 * A sideloaded build has no store to update it, so the most NOOP can do is notice a release and say so.
 * These rules decide when it may look, and when the result is worth a row in the Updates inbox.
 *
 * Twin of `UpdateAvailabilityTests` (Swift); the copy assertions below are byte-identical to it.
 */
class UpdateAvailabilityTest {

    private val day = UpdateAvailability.CHECK_INTERVAL_MS

    // --- when it may look ---

    /** Off by default, and off means SILENT: no request, no line, no trace. */
    @Test
    fun `disabled never checks`() {
        assertFalse(UpdateAvailability.shouldCheckNow(false, 0L, 1_000_000L))
        assertFalse(UpdateAvailability.shouldCheckNow(false, 1L, 1_000_000L))
    }

    /** Turning the toggle on should answer during THAT session, not tomorrow. */
    @Test
    fun `a never-checked install is due immediately`() {
        assertTrue(UpdateAvailability.shouldCheckNow(true, 0L, 1_000_000L))
    }

    @Test
    fun `it waits out the interval`() {
        val t = 1_000_000L
        assertFalse(UpdateAvailability.shouldCheckNow(true, t, t + day - 1))
        assertTrue(UpdateAvailability.shouldCheckNow(true, t, t + day))
        assertTrue(UpdateAvailability.shouldCheckNow(true, t, t + day * 3))
    }

    /**
     * A clock that moves BACKWARDS — timezone edit, NTP correction, a restored backup — would otherwise
     * park the next check arbitrarily far in the future. Treating it as due self-heals on the next write.
     */
    @Test
    fun `a clock going backwards does not strand the check`() {
        val t = 1_000_000L
        assertTrue(UpdateAvailability.shouldCheckNow(true, t, t - 5))
        assertTrue(UpdateAvailability.shouldCheckNow(true, t, t - day * 400))
    }

    // --- when it is worth saying ---

    @Test
    fun `it posts only for a newer version`() {
        assertTrue(UpdateAvailability.shouldPost("10.7.0", "10.6.0", null))
        assertFalse(UpdateAvailability.shouldPost("10.6.0", "10.6.0", null))
        assertFalse(UpdateAvailability.shouldPost("10.5.0", "10.6.0", null))
    }

    /**
     * ONCE PER VERSION. An app that repeats itself daily about something the user has already seen teaches
     * people to ignore the bell, which costs more than the feature is worth.
     */
    @Test
    fun `it never nags about a version already posted`() {
        assertFalse(UpdateAvailability.shouldPost("10.7.0", "10.6.0", "10.7.0"))
        assertTrue(UpdateAvailability.shouldPost("10.8.0", "10.6.0", "10.7.0"))
    }

    /** The counters are versions, not booleans: skipping 10.7.0 must not silence 11.0.0. */
    @Test
    fun `skipping a release does not silence the next one`() {
        assertTrue(UpdateAvailability.shouldPost("11.0.0", "10.6.0", "10.7.0"))
    }

    // --- the copy (byte-identical to the Swift twin) ---

    @Test
    fun `inbox title`() {
        assertEquals("NOOP 10.7.0 is available", UpdateAvailability.inboxTitle("10.7.0"))
    }

    /** Android: no sideload sentence — an APK has no seven-day re-sign and no AltStore. */
    @Test
    fun `inbox message without the sideload hint`() {
        assertEquals(
            "You're on 10.6.0. Open Settings and use Check for updates to see what's new and download 10.7.0.",
            UpdateAvailability.inboxMessage("10.7.0", "10.6.0", "", false),
        )
    }

    /** The iOS branch, tested here too so the twins cannot drift apart unnoticed. */
    @Test
    fun `inbox message with the sideload hint`() {
        assertEquals(
            "You're on 10.6.0. Open Settings and use Check for updates to see what's new and download 10.7.0." +
                " AltStore or SideStore can install it for you automatically if you added NOOP's source;" +
                " a direct .ipa still has to be signed on your device.",
            UpdateAvailability.inboxMessage("10.7.0", "10.6.0", "", true),
        )
    }

    @Test
    fun `inbox message appends trimmed notes`() {
        assertEquals(
            "You're on 10.6.0. Open Settings and use Check for updates to see what's new and download 10.7.0." +
                "\n\nFixed things.",
            UpdateAvailability.inboxMessage("10.7.0", "10.6.0", "  Fixed things.  ", false),
        )
    }

    /** Whitespace-only notes must not leave a trailing blank line hanging in the row. */
    @Test
    fun `blank notes add nothing`() {
        val plain = UpdateAvailability.inboxMessage("10.7.0", "10.6.0", "   \n  ", false)
        assertFalse(plain.endsWith("\n"))
        assertEquals(UpdateAvailability.inboxMessage("10.7.0", "10.6.0", "", false), plain)
    }

    // --- pruning a stale announcement ---

    /**
     * The row says "10.7.0 is available". Once the user installs 10.7.0 that sentence is false, and it
     * sits beside the What's New row for the same version — an app telling you to get what you have.
     */
    @Test
    fun `the announcement is pruned once installed`() {
        assertTrue(UpdateAvailability.shouldPruneAnnouncement("10.7.0", "10.7.0"))
        assertTrue(UpdateAvailability.shouldPruneAnnouncement("10.7.0", "10.8.0"))
    }

    /** Still behind: the row is still TRUE and must survive, or it would delete itself on the next launch. */
    @Test
    fun `an announcement still ahead survives`() {
        assertFalse(UpdateAvailability.shouldPruneAnnouncement("10.7.0", "10.6.0"))
    }

    @Test
    fun `nothing announced is nothing to prune`() {
        assertFalse(UpdateAvailability.shouldPruneAnnouncement(null, "10.6.0"))
        assertFalse(UpdateAvailability.shouldPruneAnnouncement("", "10.6.0"))
    }
}

