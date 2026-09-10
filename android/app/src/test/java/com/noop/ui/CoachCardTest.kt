package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Coach launcher card's contract (#1862) — the parts that are testable without a device.
 *
 * The issue asks for one thing above all: the card must be ABSENT by default. Someone who does not use
 * an AI provider should not gain a fixed dashboard row for one, and that is a property of the default
 * selection, not of the UI.
 */
class CoachCardTest {

    /** The headline requirement: opt-in, never a fresh install's default. */
    @Test
    fun `the coach card is not in the default selection`() {
        assertFalse("Coach must be opt-in", DashboardCard.defaultSelection.contains(DashboardCard.COACH))
        assertFalse("Coupled is the same posture and stays that way",
            DashboardCard.defaultSelection.contains(DashboardCard.COUPLED))
    }

    /** It must be addable, so it has to survive the raw round-trip Today customization persists through. */
    @Test
    fun `the coach card round-trips through its persisted raw value`() {
        assertEquals(DashboardCard.COACH, DashboardCard.fromRaw("coach"))
        // Byte-identical to the iOS `DashboardCard.coach` raw, so a settings backup restores across OS.
        assertEquals("coach", DashboardCard.COACH.raw)
    }

    /**
     * A launcher row carries no measurement, so it must not render a unit — an empty unit is what makes
     * the row show just icon + title + subtitle + chevron, exactly as COUPLED does.
     */
    @Test
    fun `the coach card carries no unit`() {
        assertTrue(DashboardCard.COACH.unit.isEmpty())
    }

    /**
     * The launcher and the full screen must offer the SAME prompts. Two lists drift the moment either is
     * edited, and the launcher exists to be a shortcut INTO the screen, not a second, different Coach.
     */
    @Test
    fun `the launcher and the coach screen share one prompt list`() {
        assertEquals(CoachPrompts.SUGGESTIONS, SUGGESTED_PROMPTS)
        assertTrue("the shared list must not be empty", CoachPrompts.SUGGESTIONS.isNotEmpty())
    }

    /**
     * The handoff must be consumed exactly ONCE. `CoachScreen` reads it from a `LaunchedEffect` keyed on
     * the configured flag, which can re-run; a read that left the value in place would resend the
     * question — and a resend is a second billed provider request the user did not ask for.
     */
    @Test
    fun `the coach handoff is consumed exactly once`() {
        CoachHandoff.pendingPrompt = "How can I improve my sleep?"
        assertEquals("How can I improve my sleep?", CoachHandoff.consume())
        assertNull("a second read must not resend", CoachHandoff.consume())
    }

    /** Nothing parked means nothing sent — the ordinary case every time Coach is opened normally. */
    @Test
    fun `an empty coach handoff yields nothing`() {
        CoachHandoff.pendingPrompt = null
        assertNull(CoachHandoff.consume())
    }
}
