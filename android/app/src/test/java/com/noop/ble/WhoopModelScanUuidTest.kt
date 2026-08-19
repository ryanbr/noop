package com.noop.ble

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift WhoopModelScanServiceTests. Pins the ADVERTISEMENT/GATT split: a 16-bit member UUID
 * may appear in an advertisement, but only the 128-bit vendor service exists in GATT, so widening the
 * scan must not widen service discovery.
 */
class WhoopModelScanUuidTest {

    private val vendor5 = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
    private val sig16Expanded = UUID.fromString("0000FD4B-0000-1000-8000-00805F9B34FB")

    @Test fun whoop4AdvertisementSetIsUnchanged() {
        // The 4.0 gains nothing: its service is not a 16-bit member UUID, and a wider filter would only
        // cost radio time on the overwhelmingly common path.
        assertEquals(listOf(WhoopModel.WHOOP4.service), WhoopModel.WHOOP4.advertisedScanUuids)
    }

    @Test fun whoop5AdvertisementSetAddsTheSixteenBitForm() {
        val uuids = WhoopModel.WHOOP5_MG.advertisedScanUuids
        assertTrue(uuids.contains(vendor5))       // vendor UUID still first: today's behaviour is a subset
        assertEquals(vendor5, uuids.first())
        assertTrue(uuids.contains(sig16Expanded))
        assertEquals(2, uuids.size)
    }

    @Test fun theSixteenBitEntryIsTheBaseExpansionNotTheVendorUuid() {
        // The distinction IS the bug: a band advertising 0xFD4B surfaces as the Bluetooth-base expansion,
        // which does not equal the vendor UUID, so a filter carrying only the vendor UUID never matches it.
        assertFalse(sig16Expanded == vendor5)
        assertTrue(WhoopModel.WHOOP5_MG.advertisedScanUuids.contains(sig16Expanded))
    }

    @Test fun gattServiceStaysTheVendorUuidAlone() {
        // After connecting, the strap exposes the real 128-bit service. Widening GATT discovery with an
        // advertisement-only UUID would be wrong, not merely redundant.
        assertEquals(vendor5, WhoopModel.WHOOP5_MG.service)
        assertEquals(WhoopBleClient.WHOOP5_SERVICE, WhoopModel.WHOOP5_MG.service)
    }
}
