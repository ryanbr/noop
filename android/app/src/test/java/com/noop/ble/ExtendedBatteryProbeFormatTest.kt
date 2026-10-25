package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #592: the pure formatter for the GET_EXTENDED_BATTERY_INFO probe result. Fixtures include the REAL
 * WHOOP 4.0 capture that resolved the issue (opcode 98 accepted, 29-byte payload, mV=3970 → 3.97 V).
 */
class ExtendedBatteryProbeFormatTest {

    private fun hexToBytes(h: String) = ByteArray(h.length / 2) { ((h[it * 2].digitToInt(16) shl 4) or h[it * 2 + 1].digitToInt(16)).toByte() }

    // The exact frame captured on a real WHOOP 4.0 (cmd byte 0x62=98 @6; total 40 B, len field 0x24=36).
    private val realFrame = "aa2400fa24c6620d010165006bff820f0c0128000f05e90321120200010100001a0000004675fe58"

    @Test fun whoop4_realCapture_acceptedWithVoltageAndGrid() {
        val (text, payHex) = WhoopBleClient.formatExtendedBatteryProbe(hexToBytes(realFrame), cmdOff = 6, isWhoop5 = false, prevPayloadHex = null)
        assertTrue(text.contains("WHOOP 4.0"))
        assertTrue(text.contains("opcode 98 answered — 29-byte payload (not a success verdict; see the bytes below)"))
        assertTrue(text.contains(realFrame))                 // full raw hex on one copyable line
        assertTrue(text.contains("Voltage: 3.97 V"))         // pay[7..8] = 0x0f82 = 3970 mV
        assertTrue(text.contains("(mV=3970 @07)"))
        assertTrue(text.contains("@00  0d 01 01 65 00 6b ff 82"))  // offset-labelled hex grid, 8/row
        assertTrue(text.contains("first capture"))           // no previous payload to diff
        assertEquals(29 * 2, payHex!!.length)                // 29-byte payload persisted for the next diff
    }

    @Test fun diff_flagsTheChangedBytes() {
        val first = hexToBytes(realFrame)
        val (_, prev) = WhoopBleClient.formatExtendedBatteryProbe(first, 6, false, null)
        // Flip one payload byte (frame[10] = payload offset 3) to simulate a second capture at another state.
        val second = first.copyOf().also { it[10] = 0x40 }
        val (text, _) = WhoopBleClient.formatExtendedBatteryProbe(second, 6, false, prev)
        assertTrue(text.contains("Δ vs previous capture:"))
        assertTrue(text.contains("@03:65→40"))               // payload offset 3 moved 0x65→0x40
        assertTrue(text.contains("SoC/capacity"))
    }

    @Test fun bareStub_isCalledOut() {
        // 11-byte frame: cmd@6=0x62 then ONLY the 4-byte CRC tail, so payEnd(7) == payStart(7) ⇒ no payload.
        val stub = hexToBytes("aa0700fa24006246758858")
        val (text, payHex) = WhoopBleClient.formatExtendedBatteryProbe(stub, 6, false, null)
        assertTrue(text.contains("bare stub"))
        assertNull(payHex)
    }

    @Test fun whoop5_unsupported_isDecisiveVerdict() {
        // 5/MG frame with the command byte 0x62 @10 and result code 3 (UNSUPPORTED) @12.
        val f = hexToBytes("aa000c000000000000006200030046758858")
        val (text, _) = WhoopBleClient.formatExtendedBatteryProbe(f, cmdOff = 10, isWhoop5 = true, prevPayloadHex = null)
        assertTrue(text.contains("REJECTED by firmware (UNSUPPORTED)"))
        assertTrue(text.contains("Result code @12: UNSUPPORTED(3)"))
    }

    @Test fun whoop5_payload_doesNotPrintAGuessedVoltage() {
        // A 5/MG SUCCESS(1) with a ≥9-byte payload: the mV offset (pay[7..8]) is unconfirmed on 5/MG, so
        // the formatter must NOT print a decoded "Voltage:" line there (raw grid only). cmd@10, result@12=1.
        val f = hexToBytes("aa000c000000000000006200010102030405060708090a46758858")
        val (text, _) = WhoopBleClient.formatExtendedBatteryProbe(f, cmdOff = 10, isWhoop5 = true, prevPayloadHex = null)
        assertTrue(text.contains("Result code @12: SUCCESS(1)"))
        assertFalse(text.contains("Voltage:"))   // no guessed decode on 5/MG
    }
}
