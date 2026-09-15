package com.noop.ble

import com.noop.protocol.Crc
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Framing
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WHOOP 5.0/MG historical-offload plumbing (#78). The puffin envelope shifts the inner record +4 vs
 * WHOOP 4.0, so the offload-frame type byte (frame[8], not frame[4]) and the HISTORY_END end_data
 * slice (frame[21:29], not frame[17:25]) both move — and crucially the 5/MG HISTORY_END/COMPLETE type
 * is PUFFIN_METADATA = 56, NOT 49. Omitting 56 silently broke 5/MG offload (the strap never trims),
 * which is why this whole path stayed dead on Android even though the decoder was ready. These tests
 * pin the family-aware plumbing against that exact regression, mirroring the hardware-proven Swift
 * path (BLEManager.isOffloadFrame, Backfiller.endData, decodeWhoop5Metadata).
 */
class Whoop5OffloadTest {

    private fun ByteArray.putU32LE(off: Int, v: Long) {
        this[off] = (v and 0xFF).toByte()
        this[off + 1] = ((v shr 8) and 0xFF).toByte()
        this[off + 2] = ((v shr 16) and 0xFF).toByte()
        this[off + 3] = ((v shr 24) and 0xFF).toByte()
    }

    /**
     * Seal a hand-built WHOOP 5.0/MG frame: declared length, header CRC-16-Modbus and the payload
     * CRC32 trailer, in place.
     *
     * A fixture that leaves those three at zero is not a frame the strap could ever send. It used to
     * decode anyway, because field reads were clamped against the array size alone; now they are
     * clamped against the start of the CRC32 trailer, which is derived from the DECLARED length — and
     * a declared length of zero puts that boundary at offset 4, i.e. in front of every inner field.
     * Sealing keeps the assertions below about the 5/MG +4 field layout rather than about how far a
     * decoder will read into an unsealed buffer. Same shape as `FrameIntegrityTest.whoop5Frame` and
     * `Whoop5RawOpticalTest.reseal`.
     */
    private fun sealWhoop5(frame: ByteArray): ByteArray {
        frame[0] = 0xAA.toByte()
        frame[1] = 0x01
        val declLen = frame.size - 8      // payload + the 4-byte CRC32 trailer
        frame[2] = (declLen and 0xFF).toByte()
        frame[3] = ((declLen shr 8) and 0xFF).toByte()
        val headerCrc = Crc.crc16Modbus(frame, 0, 6)
        frame[6] = (headerCrc and 0xFF).toByte()
        frame[7] = ((headerCrc shr 8) and 0xFF).toByte()
        val payloadEnd = frame.size - 4
        frame.putU32LE(payloadEnd, Crc.crc32(frame, 8, payloadEnd))
        return frame
    }

    // ---- isOffloadFrame: family-aware type index + the 56 accept-set ----

    @Test
    fun whoop4_acceptsHistoricalAtFrame4() {
        for (t in intArrayOf(47, 48, 49, 50)) {
            val f = ByteArray(8); f[4] = t.toByte()
            assertTrue("WHOOP4 type $t should be an offload frame",
                WhoopBleClient.isOffloadFrame(f, DeviceFamily.WHOOP4))
        }
        val live = ByteArray(8); live[4] = 40 // REALTIME_DATA
        assertFalse(WhoopBleClient.isOffloadFrame(live, DeviceFamily.WHOOP4))
    }

    @Test
    fun whoop5_acceptsAtFrame8_includingPuffinMetadata56() {
        for (t in intArrayOf(47, 48, 49, 50, 56)) {
            val f = ByteArray(12); f[8] = t.toByte()
            assertTrue("WHOOP5 type $t should be an offload frame (56 = PUFFIN_METADATA)",
                WhoopBleClient.isOffloadFrame(f, DeviceFamily.WHOOP5))
        }
        val live = ByteArray(12); live[8] = 40 // REALTIME_DATA
        assertFalse(WhoopBleClient.isOffloadFrame(live, DeviceFamily.WHOOP5))
    }

    /**
     * THE bug the PR shipped: a 5/MG HISTORY_END is type 56 at frame[8]; reading frame[4] (the WHOOP4
     * index) sees an unrelated byte and drops it as live-flood, so the offload never closes a chunk
     * and the strap never trims. This asserts the family-aware index reads frame[8], not frame[4].
     */
    @Test
    fun whoop5_readsTypeAtFrame8_notFrame4() {
        val end = ByteArray(12)
        end[4] = 40   // looks like live REALTIME_DATA at the WHOOP4 index
        end[8] = 56   // real PUFFIN_METADATA (HISTORY_END/COMPLETE) at the WHOOP5 index
        assertTrue(WhoopBleClient.isOffloadFrame(end, DeviceFamily.WHOOP5))
    }

    // ---- Backfiller.endData: family-aware +4 slice (the 8 ack bytes) ----

    @Test
    fun endData_whoop4_isFrame17to25() {
        val f = ByteArray(26)
        for (i in 17 until 25) f[i] = (i - 16).toByte() // 1..8 at [17..24]
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8), Backfiller.endData(f, DeviceFamily.WHOOP4))
    }

    @Test
    fun endData_whoop5_isFrame21to29() {
        val f = ByteArray(30)
        for (i in 21 until 29) f[i] = (i - 20).toByte() // 1..8 at [21..28]
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8), Backfiller.endData(f, DeviceFamily.WHOOP5))
    }

    // ---- WHOOP5 METADATA decode (+4): meta_type@10, unix@11, trim_cursor@21 ----

    @Test
    fun parsesWhoop5HistoryEndMetadata() {
        val f = ByteArray(30)
        f[8] = 56            // PUFFIN_METADATA -> typeName "METADATA"
        f[10] = 2            // meta_type = HISTORY_END(2)
        f.putU32LE(11, 1_780_916_150L)  // unix (the real worn-frame timestamp)
        f.putU32LE(21, 112_193L)        // trim_cursor (the real HISTORY_END trim, Swift Whoop5HistoricalTests)
        sealWhoop5(f)                   // declared length 22, header CRC-16, payload CRC32 over [8,26)

        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertTrue("the sealed fixture must pass the full verdict", p.ok)
        assertEquals("METADATA", p.typeName)
        assertTrue((p.parsed["meta_type"] as String).startsWith("HISTORY_END"))
        assertEquals(1_780_916_150, p.parsed["unix"])
        assertEquals(112_193, p.parsed["trim_cursor"])
    }
}
