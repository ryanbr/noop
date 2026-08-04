package com.noop.protocol

import com.noop.data.V18AuxCodec
import com.noop.data.V18AuxRow
import com.noop.data.V18AuxSlot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The v18 fields the decoder produced and `extractHistoricalStreams` used to DISCARD (Swift
 * `DeepCaptureChannelsTests` twin).
 *
 * Every expectation is read off the SAME real worn 5/MG frame `Whoop5HistoricalDecodeTest` uses (and
 * that `decoder_oracle.json` pins on both platforms), so nothing here asserts a value the decoder was
 * not already independently proven to produce — these tests are about the STORAGE funnel, which is where
 * the loss happened. The numbers are IDENTICAL to the Swift twin's, which is the parity guarantee.
 */
class DeepCaptureChannelsTest {

    private fun bytes(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Real worn WHOOP 5 v18 frame — the same fixture as Whoop5HistoricalDecodeTest / the Swift tests.
    private val wornV18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    // Synthetic WHOOP 4.0 v24 record (the HistoricalV24 fixture) — must add nothing.
    private val v24 =
        "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
            "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
            "200364006400b80bb80b000000000000c25c1a88"

    private val ts = 1_780_916_150L

    /**
     * The fixture frame with one byte replaced AND its CRC32 trailer recomputed. The reseal matters:
     * `extractHistoricalStreams` skips any frame whose CRC fails, so a mutated frame would otherwise
     * silently test nothing at all. WHOOP5: declaredLength@2, total = len + 8, CRC32 LE at total - 4.
     */
    private fun mutated(index: Int, value: Int): ByteArray {
        val b = bytes(wornV18)
        b[index] = value.toByte()
        val declaredLength = (b[2].toInt() and 0xFF) or ((b[3].toInt() and 0xFF) shl 8)
        val payloadEnd = declaredLength + 8 - 4
        val crc = Crc.crc32(b, 8, payloadEnd)
        for (k in 0 until 4) b[payloadEnd + k] = ((crc ushr (8 * k)) and 0xFFL).toByte()
        return b
    }

    private fun extract(frames: List<ByteArray>) =
        extractHistoricalStreams(frames, ts.toInt(), ts.toInt(), DeviceFamily.WHOOP5)

    // ── The four named channels ──────────────────────────────────────────────────────────────────────

    @Test
    fun dynamicAccelerationRidesTheGravityRow() {
        val g = extract(listOf(bytes(wornV18))).gravity.single()
        assertEquals(0.0091596, g.dynAccel!!, 1e-6)
        // Stored BESIDE the vector, never instead of it — the stager still reads x/y/z.
        assertEquals(1.0, Math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z), 0.05)
    }

    @Test
    fun auxThermalChannelsRideTheSkinTempRow() {
        val s = extract(listOf(bytes(wornV18))).skinTemp.single()
        assertEquals(3057, s.raw)      // primary, unchanged (°C = raw/100 = 30.6)
        assertEquals(247, s.aux1Raw)   // @69, °C = raw/10 = 24.7
        assertEquals(265, s.aux2Raw)   // @71, °C = raw/10 = 26.5
    }

    @Test
    fun sleepStateCarriesTheWholeFlagByteAndStateIsUnchanged() {
        // 0xE9 = 1110 1001: onwrist(b0-1)=1, wake_quality(b2-3)=2, sleep_state(b4-5)=2, reserved(b6-7)=3.
        // The reserved bits are the point: they read 0 on every real capture and have NO interpretation,
        // so a per-nibble store would make them permanently unrecoverable.
        val s = extract(listOf(mutated(81, 0xE9))).sleepState.single()
        assertEquals(0xE9, s.rawByte)
        assertEquals("state must remain (rawByte shr 4) and 3", 2, s.state)
        assertEquals(s.state, (s.rawByte!! shr 4) and 3)
        assertEquals(1, s.rawByte!! and 3)            // onwrist
        assertEquals(2, (s.rawByte!! shr 2) and 3)    // wake_quality
        assertTrue("the fixture must exercise the reserved bits", (s.rawByte!! and 0xC0) != 0)
    }

    @Test
    fun zeroFlagByteIsCarriedNotTreatedAsAbsent() {
        // 0 is a REAL reading (worn daytime wake), not an absent one.
        val s = extract(listOf(bytes(wornV18))).sleepState.single()
        assertEquals(0, s.rawByte)
        assertEquals(0, s.state)
    }

    // ── The remaining v18 slots ──────────────────────────────────────────────────────────────────────

    @Test
    fun everyRemainingV18SlotIsCollected() {
        val a = extract(listOf(bytes(wornV18))).v18Aux.single()
        assertEquals(ts, a.ts)
        assertEquals(25_443_699L, a.recordIndex)     // @11  u32
        assertEquals(2L, a.rrCount)                  // @23  u8
        assertEquals(0L, a.cardiacFlags)             // @33  u8
        assertEquals(141L, a.hrQualityFlags)         // @36  u8 flag byte (0x8D)
        assertEquals(101L, a.heartRateAlt)           // @37  u8 duplicate HR (hr@22 = 102)
        assertEquals(25_444L, a.rrPacked)            // @38  u16
        assertEquals(255L, a.cardiacStatus)          // @40  u8
        assertEquals(170L, a.stepCadence)            // @59  u8
        assertEquals(1_792L, a.statusWord)           // @75  u16
        assertEquals(3_073L, a.statusWord1)          // @77  u16
        assertEquals(3_074L, a.statusWord2)          // @79  u16
        assertEquals(0L, a.auxByte82)                // @82  u8 (raw; the gated 70-100 view is derived)
        assertEquals(101L, a.opticalBaselineA)       // @106 u8
        assertEquals(111L, a.opticalBaselineB)       // @107 u8
        assertEquals(30L, a.opticalAmpA)             // @108 u8
        assertEquals(30L, a.opticalAmpB)             // @109 u8
        // The SAME decimal literal the Swift suite asserts. 0xC0A7619D has bit 31 set, so a 32-bit
        // decoded domain reads it as -1_062_772_323 while Swift's 64-bit Int reads it positive, from
        // byte-identical blobs — the whole reason every slot here is a Long.
        assertEquals(3_232_194_973L, a.unknownF32Bits)  // @113 raw 32-bit pattern, unsigned domain
        assertEquals(-5.2307, a.unknownF32At113!!, 0.001)
    }

    /**
     * EVERY slot's [V18AuxSlot.decoderKey] must exist in a decode of a REAL v18 frame.
     *
     * This is the durable guard, and it exists because of a near-miss. Each slot is extracted with a
     * NULLABLE map lookup — `p.intOrNull(slot.decoderKey)`. If the decoder renames or retires a key, that
     * lookup returns null and the slot banks NOTHING: no compile error, and no visible symptom (absence is
     * a first-class state in the aux format, so an empty slot is indistinguishable from "the strap did not
     * send it"). The result is permanent, silent data loss in a capture format whose entire purpose is
     * preserving fields BEFORE the strap trims them on ack.
     *
     * That is not hypothetical: #861 retired `hr_fixed_8_8` and `optical_baseline_106` — the two keys four
     * of these slots used to read — and nothing in this suite would have failed. This test would have.
     *
     * Twin of the Swift `testEverySlotDecoderKeyExistsInARealV18Decode`.
     */
    @Test
    fun everySlotDecoderKeyExistsInARealV18Decode() {
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertEquals(18, p["hist_version"])   // the guard must run against a v18 decode
        val missing = V18AuxSlot.entries.filter { p[it.decoderKey] == null }
        assertEquals(
            "${missing.size} aux slot(s) read a decoder key the v18 decoder does not emit: " +
                missing.joinToString(", ") { "$it -> \"${it.decoderKey}\"" } +
                ". Those slots bank NOTHING, silently, for every strap-second. Repoint " +
                "V18AuxSlot.decoderKey (and the matching literal in extractHistoricalStreams).",
            emptyList<String>(), missing.map { it.decoderKey },
        )
    }

    /**
     * The same guard one level down: a key that exists is not enough, the value has to REACH the row.
     * [V18AuxSlot.decoderKey] and the extractor's literal are two separate strings that must agree.
     */
    @Test
    fun everySlotIsPopulatedFromARealV18Frame() {
        val a = extract(listOf(bytes(wornV18))).v18Aux.single()
        val values = a.slotValues
        assertEquals(V18AuxSlot.entries.size, values.size)
        val unbanked = V18AuxSlot.entries.filter { values[it.index] == null }
        assertEquals(
            "these slots decoded but never reached V18AuxRow — the extractor's lookup key and " +
                "V18AuxSlot.decoderKey have drifted apart",
            emptyList<String>(), unbanked.map { it.decoderKey },
        )
    }

    /**
     * `@36`/`@37` are TWO bytes, not one u16 — the reading #861 retired. They were banked as a single u16
     * `hr_fixed_8_8` slot ("higher-precision HR, bpm = value/256"). #861 disproved that over 18,650
     * records: bit 4 of `@36` is never set, 95% of its values sit in 0x80-0x8F, and the famous 0.989
     * correlation with `heart_rate@22` was circular — the u16 is just the duplicate HR at `@37` plus a flag
     * byte over 256. Twin of the Swift `testByte36AndByte37AreTwoIndependentSlots`.
     */
    @Test
    fun byte36AndByte37AreTwoIndependentSlots() {
        val a = extract(listOf(bytes(wornV18))).v18Aux.single()
        assertEquals(141L, a.hrQualityFlags)             // 0x8D — the flag byte
        assertEquals(101L, a.heartRateAlt)               // the duplicate HR
        assertEquals(1, V18AuxSlot.HR_QUALITY_FLAGS.width)
        assertEquals(1, V18AuxSlot.HEART_RATE_ALT.width)
        // Bit 7 set = the strap called this second's HR/R-R valid; bit 4 is never set on a real record.
        assertEquals(0x80L, a.hrQualityFlags!! and 0x80L)
        assertEquals(0L, a.hrQualityFlags!! and 0x10L)
        // Independence, proved by moving one byte: under the retired u16 model @37 was worth 256.
        val m = extract(listOf(mutated(37, 0xFF))).v18Aux.single()
        assertEquals(255L, m.heartRateAlt)
        assertEquals("@36 must not move when @37 does", 141L, m.hrQualityFlags)
        // And @37 is not the measured HR: @22 reads 102 while @37 reads 101.
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertEquals(102, p["heart_rate"])
    }

    /**
     * `@106`/`@107` are likewise TWO bytes. #861 showed a u16 there is structurally impossible: across
     * 18,599 consecutive-second pairs the high byte moved while the low byte stayed frozen 3,514 times,
     * with zero low-byte wraps in the corpus. Twin of `testOpticalBaselineIsTwoIndependentSlots`.
     */
    @Test
    fun opticalBaselineIsTwoIndependentSlots() {
        val a = extract(listOf(bytes(wornV18))).v18Aux.single()
        assertEquals(101L, a.opticalBaselineA)           // @106
        assertEquals(111L, a.opticalBaselineB)           // @107
        assertEquals(1, V18AuxSlot.OPTICAL_BASELINE_A.width)
        assertEquals(1, V18AuxSlot.OPTICAL_BASELINE_B.width)
        // Moving @107 must leave @106 alone — under the u16 model that byte was worth 256.
        val m = extract(listOf(mutated(107, 0xFF))).v18Aux.single()
        assertEquals(255L, m.opticalBaselineB)
        assertEquals("@106 must not move when @107 does", 101L, m.opticalBaselineA)
    }

    /**
     * The retired keys must not come back by accident: nothing may read `hr_fixed_8_8` or
     * `optical_baseline_106`, and no slot may re-fuse a byte pair into a 2-byte field.
     */
    @Test
    fun retiredU16ReadingsAreNotResurrected() {
        val retired = setOf("hr_fixed_8_8", "optical_baseline_106")
        for (slot in V18AuxSlot.entries) {
            assertFalse("$slot reads ${slot.decoderKey}, a key #861 retired", slot.decoderKey in retired)
        }
        for (slot in listOf(V18AuxSlot.HR_QUALITY_FLAGS, V18AuxSlot.HEART_RATE_ALT,
                            V18AuxSlot.OPTICAL_BASELINE_A, V18AuxSlot.OPTICAL_BASELINE_B)) {
            assertEquals("$slot is a single wire byte, never half of a u16", 1, slot.width)
        }
    }

    /**
     * The decoded domain must hold an unsigned 32-bit slot. Kotlin's `Int` is 32-bit, so slot values are
     * `Long`; Swift's `Int` is 64-bit and needs no widening. A 32-bit domain on either side silently
     * flips a bit-31 slot negative while the stored bytes stay identical.
     */
    @Test
    fun decodedDomainHoldsAFullU32() {
        assertEquals(4, V18AuxSlot.entries.maxOf { it.width })
        val r = V18AuxRow(ts = 0, recordIndex = 0xFFFF_FFFFL, unknownF32Bits = 0xC0A7_619DL)
        assertEquals(4_294_967_295L, r.recordIndex)
        assertEquals(3_232_194_973L, r.unknownF32Bits)
    }

    @Test
    fun slotValuesOrderMatchesTheSlotEnum() {
        val a = V18AuxRow(
            ts = 1, recordIndex = 10L, rrCount = 11L, cardiacFlags = 12L, hrQualityFlags = 13L,
            heartRateAlt = 14L, rrPacked = 15L, cardiacStatus = 16L, stepCadence = 17L,
            statusWord = 18L, statusWord1 = 19L, statusWord2 = 20L, auxByte82 = 21L,
            opticalBaselineA = 22L, opticalBaselineB = 23L, opticalAmpA = 24L, opticalAmpB = 25L,
            unknownF32Bits = 26L,
        )
        assertEquals(V18AuxSlot.entries.size, a.slotValues.size)
        // Slot i must round-trip to position i — this is what makes the persisted bitmap meaningful.
        assertEquals((10L..26L).toList(), a.slotValues)
        assertEquals(a, V18AuxRow.fromSlotValues(1, a.slotValues))
        // Indices must be a dense 0..<n range in declaration order (bitmap bit positions).
        assertEquals(V18AuxSlot.entries.indices.toList(), V18AuxSlot.entries.map { it.index })
    }

    @Test
    fun shortSlotListLeavesTheTailAbsent() {
        val a = V18AuxRow.fromSlotValues(1, listOf(7L, 8L))
        assertEquals(7L, a.recordIndex)
        assertEquals(8L, a.rrCount)
        assertNull(a.unknownF32Bits)
        assertNull(a.opticalAmpA)
    }

    // ── What must NOT change ─────────────────────────────────────────────────────────────────────────

    @Test
    fun whoop4V24RecordAddsNothing() {
        val s = extractHistoricalStreams(
            listOf(bytes(v24)), 1_700_000_000, 1_700_000_000, DeviceFamily.WHOOP4,
        )
        assertTrue("a 4.0 v24 record must bank no aux row", s.v18Aux.isEmpty())
        assertNull(s.gravity.firstOrNull()?.dynAccel)
        assertNull(s.skinTemp.firstOrNull()?.aux1Raw)
        assertNull(s.skinTemp.firstOrNull()?.aux2Raw)
        // The 4.0 schema DOES emit rr_count, which is why the aux gate keys on hist_version rather than
        // on which keys happen to be present — a presence test would bank a near-empty row per 4.0 second.
        assertEquals(1, decodeHistorical(bytes(v24), DeviceFamily.WHOOP4)!!["rr_count"])
    }

    @Test
    fun auxCollectionIsGatedOnLayoutV18() {
        assertEquals(18, decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!["hist_version"])
        // A v26 (optical PPG) record carries no v18 biometric slots at all.
        assertTrue(extract(listOf(mutated(9, 26))).v18Aux.isEmpty())
    }

    @Test
    fun dynAccelDiagnosticStillFoldsAlongsideTheNewColumn() {
        val s = extract(listOf(bytes(wornV18)))
        assertEquals(1, s.dynAccel.count)
        assertEquals(1, s.gravity.size)
        assertNotNull(s.gravity.single().dynAccel)
    }

    /**
     * Nothing already reachable from a banked field is banked a second time.
     *
     * The name matters (#979). Most of these ARE stored under their own column, but two are not:
     * `motion_wear_quality@63` is the same byte as `activity_class` under a second name, and
     * `spo2_candidate_82` is a gated 70-100 view of `auxByte82`. Neither is persisted in its own
     * right — both are RECOVERABLE from a byte that is, which is equally good grounds for refusing to
     * bank them and not the same claim. The old name asserted each "already has a durable home",
     * which reads as "SpO2 is being stored" and is not true. Twin of the Swift
     * `testNoSlotDuplicatesAFieldAlreadyReachable`.
     */
    @Test
    fun noSlotDuplicatesAFieldAlreadyReachable() {
        val recoverableFromABankedField = setOf(
            "unix", "heart_rate", "rr_intervals", "gravity_x", "gravity_y", "gravity_z",
            "dynamic_acceleration", "skin_temp_raw", "temp_aux_1_raw", "temp_aux_2_raw",
            "step_motion_counter", "activity_class", "motion_wear_quality", "sleep_state",
            "sleep_state_byte", "spo2_candidate_82", "ppg_waveform",
        )
        for (slot in V18AuxSlot.entries) {
            assertFalse(
                "${slot.decoderKey} is already reachable from a banked field — banking it twice is waste",
                slot.decoderKey in recoverableFromABankedField,
            )
        }
    }

    // ── Codec (byte-identical to the Swift V18AuxCodec) ──────────────────────────────────────────────

    @Test
    fun codecHeaderShapeAndSize() {
        val full = V18AuxRow(
            ts = 0, recordIndex = 1L, rrCount = 2L, cardiacFlags = 3L, hrQualityFlags = 4L,
            heartRateAlt = 5L, rrPacked = 6L, cardiacStatus = 7L, stepCadence = 8L, statusWord = 9L,
            statusWord1 = 10L, statusWord2 = 11L, auxByte82 = 12L, opticalBaselineA = 13L,
            opticalBaselineB = 14L, opticalAmpA = 15L, opticalAmpB = 16L, unknownF32Bits = 17L,
        )
        val blob = V18AuxCodec.pack(full)
        assertEquals(V18AuxCodec.FORMAT_VERSION, blob[0].toInt() and 0xFF)
        // Bitmap is a u32 LE with every slot's bit set. It is a u32 and not a u16 because there are 17
        // slots: bit 16 has nowhere to live in two bytes, and a bitmap that silently dropped it would
        // stop banking `unknown_f32_113` on both platforms at once.
        var bitmap = 0
        for (b in 0 until 4) bitmap = bitmap or ((blob[1 + b].toInt() and 0xFF) shl (8 * b))
        assertEquals((1 shl V18AuxSlot.entries.size) - 1, bitmap)
        assertTrue("a u16 bitmap would no longer fit", V18AuxSlot.entries.size > 16)
        // 5-byte header + the sum of the declared slot widths — a full row is 32 bytes.
        assertEquals(5 + V18AuxSlot.entries.sumOf { it.width }, blob.size)
        assertEquals(32, blob.size)
        assertEquals(full, V18AuxCodec.unpack(blob, 0))
    }

    @Test
    fun emptyRowPacksToEmptyArray() {
        assertTrue(V18AuxCodec.pack(V18AuxRow(ts = 0)).isEmpty())
        assertTrue(V18AuxRow(ts = 0).isEmpty)
    }

    @Test
    fun malformedBlobsDegradeToAbsentRatherThanThrow() {
        assertTrue(V18AuxCodec.unpack(ByteArray(0), 5).isEmpty)
        assertTrue(V18AuxCodec.unpack(byteArrayOf(2, -1, -1), 5).isEmpty)                // header cut short
        assertTrue(V18AuxCodec.unpack(byteArrayOf(99, -1, -1, -1, -1, 1, 2), 5).isEmpty)  // future version
        // A v1 blob (the pre-#861 layout, u16 bitmap and fused @36/@106 u16 slots) is an UNKNOWN version
        // to a v2 reader, so it reads back as "nothing known" instead of being sliced against the wrong
        // slot table. The format never shipped, so the only such rows possible are on a local build.
        assertTrue(V18AuxCodec.unpack(byteArrayOf(1, -1, 0x7F, 1, 2, 3, 4), 5).isEmpty)
        // Truncated body: bitmap 0b0110 claims slots 1 and 2 (1 byte each) but only one body byte
        // follows — slot 1 decodes and slot 2 must read absent rather than borrowing a byte.
        val partial = V18AuxCodec.unpack(byteArrayOf(2, 0b0000_0110, 0, 0, 0, 42), 5)
        assertEquals(42L, partial.rrCount)
        assertNull(partial.cardiacFlags)
        assertEquals(5L, partial.ts)
    }

    /**
     * A 4-byte slot must survive at full width AND decode to the same NUMBER Swift decodes. Both fixtures
     * have bit 31 set, which is the case a 32-bit decoded domain gets wrong — the literals below are the
     * Swift suite's, verbatim.
     */
    @Test
    fun wideSlotsSurviveAtFullWidth() {
        val r = V18AuxRow(ts = 0, recordIndex = 4_275_878_552L, unknownF32Bits = 3_232_194_973L)
        val back = V18AuxCodec.unpack(V18AuxCodec.pack(r), 0)
        assertEquals(4_275_878_552L, back.recordIndex)   // 0xFEDCBA98
        assertEquals(3_232_194_973L, back.unknownF32Bits) // 0xC0A7619D
        assertTrue("both fixtures must exercise bit 31", back.recordIndex!! > Int.MAX_VALUE)
    }

    /**
     * The exact bytes the Swift codec produces for the real fixture's slots. Hard-coded rather than
     * derived, so a one-sided edit to either codec's layout fails HERE instead of silently writing blobs
     * the other platform cannot read out of a `.noopbak`.
     */
    @Test
    fun fixtureRowPacksToTheExactCrossPlatformBytes() {
        val a = V18AuxRow(
            ts = ts, recordIndex = 25_443_699L, rrCount = 2L, cardiacFlags = 0L, hrQualityFlags = 141L,
            heartRateAlt = 101L, rrPacked = 25_444L, cardiacStatus = 255L, stepCadence = 170L,
            statusWord = 1_792L, statusWord1 = 3_073L, statusWord2 = 3_074L, auxByte82 = 0L,
            opticalBaselineA = 101L, opticalBaselineB = 111L, opticalAmpA = 30L, opticalAmpB = 30L,
            unknownF32Bits = 3_232_194_973L,
        )
        val hex = V18AuxCodec.pack(a).joinToString("") { "%02x".format(it) }
        // The BODY is byte-for-byte what v1 wrote: splitting @36/@37 and @106/@107 out of their fused u16
        // slots emits the same two bytes in the same order (a LE u16 is its low byte then its high byte).
        // Only the header moved — version 1 -> 2, and a u16 bitmap -> u32 because 17 slots need 17 bits.
        assertEquals(
            "02ffff0100" +      // version 2, bitmap 0x0001FFFF u32 LE (all 17 slots present)
                "733d8401" +    // record_index      25443699 u32 LE
                "02" +          // rr_count          2
                "00" +          // cardiac_flags     0
                "8d" +          // hr_quality_flags  141 (0x8D) @36
                "65" +          // heart_rate_alt    101        @37
                "6463" +        // rr_packed         25444 u16 LE
                "ff" +          // cardiac_status    255
                "aa" +          // step_cadence      170
                "0007" +        // status_word       1792 u16 LE
                "010c" +        // status_word_1     3073 u16 LE
                "020c" +        // status_word_2     3074 u16 LE
                "00" +          // aux_byte_82       0
                "65" +          // optical_baseline_a 101       @106
                "6f" +          // optical_baseline_b 111       @107
                "1e" +          // optical_amp_a     30
                "1e" +          // optical_amp_b     30
                "9d61a7c0",     // unknown_f32_113 bits 0xC0A7619D u32 LE
            hex,
        )
    }
}
