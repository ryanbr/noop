package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the battery-source decision (#77). The bug this replaces: `connectedFamily != WHOOP4` was asked
 * while `connectedFamily` was still a guess - its WHOOP4 default, or the PREVIOUS link's family, since
 * it survived a disconnect uncleared - so a WHOOP 4.0 reached while it still said WHOOP5 read the 4.0's
 * 0x2A19 stub and banked it as a real state of charge.
 */
class BatterySourceTest {

    @Test
    fun `an unestablished family never picks a source`() {
        // The whole point: BOTH families defer, because before discovery the value carries no evidence.
        // A test that only checked WHOOP5 here would pass against the bug.
        assertEquals(BatterySource.DEFER, batterySource(false, DeviceFamily.WHOOP5))
        assertEquals(BatterySource.DEFER, batterySource(false, DeviceFamily.WHOOP4))
    }

    @Test
    fun `an established 4-0 uses the custom command, never the stub characteristic`() {
        assertEquals(BatterySource.CUSTOM_COMMAND, batterySource(true, DeviceFamily.WHOOP4))
    }

    @Test
    fun `an established 5 or MG uses the standard characteristic`() {
        assertEquals(BatterySource.STANDARD_CHAR, batterySource(true, DeviceFamily.WHOOP5))
    }

    @Test
    fun `the standard characteristic is reachable only with positive evidence`() {
        // Restates the invariant as a sweep so a future edit cannot reintroduce the fall-through: there
        // is exactly ONE (established, family) combination that may bank from 0x2A19.
        val reaching = listOf(true, false).flatMap { est ->
            DeviceFamily.values().map { fam -> Triple(est, fam, batterySource(est, fam)) }
        }.filter { it.third == BatterySource.STANDARD_CHAR }
        assertEquals(listOf(Triple(true, DeviceFamily.WHOOP5, BatterySource.STANDARD_CHAR)), reaching)
    }
}
