package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure half of the Android env-header block (spec section 3.4). [AndroidDiagnostics.summaryLines]
 * itself reads live system services (PowerManager, BatteryManager, permission grants) and so needs a
 * real Context, which the Robolectric-free suite (junit only, see DebugExportSchedulerTest /
 * DeviceRegistryTest) does not provide. The Context-touching path is exercised centrally on-device; here
 * we pin the one piece of decision logic a bug would silently break: the OEM aggressive-vendor heuristic.
 */
class AndroidDiagnosticsTest {

    @Test fun aggressiveVendorsAreFlagged() {
        for (vendor in listOf("Xiaomi", "OPPO", "vivo", "HUAWEI", "OnePlus", "realme", "Meizu")) {
            val text = AndroidDiagnostics.oemKillHeuristic(vendor)
            assertTrue("$vendor should flag as aggressive", text.startsWith("aggressive vendor"))
            assertTrue("$vendor heuristic should advise whitelisting", text.contains("whitelist NOOP"))
        }
    }

    @Test fun standardVendorsAreNotFlagged() {
        for (vendor in listOf("Google", "Samsung", "Sony", "Motorola")) {
            assertEquals("standard", AndroidDiagnostics.oemKillHeuristic(vendor))
        }
    }

    @Test fun heuristicIsCaseInsensitive() {
        assertTrue(AndroidDiagnostics.oemKillHeuristic("XIAOMI").startsWith("aggressive vendor"))
        assertTrue(AndroidDiagnostics.oemKillHeuristic("xiaomi").startsWith("aggressive vendor"))
    }

    /**
     * The write-health line is stamped ONLY when a backfill session persists rows, so it says nothing
     * about live streaming. Labelled "Data write:" it read as "this app has stored nothing from your
     * strap" on an unbonded 5/MG that offloads nothing but streams happily, while a hundred thousand
     * HR rows sat under that very device id. The scope has to be in the words.
     */
    @Test
    fun theOffloadLineNamesItsScopeInsteadOfReadingAsEveryWrite() {
        val never = AndroidDiagnostics.offloadLine(okAtSec = 0L, ageMs = 0L)
        assertTrue(never, never.startsWith("Offload:"))
        assertTrue(never, never.contains("no history rows ever persisted"))
        assertTrue("the zero case must say what it does NOT cover: $never",
            never.contains("live HR/R-R are not counted here"))
    }

    /** With rows landed it reports when, and drops the disclaimer it no longer needs. */
    @Test
    fun theOffloadLineReportsTheLandingWhenThereIsOne() {
        val landed = AndroidDiagnostics.offloadLine(okAtSec = 1_700_000_000L, ageMs = 3 * 3_600_000L)
        assertTrue(landed, landed.startsWith("Offload:"))
        assertTrue(landed, landed.contains("rows last landed"))
        assertFalse(landed, landed.contains("not counted here"))
    }

    /** The label is padded to 13 like every other in this block, so the values stay in one column. */
    @Test
    fun theOffloadLabelKeepsTheColumn() {
        assertEquals(13, AndroidDiagnostics.offloadLine(0L, 0L).indexOf("no history"))
    }
}
