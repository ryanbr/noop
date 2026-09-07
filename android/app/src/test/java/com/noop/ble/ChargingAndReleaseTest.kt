package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-predicate tests for two BLE-lane changes that can't exercise a live GATT stack (no Robolectric —
 * see [GattCrashSafetyTest]):
 *
 *   - PR #568 (charging bolt): [WhoopBleClient.shouldApplyChargingFromBatteryEvent] — a LIVE BATTERY_LEVEL
 *     event drives the charging pill; a historical one replayed mid-backfill does not. The old 45 s
 *     event-timestamp freshness gate is gone.
 *   - H3 / #520 (device-remove release): [WhoopBleClient.releasedLiveState] — releasing a strap clears the
 *     live link + every stale readout so a removed band can't keep showing live HR / a bond / a charge.
 */
class ChargingAndReleaseTest {

    // --- PR #568: charging-from-battery-event gate -----------------------------------------------------

    @Test fun liveBatteryEvent_appliesCharging() {
        assertTrue(WhoopBleClient.shouldApplyChargingFromBatteryEvent(replayedOffload = false))
    }

    @Test fun replayedHistoricalBatteryEvent_doesNotApplyCharging() {
        assertFalse(WhoopBleClient.shouldApplyChargingFromBatteryEvent(replayedOffload = true))
    }

    // --- H3 / #520: released LiveState -----------------------------------------------------------------

    @Test fun releasedState_dropsTheLinkAndClearsLiveReadouts() {
        val live = LiveState(
            connected = true, bonded = true, encryptedBond = true,
            heartRate = 72, rr = listOf(800, 810), rrRecent = listOf(800, 810),
            charging = true, pairingHint = "still bonded to the official app",
            strapFirmware = "41.17.6.0", historyLayoutVersion = 25,
            scanning = true, statusNote = "Searching…",
        )
        val released = WhoopBleClient.releasedLiveState(live)
        assertFalse(released.connected)
        assertFalse(released.bonded)
        assertFalse(released.encryptedBond)
        assertNull(released.heartRate)
        assertTrue(released.rr.isEmpty())
        assertTrue(released.rrRecent.isEmpty())
        assertNull(released.charging)
        assertNull(released.strapFirmware)
        assertNull(released.historyLayoutVersion)
        assertNull(released.pairingHint)
        assertFalse(released.scanning)
        assertNull(released.statusNote)
    }

    @Test fun releasedState_isIdempotentFromAnAlreadyDownState() {
        val down = LiveState()
        val released = WhoopBleClient.releasedLiveState(down)
        assertFalse(released.connected)
        assertNull(released.heartRate)
        assertNull(released.charging)
    }

    // --- #1935: only an EDGE may set the charging flag -------------------------------------------------

    /**
     * The pushed pack-info event (109) must publish the pack's SoC and NOTHING ELSE.
     *
     * It used to write `charging = true` as well, keyed on pack PRESENCE, as an anti-staleness half for an
     * attach edge the app missed. That is the one write that cannot be allowed here: 109 repeats every
     * couple of minutes, so it outran the ~8 min BATTERY_LEVEL that corrects the flag from the strap's own
     * gauge, and a flat or badly seated pack then read "charging" for its whole attachment instead of
     * self-correcting. The flag reaches three throttling levers (see [LiveState.charging]), so that is not
     * only a wrong pill.
     *
     * Pinned against the source the way [StalledLinkDiagnosticsTest] pins its caller-side invariants: the
     * write lives inline in a GATT callback that no JVM test can construct, and the regression is a single
     * word being added back.
     */
    @Test
    fun `the repeating pack-info event publishes SoC without touching the charging flag`() {
        val src = clientSource()
        // Anchored on the handler's own guard, which is unique in the file: the decode call and the event
        // constant both appear earlier in the address-masking helper, and anchoring there swallowed 400k
        // characters and passed on the pre-fix source.
        val start = src.indexOf("info.displayable && soc != null")
        assertTrue("the pack-info event handler was not found", start > 0)
        val end = src.indexOf("packSocPct = null", start)
        assertTrue("the pack-info handler's absent-pack branch was not found", end > start)
        // Comments discuss the removed write by name, so judge the CODE only.
        val code = src.substring(start, end).lines()
            .filterNot { it.trim().startsWith("//") }
            .joinToString("\n")
        assertTrue("pack info must still publish the SoC", code.contains("packSocPct = soc"))
        assertFalse("pack PRESENCE must never write the charging flag (#1935) — an EDGE may (7, 21, 22), " +
                    "a repeating signal may not, or the gauge can no longer correct it",
                    code.contains("charging"))
    }

    private fun clientSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt")
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        error("WhoopBleClient.kt not found — this test must not pass by default")
    }
}
