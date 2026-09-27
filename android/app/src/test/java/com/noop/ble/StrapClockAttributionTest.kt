package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The fourth appearance of one defect, after [resolveFirmware], [resolveLastSync] and
 * [writeHealthPrefKey]. What makes this one worse is that the global reading feeds a VERDICT: the alarm
 * section does not merely print a timestamp, it concludes "alarm unreliable" from it.
 *
 * The field capture said `Strap clock: 20d behind wall (reset/stale — alarm unreliable)` for an active
 * 5/MG whose own header two lines up said `Last sync: never (this strap)` and `no history rows ever
 * persisted`. A strap that has banked nothing cannot be 20 days stale; the 20 days belonged to the paired
 * 4.0, last seen exactly 20 days earlier. The same strap's own alarm readback said 2045, which is ahead
 * of the wall clock rather than behind it, so the two lines disagreed in direction as well as in value.
 */
class StrapClockAttributionTest {

    @Test
    fun `a strap's own range reply always wins`() {
        assertEquals(500L, resolveStrapClockTs(perDevice = 500L, legacyGlobal = 900L, pairedCount = 1))
        assertEquals(500L, resolveStrapClockTs(perDevice = 500L, legacyGlobal = 900L, pairedCount = 3))
    }

    /** The single-strap upgrade path: unattributed, but only one strap can have written it. */
    @Test
    fun `the legacy global is trustworthy only when one strap could have written it`() {
        assertEquals(900L, resolveStrapClockTs(perDevice = 0L, legacyGlobal = 900L, pairedCount = 1))
        assertNull(resolveStrapClockTs(perDevice = 0L, legacyGlobal = 900L, pairedCount = 2))
    }

    /**
     * THE case from the capture. The verdict must be withheld rather than borrowed: for a strap that has
     * never answered a range reply, "not known" is the correct answer and "20d stale, alarm unreliable"
     * is an accusation sourced from another strap.
     */
    @Test
    fun `an active strap with no range reply of its own borrows no verdict`() {
        assertNull(resolveStrapClockTs(perDevice = 0L, legacyGlobal = 1_787_000_000L, pairedCount = 2))
    }

    @Test
    fun `a non-positive stamp is no stamp`() {
        assertNull(resolveStrapClockTs(perDevice = 0L, legacyGlobal = 0L, pairedCount = 1))
        assertNull(resolveStrapClockTs(perDevice = -1L, legacyGlobal = -1L, pairedCount = 1))
        assertEquals(900L, resolveStrapClockTs(perDevice = -1L, legacyGlobal = 900L, pairedCount = 1))
    }

    /** Keyed on the address, lowercased, and blank-rejecting, exactly as [lastSyncPrefKey] is. */
    @Test
    fun `the key is per address, lowercased, and refuses a blank`() {
        assertEquals("strap.newestRecordTs.aa:bb:cc", strapClockPrefKey("AA:BB:CC"))
        assertEquals("strap.newestRecordTs.aa:bb:cc", strapClockPrefKey("  aa:bb:cc  "))
        assertNull(strapClockPrefKey(null))
        assertNull(strapClockPrefKey("   "))
    }

    /** It must not collide with the legacy global key, or the fix would overwrite what it falls back to. */
    @Test
    fun `the per-device key is distinct from the legacy global`() {
        assertEquals("strap.newestRecordTs", "strap.newestRecordTs")
        assertEquals(false, strapClockPrefKey("aa:bb:cc") == "strap.newestRecordTs")
    }
}
