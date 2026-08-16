package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/** Proximity ordering + dedup of the standard-HR discovery list (`StandardHrSource.upsertByProximity`):
 *  strongest RSSI first, same address updates in place. Pure — no android.bluetooth. Twin of the Swift
 *  `StandardHRProximityTests`. */
class StandardHrProximityTest {

    private fun strap(addr: String, rssi: Int) = StandardHrSource.DiscoveredStrap(addr, "s-$addr", rssi)

    @Test fun sortsByProximityStrongestFirst() {
        var list = StandardHrSource.upsertByProximity(emptyList(), strap("A", -80))
        list = StandardHrSource.upsertByProximity(list, strap("B", -50))
        list = StandardHrSource.upsertByProximity(list, strap("C", -65))
        assertEquals(listOf("B", "C", "A"), list.map { it.address })   // -50 > -65 > -80 → closest first
    }

    @Test fun sameAddressUpdatesInPlaceWithNewestRssiAndReorders() {
        var list = StandardHrSource.upsertByProximity(emptyList(), strap("A", -80))
        list = StandardHrSource.upsertByProximity(list, strap("B", -60))
        list = StandardHrSource.upsertByProximity(list, strap("A", -40))   // A re-seen, now closer
        assertEquals(2, list.size)                                         // updated in place, no duplicate
        assertEquals(listOf("A", "B"), list.map { it.address })            // A jumps ahead of B
        assertEquals(-40, list.first { it.address == "A" }.rssi)           // newest RSSI kept
    }
}
