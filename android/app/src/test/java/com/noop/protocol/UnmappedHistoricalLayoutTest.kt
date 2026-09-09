package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The archive decision for a WHOOP 5/MG type-47 record must be made on its LAYOUT VERSION, not on what
 * the record happened to decode to. Twin of the Swift `UnmappedHistoricalLayoutTests`.
 *
 * [rejectedHistoricalRecords] used to ask only "did [decodeHistorical] produce a record?". That screen is
 * the wrong QUESTION for a layout NOOP has no field map for: a record from an unmapped version that
 * answered yes would be kept NOWHERE — not as rows (nothing mapped it) and not as bytes (it passed the
 * archive filter) — and the strap frees it on the very next trim ack. A record type NOOP has not mapped
 * yet — banked to flash by a newer firmware and pulled back in a later offload — is exactly the shape
 * that can look well-formed enough to pass.
 *
 * The screen survives in practice only because of an accident: [decodeWhoop5Historical] returns null for
 * every version but 18 (`unmappedLayoutsDecodeNothing` pins that this is true right now). One added
 * static field for type 47, or one partially-mapped new version, would silently reopen the hole. These
 * pin the version-based decision instead, so the archive no longer depends on that accident holding.
 */
class UnmappedHistoricalLayoutTest {

    private fun bytes(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // A real WHOOP 5/MG type-47 v18 record (from Whoop5HistoricalDecodeTest): decodes a real unix, a
    // plausible heart rate and a ~1 g gravity vector — i.e. it PASSES the old decode-outcome screen.
    private val whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    /**
     * Re-stamp the WHOOP 5 CRC32 trailer after mutating the version byte, so the frame stays CRC-VALID.
     * Load-bearing for every test here: a CRC failure is archived on its own, which would make the
     * version-based path untestable.
     */
    private fun whoop5FrameWithVersion(version: Int): ByteArray {
        val f = bytes(whoop5V18Hex)
        f[9] = version.toByte()
        val payloadEnd = f.size - 4
        val c = Crc.crc32(f, 8, payloadEnd)
        for (b in 0 until 4) f[payloadEnd + b] = ((c shr (8 * b)) and 0xFF).toByte()
        return f
    }

    // MARK: - defect: an unmapped layout that decodes real biometrics must still be archived

    /**
     * The headline case. The frame's BYTES are a real v18 record — at the v18 offsets they carry a valid
     * unix, a plausible heart rate and a ~1 g gravity vector, the exact combination that made the old
     * screen say "decodable, nothing lost". Only the layout-version byte differs. Whatever such a record
     * decodes to, its bytes must reach the archive.
     */
    @Test fun unmappedLayoutIsArchivedEvenThoughItsBytesDecodeCleanlyAsV18() {
        // Precondition: read as its true version, this record decodes everything the old screen wanted.
        val asV18 = decodeHistorical(bytes(whoop5V18Hex), DeviceFamily.WHOOP5)!!
        // #869 widened the decoded `unix` from Int to Long — a u32 with bit 31 set narrowed to a NEGATIVE
        // Int, which the #547 plausibility gate then dropped, silently losing all history from 2038-01-19
        // (and today on a future-dated strap). The value here is unchanged; only its type is wider, so the
        // literal needs the L or assertEquals compares Integer against Long and fails on the box.
        assertEquals("precondition: these bytes DO decode a unix", 1780916150L, asV18["unix"])
        assertEquals("precondition: these bytes DO decode a heart rate", 102, asV18["heart_rate"])
        assertTrue("precondition: these bytes DO decode a gravity vector", asV18["gravity_x"] is Double)

        val unmapped = whoop5FrameWithVersion(22)
        assertEquals(
            "precondition: the record is CRC-VALID, so only the layout decision can archive it",
            true, Framing.parseFrame(unmapped, DeviceFamily.WHOOP5).crcOk,
        )
        assertTrue(isUnmappedWhoop5HistoricalRecord(unmapped))
        assertEquals(
            "a record from a layout NOOP cannot map must be archived whatever it decoded",
            listOf(unmapped.toList()),
            rejectedHistoricalRecords(listOf(unmapped), DeviceFamily.WHOOP5).map { it.toList() },
        )
    }

    /** Every version outside [MAPPED_WHOOP5_HISTORICAL_VERSIONS] is archived — no gaps, no lucky values. */
    @Test fun everyUnmappedVersionIsArchived() {
        for (v in 0..255) {
            if (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) continue
            val f = whoop5FrameWithVersion(v)
            assertEquals(
                "hist_version $v has no field map, so its bytes must be archived",
                1, rejectedHistoricalRecords(listOf(f), DeviceFamily.WHOOP5).size,
            )
        }
    }

    // MARK: - lockstep: the version set and the decoder's dispatch cannot drift apart

    /**
     * [MAPPED_WHOOP5_HISTORICAL_VERSIONS] is the single source of truth for the archive decision, so it
     * must not claim more (or fewer) versions than the decoder actually maps. Proved from the decoder's
     * own behaviour: EVERY version outside the set decodes to nothing at all.
     */
    @Test fun unmappedLayoutsDecodeNothing() {
        for (v in 0..255) {
            if (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) continue
            assertNull(
                "v$v is outside the mapped set but the decoder produced a record for it — the set and " +
                    "the version gate in decodeWhoop5Historical have drifted",
                decodeHistorical(whoop5FrameWithVersion(v), DeviceFamily.WHOOP5),
            )
        }
    }

    /**
     * The mapped versions ARE recognised as mapped (the other direction of the lockstep).
     *
     * This set is now {18, 20, 21, 26}, matching Swift. v20 (raw optical) and v21 (raw 6-axis IMU) were
     * the long-standing gap: `Whoop5RawOptical`/`Whoop5RawImu` existed on this side but were wired only
     * to the LIVE deep-buffer route, never to the type-47 historical dispatch, so an offloaded record in
     * either layout decoded to null. `decodeWhoop5HistoricalV2021` closes that.
     */
    @Test fun mappedVersionsAreNotTreatedAsUnmapped() {
        assertEquals(setOf(18, 20, 21, 26), MAPPED_WHOOP5_HISTORICAL_VERSIONS)
        for (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) {
            assertFalse(
                "v$v has a field map and must not be archived on layout grounds",
                isUnmappedWhoop5HistoricalRecord(whoop5FrameWithVersion(v)),
            )
        }
    }

    /**
     * A cleanly-decoding v18 record is still NOT archived — widening the screen must not start archiving
     * the layouts NOOP already understands wholesale. v26 keeps its own exclusion (raw PPG has a durable
     * `ppgWaveformSample` stream; it is known-skipped, not lost).
     */
    @Test fun mappedRecordsAreStillNotArchived() {
        assertTrue(rejectedHistoricalRecords(listOf(bytes(whoop5V18Hex)), DeviceFamily.WHOOP5).isEmpty())
        assertTrue(rejectedHistoricalRecords(listOf(whoop5FrameWithVersion(26)), DeviceFamily.WHOOP5).isEmpty())
    }

    /**
     * The layout rule is WHOOP 5-only: it keys off `frame[9]`, which on a WHOOP 4 frame is a payload byte,
     * not a version. WHOOP 4's unmapped versions go through the validated v24 fallback in
     * [decodeHistorical], which keeps a record only when it decodes to a ~1 g gravity vector and a
     * plausible HR and otherwise drops the biometrics — so those records reach the archive by the
     * decode-outcome route and must not be dragged in by this one.
     */
    @Test fun whoop4FramesAreUnaffectedByTheWhoop5LayoutRule() {
        // A synthetic WHOOP 4 V24 type-47 record (HR=63) that decodes cleanly.
        val v24Hex =
            "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
                "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
                "200364006400b80bb80b000000000000c25c1a88"
        assertTrue(rejectedHistoricalRecords(listOf(bytes(v24Hex)), DeviceFamily.WHOOP4).isEmpty())
        assertFalse(
            "a WHOOP 4 frame has no type-47 byte at index 8 — the rule must not fire on it",
            isUnmappedWhoop5HistoricalRecord(bytes(v24Hex)),
        )
    }
    // MARK: - v20 / v21 historical dispatch (ported from Swift)

    /**
     * The guard the archive-filter change was landed for.
     *
     * v20 now DECODES on this platform, so it is no longer archived by the unmapped-layout rule and no
     * longer archived for failing to decode. It must still reach the archive, because the record yields
     * no heart rate and no gravity: those bytes are the input for working out what the optical channels
     * mean, and the strap frees them on the next trim ack. Had the filter still asked "did it decode at
     * all", this port would have silently stopped collecting them, on the only platform collecting them.
     */
    @Test
    fun whoop5V20StillArchivedAfterItDecodes() {
        val frame = whoop5FrameWithVersion(20)
        val decoded = decodeHistorical(frame, DeviceFamily.WHOOP5)
        assertNotNull("v20 must decode now that the dispatch exists", decoded)
        assertNull("v20 carries no per-second heart rate", decoded!!["heart_rate"])
        assertNull("v20 carries no gravity vector", decoded["gravity_x"])
        assertEquals(
            "a v20 record that decodes into unread channels must still be archived",
            1,
            rejectedHistoricalRecords(listOf(frame), DeviceFamily.WHOOP5).size,
        )
    }

    /** v21 is the same story: it decodes, carries no scoreable signal, and is still archived. */
    @Test
    fun whoop5V21StillArchivedAfterItDecodes() {
        val frame = whoop5FrameWithVersion(21)
        val decoded = decodeHistorical(frame, DeviceFamily.WHOOP5)
        assertNotNull(decoded)
        assertNull(decoded!!["heart_rate"])
        assertEquals(1, rejectedHistoricalRecords(listOf(frame), DeviceFamily.WHOOP5).size)
    }

    /**
     * Both layouts reuse the v18 record header, so the fields that make a record identifiable at all
     * decode even when its body does not: the layout marker, the monotonic record index and the unix.
     * A v20/v21 record used to yield NOTHING, not even a timestamp.
     */
    @Test
    fun whoop5V2021ReadTheSharedRecordHeader() {
        for (v in listOf(20, 21)) {
            val d = decodeHistorical(whoop5FrameWithVersion(v), DeviceFamily.WHOOP5)!!
            assertEquals("hist_version", v, d["hist_version"])
            assertNotNull("v$v must carry the shared-header unix", d["unix"])
            assertNotNull("v$v must carry the shared-header record index", d["record_index"])
            // Long, not Int, on both: an unsigned 32-bit field narrowed to Kotlin's 32-bit Int decodes
            // differently from Swift's 64-bit Int for the same bytes once bit 31 is set.
            assertTrue("unix must stay in the unsigned domain", d["unix"] is Long)
            assertTrue("record_index must stay in the unsigned domain", d["record_index"] is Long)
        }
    }

    /**
     * A body too short for the channel arrays yields the header and NO half-filled channels. The Swift
     * twin breaks out of a channel the moment a sample is unreadable and emits it only at a full 100, so
     * a truncated record cannot produce an array that looks complete.
     */
    @Test
    fun whoop5V21EmitsNoPartialChannels() {
        val d = decodeHistorical(whoop5FrameWithVersion(21), DeviceFamily.WHOOP5)!!
        for (name in listOf("accel_x", "accel_y", "accel_z", "gyro_x", "gyro_y", "gyro_z")) {
            assertNull("$name must be absent rather than partial on a short record", d[name])
        }
    }

    /**
     * The v20 OPTICAL body, end to end through the historical dispatch, on a real-shaped 2140-byte
     * frame. The tests above use a short v18-derived frame, on which `Whoop5RawOptical.decode` refuses
     * and only the shared header decodes, so without this the optical branch this port exists for would
     * be entirely unexercised. `decode` requires the frame to BE the 2140-byte buffer, CRC-sealed, with
     * the record class and layout version in place, so the fixture has to be sealed exactly as a strap
     * seals one.
     */
    @Test
    fun whoop5V20DecodesItsOpticalBlocksThroughTheHistoricalDispatch() {
        val frame = sealedV20Frame(sampleCount = 3, firstSample = 0x00012345)
        val d = decodeHistorical(frame, DeviceFamily.WHOOP5)
        assertNotNull("a sealed v20 buffer must decode", d)
        assertEquals(20, d!!["hist_version"])
        assertEquals(Whoop5RawOptical.BLOCK_COUNT, d["sensor_block_count"])
        assertEquals(3, d["block_b0_sample_count"])
        assertEquals("the widest block's sample count", 3, d["sensor_channel_samples"])
        // Two channel slots per block, emitted only for blocks whose sample count is non-zero.
        assertEquals(2, d["sensor_channels_present"])
        @Suppress("UNCHECKED_CAST")
        val ch = d["channel_b0_0"] as List<Int>
        assertEquals(3, ch.size)
        assertEquals("raw signed i32 sample, no masking or scaling applied", 0x00012345, ch[0])
        assertNotNull("the block's raw header is carried too", d["block_b0_header"])
        // And it is still archived: it decoded, but it carries no heart rate and no gravity.
        assertEquals(1, rejectedHistoricalRecords(listOf(frame), DeviceFamily.WHOOP5).size)
    }

    /**
     * A 2140-byte v20 buffer with block 0 given [sampleCount] samples, the first of them [firstSample],
     * sealed with both checksums. Mirrors the builder in `Whoop5RawOpticalTest`, which is private there.
     */
    private fun sealedV20Frame(sampleCount: Int, firstSample: Int): ByteArray {
        val f = ByteArray(Whoop5RawOptical.BUFFER_LENGTH)
        f[0] = 0xAA.toByte()
        f[1] = 0x01
        f[2] = 0x54            // declared length 2132 = 2140 - 8
        f[3] = 0x08
        f[4] = 0x01
        f[8] = Whoop5RawOptical.RECORD_CLASS.toByte()
        f[9] = Whoop5RawOptical.LAYOUT_VERSION.toByte()
        f[10] = 0x81.toByte()  // v20's layout marker
        // record_index @11 and unix @15, both u32 LE, so the shared header has real values to read.
        for ((off, v) in listOf(11 to 0x0000_2233L, 15 to 0x6600_0000L)) {
            for (b in 0 until 4) f[off + b] = ((v shr (8 * b)) and 0xFF).toByte()
        }
        val blockStart = Whoop5RawOptical.BLOCK_START
        f[blockStart] = sampleCount.toByte()
        val sampleStart = blockStart + Whoop5RawOptical.HEADER_LENGTH
        for (b in 0 until 4) f[sampleStart + b] = ((firstSample shr (8 * b)) and 0xFF).toByte()
        val headerCrc = Crc.crc16Modbus(f, 0, 6)
        f[6] = (headerCrc and 0xFF).toByte()
        f[7] = ((headerCrc shr 8) and 0xFF).toByte()
        val end = Whoop5RawOptical.CHECKSUM_OFFSET
        val payloadCrc = Crc.crc32(f, 8, end)
        for (i in 0 until 4) f[end + i] = ((payloadCrc shr (8 * i)) and 0xFF).toByte()
        return f
    }

}
