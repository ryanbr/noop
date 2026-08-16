package com.noop.polar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the clean-room Polar PMD decode against the SAME hand-built frames as the Swift twin
 * (PolarProtocolTests.PmdDecoderTests) — byte-parity is the #1 rule. Pure JVM, no android.bluetooth.
 */
class PmdDecoderTest {

    /** Byte-literal helper (0xE8 etc. exceed signed Byte, so build from Ints). */
    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    /** Little-endian bytes for the 8-byte PMD frame timestamp 0x0102030405060708. */
    private val tsBytes = intArrayOf(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01)
    private val tsValue = 0x0102030405060708L

    /** Build a PPI frame header (measurement 0x03, frame type 0) followed by [samples] raw bytes. */
    private fun ppiFrame(vararg samples: Int): ByteArray = bytes(0x03, *tsBytes, 0x00, *samples)

    // MARK: - Header

    @Test fun headerParsesTypeTimestampAndFrameType() {
        // ECG (0x00), compressed bit set on the frame-type byte (0x80 | 0x01).
        val h = PmdDecoder.header(bytes(0x00, *tsBytes, 0x81))
        assertNotNull(h)
        assertEquals(PolarPmdMeasurement.ECG, h!!.measurement)
        assertEquals(tsValue, h.timestampNs)     // 8-byte LE assembled correctly
        assertEquals(0x01, h.frameType)          // low 7 bits
        assertTrue(h.isCompressed)               // high bit
    }

    @Test fun headerRejectsUnknownMeasurementType() {
        assertNull(PmdDecoder.header(bytes(0x7F, *tsBytes, 0x00)))
    }

    @Test fun headerRejectsTooShort() {
        assertNull(PmdDecoder.header(bytes(0x03, 0x00, 0x00)))
    }

    // MARK: - PPI

    @Test fun decodesSinglePpiSample() {
        // hr=60, ppi=800ms (0x0320 LE), err=5ms, flags=0x06 (skinContact + supported, no blocker).
        val samples = PmdDecoder.decodePPI(ppiFrame(60, 0x20, 0x03, 0x05, 0x00, 0x06))
        assertNotNull(samples)
        assertEquals(1, samples!!.size)
        val s = samples[0]
        assertEquals(60, s.heartRate)
        assertEquals(800, s.ppiMs)
        assertEquals(5, s.errorEstimateMs)
        assertFalse(s.blocker)
        assertTrue(s.skinContact)
        assertTrue(s.skinContactSupported)
    }

    @Test fun decodesMultiplePpiSamplesInOrder() {
        val samples = PmdDecoder.decodePPI(
            ppiFrame(
                62, 0x0A, 0x03, 0x00, 0x00, 0x07,   // hr 62, ppi 778, all flags set (incl. blocker)
                48, 0xE8, 0x03, 0x02, 0x00, 0x00,   // hr 48, ppi 1000, err 2, no flags
            ),
        )
        assertNotNull(samples)
        assertEquals(2, samples!!.size)
        assertEquals(778, samples[0].ppiMs)
        assertTrue(samples[0].blocker)              // bit0 set → unreliable interval
        assertEquals(48, samples[1].heartRate)
        assertEquals(1000, samples[1].ppiMs)
        assertFalse(samples[1].skinContactSupported)
    }

    @Test fun zeroHeartRateSampleIsKeptNotDropped() {
        val samples = PmdDecoder.decodePPI(ppiFrame(0, 0x00, 0x00, 0x00, 0x00, 0x00))
        assertEquals(0, samples!!.first().heartRate)
    }

    @Test fun trailingPartialSampleIsIgnored() {
        val samples = PmdDecoder.decodePPI(ppiFrame(60, 0x20, 0x03, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC))
        assertEquals(1, samples!!.size)
    }

    @Test fun emptyPpiFrameDecodesToNoSamples() {
        assertEquals(0, PmdDecoder.decodePPI(ppiFrame())!!.size)
    }

    @Test fun decodePpiRejectsNonPpiFrame() {
        // A well-formed ACC (0x02) header is not PPI → null, even though the header itself parses.
        val acc = bytes(0x02, *tsBytes, 0x00, 0x11, 0x22, 0x33)
        assertNotNull(PmdDecoder.header(acc))
        assertNull(PmdDecoder.decodePPI(acc))
    }

    @Test fun pmdEpochToUnixConversion() {
        // PMD counts ns since 2000-01-01 UTC, not the Unix epoch; the offset re-bases it to wall clock.
        assertEquals(946_684_800_000_000_000L, PolarPmdFrameHeader.PMD_EPOCH_UNIX_OFFSET_NS)
        val h = PolarPmdFrameHeader(PolarPmdMeasurement.PPI, 1_000_000_000L, 0, false)
        assertEquals(1_000_000_000L + PolarPmdFrameHeader.PMD_EPOCH_UNIX_OFFSET_NS, h.unixTimestampNs)
    }
}
