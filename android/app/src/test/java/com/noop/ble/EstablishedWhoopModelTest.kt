package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Pins the service-discovered family used for the saved reconnect pair (#2068). */
class EstablishedWhoopModelTest {

    @Test
    fun `an unestablished family never becomes a saved-model guess`() {
        // Both values are unsafe before discovery: WHOOP4 is the initial default and either value can
        // belong to the previous link. A test covering only one would leave the other guess reachable.
        assertNull(establishedWhoopModel(false, DeviceFamily.WHOOP4))
        assertNull(establishedWhoopModel(false, DeviceFamily.WHOOP5))
    }

    @Test
    fun `an established 4-0 family persists as the 4-0 model`() {
        assertEquals(WhoopModel.WHOOP4, establishedWhoopModel(true, DeviceFamily.WHOOP4))
    }

    @Test
    fun `an established 5 or MG family persists as the 5 or MG model`() {
        assertEquals(WhoopModel.WHOOP5_MG, establishedWhoopModel(true, DeviceFamily.WHOOP5))
    }
}
