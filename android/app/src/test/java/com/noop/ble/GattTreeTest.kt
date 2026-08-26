package com.noop.ble

import android.bluetooth.BluetoothGattCharacteristic as C
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The GATT tree dump — the one probe that works on a strap that never bonds. */
class GattTreeTest {
    @Test
    fun `every characteristic is listed with its decoded properties`() {
        val lines = gattTreeLines(
            listOf(
                "fd4b0001" to listOf("fd4b0002" to (C.PROPERTY_WRITE or C.PROPERTY_WRITE_NO_RESPONSE)),
                "180a" to listOf("2a26" to C.PROPERTY_READ, "2a25" to C.PROPERTY_READ),
            )
        )
        assertEquals("GATT tree: 2 service(s)", lines.first())
        assertTrue(lines.any { it.contains("fd4b0002") && it.contains("WriteNoResponse+Write") })
        assertTrue(lines.any { it.contains("2a26") && it.contains("(Read)") })
        assertTrue(lines.any { it.contains("service 180a (2 char)") })
    }

    @Test
    fun `an empty tree says so rather than printing a bare header`() {
        assertEquals(listOf("GATT tree: no services discovered"), gattTreeLines(emptyList()))
    }

    @Test
    fun `a characteristic with no properties reads as none, not as empty parentheses`() {
        val lines = gattTreeLines(listOf("svc" to listOf("ch" to 0)))
        assertTrue(lines.any { it.contains("props=0x0 (none)") })
    }

    @Test
    fun `the tree and the single-characteristic line decode the same bits identically`() {
        // They share one decoder precisely so a capture cannot describe the same mask two ways.
        val props = C.PROPERTY_NOTIFY or C.PROPERTY_READ
        val single = characteristicCapabilityLine("ch", props, writingWithResponse = false)
        val tree = gattTreeLines(listOf("svc" to listOf("ch" to props))).last()
        val names = characteristicPropertyNames(props)
        assertTrue(single.contains(names))
        assertTrue(tree.contains(names))
    }
}
