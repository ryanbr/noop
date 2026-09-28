package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A strap that drains while disconnected still gets a warning (#2556).
 *
 * The live crossings in [BatteryAlertPolicy] can only judge a percentage the app received, and both run off
 * the connection, so a strap that goes flat out of range crosses 15 and 12 unseen. On an unbonded 5/MG,
 * where a link can average under two minutes, that is the ordinary case rather than an exotic one.
 *
 * Expected values come from an oracle over the same rules, not from reading the implementation back.
 * Twin of Swift `StaleBatteryAlertPolicyTests`.
 */
class StaleBatteryAlertPolicyTest {

    private val now = 1_790_000_000L
    private fun hours(h: Long) = h * 3600L

    private fun ev(
        soc: Int? = 11,
        ts: Long? = 1_790_000_000L - 6 * 3600L,
        charging: Boolean? = false,
        connected: Boolean = false,
        alerted: Long? = null,
    ) = StaleBatteryAlertPolicy.evaluate(
        lastSocPct = soc, lastTsSec = ts, lastCharging = charging,
        nowSec = now, connected = connected, alertedForTs = alerted,
    )

    /** The live crossings own the connected case. Two readouts of one fact must not disagree. */
    @Test
    fun `a connected strap is never the stale path's business`() {
        assertFalse(ev(connected = true).fire)
    }

    @Test
    fun `six hours out of contact at eleven percent warns, and reports the age`() {
        val d = ev()
        assertTrue(d.fire)
        assertEquals(hours(6), d.ageSeconds)
    }

    /** Recent silence is normal: a strap goes out of range constantly and that is not news. */
    @Test
    fun `one hour out of contact is not stale enough`() {
        assertFalse(ev(ts = now - hours(1)).fire)
    }

    /** The boundary belongs to firing, so a strap exactly at the window is not left in limbo. */
    @Test
    fun `exactly at the stale window fires`() {
        val d = ev(ts = now - StaleBatteryAlertPolicy.STALE_AFTER_SECONDS)
        assertTrue(d.fire)
        assertEquals(StaleBatteryAlertPolicy.STALE_AFTER_SECONDS, d.ageSeconds)
    }

    @Test
    fun `a healthy last reading says nothing however long ago it was`() {
        assertFalse(ev(soc = 16).fire)
    }

    /** Same threshold as the live low alert, inclusive, so the two cannot disagree about what "low" is. */
    @Test
    fun `exactly at the low threshold counts as low`() {
        assertTrue(ev(soc = BatteryAlertPolicy.LOW_THRESHOLD).fire)
    }

    @Test
    fun `a strap last seen on the charger is not in trouble`() {
        assertFalse(ev(charging = true).fire)
    }

    /** Only a CONFIRMED charging reading suppresses, matching the live policy. Unknown still warns. */
    @Test
    fun `unknown charging state still warns`() {
        assertTrue(ev(charging = null).fire)
    }

    @Test
    fun `the same reading does not re-notify on every app open`() {
        assertFalse(ev(alerted = now - hours(6)).fire)
    }

    /** Keyed on the reading's timestamp, not a boolean: a NEWER low reading is a new fact. */
    @Test
    fun `a newer low reading fires even though an older one already did`() {
        assertTrue(ev(alerted = now - hours(9)).fire)
    }

    @Test
    fun `no banked reading means nothing to say`() {
        assertFalse(ev(soc = null, ts = null, charging = null).fire)
    }

    /**
     * The age label is what the wearer actually reads, and it is shared phrasing with the Swift twin, so
     * both ends of the pair pin the same boundary. Hours below two days, days above, and never a unit that
     * disagrees with the number beside it.
     */
    @Test
    fun `the age label reads in hours below two days and in days above`() {
        assertEquals("2h", StaleBatteryAlertPolicy.ageLabel(hours(2)))
        assertEquals("6h", StaleBatteryAlertPolicy.ageLabel(hours(6)))
        assertEquals("47h", StaleBatteryAlertPolicy.ageLabel(hours(47)))
        assertEquals("2d", StaleBatteryAlertPolicy.ageLabel(hours(48)))
        assertEquals("3d", StaleBatteryAlertPolicy.ageLabel(hours(80)))
    }

    /** Truncation, not rounding: 6h59m is still "6h", so the label never overstates the silence. */
    @Test
    fun `a partial hour rounds down`() {
        assertEquals("6h", StaleBatteryAlertPolicy.ageLabel(hours(6) + 3599L))
    }

    /** A reading from the future is a clock problem, not a flat strap. */
    @Test
    fun `a future reading never warns`() {
        assertFalse(ev(ts = now + hours(1)).fire)
    }
}
