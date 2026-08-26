package com.noop.ble

import android.bluetooth.BluetoothGattCharacteristic as C
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #1635: what fd4b0002 declares, and whether a with-response write is honouring it. */
class GattCapabilityTest {
    @Test
    fun `a write-no-response-only characteristic is flagged as a mismatch`() {
        // The hypothesis this exists to settle: if fd4b0002 never declared Write, then the June switch
        // from WRITE_TYPE_NO_RESPONSE to WRITE_TYPE_DEFAULT asked for a completion nothing owes us -
        // which matches the failure exactly (16 writes, 0 acks, link gone ~3.15s later).
        val line = characteristicCapabilityLine("fd4b0002", C.PROPERTY_WRITE_NO_RESPONSE, writingWithResponse = true)
        assertTrue(line.contains("WriteNoResponse"))
        assertFalse(line.contains("+Write"))
        assertTrue(line.contains("MISMATCH"))
    }

    @Test
    fun `a characteristic that declares Write kills the hypothesis, and says so`() {
        val line = characteristicCapabilityLine(
            "fd4b0002", C.PROPERTY_WRITE or C.PROPERTY_WRITE_NO_RESPONSE or C.PROPERTY_NOTIFY,
            writingWithResponse = true,
        )
        assertTrue(line.contains("with-response writes are supported"))
        assertFalse(line.contains("MISMATCH"))
    }

    @Test
    fun `no verdict is offered when we are not writing with response`() {
        // The verdict is about OUR write, not about the characteristic — claiming a mismatch for a write
        // we never made would be a confidently wrong line, which is the failure mode this issue keeps
        // producing.
        val line = characteristicCapabilityLine("fd4b0003", C.PROPERTY_NOTIFY, writingWithResponse = false)
        assertFalse(line.contains("MISMATCH"))
        assertFalse(line.contains("supported"))
        assertTrue(line.contains("Notify"))
    }

    @Test
    fun `an empty bitmask degrades without punctuation debris`() {
        val line = characteristicCapabilityLine("fd4b0002", 0, writingWithResponse = false)
        assertTrue(line.contains("(none)"))
        assertTrue(line.contains("properties=0x0"))
    }
}
