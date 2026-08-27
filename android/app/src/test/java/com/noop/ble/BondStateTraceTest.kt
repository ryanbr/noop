package com.noop.ble

import android.bluetooth.BluetoothDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the OS bond-state trace (#1635).
 *
 * NOOP has never observed ACTION_BOND_STATE_CHANGED, so whether a CLIENT_HELLO triggers pairing at all —
 * and whether that pairing fails — has been invisible. Both readings decide the open question, so the
 * line has to be equally clear about a transition happening and about one not happening.
 */
class BondStateTraceTest {

    @Test
    fun `a failed pairing is called out, not left to be inferred`() {
        assertEquals(
            "bond state: BOND_BONDING -> BOND_NONE device=FD:D4:F7:24:53:4A 3158ms after CLIENT_HELLO" +
                " — pairing did NOT complete",
            bondStateTraceLine(BluetoothDevice.BOND_BONDING, BluetoothDevice.BOND_NONE,
                "FD:D4:F7:24:53:4A", 3158),
        )
    }

    @Test
    fun `entering bonding is reported with its offset from the write that may have caused it`() {
        assertEquals(
            "bond state: BOND_NONE -> BOND_BONDING device=FD:D4:F7:24:53:4A 120ms after CLIENT_HELLO",
            bondStateTraceLine(BluetoothDevice.BOND_NONE, BluetoothDevice.BOND_BONDING,
                "FD:D4:F7:24:53:4A", 120),
        )
    }

    @Test
    fun `a success says so`() {
        assertTrue(
            bondStateTraceLine(BluetoothDevice.BOND_BONDING, BluetoothDevice.BOND_BONDED, "AA:BB", 900)
                .endsWith("— paired"),
        )
    }

    @Test
    fun `no outstanding hello means no elapsed time rather than a misleading one`() {
        // A transition from an unrelated pairing (another app, another device) must not be timed against
        // a CLIENT_HELLO it has nothing to do with.
        assertEquals(
            "bond state: BOND_NONE -> BOND_BONDING device=AA:BB",
            bondStateTraceLine(BluetoothDevice.BOND_NONE, BluetoothDevice.BOND_BONDING, "AA:BB", null),
        )
    }

    @Test
    fun `an unknown state prints its number rather than a guess`() {
        assertTrue(bondStateTraceLine(99, BluetoothDevice.BOND_NONE, "AA:BB", null).contains("BOND_99"))
        assertEquals("BOND_NONE", bondStateName(BluetoothDevice.BOND_NONE))
        assertEquals("BOND_BONDED", bondStateName(BluetoothDevice.BOND_BONDED))
    }

    @Test
    fun `a missing address degrades to unknown`() {
        assertTrue(bondStateTraceLine(10, 11, null, null).contains("device=unknown"))
        assertTrue(bondStateTraceLine(10, 11, "  ", null).contains("device=unknown"))
    }

    @Test
    fun `an unrelated device's pairing is never traced`() {
        // The receiver hears every pairing on the phone. The strap log is attached to public issues, so
        // a colleague's headphones must not appear in it.
        assertFalse(shouldTraceBondState("AA:BB:CC:DD:EE:FF", "FD:D4:F7:24:53:4A", helloOutstanding = true))
        assertFalse(shouldTraceBondState("AA:BB:CC:DD:EE:FF", "FD:D4:F7:24:53:4A", helloOutstanding = false))
    }

    @Test
    fun `our strap matches case-insensitively`() {
        // A case-sensitive compare would trace NOTHING — which looks exactly like "the pairing never
        // happened", one of the two answers this trace exists to tell apart.
        assertTrue(shouldTraceBondState("fd:d4:f7:24:53:4a", "FD:D4:F7:24:53:4A", helloOutstanding = false))
        assertTrue(shouldTraceBondState("FD:D4:F7:24:53:4A", "fd:d4:f7:24:53:4a", helloOutstanding = true))
    }

    @Test
    fun `an anonymous event is traced only inside the handshake window`() {
        assertTrue(shouldTraceBondState(null, "FD:D4", helloOutstanding = true))
        assertFalse(shouldTraceBondState(null, "FD:D4", helloOutstanding = false))
        assertFalse(shouldTraceBondState("  ", "FD:D4", helloOutstanding = false))
    }

    @Test
    fun `with no strap address, an addressed event is not ours to trace`() {
        assertFalse(shouldTraceBondState("AA:BB", null, helloOutstanding = true))
    }

    @Test
    fun `a pairing-request transition is timed against the pairing, not a hello that never went out`() {
        // The #1635 explicit-pairing experiment deliberately sends no CLIENT_HELLO. Timing only against
        // the hello left every transition it causes untimed, so a 200ms pairing and an 8s one read the
        // same - and how long a pairing took is most of what makes it diagnosable.
        val line = bondStateTraceLine(
            previous = android.bluetooth.BluetoothDevice.BOND_BONDING,
            current = android.bluetooth.BluetoothDevice.BOND_BONDED,
            address = "FD:D4",
            sinceMs = 4200L,
            sinceLabel = "the pairing request",
        )
        assertTrue(line.contains("4200ms after the pairing request"))
        assertFalse(line.contains("CLIENT_HELLO"))
        assertTrue(line.contains("paired"))
    }

    @Test
    fun `the connect line names the bond state the link STARTED with`() {
        // Without it, a hello failing on an unencrypted link and one failing on an ENCRYPTED link print
        // identically - and they are completely different findings.
        val l = bondStateAtConnectLine(android.bluetooth.BluetoothDevice.BOND_BONDED, "FD:D4")
        assertTrue(l.contains("BOND_BONDED"))
        assertTrue(l.contains("FD:D4"))
        assertTrue(bondStateAtConnectLine(android.bluetooth.BluetoothDevice.BOND_NONE, null).contains("unknown"))
    }

    @Test
    fun `BONDING with no transition line convicts our receiver, not the strap`() {
        // The whole point: a capture showed createBond accepted and then silence, and that has two very
        // different causes. Polling the device removes our own broadcast receiver from the chain, so the
        // answer no longer depends on the component under suspicion.
        val line = bondStatePollLine(android.bluetooth.BluetoothDevice.BOND_BONDING, sawTransitionLine = false)
        assertTrue(line.contains("receiver missed it"))
        assertTrue(line.contains("a NOOP bug, not the strap"))
    }

    /**
     * The verdict this line used to give was "Android did not begin pairing at all". An HCI capture of
     * exactly this case disproved it: the phone DOES transmit an SMP Pairing Request and a WHOOP 5/MG
     * answers "Pairing Failed — Pairing Not Supported" (0x05). A refused pairing ends at BOND_NONE with
     * no BONDED transition, which is indistinguishable from never starting if the bond state is all you
     * can see. The line must now name both causes and the capture that separates them.
     */
    @Test
    fun `NONE with no transition line names BOTH causes rather than convicting Android`() {
        val line = bondStatePollLine(android.bluetooth.BluetoothDevice.BOND_NONE, sawTransitionLine = false)
        assertFalse("the disproved verdict must not come back", line.contains("did not begin pairing at all"))
        assertFalse("nor its softer form", line.contains("nothing was heard"))
        assertTrue("a refusal must be named as the other cause", line.contains("REFUSED pairing ends here too"))
        assertTrue("the known 5/MG answer belongs in the line", line.contains("Pairing Not Supported"))
        assertTrue(line.contains("SMP 0x05"))
        assertTrue("name the discriminator", line.contains("HCI capture"))
        assertFalse(line.contains("NOOP bug"))
    }

    @Test
    fun `a heard transition is not reported as a missed one`() {
        val line = bondStatePollLine(android.bluetooth.BluetoothDevice.BOND_BONDING, sawTransitionLine = true)
        assertFalse(line.contains("missed it"))
        assertTrue(bondStatePollLine(android.bluetooth.BluetoothDevice.BOND_BONDED, true).contains("paired"))
    }
}
