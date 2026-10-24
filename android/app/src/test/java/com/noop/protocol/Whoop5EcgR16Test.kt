package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #891: the flash-banked ECG record — type 47 HISTORICAL_DATA, data revision 16, 1584 bytes.
 *
 * Twin of the Swift `Whoop5EcgR16Tests`. The layout is a protocol fact, so both platforms carry the decode
 * and both pin it; a test only on the side that happens to call it today would not stop the other drifting.
 *
 * Fixtures here are SYNTHETIC, built from the layout in `docs/PROTOCOL_ECG.md`. They verify the decoder
 * against the documented contract. They are not a hardware measurement and nothing here establishes volts
 * per count, a sample rate, or anything clinical.
 */
class Whoop5EcgR16Test {

    /**
     * A complete, CRC-valid R16 frame.
     *
     * [slots] are written as raw three-byte groups from the waveform offset, so a test can plant exact tag
     * bytes rather than go through the decoder's own arithmetic to build its input.
     */
    private fun r16Frame(
        declaredCount: Int,
        slots: List<Triple<Int, Int, Int>> = emptyList(),
        leadsOffCount: Int = 10,
        leadsI: List<Int> = emptyList(),
        leadsQ: List<Int> = emptyList(),
        liveHR: Int = 0,
        revision: Int = Whoop5Ecg.R16_REVISION,
        type: Int = Whoop5Ecg.STORED_RECORD_TYPE,
        alignment: Int = 0,
    ): ByteArray {
        val inner = IntArray(Whoop5Ecg.R16_INNER_LENGTH)
        inner[0] = type
        inner[1] = revision
        inner[2] = 0x5a                                  // headerSecondary
        put32(inner, 3, 0x0001_2345)                     // sequence / record index
        put32(inner, 7, 0x6543_0001)                     // strapSeconds
        put16(inner, 11, 16_384)                         // subseconds
        inner[13] = 3                                    // quality
        inner[14] = 0x08                                 // flags: presence
        inner[15] = 1                                    // arrhythmia check result
        inner[16] = 2                                    // classifier state (terminal)
        inner[17] = 100                                  // progress (terminal)
        inner[18] = 0x00                                 // unreadable mask
        inner[19] = 64                                   // averageHR
        inner[20] = liveHR
        put16(inner, 21, 42)                             // variability
        inner[23] = 0                                    // reserved
        put16(inner, 24, declaredCount)
        for ((i, s) in slots.withIndex()) {
            val o = Whoop5Ecg.R16_SAMPLE_START + i * Whoop5Ecg.R16_SAMPLE_SLOT_BYTES
            if (o + 2 >= Whoop5Ecg.R16_LEADS_OFF_COUNT_OFFSET) break
            inner[o] = s.first; inner[o + 1] = s.second; inner[o + 2] = s.third
        }
        inner[Whoop5Ecg.R16_LEADS_OFF_COUNT_OFFSET] = leadsOffCount
        for ((i, v) in leadsI.withIndex()) {
            if (i >= Whoop5Ecg.R16_LEADS_OFF_SLOTS) break
            put16(inner, Whoop5Ecg.R16_LEADS_OFF_I_START + i * 2, v)
        }
        for ((i, v) in leadsQ.withIndex()) {
            if (i >= Whoop5Ecg.R16_LEADS_OFF_SLOTS) break
            put16(inner, Whoop5Ecg.R16_LEADS_OFF_Q_START + i * 2, v)
        }
        inner[Whoop5Ecg.R16_ALIGNMENT_OFFSET] = alignment
        return Framing.puffinCommandFrame(
            cmd = inner[2],
            seq = inner[1],
            payload = ByteArray(inner.size - 3) { inner[it + 3].toByte() },
            type = inner[0],
        )
    }

    private fun put16(b: IntArray, i: Int, v: Int) {
        b[i] = v and 0xff; b[i + 1] = (v shr 8) and 0xff
    }

    private fun put32(b: IntArray, i: Int, v: Int) {
        for (k in 0 until 4) b[i + k] = (v shr (8 * k)) and 0xff
    }

    // Framing

    @Test
    fun theFixtureBuilderProducesTheDocumentedFrameAndInnerLengths() {
        val f = r16Frame(0)
        assertEquals(Whoop5Ecg.R16_RECORD_LENGTH, f.size)
        assertEquals(12, Whoop5Ecg.R16_RECORD_LENGTH - Whoop5Ecg.R16_INNER_LENGTH)  // 8 envelope + 4 CRC32
        assertTrue(Framing.verifyFrame(f, DeviceFamily.WHOOP5).ok)
        assertTrue(Whoop5Ecg.isR16Record(f))
        assertNotNull(Whoop5Ecg.r16FromFrame(f))
    }

    @Test
    fun aCorruptFrameIsRefusedBeforeAnyFieldIsRead() {
        val f = r16Frame(1, listOf(Triple(0x80, 0x01, 0x02)))
        assertNotNull(Whoop5Ecg.r16FromFrame(f))
        f[600] = (f[600].toInt() xor 0xff).toByte()      // flip a waveform byte, breaking the CRC32
        assertNull(Whoop5Ecg.r16FromFrame(f))
    }

    @Test
    fun onlyType47Revision16IsAnR16Record() {
        assertNull(Whoop5Ecg.r16FromFrame(r16Frame(0, revision = 17)))
        assertNull(Whoop5Ecg.r16FromFrame(r16Frame(0, type = 43)))
        assertFalse(Whoop5Ecg.isR16Record(r16Frame(0, revision = 17)))
        // An R17 frame must not decode as an R16, and vice versa: the two revisions share a header and are
        // told apart ONLY by inner[1], so a decoder that ignored it would read 240 bytes as 1584.
        assertNull(Whoop5Ecg.parseR16(List(228) { 0 }))
    }

    @Test
    fun aShortInnerRecordIsRefusedRatherThanDecodedWithAShrunkSampleBlock() {
        // R17 derives its extent from the declared count; R16 cannot. Every region after the waveform is
        // at a FIXED offset, so decoding a short buffer would read the lead-off arrays from inside the
        // waveform and report them as diagnostics.
        val inner = MutableList(Whoop5Ecg.R16_INNER_LENGTH - 1) { 0 }
        inner[0] = Whoop5Ecg.STORED_RECORD_TYPE
        inner[1] = Whoop5Ecg.R16_REVISION
        assertNull(Whoop5Ecg.parseR16(inner))
    }

    // Sample coding

    @Test
    fun samplesAreBigEndianEighteenBitTwosComplement() {
        // The documented rule: raw18 = ((b0 & 3) shl 16) or (b1 shl 8) or b2, then sign-extend at 18 bits.
        // Tag bits 7/6 are flags and bits 2-5 reserved, so a tag of 0xFF must not reach the value.
        val cases = listOf(
            Triple(0x00, 0x00, 0x00) to 0,
            Triple(0x00, 0x00, 0x01) to 1,
            Triple(0x00, 0x01, 0x00) to 256,
            Triple(0x01, 0x00, 0x00) to 65_536,
            Triple(0x01, 0xff, 0xff) to 131_071,         // the largest positive value
            Triple(0x02, 0x00, 0x00) to -131_072,        // the sign threshold itself
            Triple(0x03, 0xff, 0xff) to -1,              // all 18 bits set
            Triple(0xfc, 0x12, 0x34) to 0x1234,          // flags + reserved set, value bits clear
        )
        for ((slot, expected) in cases) {
            val got = Whoop5Ecg.r16FromFrame(r16Frame(1, listOf(slot)))
            assertEquals("slot $slot", expected, got!!.samples[0])
        }
    }

    @Test
    fun theCodingRangeIsExactlyEighteenSignedBits() {
        assertEquals(131_072, Whoop5Ecg.R16_SAMPLE_SIGN_THRESHOLD)
        assertEquals(262_144, Whoop5Ecg.R16_SAMPLE_MODULUS)
        assertEquals(Whoop5Ecg.R16_SAMPLE_SIGN_THRESHOLD * 2, Whoop5Ecg.R16_SAMPLE_MODULUS)
    }

    @Test
    fun readingASlotAsLittleEndianInt16WouldBeADifferentNumber() {
        // Pinned as a NEGATIVE: this is the misdecode that puts a ~65,000-count cliff at every zero
        // crossing, and it is worth a test that the right answer is not the wrong one by coincidence.
        val got = Whoop5Ecg.r16FromFrame(r16Frame(1, listOf(Triple(0x03, 0xff, 0xfe))))
        assertEquals(-2, got!!.samples[0])
        val littleEndian = (0xff or (0xfe shl 8)).let { if (it >= 0x8000) it - 0x10000 else it }
        assertTrue(littleEndian != got.samples[0])
    }

    // Counts and capacity

    @Test
    fun aFullRecordCarriesFiveHundredSamples() {
        val slots = ArrayList<Triple<Int, Int, Int>>()
        for (i in 0 until 500) {
            slots.add(Triple((i shr 16) and 0x03, (i shr 8) and 0xff, i and 0xff))
        }
        val got = Whoop5Ecg.r16FromFrame(r16Frame(500, slots))!!
        assertEquals(500, got.sampleCount)
        assertEquals(500, got.samples.size)
        assertEquals(0, got.samples.first())
        assertEquals(499, got.samples.last())
        assertEquals(500, Whoop5Ecg.R16_MAX_SAMPLES)
    }

    @Test
    fun aShortAndAnEmptyCountAreBothValid() {
        // The opening records of a real run declare 0 and then 245 before the first full 500.
        for (n in listOf(0, 245, 499)) {
            val got = Whoop5Ecg.r16FromFrame(r16Frame(n))!!
            assertEquals("declared $n", n, got.samples.size)
            assertEquals("declared $n", n, got.sampleTags.size)
        }
    }

    @Test
    fun aDeclaredCountAboveCapacityIsRefused() {
        assertNull(Whoop5Ecg.r16FromFrame(r16Frame(501)))
        assertNull(Whoop5Ecg.r16FromFrame(r16Frame(0xffff)))
    }

    @Test
    fun theWaveformRegionStopsBeforeTheLeadOffTrailer() {
        // 500 slots of 3 bytes from offset 26 ends exactly where the lead-off count begins. If these two
        // ever disagree a full record would decode its own diagnostics as waveform.
        assertEquals(
            Whoop5Ecg.R16_LEADS_OFF_COUNT_OFFSET,
            Whoop5Ecg.R16_SAMPLE_START + Whoop5Ecg.R16_MAX_SAMPLES * Whoop5Ecg.R16_SAMPLE_SLOT_BYTES,
        )
    }

    // Flags

    @Test
    fun flagSixAndFlagSevenAndReservedBitsComeFromTheTagByte() {
        val got = Whoop5Ecg.r16FromFrame(
            r16Frame(
                4,
                listOf(
                    Triple(0x00, 0, 0),   // neither flag
                    Triple(0x40, 0, 0),   // flag 6 only
                    Triple(0x80, 0, 0),   // flag 7 only
                    Triple(0x3c, 0, 0),   // reserved bits 2-5 only
                ),
            ),
        )!!
        assertEquals(false, got.flag6(0))
        assertEquals(false, got.flag7(0))
        assertEquals(true, got.flag6(1))
        assertEquals(false, got.flag7(1))
        assertEquals(false, got.flag6(2))
        assertEquals(true, got.flag7(2))
        assertEquals(0x0f, got.reservedBits(3))
        assertEquals(0, got.reservedBits(0))
        // Out of range reads null rather than throwing or inventing a value.
        assertNull(got.flag6(4))
        assertNull(got.flag7(-1))
        assertNull(got.reservedBits(99))
    }

    @Test
    fun theTagByteIsRetainedWholeSoNothingIsDiscarded() {
        val got = Whoop5Ecg.r16FromFrame(r16Frame(1, listOf(Triple(0xff, 0, 0))))!!
        assertEquals(0xff, got.sampleTags[0])
    }

    // The flag-7 grouping

    @Test
    fun theLeadStateGroupingIsFiftyOneThenEightOfFiftyThenFortyNine() {
        // The documented 500-raw / 10-slower mapping. The boundary sample keeps the EARLIER entry before
        // the index advances, so entry 0 covers 0..50 — 51 samples, not 50. Ten equal groups of 50 is the
        // wrong answer the doc explicitly tells implementers not to substitute.
        val got = Whoop5Ecg.r16FromFrame(r16Frame(500, leadsOffCount = 10))!!
        assertEquals(0, got.leadStateGroup(0))
        assertEquals(0, got.leadStateGroup(50))
        assertEquals(1, got.leadStateGroup(51))
        assertEquals(1, got.leadStateGroup(100))
        assertEquals(2, got.leadStateGroup(101))
        assertEquals(8, got.leadStateGroup(450))
        assertEquals(9, got.leadStateGroup(451))
        assertEquals(9, got.leadStateGroup(499))

        // And the group sizes that mapping implies, counted rather than asserted by hand.
        val sizes = IntArray(10)
        for (i in 0 until 500) sizes[got.leadStateGroup(i)!!] += 1
        assertEquals(51, sizes[0])
        assertEquals(49, sizes[9])
        for (g in 1..8) assertEquals("group $g", 50, sizes[g])
        assertEquals(500, sizes.sum())
    }

    @Test
    fun theGroupingIsNotOfferedWhereItIsNotEstablished() {
        // A zero count omits flag-7 insertion, and nonzero counts other than ten are not attested as input
        // to the rule. Null is the honest answer; a divisor computed anyway would be invented — and a real
        // strap sends 11 often enough that guessing would misreport live records.
        for (count in listOf(0, 1, 9, 11)) {
            val got = Whoop5Ecg.r16FromFrame(r16Frame(500, leadsOffCount = count))!!
            assertNull("count $count", got.leadStateGroup(0))
        }
        // Nor for a record that is not a full 500, which is the only raw count the table covers.
        val short = Whoop5Ecg.r16FromFrame(r16Frame(245, leadsOffCount = 10))!!
        assertNull(short.leadStateGroup(0))
        assertNull(short.leadStateGroup(500))
    }

    // Lead-off diagnostics

    @Test
    fun theLeadOffArraysAreAtFixedOffsetsAndDoNotMoveWithEitherCount() {
        val i = ArrayList<Int>()
        val q = ArrayList<Int>()
        for (k in 0 until Whoop5Ecg.R16_LEADS_OFF_SLOTS) { i.add(1000 + k); q.add(2000 + k) }
        // Declared waveform count of ZERO: a `header + count * width` formula would place the arrays at
        // offset 26 and read zeros. They are fixed, so they are still here.
        val got = Whoop5Ecg.r16FromFrame(r16Frame(0, leadsI = i, leadsQ = q))!!
        assertEquals(i, got.leadsOffIRaw)
        assertEquals(q, got.leadsOffQRaw)
        assertEquals(Whoop5Ecg.R16_LEADS_OFF_SLOTS, got.leadsOffIRaw.size)
        assertEquals(Whoop5Ecg.R16_LEADS_OFF_SLOTS, got.leadsOffQRaw.size)

        // And identical on a full record, which is what "fixed" means.
        val full = Whoop5Ecg.r16FromFrame(r16Frame(500, leadsI = i, leadsQ = q))!!
        assertEquals(i, full.leadsOffIRaw)
        assertEquals(q, full.leadsOffQRaw)
    }

    /**
     * The halfwords are read little-endian, which `docs/PROTOCOL_ECG.md` does not state and which the
     * waveform slots in the same record contradict. Pinned against the frame's OWN bytes rather than
     * against the fixture's writer, so the chosen reading is a visible decision and flipping it fails
     * here: `put16` is little-endian too, so a round-trip through it would pin nothing.
     */
    @Test
    fun theLeadOffHalfwordsAreReadLittleEndianByChoice() {
        val i = MutableList(Whoop5Ecg.R16_LEADS_OFF_SLOTS) { 0 }
        val q = MutableList(Whoop5Ecg.R16_LEADS_OFF_SLOTS) { 0 }
        i[0] = 0x1234
        q[0] = 0xABCD
        val frame = r16Frame(0, leadsI = i, leadsQ = q)

        // What is actually on the wire, read straight out of the frame.
        val iByte = Whoop5Ecg.RAW_TYPE_OFFSET + Whoop5Ecg.R16_LEADS_OFF_I_START
        val qByte = Whoop5Ecg.RAW_TYPE_OFFSET + Whoop5Ecg.R16_LEADS_OFF_Q_START
        assertEquals(0x34, frame[iByte].toInt() and 0xFF)
        assertEquals(0x12, frame[iByte + 1].toInt() and 0xFF)
        assertEquals(0xCD, frame[qByte].toInt() and 0xFF)
        assertEquals(0xAB, frame[qByte + 1].toInt() and 0xFF)

        // Low byte at the lower address, so these and not 0x3412 / 0xCDAB.
        val got = Whoop5Ecg.r16FromFrame(frame)!!
        assertEquals(0x1234, got.leadsOffIRaw[0])
        assertEquals(0xABCD, got.leadsOffQRaw[0])
    }

    @Test
    fun theTwoLeadOffChannelsDoNotOverlap() {
        assertEquals(
            Whoop5Ecg.R16_LEADS_OFF_Q_START,
            Whoop5Ecg.R16_LEADS_OFF_I_START + Whoop5Ecg.R16_LEADS_OFF_SLOTS * 2,
        )
        assertEquals(
            Whoop5Ecg.R16_ALIGNMENT_OFFSET,
            Whoop5Ecg.R16_LEADS_OFF_Q_START + Whoop5Ecg.R16_LEADS_OFF_SLOTS * 2,
        )
        assertEquals(Whoop5Ecg.R16_INNER_LENGTH, Whoop5Ecg.R16_ALIGNMENT_OFFSET + 1)
    }

    @Test
    fun anOverCapacityLeadOffCountIsReportedNotClamped() {
        // Clamping would invent a count the strap never sent. The record still decodes — the arrays are at
        // fixed offsets, so a bad count cannot corrupt the waveform — and the anomaly is surfaced.
        val got = Whoop5Ecg.r16FromFrame(r16Frame(500, leadsOffCount = 12))!!
        assertEquals(12, got.leadsOffCountRaw)
        assertFalse(got.leadsOffCountWithinCapacity)
        assertEquals(500, got.samples.size)
        assertEquals(Whoop5Ecg.R16_LEADS_OFF_SLOTS, got.leadsOffIRaw.size)

        val ok = Whoop5Ecg.r16FromFrame(r16Frame(500, leadsOffCount = 11))!!
        assertTrue(ok.leadsOffCountWithinCapacity)
    }

    @Test
    fun theAlignmentByteIsCarriedRatherThanAssumed() {
        assertEquals(0, Whoop5Ecg.r16FromFrame(r16Frame(0))!!.alignmentByte)
        // Documented as zero; carried verbatim so a caller can see when it is not.
        assertEquals(7, Whoop5Ecg.r16FromFrame(r16Frame(0, alignment = 7))!!.alignmentByte)
    }

    // The shared status header

    @Test
    fun theStatusHeaderDecodesIdenticallyToR17() {
        // R16 and R17 share their status region byte for byte. The two decoders read it with their own
        // expressions rather than one shared reader, because `parseR17` is the live path; this is what
        // stops them drifting.
        val r16 = Whoop5Ecg.r16FromFrame(r16Frame(0, liveHR = 71))!!

        val inner17 = MutableList(228) { 0 }
        inner17[0] = Whoop5Ecg.RAW_RECORD_TYPE
        inner17[1] = Whoop5Ecg.R17_REVISION
        inner17[2] = 0x5a
        for (k in 0 until 4) inner17[3 + k] = (0x0001_2345 shr (8 * k)) and 0xff
        for (k in 0 until 4) inner17[7 + k] = (0x6543_0001 shr (8 * k)) and 0xff
        inner17[11] = 16_384 and 0xff
        inner17[12] = (16_384 shr 8) and 0xff
        inner17[13] = 3
        inner17[14] = 0x08
        inner17[15] = 1
        inner17[16] = 2
        inner17[17] = 100
        inner17[18] = 0x00
        inner17[19] = 64
        inner17[20] = 71
        inner17[21] = 42
        inner17[23] = 0
        val r17 = Whoop5Ecg.parseR17(inner17)!!

        assertEquals(r17.headerSecondary, r16.headerSecondary)
        assertEquals(r17.sequence, r16.sequence)
        assertEquals(r17.strapSeconds, r16.strapSeconds)
        assertEquals(r17.subseconds, r16.subseconds)
        assertEquals(r17.signalQualityRaw, r16.signalQualityRaw)
        assertEquals(r17.signalQuality, r16.signalQuality)
        assertEquals(r17.flags, r16.flags)
        assertEquals(r17.presence, r16.presence)
        assertEquals(r17.arrhythmiaCheckResultRaw, r16.arrhythmiaCheckResultRaw)
        assertEquals(r17.arrhythmiaCheckResult, r16.arrhythmiaCheckResult)
        assertEquals(r17.classifierState, r16.classifierState)
        assertEquals(r17.progress, r16.progress)
        assertEquals(r17.unreadable, r16.unreadable)
        assertEquals(r17.averageHR, r16.averageHR)
        assertEquals(r17.liveHR, r16.liveHR)
        assertEquals(r17.variabilityRaw, r16.variabilityRaw)
        assertEquals(r17.reserved, r16.reserved)
        assertEquals(r17.isTerminal, r16.isTerminal)
        assertEquals(r17.isInvalid, r16.isInvalid)
    }

    @Test
    fun theSampleBlockBeginsAtTheSameOffsetAsR17() {
        assertEquals(Whoop5Ecg.R17_SAMPLE_START, Whoop5Ecg.R16_SAMPLE_START)
        assertEquals(Whoop5Ecg.R17_FIXED_LENGTH, Whoop5Ecg.R16_SAMPLE_START)
    }

    @Test
    fun theUnavailableVariabilitySentinelIsSharedWithR17() {
        // inner[21..22] is frame[29..30].
        val inner = IntArray(Whoop5Ecg.R16_INNER_LENGTH)
        inner[0] = Whoop5Ecg.STORED_RECORD_TYPE
        inner[1] = Whoop5Ecg.R16_REVISION
        inner[21] = 0xff
        inner[22] = 0xff
        val f = Framing.puffinCommandFrame(
            cmd = inner[2],
            seq = inner[1],
            payload = ByteArray(inner.size - 3) { inner[it + 3].toByte() },
            type = inner[0],
        )
        assertNull(Whoop5Ecg.r16FromFrame(f)!!.variabilityRaw)
    }

    // What this record is not

    @Test
    fun nothingHereClaimsARateOrAVoltage() {
        // A guard on the module's own vocabulary. The R16 decode establishes coding and structure; the
        // moment a constant here names volts, millivolts or a sample rate, that is a claim the thread's
        // evidence does not support and it should fail review rather than ship quietly.
        val got = Whoop5Ecg.r16FromFrame(r16Frame(1, listOf(Triple(0x00, 0x01, 0x00))))!!
        assertEquals(256, got.samples[0])                // counts, not microvolts
        assertEquals(500, Whoop5Ecg.R16_MAX_SAMPLES)     // slots per record, not samples per second
    }
}
