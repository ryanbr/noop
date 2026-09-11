package com.noop.ui

import com.noop.ble.SourceIdentity
import com.noop.data.PairedDeviceRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2075: the Live Console must read out the ACTIVE device, not whichever field happens to be populated.
 *
 * `LiveState` is one object every live source writes into, so a bonded WHOOP sitting beside a streaming
 * Oura ring leaves every WHOOP-only field truthful-looking while the console is naming the ring. The
 * report was a ring on 93% displaying the strap's 72% under "Oura Ring 5", with a WHOOP pairing pill.
 *
 * Mirrors Swift `LiveConsoleReadoutTests` case-for-case.
 */
class LiveConsoleReadoutTest {

    private fun row(id: String, brand: String) = PairedDeviceRow(
        id = id, brand = brand, model = "m", nickname = null, peripheralId = null,
        sourceKind = "liveBLE", capabilities = "hr", status = "active", addedAt = 0L, lastSeenAt = 0L,
    )

    // MARK: - activeIsWhoop

    @Test
    fun `an oura active device is not a whoop`() {
        val rows = listOf(row("my-whoop", "WHOOP"), row("oura-123", "Oura"))
        assertFalse(LiveConsoleReadout.activeIsWhoop(rows, "oura-123"))
        assertTrue(LiveConsoleReadout.activeIsWhoop(rows, "my-whoop"))
    }

    @Test
    fun `the legacy seeded row is a whoop whatever its brand says`() {
        // SourceIdentity's rule: the seeded id counts even if the brand column is blank.
        assertTrue(LiveConsoleReadout.activeIsWhoop(listOf(row("my-whoop", "")), "my-whoop"))
    }

    @Test
    fun `an unresolvable active device stays whoop-first`() {
        // Before the registry opens the console already names WHOOP; the gate must agree rather than
        // blanking a working strap's readouts on a cold start.
        assertTrue(LiveConsoleReadout.activeIsWhoop(emptyList(), null))
        assertTrue(LiveConsoleReadout.activeIsWhoop(emptyList(), "oura-123"))
    }

    @Test
    fun `brand matching is case insensitive`() {
        assertTrue(LiveConsoleReadout.activeIsWhoop(listOf(row("w1", "whoop")), "w1"))
        assertFalse(LiveConsoleReadout.activeIsWhoop(listOf(row("o1", "OURA")), "o1"))
    }

    // MARK: - batteryPercent

    @Test
    fun `a whoop active device shows the strap charge`() {
        assertEquals(72, LiveConsoleReadout.batteryPercent(true, 72.4, 93))
    }

    /**
     * ROUNDS, it does not truncate. The surfaces this seam replaced disagreed: Devices and the widget
     * rounded, the Live Console truncated. Folding them onto a truncating seam would have quietly moved
     * five readouts down by a point, which is the kind of change nobody reports and everyone notices.
     */
    @Test
    fun `the charge is rounded, not truncated`() {
        assertEquals(73, LiveConsoleReadout.batteryPercent(true, 72.6, null))
        assertEquals(72, LiveConsoleReadout.batteryPercent(true, 72.4, null))
        // The exact half goes up, matching Swift's half-away-from-zero over a positive percentage.
        assertEquals(73, LiveConsoleReadout.batteryPercent(true, 72.5, null))
        assertEquals(100, LiveConsoleReadout.batteryPercent(true, 99.7, null))
    }

    @Test
    fun `a ring active device shows the ring charge`() {
        // The reported numbers exactly: ring 93, strap 72.40, console showed 72.
        assertEquals(93, LiveConsoleReadout.batteryPercent(false, 72.4, 93))
    }

    @Test
    fun `a ring active device never falls back to the strap charge`() {
        // The heart of it. Nothing is the honest answer; the strap's number under the ring's name is a
        // confident lie, and is the bug.
        assertNull(LiveConsoleReadout.batteryPercent(false, 72.4, null))
    }

    /**
     * The Devices list asks this PER ROW rather than of the active device, which is the stronger question
     * there because the row itself is in hand. Composed here so the two halves are pinned together the
     * way the screen uses them.
     *
     * Calls [SourceIdentity.isWhoop] directly, where the screens call `SourceCoordinator.isWhoop`, which
     * delegates to it verbatim. Kept the same either side so the Swift twin can do likewise: there that
     * wrapper is main-actor isolated and a synchronous test cannot reach it.
     */
    @Test
    fun `a ring row shows the ring charge even when the strap reported one`() {
        val ring = row("oura-123", "Oura")
        val strap = row("my-whoop", "WHOOP")
        assertEquals(93, LiveConsoleReadout.batteryPercent(SourceIdentity.isWhoop(ring), 72.4, 93))
        assertEquals(72, LiveConsoleReadout.batteryPercent(SourceIdentity.isWhoop(strap), 72.4, 93))
    }

    @Test
    fun `a whoop active device ignores any ring charge`() {
        // Symmetry: a ring that reported earlier must not leak into a strap's readout either.
        assertNull(LiveConsoleReadout.batteryPercent(true, null, 93))
    }
}
