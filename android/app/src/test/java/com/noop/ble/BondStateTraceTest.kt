package com.noop.ble

import android.bluetooth.BluetoothDevice
import org.junit.Assert.assertEquals
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
}
