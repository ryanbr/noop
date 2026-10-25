package com.noop.ble

import org.junit.Assert.*
import org.junit.Test

class ScanOutcomeTest {
    @Test fun connectedScanTimesOutWithoutDroppingHealthyLinkOrHistory() {
        val before = LiveState(connected = true, bonded = true, scanning = true, backfilling = true)
        val after = ScanOutcome.timeout(before)
        assertFalse(after.scanning)
        assertTrue(after.connected)
        assertTrue(after.bonded)
        assertTrue(after.backfilling)
        assertEquals(before.copy(scanning = false, statusNote = after.statusNote), after)
        assertTrue(after.statusNote!!.contains("Keeping"))
    }

    @Test fun disconnectedScanTimesOutWithActionableOutcome() {
        val after = ScanOutcome.timeout(LiveState(scanning = true))
        assertFalse(after.scanning)
        assertFalse(after.connected)
        assertTrue(after.statusNote!!.contains("No strap found"))
    }

    @Test fun scanFailureStopsSearchingAndNamesObservedFailure() {
        for (connected in listOf(false, true)) {
            val before = LiveState(connected = connected, scanning = true)
            val after = ScanOutcome.failed(before, "SCANNING_TOO_FREQUENTLY")
            assertFalse(after.scanning)
            assertEquals(connected, after.connected)
            assertTrue(after.statusNote!!.contains("SCANNING_TOO_FREQUENTLY"))
            assertEquals(before.copy(scanning = false, statusNote = after.statusNote), after)
        }
    }
}
