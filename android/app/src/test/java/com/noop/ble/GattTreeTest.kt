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

    // --- #1949: the pairing dump ----------------------------------------------------------------------

    private fun chars() = listOf(
        NotifyCharDump("fd4b0003", hasCccd = true, subscribed = false),
        NotifyCharDump("fd4b0007", hasCccd = true, subscribed = true),
    )

    @Test
    fun `the header carries the pairing posture the log otherwise lacks`() {
        val head = whoop5PairingDumpLines(
            bondState = 10, didBond = false, helloWrittenThisLink = false,
            probeOptedIn = false, notifyChars = chars(),
        ).first()
        assertEquals(
            "pairing: bond=BOND_NONE didBond=false helloWritten=false unbondedProbe=off",
            head,
        )
    }

    @Test
    fun `each notify char reports its CCCD and whether we subscribed it`() {
        val lines = whoop5PairingDumpLines(
            bondState = 12, didBond = true, helloWrittenThisLink = true,
            probeOptedIn = true, notifyChars = chars(),
        )
        assertEquals("  fd4b0003 cccd=yes subscribed=no", lines[1])
        assertEquals("  fd4b0007 cccd=yes subscribed=yes", lines[2])
        assertTrue(lines.first(), lines.first().contains("bond=BOND_BONDED"))
        assertTrue(lines.first(), lines.first().contains("unbondedProbe=on"))
    }

    /** Discovering none is itself a reading, and must not render as an empty section. */
    @Test
    fun `no discovered notify chars says so rather than printing nothing`() {
        val lines = whoop5PairingDumpLines(
            bondState = 10, didBond = false, helloWrittenThisLink = false,
            probeOptedIn = false, notifyChars = emptyList(),
        )
        assertEquals("  no puffin notify characteristics discovered", lines[1])
    }

    /**
     * The note is the honest part: bond state is a proxy, not an encryption reading, and the codes it
     * names are what actually answer the question. Pinned so a later edit cannot quietly upgrade the
     * claim to "the link is encrypted", which nothing here knows.
     */
    @Test
    fun `the note refuses to claim an encryption state it cannot read`() {
        val note = whoop5PairingDumpLines(
            bondState = 10, didBond = false, helloWrittenThisLink = false,
            probeOptedIn = false, notifyChars = chars(),
        ).last()
        assertTrue(note, note.contains("no link-encryption flag"))
        assertTrue(note, note.contains("status 5 (insufficient authentication)"))
        assertTrue(note, note.contains("15 (insufficient encryption)"))
    }

}
