package com.noop.protocol

import com.noop.data.StreamBatch
import com.noop.ingest.CaptureImporter
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * FRAME INTEGRITY — the Kotlin half of the cross-platform verdict contract.
 *
 * The frame verifier is the ONE place that decides whether bytes off the air may drive state. For
 * the same bytes this side must reach the same verdict, name the same reason and reach the same
 * historical classification as the Swift `WhoopProtocol` twin (`Framing.swift` / `Interpreter.swift`),
 * because the two are independent reimplementations rather than shared code.
 *
 * What the rules are, in the order the verifier applies them:
 *  1. start of frame (0xAA),
 *  2. the family minimum — 11 bytes on WHOOP 4.0, 13 on WHOOP 5.0/MG,
 *  3. the EXACT total the declared length implies (`len + 4` / `declLen + 8`), so a truncated frame
 *     and one carrying trailing bytes are both rejected,
 *  4. the header checksum (CRC-8 / CRC-16-Modbus),
 *  5. the payload CRC32 — where "could not be computed" is a REJECTION, never an "unknown" a gate
 *     might read as a pass.
 *
 * Reason names map one-to-one onto the Swift enum: `none` ↔ [FrameRejectReason.NONE],
 * `noStartOfFrame` ↔ [FrameRejectReason.NO_START_OF_FRAME], `belowMinimumLength` ↔
 * [FrameRejectReason.BELOW_MINIMUM_LENGTH], `lengthMismatch` ↔ [FrameRejectReason.LENGTH_MISMATCH],
 * `headerChecksumMismatch` ↔ [FrameRejectReason.HEADER_CHECKSUM_MISMATCH], `payloadCRCMismatch` ↔
 * [FrameRejectReason.PAYLOAD_CRC_MISMATCH], `payloadCRCUnverifiable` ↔
 * [FrameRejectReason.PAYLOAD_CRC_UNVERIFIABLE].
 */
class FrameIntegrityTest {

    // MARK: - frame builders (real checksums, never a placeholder)

    private fun putU32LE(b: ByteArray, off: Int, v: Long) {
        b[off] = (v and 0xFF).toByte()
        b[off + 1] = ((v shr 8) and 0xFF).toByte()
        b[off + 2] = ((v shr 16) and 0xFF).toByte()
        b[off + 3] = ((v shr 24) and 0xFF).toByte()
    }

    /**
     * `[0xAA][len u16 LE][crc8(len)][inner…][crc32(inner) u32 LE]`, `len = inner.size + 4`, total
     * `len + 4`. An inner record of 3 bytes yields the 11-byte family minimum.
     */
    private fun whoop4Frame(inner: ByteArray): ByteArray {
        val length = inner.size + 4
        val out = ByteArray(inner.size + 8)
        out[0] = 0xAA.toByte()
        out[1] = (length and 0xFF).toByte()
        out[2] = ((length shr 8) and 0xFF).toByte()
        out[3] = Crc.crc8(byteArrayOf(out[1], out[2])).toByte()
        inner.copyInto(out, 4)
        putU32LE(out, length, Crc.crc32(inner))
        return out
    }

    /**
     * `[0xAA][0x01][declLen u16 LE][hdr u16][crc16 u16][payload…][crc32(payload) u32 LE]`,
     * `declLen = payload.size + 4`, total `declLen + 8`. A 1-byte payload yields the 13-byte minimum.
     */
    private fun whoop5Frame(payload: ByteArray): ByteArray {
        val declLen = payload.size + 4
        val out = ByteArray(payload.size + 12)
        out[0] = 0xAA.toByte()
        out[1] = 0x01
        out[2] = (declLen and 0xFF).toByte()
        out[3] = ((declLen shr 8) and 0xFF).toByte()
        out[4] = 0x00
        out[5] = 0x01
        val c16 = Crc.crc16Modbus(out, 0, 6)
        out[6] = (c16 and 0xFF).toByte()
        out[7] = ((c16 shr 8) and 0xFF).toByte()
        payload.copyInto(out, 8)
        putU32LE(out, 8 + payload.size, Crc.crc32(out, 8, 8 + payload.size))
        return out
    }

    /** A complete, valid WHOOP 4.0 REALTIME_DATA frame: ts@6, subsec@10, hr@12, rr_count@13. */
    private fun realtimeWhoop4(ts: Long = 1_780_916_150L, hr: Int = 61): ByteArray {
        val inner = ByteArray(10)
        inner[0] = PacketType.REALTIME_DATA.rawValue.toByte()
        inner[1] = 0            // seq
        inner[2] = 0            // cmd
        putU32LE(inner, 2, ts)  // ts@6 == inner[2]
        inner[8] = hr.toByte()  // hr@12 == inner[8]
        inner[9] = 0            // rr_count@13
        return whoop4Frame(inner)
    }

    /** A complete, valid WHOOP 4.0 type-47 HISTORICAL_DATA v24 record (the archive's subject). */
    private fun historicalWhoop4(): ByteArray = hexToBytes(realFrameHex("whoop4_v24_real_worn"))

    private fun hexToBytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private fun oracle(): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream("decoder_oracle.json")
        assertNotNull("decoder_oracle.json missing from test classpath", stream)
        return JSONObject(stream!!.bufferedReader().use { it.readText() })
    }

    private fun realFrameHex(name: String): String {
        val frames = oracle().getJSONArray("frames")
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            if (f.getString("name") == name) return f.getString("hex")
        }
        throw AssertionError("fixture frame '$name' missing from decoder_oracle.json")
    }

    /** Flip one bit in the frame's header checksum byte — the class that used to pass every gate. */
    private fun breakHeaderChecksum(frame: ByteArray, family: DeviceFamily): ByteArray {
        val out = frame.copyOf()
        val at = if (family == DeviceFamily.WHOOP5) 6 else 3
        out[at] = (out[at].toInt() xor 0x01).toByte()
        return out
    }

    // MARK: - Full integrity verdict in the parse result

    @Test
    fun whoop4_headerChecksumWrong_payloadCrcRight_isRejected() {
        val good = realtimeWhoop4()
        assertTrue(Framing.parseFrame(good, DeviceFamily.WHOOP4).ok)

        val bad = breakHeaderChecksum(good, DeviceFamily.WHOOP4)
        val p = Framing.parseFrame(bad, DeviceFamily.WHOOP4)
        assertFalse("a broken header checksum is a rejection, even with a correct payload CRC", p.ok)
        assertEquals(FrameRejectReason.HEADER_CHECKSUM_MISMATCH, p.rejectReason)
        // The payload CRC32 itself is still right — that combination is exactly the class that used
        // to reach the gates, so it must stay observable rather than be flattened into the verdict.
        assertEquals(true, p.crcOk)
    }

    @Test
    fun whoop5_headerChecksumWrong_payloadCrcRight_isRejected() {
        val good = hexToBytes(realFrameHex("whoop5_v18_real_worn"))
        assertTrue(Framing.parseFrame(good, DeviceFamily.WHOOP5).ok)

        val bad = breakHeaderChecksum(good, DeviceFamily.WHOOP5)
        val p = Framing.parseFrame(bad, DeviceFamily.WHOOP5)
        assertFalse(p.ok)
        assertEquals(FrameRejectReason.HEADER_CHECKSUM_MISMATCH, p.rejectReason)
        assertEquals(true, p.crcOk)
    }

    @Test
    fun payloadCrcNotComputable_isNegative_notUnknown() {
        // Too short for the payload CRC32 to be computed at all. The verdict must be NEGATIVE — the
        // "unknown" tri-state is what let these through before, since every gate only asked whether
        // the CRC was DEMONSTRABLY wrong.
        val runt = byteArrayOf(0xAA.toByte(), 0x08, 0x00, 0x00, 0x28, 0x00, 0x00)
        val p = Framing.parseFrame(runt, DeviceFamily.WHOOP4)
        assertFalse(p.ok)
        assertNull("nothing to check is not a check that passed", p.crcOk)
        assertEquals(FrameRejectReason.BELOW_MINIMUM_LENGTH, p.rejectReason)
    }

    @Test
    fun validFrame_carriesPositiveVerdictAndNoReason() {
        val p = Framing.parseFrame(realtimeWhoop4(hr = 61), DeviceFamily.WHOOP4)
        assertTrue(p.ok)
        assertEquals(FrameRejectReason.NONE, p.rejectReason)
        assertEquals("REALTIME_DATA", p.typeName)
        assertEquals(61, p.parsed["heart_rate"])
    }

    // MARK: - The reason is on the parse result, and the reasons are distinguishable

    @Test
    fun everyRejectionClassCarriesItsOwnReason() {
        val good = realtimeWhoop4()

        val noSof = good.copyOf().also { it[0] = 0x55 }
        val belowMinimum = whoop4Frame(ByteArray(3)).copyOf(9)   // 9 bytes: under the 11-byte floor
        val trailing = good + byteArrayOf(0x00)
        val truncated = good.copyOf(good.size - 1)
        val headerBroken = breakHeaderChecksum(good, DeviceFamily.WHOOP4)
        val payloadBroken = good.copyOf().also { it[12] = (it[12] + 1).toByte() }

        val reasons = listOf(noSof, belowMinimum, trailing, truncated, headerBroken, payloadBroken)
            .map { Framing.parseFrame(it, DeviceFamily.WHOOP4).rejectReason }

        assertEquals(
            listOf(
                FrameRejectReason.NO_START_OF_FRAME,
                FrameRejectReason.BELOW_MINIMUM_LENGTH,
                FrameRejectReason.LENGTH_MISMATCH,
                FrameRejectReason.LENGTH_MISMATCH,
                FrameRejectReason.HEADER_CHECKSUM_MISMATCH,
                FrameRejectReason.PAYLOAD_CRC_MISMATCH,
            ),
            reasons,
        )
        // A consumer determines the cause from the value it was HANDED: no second verify, no second
        // parse. That is what keeps the parse-once invariant intact.
        assertEquals(FrameRejectReason.NONE, Framing.parseFrame(good, DeviceFamily.WHOOP4).rejectReason)
    }

    // MARK: - Structural minimum and exact length, per device family

    @Test
    fun whoop4_belowMinimumLength_readsNoPacketType() {
        // Declared lengths 4..6 → totals 8..10, all under the 11-byte floor.
        for (declared in 4..6) {
            val total = declared + 4
            val f = ByteArray(total)
            f[0] = 0xAA.toByte()
            f[1] = declared.toByte()
            f[3] = Crc.crc8(byteArrayOf(f[1], f[2])).toByte()
            f[4] = PacketType.METADATA.rawValue.toByte()
            val p = Framing.parseFrame(f, DeviceFamily.WHOOP4)
            assertFalse("total $total must be rejected", p.ok)
            assertEquals(FrameRejectReason.BELOW_MINIMUM_LENGTH, p.rejectReason)
            assertEquals("no packet type is read out of a runt", "INVALID/FRAGMENT", p.typeName)
        }
    }

    @Test
    fun whoop5_belowMinimumLength_readsNoInnerTypeFromTheTrailer() {
        // declLen 4 → total 12: one byte under the floor, and the byte at [8] that would be read as
        // the inner packet type is the first byte of the frame's own CRC32 trailer.
        val f = ByteArray(12)
        f[0] = 0xAA.toByte()
        f[1] = 0x01
        f[2] = 0x04
        val c16 = Crc.crc16Modbus(f, 0, 6)
        f[6] = (c16 and 0xFF).toByte()
        f[7] = ((c16 shr 8) and 0xFF).toByte()
        f[8] = PuffinPacketType.PUFFIN_METADATA.toByte()
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertFalse(p.ok)
        assertEquals(FrameRejectReason.BELOW_MINIMUM_LENGTH, p.rejectReason)
        assertEquals("INVALID/FRAGMENT", p.typeName)
    }

    @Test
    fun exactlyAtTheFamilyMinimum_isAccepted() {
        val w4 = whoop4Frame(byteArrayOf(PacketType.METADATA.rawValue.toByte(), 0, 3))
        assertEquals(FrameLimits.WHOOP4_MINIMUM_FRAME_BYTES, w4.size)
        assertTrue("the smallest real WHOOP 4.0 frame is exactly 11 bytes", Framing.frameCrcOk(w4, DeviceFamily.WHOOP4))

        val w5 = whoop5Frame(byteArrayOf(PuffinPacketType.PUFFIN_METADATA.toByte()))
        assertEquals(FrameLimits.WHOOP5_MINIMUM_FRAME_BYTES, w5.size)
        assertTrue(Framing.frameCrcOk(w5, DeviceFamily.WHOOP5))
    }

    @Test
    fun trailingBytesAndTruncationAreBothRejected_bothFamilies() {
        val w4 = realtimeWhoop4()
        assertEquals(
            FrameRejectReason.LENGTH_MISMATCH,
            Framing.parseFrame(w4 + byteArrayOf(0x00), DeviceFamily.WHOOP4).rejectReason,
        )
        assertEquals(
            FrameRejectReason.LENGTH_MISMATCH,
            Framing.parseFrame(w4.copyOf(w4.size - 1), DeviceFamily.WHOOP4).rejectReason,
        )

        val w5 = hexToBytes(realFrameHex("whoop5_v18_real_worn"))
        assertEquals(
            FrameRejectReason.LENGTH_MISMATCH,
            Framing.parseFrame(w5 + byteArrayOf(0x00), DeviceFamily.WHOOP5).rejectReason,
        )
        assertEquals(
            FrameRejectReason.LENGTH_MISMATCH,
            Framing.parseFrame(w5.copyOf(w5.size - 1), DeviceFamily.WHOOP5).rejectReason,
        )
    }

    @Test
    fun declaredLengthFarBeyondTheBytesPresent_isRejectedAndReadsNothingOffTheEnd() {
        val f = realtimeWhoop4().also { it[1] = 0xFF.toByte(); it[2] = 0xFF.toByte() }
        // Must not throw: the D7 bound is the MINIMUM of the trailer start and the real size, so the
        // size still guards every read even though the declared trailer sits far past the buffer.
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP4)
        assertFalse(p.ok)
        assertEquals(FrameRejectReason.LENGTH_MISMATCH, p.rejectReason)
        assertTrue("no row may be derived from it", extractStreams(listOf(p), 0, 0).hr.isEmpty())
    }

    // MARK: - Reassembler: never emit an under-length frame

    @Test
    fun reassembler_dropsUnderLengthStartOfFrame_andCountsIt() {
        val valid = realtimeWhoop4()
        // A start-of-frame declaring total 8 (below the 11-byte floor), then a complete valid frame.
        val stream = byteArrayOf(0xAA.toByte(), 0x04, 0x00, 0x00) + valid
        val r = Reassembler(DeviceFamily.WHOOP4)
        val out = r.feed(stream)
        assertEquals("only the complete valid frame is emitted", 1, out.size)
        assertArrayEquals(valid, out[0])
        assertEquals("the dropped byte run stays visible as a counted rejection", 1, r.belowMinimumLengthDrops)
    }

    @Test
    fun reassembler_underLengthFloorIsPerFamily() {
        // The floor the reassembler applies is the FAMILY's, not one shared number. A declared total
        // of 12 is a legal WHOOP 4.0 frame but one byte under the WHOOP 5.0/MG minimum, so the same
        // byte run must be kept by one reassembler and dropped by the other.
        val w4 = realtimeWhoop4()
        assertEquals(12, w4.copyOf(12).size)

        // WHOOP 5/MG: declLen 4 → total 12, below the 13-byte floor. Dropped, then it resyncs onto
        // the complete frame that follows.
        val valid5 = whoop5Frame(byteArrayOf(PuffinPacketType.PUFFIN_METADATA.toByte(), 0, 0, 0))
        val runt5 = byteArrayOf(0xAA.toByte(), 0x01, 0x04, 0x00)
        val r5 = Reassembler(DeviceFamily.WHOOP5)
        val out5 = r5.feed(runt5 + valid5)
        assertEquals("only the complete 5/MG frame is emitted", 1, out5.size)
        assertArrayEquals(valid5, out5[0])
        assertEquals(1, r5.belowMinimumLengthDrops)

        // WHOOP 4.0 with a declared total of 12: at the floor's other side, so it is emitted whole
        // and nothing is counted — the floor did not silently become a global constant.
        val inner4 = ByteArray(4).also { it[0] = PacketType.METADATA.rawValue.toByte() }
        val small4 = whoop4Frame(inner4)
        assertEquals(12, small4.size)
        val r4 = Reassembler(DeviceFamily.WHOOP4)
        val out4 = r4.feed(small4)
        assertEquals(1, out4.size)
        assertArrayEquals(small4, out4[0])
        assertEquals(0, r4.belowMinimumLengthDrops)
    }

    @Test
    fun reassembler_fragmentedDeliveryIsUnchanged() {
        val valid = realtimeWhoop4()
        val r = Reassembler(DeviceFamily.WHOOP4)
        assertTrue(r.feed(valid.copyOfRange(0, 5)).isEmpty())
        assertTrue(r.feed(valid.copyOfRange(5, 9)).isEmpty())
        val out = r.feed(valid.copyOfRange(9, valid.size))
        assertEquals(1, out.size)
        assertArrayEquals(valid, out[0])
        assertEquals(0, r.belowMinimumLengthDrops)
    }

    // MARK: - D7: inner fields come only from payload bytes

    @Test
    fun whoop5_atExactlyTheMinimum_decodesNoInnerFieldAtAll() {
        // 13 bytes: the trailer starts at 9, so every named inner field (sequence number, command
        // byte, metadata type) sits inside the frame's own checksum. Only the packet TYPE at [8],
        // which the family minimum guarantees is a payload byte, is read.
        val f = whoop5Frame(byteArrayOf(PuffinPacketType.PUFFIN_METADATA.toByte()))
        assertEquals(FrameLimits.WHOOP5_MINIMUM_FRAME_BYTES, f.size)
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertTrue(p.ok)
        assertEquals("METADATA", p.typeName)
        assertNull(p.parsed["meta_type"])
        assertNull(p.parsed["unix"])
        assertNull(p.parsed["trim_cursor"])
        assertEquals(HistoricalMeta.Other, classifyHistoricalMeta(p))
    }

    @Test
    fun whoop5_atTheMinimum_decodesNoMetadataFieldFromItsOwnTrailer() {
        // A 14-byte 5/MG METADATA frame with CORRECT checksums whose CRC32 trailer starts with the
        // byte that means HISTORY_COMPLETE, at exactly the offset meta_type would be read from.
        val filler = (0..255).firstOrNull {
            Crc.crc32(byteArrayOf(PuffinPacketType.PUFFIN_METADATA.toByte(), it.toByte())) and 0xFFL ==
                MetadataType.HISTORY_COMPLETE.rawValue.toLong()
        }
        assertNotNull("no payload byte produces the wanted trailer", filler)
        val f = whoop5Frame(byteArrayOf(PuffinPacketType.PUFFIN_METADATA.toByte(), filler!!.toByte()))
        assertEquals(14, f.size)

        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertTrue("the frame itself is intact — only its FIELDS are out of bounds", p.ok)
        assertEquals("METADATA", p.typeName)
        assertNull("meta_type@10 sits in the CRC32 trailer and must not be decoded", p.parsed["meta_type"])
        assertEquals(
            "and so it cannot be classified as history completion",
            HistoricalMeta.Other, classifyHistoricalMeta(p),
        )
    }

    @Test
    fun whoop5_oneByteMoreOfPayload_decodesTheMetadataField() {
        // 15 bytes: the trailer now starts at 11, so meta_type@10 IS a payload byte and is decoded.
        val f = whoop5Frame(
            byteArrayOf(PuffinPacketType.PUFFIN_METADATA.toByte(), 0, MetadataType.HISTORY_COMPLETE.rawValue.toByte()),
        )
        assertEquals(15, f.size)
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertTrue(p.ok)
        assertTrue((p.parsed["meta_type"] as String).startsWith("HISTORY_COMPLETE"))
        assertEquals(HistoricalMeta.Complete, classifyHistoricalMeta(p))
    }

    @Test
    fun whoop4_smallestRealHistoryFrame_stillYieldsItsMetadataType() {
        // D7's comparison form is "start + length must not EXCEED the bound", NOT "must stay below
        // it". The smallest real WHOOP 4.0 metadata frame is 11 bytes with its trailer at 7, and its
        // meta_type occupies precisely the last payload byte — a stricter comparison would swallow
        // HISTORY_COMPLETE and the offload would never end.
        val f = whoop4Frame(
            byteArrayOf(PacketType.METADATA.rawValue.toByte(), 0, MetadataType.HISTORY_COMPLETE.rawValue.toByte()),
        )
        assertEquals(11, f.size)
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP4)
        assertTrue(p.ok)
        assertEquals(HistoricalMeta.Complete, classifyHistoricalMeta(p))
    }

    @Test
    fun whoop4_shortenedInnerRecord_decodesNoFieldPastTheTrailer() {
        // A 14-byte REALTIME_DATA frame: the trailer starts at 10, so the timestamp@6 is payload and
        // is decoded, while subseconds@10 and heart_rate@12 are the frame's own checksum bytes.
        val inner = ByteArray(6)
        inner[0] = PacketType.REALTIME_DATA.rawValue.toByte()
        putU32LE(inner, 2, 1_780_916_150L)
        val f = whoop4Frame(inner)
        assertEquals(14, f.size)

        val p = Framing.parseFrame(f, DeviceFamily.WHOOP4)
        assertTrue(p.ok)
        assertEquals(1_780_916_150L.toInt(), p.parsed["timestamp"])
        assertNull("heart_rate@12 lies in the CRC32 trailer", p.parsed["heart_rate"])
        assertNull("subseconds@10 lies in the CRC32 trailer", p.parsed["subseconds"])
    }

    // MARK: - State-driving gates

    @Test
    fun historicalMetaClassifier_rejectsEveryForgedShape() {
        val end = whoop4Frame(
            byteArrayOf(PacketType.METADATA.rawValue.toByte(), 0, MetadataType.HISTORY_END.rawValue.toByte()) +
                ByteArray(14),
        )
        val good = Framing.parseFrame(end, DeviceFamily.WHOOP4)
        assertTrue(good.ok)
        assertTrue("the honest frame still advances the trim cursor", classifyHistoricalMeta(good) is HistoricalMeta.End)

        val headerBroken = Framing.parseFrame(breakHeaderChecksum(end, DeviceFamily.WHOOP4), DeviceFamily.WHOOP4)
        val truncated = Framing.parseFrame(end.copyOf(end.size - 1), DeviceFamily.WHOOP4)
        val trailing = Framing.parseFrame(end + byteArrayOf(0), DeviceFamily.WHOOP4)
        for (p in listOf(headerBroken, truncated, trailing)) {
            assertEquals(
                "a forged HISTORY_END must not advance the trim cursor or trigger an ack",
                HistoricalMeta.Other, classifyHistoricalMeta(p),
            )
        }
    }

    @Test
    fun streamExtraction_skipsAFrameWithABrokenHeader() {
        val good = Framing.parseFrame(realtimeWhoop4(hr = 61), DeviceFamily.WHOOP4)
        val bad = Framing.parseFrame(
            breakHeaderChecksum(realtimeWhoop4(hr = 61), DeviceFamily.WHOOP4), DeviceFamily.WHOOP4,
        )
        assertEquals(1, extractStreams(listOf(good), 0, 0).hr.size)
        assertTrue("no row may be derived from a broken-header frame", extractStreams(listOf(bad), 0, 0).hr.isEmpty())
    }

    @Test
    fun historicalExtraction_skipsAFrameWithABrokenHeader() {
        val good = historicalWhoop4()
        val bad = breakHeaderChecksum(good, DeviceFamily.WHOOP4)
        val fromGood: StreamBatch = extractHistoricalStreams(listOf(good), 0, 0, DeviceFamily.WHOOP4)
        val fromBad: StreamBatch = extractHistoricalStreams(listOf(bad), 0, 0, DeviceFamily.WHOOP4)
        assertTrue("the honest record still banks rows", fromGood.hr.isNotEmpty())
        assertTrue("a broken-header record banks none", fromBad.hr.isEmpty())
        assertTrue(fromBad.gravity.isEmpty())
    }

    @Test
    fun historicalExtraction_gatesTheRawPpgWaveformToo() {
        // A 5/MG layout-v26 record: type@8, version@9, unix@15, 24 i16 samples at [27, 75).
        // This branch reads the record DIRECTLY instead of going through the record decoder, so it
        // needs the verdict applied ahead of the per-type work — otherwise a forged frame banks PPG
        // rows through the one path that never asked.
        val payload = ByteArray(70)
        payload[0] = PacketType.HISTORICAL_DATA.rawValue.toByte()
        payload[1] = 26
        putU32LE(payload, 7, 1_780_916_150L)          // unix@15
        for (i in 0 until 24) {                        // samples@27..75
            payload[19 + i * 2] = ((i + 1) and 0xFF).toByte()
            payload[20 + i * 2] = 0
        }
        val frame = whoop5Frame(payload)
        assertTrue(Framing.frameCrcOk(frame, DeviceFamily.WHOOP5))

        val fromGood = extractHistoricalStreams(listOf(frame), 0, 0, DeviceFamily.WHOOP5)
        assertEquals("the honest v26 record still banks its waveform", 1, fromGood.ppgWaveform.size)

        val forged = breakHeaderChecksum(frame, DeviceFamily.WHOOP5)
        val fromForged = extractHistoricalStreams(listOf(forged), 0, 0, DeviceFamily.WHOOP5)
        assertTrue("a forged v26 record banks nothing", fromForged.ppgWaveform.isEmpty())
        assertTrue(fromForged.ppgHr.isEmpty())
    }

    // MARK: - Evidence-preserving reader (D8): a rejected record is ARCHIVED, not dropped

    @Test
    fun rejectedRecordArchive_keepsATypeFortySevenFrameWithABrokenHeader() {
        val good = historicalWhoop4()
        val bad = breakHeaderChecksum(good, DeviceFamily.WHOOP4)

        assertTrue(
            "a decodable record is not archived — it became rows",
            rejectedHistoricalRecords(listOf(good), DeviceFamily.WHOOP4).isEmpty(),
        )
        val archived = rejectedHistoricalRecords(listOf(bad), DeviceFamily.WHOOP4)
        assertEquals("the tightened verdict ENLARGES the archived set, it never shrinks it", 1, archived.size)
        assertArrayEquals("archived verbatim, header bytes and all", bad, archived[0])
    }

    /** A 5/MG layout-v26 (raw PPG) record: type@8, version@9, unix@15, 24 i16 samples at [27, 75). */
    private fun historicalWhoop5V26(): ByteArray {
        val payload = ByteArray(70)
        payload[0] = PacketType.HISTORICAL_DATA.rawValue.toByte()
        payload[1] = 26
        putU32LE(payload, 7, 1_780_916_150L)
        for (i in 0 until 24) {
            payload[19 + i * 2] = ((i + 1) and 0xFF).toByte()
            payload[20 + i * 2] = 0
        }
        return whoop5Frame(payload)
    }

    @Test
    fun rejectedRecordArchive_keepsAV26RecordWithABrokenHeader() {
        // The v26 skip exists BECAUSE the extraction banks such a record in its own waveform stream.
        // Since the integrity gate a broken v26 record banks nothing there
        // ([historicalExtraction_gatesTheRawPpgWaveformToo]), so skipping it on the version byte alone
        // would leave it stored nowhere while its section is acked anyway.
        val bad = breakHeaderChecksum(historicalWhoop5V26(), DeviceFamily.WHOOP5)
        assertEquals(26, bad[9].toInt() and 0xFF)
        val p = Framing.parseFrame(bad, DeviceFamily.WHOOP5)
        assertEquals(FrameRejectReason.HEADER_CHECKSUM_MISMATCH, p.rejectReason)
        assertEquals("precondition: the PAYLOAD CRC32 still verifies", true, p.crcOk)
        val archived = rejectedHistoricalRecords(listOf(bad), DeviceFamily.WHOOP5)
        assertEquals("a rejected v26 record reaches no stream, so its bytes are the only copy left", 1, archived.size)
        assertArrayEquals("archived verbatim, header bytes and all", bad, archived[0])
    }

    @Test
    fun rejectedRecordArchive_stillSkipsAnIntactV26Record() {
        // The other direction: binding the skip to the verdict must not grow the archive by the
        // NORMAL case — an intact v26 record is banked as a waveform and stays out.
        val good = historicalWhoop5V26()
        assertTrue("precondition: the record is intact", Framing.parseFrame(good, DeviceFamily.WHOOP5).ok)
        assertTrue(
            "the archive must not grow by the normal case",
            rejectedHistoricalRecords(listOf(good), DeviceFamily.WHOOP5).isEmpty(),
        )
    }

    // MARK: - the BLE seam's gate on the GET_DATA_RANGE reply (task 2.15)

    /** A complete WHOOP 4.0 GET_DATA_RANGE COMMAND_RESPONSE: type@4, seq@5, cmd@6, body from 7 —
     *  `oldest` on the aligned grid `oldestUnix` scans, `newest` one word later. */
    private fun dataRangeReply(oldest: Long, newest: Long): ByteArray {
        val inner = ByteArray(11)
        inner[0] = PacketType.COMMAND_RESPONSE.rawValue.toByte()
        inner[1] = 1
        inner[2] = CommandNumber.GET_DATA_RANGE.rawValue.toByte()
        putU32LE(inner, 3, oldest)
        putU32LE(inner, 7, newest)
        return whoop4Frame(inner)
    }

    @Test
    fun dataRangeSeam_acceptsAnIntactReplyAndCarriesTheWindow() {
        val oldest = 1_750_000_000L
        val newest = 1_780_000_000L
        val f = dataRangeReply(oldest, newest)
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP4)
        assertTrue("precondition: the reply is intact", p.ok)
        assertTrue(DataRange.acceptsReply(f, 6, CommandNumber.GET_DATA_RANGE.rawValue) { p.ok })
        assertEquals(newest, DataRange.newestUnix(f, 1_790_000_000L, 48 * 3600L))
        assertEquals(oldest, DataRange.oldestUnix(f))
    }

    @Test
    fun dataRangeSeam_brokenReplyMovesNeitherTheWindowNorThePlausibilityBounds() {
        // "eine Antwort mit falscher Kopfprüfsumme verändert weder den gemeldeten Zeitbereich noch die
        // Plausibilitätsgrenzen des Abzugs": the damaged reply still DECODES a window, so the verdict
        // is the only thing keeping it out — which is why the gate must be a predicate a test can hold.
        val oldest = 1_750_000_000L
        val newest = 1_780_000_000L
        val bad = breakHeaderChecksum(dataRangeReply(oldest, newest), DeviceFamily.WHOOP4)
        val p = Framing.parseFrame(bad, DeviceFamily.WHOOP4)
        assertEquals(FrameRejectReason.HEADER_CHECKSUM_MISMATCH, p.rejectReason)
        assertEquals("precondition: the payload CRC32 still verifies", true, p.crcOk)
        assertEquals(
            "precondition: these bytes DO carry a window a seam could apply",
            newest, DataRange.newestUnix(bad, 1_790_000_000L, 48 * 3600L),
        )

        // The seam in miniature: the reported window and the two plausibility bounds, moved only on an
        // accepted reply. Their previous values must survive a damaged one untouched.
        var reportedNewest: Long? = 1_700_000_001L
        var boundsNewest: Long? = 1_700_000_001L
        var boundsOldest: Long? = 1_700_000_000L
        if (DataRange.acceptsReply(bad, 6, CommandNumber.GET_DATA_RANGE.rawValue) { p.ok }) {
            reportedNewest = DataRange.newestUnix(bad, 1_790_000_000L, 48 * 3600L)
            boundsNewest = reportedNewest
            boundsOldest = DataRange.oldestUnix(bad)
        }
        assertEquals("the reported range must not move", 1_700_000_001L, reportedNewest)
        assertEquals("the offload's upper plausibility bound must not move", 1_700_000_001L, boundsNewest)
        assertEquals("the offload's lower plausibility bound must not move", 1_700_000_000L, boundsOldest)
    }

    @Test
    fun dataRangeSeam_anotherOpcodeIsNotADataRangeReply() {
        val other = dataRangeReply(1_750_000_000L, 1_780_000_000L)
        other[6] = CommandNumber.GET_BATTERY_LEVEL.rawValue.toByte()
        assertFalse(DataRange.acceptsReply(other, 6, CommandNumber.GET_DATA_RANGE.rawValue) { true })
    }

    @Test
    fun rejectedRecordArchive_losesNothingItUsedToKeep() {
        // Every real record fixture: still decodable, so still not archived — the archive grew only
        // by frames that used to be silently dropped.
        val frames = oracle().getJSONArray("frames")
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            val family = if (f.getString("family") == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            val bytes = hexToBytes(f.getString("hex"))
            assertTrue(
                "${f.getString("name")} must still decode into rows",
                rejectedHistoricalRecords(listOf(bytes), family).isEmpty(),
            )
        }
    }

    @Test
    fun captureImport_archivesTheRecordItCanNoLongerDecode() {
        // The capture-import path reaches the same evidence-preserving filter as the live offload, so
        // a record the tightened verdict now refuses is archived there too rather than lost when a
        // user replays a file. Archiving is a side effect of forward-decoding on this platform: the
        // importer never asks a separate reader, it keeps whatever the decoder could not turn into
        // rows.
        val good = historicalWhoop4()
        val bad = breakHeaderChecksum(good, DeviceFamily.WHOOP4)
        val char = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"   // the WHOOP 4.0 notify characteristic
        val json = listOf(good, bad).joinToString(prefix = "[", postfix = "]") { f ->
            """{"hex":"${f.joinToString("") { "%02x".format(it) }}","char":"$char","ts_ms":0,"hr":0}"""
        }

        val decoded = CaptureImporter.decode(CaptureImporter.parse(json))
        val rejects = decoded.rejects[DeviceFamily.WHOOP4].orEmpty()
        assertEquals("the broken-header record is archived, not dropped", 1, rejects.size)
        assertArrayEquals("archived verbatim", bad, rejects[0])
        assertTrue(
            "and the honest record still becomes rows",
            decoded.batches[DeviceFamily.WHOOP4]!!.hr.isNotEmpty(),
        )
    }

    // MARK: - The second verifying path: the ECG payload accessor

    @Test
    fun ecgInnerPayload_inheritsTheCentralBounds() {
        val payload = ByteArray(24) { (it + 1).toByte() }
        val frame = whoop5Frame(payload)
        val inner = Whoop5Ecg.innerPayload(frame)
        assertNotNull("a well-formed frame still yields its payload", inner)
        assertEquals(payload.size + 8 - 11, inner!!.size)

        assertNull(
            "trailing bytes are rejected here exactly as in the central verifier",
            Whoop5Ecg.innerPayload(frame + byteArrayOf(0x00)),
        )
        assertNull("a truncated frame likewise", Whoop5Ecg.innerPayload(frame.copyOf(frame.size - 1)))
        assertNull(
            "and a 12-byte frame is below the family minimum",
            Whoop5Ecg.innerPayload(whoop5Frame(byteArrayOf(1)).copyOf(12)),
        )
        assertNull(
            "a broken header checksum is a rejection here too",
            Whoop5Ecg.innerPayload(breakHeaderChecksum(frame, DeviceFamily.WHOOP5)),
        )
    }

    // MARK: - The three callers of the verifier wrapper keep their useful path

    @Test
    fun featureFlagProbe_stillParsesAWellFormedReply() {
        // START_FF_KEY_EXCHANGE COMMAND_RESPONSE(36) in the WHOOP 4.0 envelope, real checksums:
        // [type][seq][cmd] + [result][resp_seq] + record(revision, count u16).
        val frame = whoop4Frame(
            byteArrayOf(36, 1, FeatureFlagProbe.START_KEY_EXCHANGE_CMD.toByte(), 1, 0, 7, 3, 0),
        )
        val start = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).value
        assertNotNull("the tightened verifier must not turn a well-formed reply away", start)
        assertEquals(7, start!!.revision)
        assertEquals(3, start.count)

        assertEquals(
            "…while a broken header checksum, which used to pass, now fails at the CRC gate",
            FeatureFlagProbe.ParseFailure.CRC,
            FeatureFlagProbe.parseStart(
                breakHeaderChecksum(frame, DeviceFamily.WHOOP4), DeviceFamily.WHOOP4,
            ).failure,
        )
        assertEquals(
            FeatureFlagProbe.ParseFailure.CRC,
            FeatureFlagProbe.parseStart(frame + byteArrayOf(0x00), DeviceFamily.WHOOP4).failure,
        )
    }

    @Test
    fun deviceConfigReadProbe_stillParsesAWellFormedReply() {
        val cmd = DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD
        val frame = whoop4Frame(byteArrayOf(36, 1, cmd.toByte(), 1, 0, 0, 0x41, 0x00))
        val parsed = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP4, cmd)
        assertNotNull("a well-formed reply still decodes", parsed.value)

        assertEquals(
            "…and a broken header checksum now fails at the CRC gate",
            DeviceConfigReadProbe.ParseFailure.CRC,
            DeviceConfigReadProbe.parse(
                breakHeaderChecksum(frame, DeviceFamily.WHOOP4), DeviceFamily.WHOOP4, cmd,
            ).failure,
        )
        assertEquals(
            DeviceConfigReadProbe.ParseFailure.CRC,
            DeviceConfigReadProbe.parse(frame + byteArrayOf(0x00), DeviceFamily.WHOOP4, cmd).failure,
        )
    }

    @Test
    fun rawOpticalDecoder_stillAcceptsItsRealRecord() {
        val stream = javaClass.classLoader!!.getResourceAsStream("r20_optical_oracle.json")
        assertNotNull("r20_optical_oracle.json missing from test classpath", stream)
        val records = JSONObject(stream!!.bufferedReader().use { it.readText() }).getJSONArray("records")
        for (i in 0 until records.length()) {
            val bytes = hexToBytes(records.getJSONObject(i).getString("hex"))
            assertTrue(
                "the real 2,140-byte v20 record must keep a positive verdict",
                Framing.frameCrcOk(bytes, DeviceFamily.WHOOP5),
            )
            assertNotNull("and must still decode", Whoop5RawOptical.decode(bytes))
        }
    }

    // MARK: - Regression: no real recorded frame is rejected by the new bounds

    @Test
    fun everyRecordedFrameFixtureKeepsAPositiveVerdict() {
        val frames = oracle().getJSONArray("frames")
        assertTrue("the fixture must not be empty", frames.length() > 0)
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            val family = if (f.getString("family") == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            val bytes = hexToBytes(f.getString("hex"))
            val p = Framing.parseFrame(bytes, family)
            assertTrue("${f.getString("name")} must stay valid", p.ok)
            assertEquals("${f.getString("name")} carries no reject reason", FrameRejectReason.NONE, p.rejectReason)
            assertTrue(
                "${f.getString("name")} is at or above its family minimum",
                bytes.size >= FrameLimits.minimumFrameBytes(family),
            )
        }
    }
}
