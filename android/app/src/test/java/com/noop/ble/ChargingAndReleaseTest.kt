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

    // --- #1948: the 5/MG keep-alive asks for nothing it cannot be given ------------------------------

    /**
     * The WHOOP5 keep-alive branch must not send `GET_BATTERY_PACK_INFO`.
     *
     * It did, on the gauge's cadence, under a comment saying the pack "rides the SAME cadence". It never
     * did: the 5/MG send allowlist admits opcode 151 only while a user-initiated probe is in flight, so
     * every one was refused before leaving the app — 40 in 40 minutes of one capture. The pack's charge
     * comes from the pushed event (109) and the strap's percent from the 0x2A19 read, so asking bought
     * nothing and cost a skip line a minute.
     *
     * Pinned against the source, like the pack-event guard above, because the send lives in a keep-alive
     * body no JVM test can drive. Scoped to the WHOOP5 branch so the WHOOP4 poll beside it is untouched.
     */
    @Test
    fun `the 5MG keepalive does not poll a pack opcode the allowlist refuses`() {
        val src = clientSource()
        val start = src.indexOf("} else if (connectedFamily == DeviceFamily.WHOOP5) {")
        assertTrue("the WHOOP5 keep-alive branch was not found", start > 0)
        // Ends at the branch's OWN battery poll, not at the nearer #1865 landmark. Stopping there left a
        // window holding one line of code and the rest comment, so a poll re-added anywhere past it would
        // have slipped through while the negative control still passed — the control only re-inserts at
        // the natural spot. This span covers every line between the branch opening and the 0x2A19 read,
        // which is the whole region a battery send would plausibly be put back into.
        val end = src.indexOf("5/MG battery comes only from a 0x2A19 read", start)
        assertTrue("the branch's own battery poll was not found", end > start)
        val code = src.substring(start, end).lines()
            .filterNot { it.trim().startsWith("//") }
            .joinToString("\n")
        assertFalse("the 5/MG keep-alive must not send GET_BATTERY_PACK_INFO (#1948): $code",
                    code.contains("GET_BATTERY_PACK_INFO"))
        // The 4.0 branch keeps its own poll: this is a 5/MG-only removal, not a battery-polling change.
        assertTrue("the WHOOP4 gauge poll must survive",
                   src.contains("if (batteryPollDue(keepAliveTick, s.charging == true)) send(CommandNumber.GET_BATTERY_LEVEL)"))
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
