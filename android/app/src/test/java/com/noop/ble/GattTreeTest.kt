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
        NotifyCharDump("fd4b0003", hasCccd = true),
        NotifyCharDump("fd4b0007", hasCccd = false),
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
    fun `each notify char reports whether it carries a CCCD`() {
        val lines = whoop5PairingDumpLines(
            bondState = 12, didBond = true, helloWrittenThisLink = true,
            probeOptedIn = true, notifyChars = chars(),
        )
        assertEquals("  fd4b0003 cccd=yes", lines[1])
        assertEquals("  fd4b0007 cccd=no", lines[2])
        assertTrue(lines.first(), lines.first().contains("bond=BOND_BONDED"))
        assertTrue(lines.first(), lines.first().contains("unbondedProbe=on"))
    }

    /**
     * There must be NO subscription column. This runs at service discovery, before the CCCD queue is
     * drained, so any such field would read "not yet" as a matter of ordering rather than fact — and on
     * API 33+ it could not be read at all, since `writeDescriptor(descriptor, value)` leaves
     * `descriptor.value` null. The outcomes are the `Subscribed <uuid>` lines that follow, and the note
     * points a reader at them instead of restating them wrongly here.
     */
    @Test
    fun `no line claims a subscription state this dump cannot know yet`() {
        val lines = whoop5PairingDumpLines(
            bondState = 10, didBond = false, helloWrittenThisLink = false,
            probeOptedIn = false, notifyChars = chars(),
        )
        assertTrue(lines.toString(), lines.none { it.contains("subscribed=") })
        assertTrue("a reader must be told where the answer is: $lines",
                   lines.any { it.contains("no later \"Subscribed\" line went unsubscribed by OUR choice") })
    }

    /**
     * What an ABSENT `Subscribed` line means inverts with the opt-in, and this is the one distinction the
     * dump exists to draw. Probe off: only HR and battery are ever queued, so an unsubscribed puffin char
     * is ours. Probe ON: the probe subscribes those same chars, so a missing line is the strap refusing.
     * A single unconditional sentence here would be confidently wrong in exactly the configuration the
     * probe is run for.
     */
    @Test
    fun `the note flips with the opt-in, because the meaning of a missing subscribe does`() {
        val off = whoop5PairingDumpLines(
            bondState = 10, didBond = false, helloWrittenThisLink = false,
            probeOptedIn = false, notifyChars = chars(),
        )
        assertTrue(off.toString(), off.any { it.contains("went unsubscribed by OUR choice") })
        assertTrue(off.toString(), off.none { it.contains("is the STRAP's answer") })

        val on = whoop5PairingDumpLines(
            bondState = 10, didBond = false, helloWrittenThisLink = false,
            probeOptedIn = true, notifyChars = chars(),
        )
        assertTrue(on.toString(), on.any { it.contains("is the STRAP's answer") })
        assertTrue(on.toString(), on.none { it.contains("by OUR choice") })
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
