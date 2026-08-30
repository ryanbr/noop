package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Reported three times before it was believed, which is the part worth remembering: the number was
 * plausible, so the user was told their reading was wrong rather than the label.
 *
 * The field capture had `Last sync: 4d ago` beside `Days: whoop-MGB…=0` and a 4.0 last seen three days
 * earlier. The 5/MG had never banked a row; the timestamp on its screen belonged to the other strap.
 */
class LastSyncAttributionTest {

    @Test
    fun `a strap's own stamp always wins`() {
        assertEquals(500L, resolveLastSync(perDevice = 500L, legacyGlobal = 900L, pairedCount = 1))
        assertEquals(500L, resolveLastSync(perDevice = 500L, legacyGlobal = 900L, pairedCount = 3))
    }

    /**
     * The single-strap upgrade path. The global key is unattributed, but with one strap paired there is
     * only one strap it can have come from — so it reads correctly across the upgrade instead of
     * resetting to "never" for everyone.
     */
    @Test
    fun `the legacy global is trustworthy only when one strap could have written it`() {
        assertEquals(900L, resolveLastSync(perDevice = 0L, legacyGlobal = 900L, pairedCount = 1))
        assertNull(resolveLastSync(perDevice = 0L, legacyGlobal = 900L, pairedCount = 2))
    }

    /**
     * THE case from the capture. Two straps, and the active one has never synced: the honest answer is
     * "never", not the other strap's timestamp. Not a degraded answer — the correct one, and the one the
     * whole investigation was missing.
     */
    @Test
    fun `a strap that has never synced says so, even when another strap has`() {
        assertNull(resolveLastSync(perDevice = 0L, legacyGlobal = 1_787_000_000L, pairedCount = 2))
    }

    @Test
    fun `nothing recorded anywhere is never`() {
        assertNull(resolveLastSync(perDevice = 0L, legacyGlobal = 0L, pairedCount = 1))
        assertNull(resolveLastSync(perDevice = 0L, legacyGlobal = 0L, pairedCount = 0))
    }

    /**
     * A zero-paired registry must not license the global. The count is the evidence that exactly one
     * strap could have written it; "no straps" is not that evidence, and treating it as such would let a
     * mid-migration or failed registry read resurrect the bug.
     */
    @Test
    fun `an unknown or empty registry does not license the global`() {
        assertNull(resolveLastSync(perDevice = 0L, legacyGlobal = 900L, pairedCount = 0))
    }

    @Test
    fun `the key is per device and case-insensitive`() {
        // The same strap presents its address in different cases across sessions; a case-sensitive key
        // would strand the earlier stamp under a second name and report "never" on a strap that had synced.
        assertEquals(lastSyncPrefKey("AA:BB:CC:DD:EE:FF"), lastSyncPrefKey("aa:bb:cc:dd:ee:ff"))
        assertNull(lastSyncPrefKey(null))
        assertNull(lastSyncPrefKey("   "))
    }

    /**
     * The #57 write-health pair had the identical defect one line below in the same capture: "rows last
     * landed 4d ago" printed for a strap whose own row count was zero. Both halves are scoped, because
     * they are read as a pair — "stalled more recently than ok" is the alarm, and scoping only one would
     * compare this strap's stall against another strap's success.
     */
    @Test
    fun `the write-health pair is scoped per strap and the two halves stay distinct`() {
        val addr = "aa:bb:cc:dd:ee:ff"
        val ok = writeHealthPrefKey(addr, "lastWriteOkAt")
        val stalled = writeHealthPrefKey(addr, "lastWriteStalledAt")
        assertEquals(false, ok == stalled)
        assertEquals(ok, writeHealthPrefKey("AA:BB:CC:DD:EE:FF", "lastWriteOkAt"))
        assertNull(writeHealthPrefKey(null, "lastWriteOkAt"))
        assertNull(writeHealthPrefKey("  ", "lastWriteOkAt"))
    }

    /**
     * Different straps must never share a write-health key, or one strap's successful offload would clear
     * the alarm raised by another strap's stall.
     */
    @Test
    fun `two straps get different write-health keys`() {
        assertEquals(
            false,
            writeHealthPrefKey("aa:bb:cc:dd:ee:ff", "lastWriteOkAt") ==
                writeHealthPrefKey("ff:ee:dd:cc:bb:aa", "lastWriteOkAt"),
        )
    }

    /**
     * It must not collide with the firmware key, which is built the same way from the same address.
     */
    @Test
    fun `it does not collide with the firmware key for the same strap`() {
        val addr = "aa:bb:cc:dd:ee:ff"
        assertEquals(false, lastSyncPrefKey(addr) == firmwarePrefKey(addr))
    }
}
