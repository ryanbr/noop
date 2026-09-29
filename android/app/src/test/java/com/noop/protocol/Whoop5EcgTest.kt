package com.noop.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WHOOP MG ECG ("Labrador") decode + command construction — the Kotlin twin of
 * WhoopProtocolTests/Whoop5EcgTests.swift. Same synthetic fixtures, same expected outputs, so the two
 * decoders cannot drift.
 *
 * Every fixture is SYNTHETIC: no WHOOP MG ECG capture exists in this repo, and inventing one would be
 * worse than having none. What is pinned here is the structural contract a capture cannot change — field
 * order and widths, the length agreement between numberOfECGSamples and the sample array, fail-closed
 * behaviour on truncation and bad CRC, and the exact command bytes.
 */
class Whoop5EcgTest {

    private fun header(
        signalQuality: Int = 2,
        statusFlags: Int = 0x05,
        started: Int = 1,
        running: Int = 1,
        stoppedAndComplete: Int = 0,
        leadsOn: Int = 1,
        arrhythmiaResult: Int = 0,
        arrhythmiaStatus: Int = 1,
        progress: Int = 42,
        unreadableReason: Int = 0,
        averageHR: Int = 61,
        hr: Int = 63,
        hrv: Int = 812,
        stress: Int = 17,
        samples: Int,
    ): List<Int> = listOf(
        signalQuality, statusFlags, started, running, stoppedAndComplete, leadsOn,
        arrhythmiaResult, arrhythmiaStatus, progress, unreadableReason, averageHR, hr,
        hrv and 0xFF, (hrv shr 8) and 0xFF, stress,
        samples and 0xFF, (samples shr 8) and 0xFF,
    )

    /**
     * A revision-17 INNER record, in wire order: `inner[0]` type, `inner[1]` revision, fixed fields
     * through `inner[25]`, then the samples.
     *
     * Note what `inner[1]` and `inner[2]` are NOT. On a COMMAND frame those offsets are the sequence and
     * the opcode, which is what the `[8]type [9]seq [10]cmd` comment in the decoder describes. A DATA
     * record reuses the same two bytes for the data revision and a context marker — which is why a
     * decoder that started reading fields at `frame[11]` was six bytes off.
     */
    private fun r17Inner(
        type: Int = 43,
        revision: Int = 17,
        headerSecondary: Int = 0,
        sequence: Long = 7,
        strapSeconds: Long = 1_700_000_000,
        subseconds: Int = 16_384,
        quality: Int = 2,
        flags: Int = 0x0A,
        result: Int = 0,
        state: Int = 1,
        progress: Int = 42,
        unreadable: Int = 0,
        averageHR: Int = 61,
        liveHR: Int = 63,
        variability: Int = 812,
        reserved: Int = 17,
        samples: Int,
    ): List<Int> = buildList {
        add(type); add(revision); add(headerSecondary)
        for (i in 0 until 4) add(((sequence shr (8 * i)) and 0xFF).toInt())
        for (i in 0 until 4) add(((strapSeconds shr (8 * i)) and 0xFF).toInt())
        add(subseconds and 0xFF); add((subseconds shr 8) and 0xFF)
        add(quality); add(flags); add(result); add(state); add(progress); add(unreadable)
        add(averageHR); add(liveHR)
        add(variability and 0xFF); add((variability shr 8) and 0xFF)
        add(reserved)
        add(samples and 0xFF); add((samples shr 8) and 0xFF)
    }

    /**
     * "Does this frame decode as an R17?" — a TEST-local predicate over the product entry point.
     *
     * Deliberately not a shipped helper: the probe calls [Whoop5Ecg.r17FromFrame] and uses the packet,
     * so a separate boolean wrapper in the protocol object would be a declaration nothing runs.
     */
    private fun r17IsRecognised(frame: ByteArray, allowStored: Boolean = false): Boolean =
        Whoop5Ecg.r17FromFrame(frame, allowStored) != null

    /**
     * Wrap an inner record in a valid puffin envelope. The inner record starts at `frame[8]`, so the
     * builder takes everything from the type byte onwards.
     */
    private fun r17Frame(inner: List<Int>): ByteArray =
        Framing.puffinCommandFrame(
            cmd = if (inner.size > 2) inner[2] else 0,
            seq = if (inner.size > 1) inner[1] else 0,
            payload = inner.drop(3).map { it.toByte() }.toByteArray(),
            type = inner[0],
        )

    private fun i16le(values: List<Int>): List<Int> =
        values.flatMap { listOf(it and 0xFF, (it shr 8) and 0xFF) }

    private fun u16le(values: List<Int>): List<Int> =
        values.flatMap { listOf(it and 0xFF, (it shr 8) and 0xFF) }

    private fun puffinFrame(type: Int, payload: List<Int>): ByteArray =
        Framing.puffinCommandFrame(
            cmd = 0x00, seq = 0x01,
            payload = payload.map { it.toByte() }.toByteArray(),
            type = type,
        )

    // MARK: - Revision-17 packet

    @Test
    fun r17DecodesEveryFieldInWireOrder() {
        val samples = listOf(0, 1, -1, 32_767, -32_768, 250, -250)
        val packet = Whoop5Ecg.parseR17(r17Inner(samples = samples.size) + i16le(samples))
        assertNotNull(packet)
        packet!!

        assertEquals(43, packet.packetType)
        assertEquals(0, packet.headerSecondary)
        assertEquals(7L, packet.sequence)
        assertEquals(1_700_000_000L, packet.strapSeconds)
        assertEquals(16_384, packet.subseconds)
        assertEquals(EcgSignalQuality.MEDIUM, packet.signalQuality)
        assertEquals(2, packet.signalQualityRaw)
        assertEquals(0x0A, packet.flags.raw)
        assertEquals(EcgArrhythmiaCheckResult.NOT_COMPLETE, packet.arrhythmiaCheckResult)
        assertEquals(0, packet.arrhythmiaCheckResultRaw)
        assertEquals(1, packet.classifierState)
        assertEquals(42, packet.progress.percentValue)
        assertEquals(0, packet.unreadable.raw)
        assertEquals(61, packet.averageHR)
        assertEquals(63, packet.liveHR)
        assertEquals(812, packet.variabilityRaw)              // u16 LE, not two u8s
        assertEquals(17, packet.reserved)
        assertEquals(7, packet.sampleCount)
        assertEquals(samples, packet.samples)                 // signed, LE
        assertTrue(packet.tail.isEmpty())
    }

    /**
     * The offset that says the source-closed layout and the layout OBSERVED on hardware are the same
     * record. RAW_WAVEFORM_START was measured on an MG before any of this was decoded; it has to equal
     * where the R17 sample block begins, or one of the two readings is wrong.
     */
    @Test
    fun theObservedWaveformOffsetEqualsTheR17SampleStart() {
        assertEquals(Whoop5Ecg.RAW_WAVEFORM_START, Whoop5Ecg.RAW_TYPE_OFFSET + Whoop5Ecg.R17_SAMPLE_START)
    }

    @Test
    fun r17FlagsDecodeBitByBit() {
        assertTrue(EcgLabradorFlags(0x01).enteringStateOne)
        assertTrue(EcgLabradorFlags(0x02).currentStateOne)
        assertTrue(EcgLabradorFlags(0x04).stateTransitionOneToTwo)
        assertTrue(EcgLabradorFlags(0x08).presence)
        assertFalse(EcgLabradorFlags(0x07).presence)
        // 0x0c is the terminal frame's physically observed value: transition set, presence set.
        val terminal = EcgLabradorFlags(0x0C)
        assertTrue(terminal.stateTransitionOneToTwo)
        assertTrue(terminal.presence)
        assertFalse(terminal.currentStateOne)
    }

    /**
     * The bug the whole layout correction is about, pinned as a value.
     *
     * The superseded triage required `payload[4] <= 1 && payload[5] <= 1`. Those two bytes are this
     * record's quality (0..3) and flags. A packet reporting electrode contact has `0x08` set in flags, so
     * it could never satisfy that check — every packet carrying a real reading was discarded.
     */
    @Test
    fun aPresencePositivePacketIsAcceptedNow() {
        val packet = Whoop5Ecg.parseR17(r17Inner(quality = 3, flags = 0x0A, samples = 2) + i16le(listOf(1, 2)))
        assertNotNull("a contact-positive packet must decode", packet)
        assertTrue(packet!!.presence)
        assertTrue("precondition: the old triage capped this at 1", packet.flags.raw > 1)
        assertTrue("precondition: same for quality", packet.signalQualityRaw > 1)
    }

    @Test
    fun r17UnreadableMaskNamesItsBits() {
        assertEquals(emptyList<String>(), EcgUnreadableMask(0x00).reasons)
        assertEquals(listOf("low_amplitude"), EcgUnreadableMask(0x01).reasons)
        assertEquals(
            listOf("low_amplitude", "significant_noise", "unstable_signal", "not_enough_data"),
            EcgUnreadableMask(0x0F).reasons,
        )
        // An unmapped bit is reported as unknown, never folded onto a named reason.
        assertEquals(listOf("unknown_bits_0x10"), EcgUnreadableMask(0x10).reasons)
    }

    @Test
    fun r17TerminalAndInvalidPredicates() {
        val running = Whoop5Ecg.parseR17(r17Inner(state = 1, progress = 42, samples = 0))
        assertEquals(false, running?.isTerminal)
        assertEquals(false, running?.isInvalid)
        // Either condition alone is terminal.
        assertEquals(true, Whoop5Ecg.parseR17(r17Inner(state = 1, progress = 100, samples = 0))?.isTerminal)
        assertEquals(true, Whoop5Ecg.parseR17(r17Inner(state = 2, progress = 42, samples = 0))?.isTerminal)
        // 255 is the abort sentinel, and it is NOT a completion.
        val invalid = Whoop5Ecg.parseR17(r17Inner(state = 1, progress = 255, samples = 0))
        assertEquals(true, invalid?.isInvalid)
        assertEquals(false, invalid?.isTerminal)
    }

    @Test
    fun r17VariabilitySentinelBecomesNull() {
        assertNull(Whoop5Ecg.parseR17(r17Inner(variability = 0xFFFF, samples = 0))?.variabilityRaw)
        assertEquals(0xFFFE, Whoop5Ecg.parseR17(r17Inner(variability = 0xFFFE, samples = 0))?.variabilityRaw)
    }

    @Test
    fun r17CarriesTrailingBytesAsTail() {
        val packet = Whoop5Ecg.parseR17(r17Inner(samples = 2) + i16le(listOf(5, -5)) + listOf(0, 0, 0))
        assertEquals(listOf(5, -5), packet?.samples)
        assertEquals(listOf(0, 0, 0), packet?.tail)
    }

    @Test
    fun r17ZeroSamplesIsValid() {
        val packet = Whoop5Ecg.parseR17(r17Inner(flags = 0x00, samples = 0))
        assertNotNull(packet)
        assertEquals(emptyList<Int>(), packet?.samples)
        assertEquals(false, packet?.presence)
    }

    @Test
    fun r17RejectsShortRecord() {
        for (count in 0 until Whoop5Ecg.R17_FIXED_LENGTH) {
            val inner = MutableList(count) { 0 }
            if (count > 0) inner[0] = 43
            if (count > 1) inner[1] = 17
            assertNull("$count-byte record must not decode", Whoop5Ecg.parseR17(inner))
        }
    }

    @Test
    fun r17RejectsTheWrongTypeOrRevision() {
        assertNull("stored needs allowStored", Whoop5Ecg.parseR17(r17Inner(type = 47, samples = 0)))
        assertNotNull(Whoop5Ecg.parseR17(r17Inner(type = 47, samples = 0), allowStored = true))
        assertNull(Whoop5Ecg.parseR17(r17Inner(type = 40, samples = 0), allowStored = true))
        // Revision 16 is the RAW record and shares the type byte. Reading it as an R17 would invent
        // fields, so the revision check is what keeps the two apart.
        assertNull(Whoop5Ecg.parseR17(r17Inner(revision = 16, samples = 0)))
    }

    @Test
    fun r17RejectsSampleCountLongerThanBuffer() {
        assertNull(Whoop5Ecg.parseR17(r17Inner(samples = 10) + i16le(listOf(1, 2, 3))))
    }

    @Test
    fun r17RejectsSampleCountOffByOneByte() {
        assertNull(Whoop5Ecg.parseR17(r17Inner(samples = 4) + i16le(listOf(1, 2, 3)) + listOf(7)))
    }

    @Test
    fun r17RejectsMoreSamplesThanTheWireCanCarry() {
        // 100 is the physical capacity. A count above it is a corrupt or misread record, not a big packet.
        val over = Whoop5Ecg.R17_MAX_SAMPLES + 1
        assertNull(Whoop5Ecg.parseR17(r17Inner(samples = over) + List(over * 2) { 0 }))
        val atLimit = r17Inner(samples = Whoop5Ecg.R17_MAX_SAMPLES) + List(Whoop5Ecg.R17_MAX_SAMPLES * 2) { 0 }
        assertNotNull("exactly 100 is on the wire, not over it", Whoop5Ecg.parseR17(atLimit))
    }

    @Test
    fun r17ExtraSamplesBeyondTheCountBecomeTail() {
        val packet = Whoop5Ecg.parseR17(r17Inner(samples = 2) + i16le(listOf(9, 9, 9, 9)))
        assertEquals(2, packet?.samples?.size)
        assertEquals(4, packet?.tail?.size)
    }

    // MARK: - Enum coverage

    @Test
    fun everyArrhythmiaCheckResultCaseDecodes() {
        val expected = listOf(
            Triple(0, EcgArrhythmiaCheckResult.NOT_COMPLETE, "notComplete"),
            Triple(1, EcgArrhythmiaCheckResult.NORMAL_SINUS_RHYTHM, "normalSinusRhythm"),
            Triple(2, EcgArrhythmiaCheckResult.SIGNAL_UNREADABLE, "signalUnreadable"),
            Triple(3, EcgArrhythmiaCheckResult.BRADYCARDIA, "bradycardia"),
            Triple(4, EcgArrhythmiaCheckResult.AFIB_DETECTED, "afibDetected"),
            Triple(5, EcgArrhythmiaCheckResult.TACHYCARDIA, "tachycardia"),
            Triple(6, EcgArrhythmiaCheckResult.INCONCLUSIVE, "inconclusive"),
        )
        assertEquals(EcgArrhythmiaCheckResult.entries.size, expected.size)
        for ((raw, expectedCase, token) in expected) {
            val packet = Whoop5Ecg.parseR17(r17Inner(result = raw, samples = 1) + i16le(listOf(0)))
            assertEquals("raw $raw", expectedCase, packet?.arrhythmiaCheckResult)
            assertEquals(raw, packet?.arrhythmiaCheckResultRaw)
            assertEquals(token, expectedCase.token)
        }
    }

    @Test
    fun unknownArrhythmiaResultIsCarriedRawNotCoerced() {
        val packet = Whoop5Ecg.parseR17(r17Inner(result = 200, samples = 1) + i16le(listOf(0)))
        assertNull(packet?.arrhythmiaCheckResult)
        assertEquals(200, packet?.arrhythmiaCheckResultRaw)
    }

    @Test
    fun everySignalQualityCaseDecodes() {
        for (quality in EcgSignalQuality.entries) {
            assertEquals(quality, Whoop5Ecg.parseR17(r17Inner(quality = quality.raw, samples = 0))?.signalQuality)
        }
        val packet = Whoop5Ecg.parseR17(r17Inner(quality = 77, samples = 0))
        assertEquals(EcgSignalQuality.UNKNOWN, packet?.signalQuality)
        assertEquals(77, packet?.signalQualityRaw)
    }

    @Test
    fun progressPercentInRangeAndRawOutside() {
        for (value in listOf(0, 1, 50, 99, 100)) {
            assertEquals(value, Whoop5Ecg.parseR17(r17Inner(progress = value, samples = 0))?.progress?.percentValue)
        }
        // 101..255 is out of percentage range. 255 is the strap's abort sentinel; the rest have no
        // attested meaning, so the byte is carried raw rather than renamed into an unproven state.
        for (value in listOf(101, 200, 255)) {
            val progress = Whoop5Ecg.parseR17(r17Inner(progress = value, samples = 0))?.progress
            assertNull(progress?.percentValue)
            assertEquals(value, progress?.raw)
            assertEquals(false, progress?.isMapped)
        }
    }

    // MARK: - Raw packet

    @Test
    fun rawDecodesWithExplicitSampleWidth() {
        val rawBlob = (0 until 12).toList()                  // 4 samples × 3 bytes
        val leadsOffI = listOf(1, 2)
        val leadsOffQ = listOf(3, 4)
        val payload = header(samples = 4) + rawBlob + listOf(2) + u16le(leadsOffI) + u16le(leadsOffQ)

        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 3)
        assertNotNull(packet)
        assertEquals(rawBlob, packet?.rawECGDataRaw)
        assertEquals(2, packet?.numberOfLeadsOffSamples)
        assertEquals(leadsOffI, packet?.leadsOffIRaw)
        assertEquals(leadsOffQ, packet?.leadsOffQRaw)
        assertEquals(emptyList<Int>(), packet?.padding)
        assertEquals(3, packet?.bytesPerSample)              // count ÷ numberOfECGSamples
    }

    @Test
    fun rawWithNoLeadsOffSamples() {
        val payload = header(samples = 2) + listOf(0xAA, 0xBB, 0xCC, 0xDD) + listOf(0)
        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2)
        assertEquals(0, packet?.numberOfLeadsOffSamples)
        assertEquals(emptyList<Int>(), packet?.leadsOffIRaw)
        assertEquals(emptyList<Int>(), packet?.leadsOffQRaw)
        assertEquals(listOf(0xAA, 0xBB, 0xCC, 0xDD), packet?.rawECGDataRaw)
    }

    @Test
    fun rawRejectsTruncatedLeadsOffArrays() {
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) + listOf(3) + u16le(listOf(1, 2, 3))
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
    }

    @Test
    fun rawRejectsMissingLeadsOffCountByte() {
        val payload = header(samples = 2) + listOf(0, 0, 0, 0)
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
    }

    @Test
    fun rawRejectsAWidthThatWouldOverflowTheOffsetMath() {
        // A Kotlin Int overflow wraps silently NEGATIVE, which would throw on the subscript. Twin of the
        // Swift testRawRejectsAWidthThatWouldOverflowTheOffsetMath.
        val payload = header(samples = 65_535) + List(8) { 0 }
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = Int.MAX_VALUE))
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = Int.MAX_VALUE / 2))
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 1_000_000))
        val frame = puffinFrame(0x2F, payload)
        assertNull(Whoop5Ecg.decodeRawFrame(frame, bytesPerSample = Int.MAX_VALUE))
    }

    @Test
    fun rawRejectsShortHeaderAndZeroWidth() {
        assertNull(Whoop5Ecg.decodeRaw(listOf(1, 2, 3), bytesPerSample = 2))
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) + listOf(0)
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 0))
    }

    @Test
    fun rawSampleWidthCandidatesAreEnumeratedNotGuessed() {
        val payload = header(samples = 4) + List(8) { 0x11 } + listOf(1) + u16le(listOf(7)) + u16le(listOf(8))
        val candidates = Whoop5Ecg.rawBytesPerSampleCandidates(payload)
        assertTrue("width 2 must be structurally admissible", candidates.contains(2))
        if (candidates.size == 1) {
            assertEquals(candidates[0], Whoop5Ecg.decodeRaw(payload)?.bytesPerSample)
        } else {
            assertNull("ambiguous buffer ($candidates) must refuse to decode", Whoop5Ecg.decodeRaw(payload))
        }
    }

    @Test
    fun rawAmbiguousBufferRefusesToDecode() {
        val payload = header(samples = 1) + List(6) { 0 }
        val candidates = Whoop5Ecg.rawBytesPerSampleCandidates(payload, maxPadding = 8)
        assertTrue("fixture is meant to be ambiguous", candidates.size > 1)
        assertNull(Whoop5Ecg.decodeRaw(payload, maxPadding = 8))
    }

    // MARK: - Frame level (CRC gating)

    @Test
    fun r17DecodesThroughAValidPuffinEnvelope() {
        val samples = listOf(10, -10, 300)
        val frame = r17Frame(r17Inner(samples = samples.size) + i16le(samples))
        val packet = Whoop5Ecg.r17FromFrame(frame)
        assertEquals(samples, packet?.samples)
        assertEquals(63, packet?.liveHR)
        // The record starts at frame[8], so the samples land at frame[34] — the offset observed on an MG.
        assertEquals(43, frame[Whoop5Ecg.RAW_TYPE_OFFSET].toInt() and 0xFF)
        assertEquals(17, frame[Whoop5Ecg.RAW_TYPE_OFFSET + 1].toInt() and 0xFF)
        // `tail` is record bytes only. Slicing the frame to its END instead of to the declared length
        // would put the four-byte CRC32 trailer in here and call it part of the record.
        assertTrue("the CRC32 trailer is envelope, not tail", packet?.tail?.isEmpty() == true)
    }

    /**
     * The same guarantee with a tail that genuinely exists, so an empty-tail assertion cannot pass for
     * the wrong reason.
     *
     * Two samples, not one: the inner record is padded to a 4-byte boundary, so an odd sample count puts
     * pad bytes in `tail` too and the exact-bytes assertion stops being about the CRC at all.
     * 26 fixed + 4 sample + 2 trailing = 32, already aligned.
     */
    @Test
    fun tailStopsAtTheCrcTrailer() {
        val frame = r17Frame(r17Inner(samples = 2) + i16le(listOf(1, 2)) + listOf(0xAB, 0xCD))
        val packet = Whoop5Ecg.r17FromFrame(frame)
        assertEquals(listOf(0xAB, 0xCD), packet?.tail)
        // Decisive: the four CRC32 bytes the envelope ends with are absent from the record's tail.
        val crc = frame.takeLast(4).map { it.toInt() and 0xFF }
        assertFalse(packet!!.tail.takeLast(4) == crc)
    }

    @Test
    fun r17FrameRejectsBadCrc32() {
        val frame = r17Frame(r17Inner(samples = 2) + i16le(listOf(1, 2)))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertNull("a bad CRC must never reach a field read", Whoop5Ecg.r17FromFrame(frame))
    }

    @Test
    fun r17FrameRejectsBadHeaderCrc16() {
        val frame = r17Frame(r17Inner(samples = 2) + i16le(listOf(1, 2)))
        frame[6] = (frame[6].toInt() xor 0xFF).toByte()
        assertNull(Whoop5Ecg.r17FromFrame(frame))
    }

    @Test
    fun r17FrameRejectsCorruptedBodyThatBreaksCrc() {
        val frame = r17Frame(r17Inner(samples = 2) + i16le(listOf(1, 2)))
        frame[12] = (frame[12].toInt() xor 0x01).toByte()
        assertNull(Whoop5Ecg.r17FromFrame(frame))
    }

    @Test
    fun frameRejectsGarbageAndShortInput() {
        assertNull(Whoop5Ecg.r17FromFrame(ByteArray(0)))
        assertNull(Whoop5Ecg.r17FromFrame(byteArrayOf(0xAA.toByte(), 0x01, 0x00)))
        assertNull(Whoop5Ecg.r17FromFrame(ByteArray(64) { 0xFF.toByte() }))
    }

    @Test
    fun rawFrameDecodesThroughAValidPuffinEnvelope() {
        val payload = header(samples = 2) + listOf(1, 2, 3, 4) + listOf(1) + u16le(listOf(5)) + u16le(listOf(6))
        val frame = puffinFrame(0x2F, payload)
        val packet = Whoop5Ecg.decodeRawFrame(frame, bytesPerSample = 2)
        assertEquals(listOf(1, 2, 3, 4), packet?.rawECGDataRaw)
        assertEquals(listOf(5), packet?.leadsOffIRaw)
        assertEquals(listOf(6), packet?.leadsOffQRaw)
    }

    @Test
    fun rawFrameRejectsBadCrc() {
        val payload = header(samples = 2) + listOf(1, 2, 3, 4) + listOf(0)
        val frame = puffinFrame(0x2F, payload)
        frame[frame.size - 2] = (frame[frame.size - 2].toInt() xor 0xFF).toByte()
        assertNull(Whoop5Ecg.decodeRawFrame(frame, bytesPerSample = 2))
    }

    // MARK: - Packet recognition

    @Test
    fun isLabradorR17FrameAcceptsAWellFormedRecord() {
        assertTrue(r17IsRecognised(r17Frame(r17Inner(samples = 3) + i16le(listOf(1, 2, 3)))))
    }

    /**
     * What the superseded heuristic got wrong, as a test rather than a comment.
     *
     * It read a status block from `frame[11]` and required four of those bytes to be 0 or 1. Two of them
     * are this record's quality and flags bytes. A packet with electrode contact carries `0x08` in flags,
     * so the triage rejected exactly the packets a reading is made of. The recogniser that replaced it
     * keys on the record's own type and revision instead.
     */
    @Test
    fun recognitionDoesNotDependOnTheBytesTheOldHeuristicCapped() {
        for (flags in listOf(0x00, 0x02, 0x08, 0x0A, 0x0C)) {
            for (quality in 0..3) {
                val frame = r17Frame(r17Inner(quality = quality, flags = flags, samples = 2) + i16le(listOf(1, 2)))
                assertTrue(
                    "flags=0x%02x quality=%d must be recognised".format(flags, quality),
                    r17IsRecognised(frame),
                )
            }
        }
    }

    @Test
    fun isLabradorR17FrameRejectsOtherRecords() {
        // Right type, wrong revision: the RAW (revision 16) record must not be read as filtered.
        assertFalse(r17IsRecognised(r17Frame(r17Inner(revision = 16, samples = 2) + i16le(listOf(1, 2)))))
        // Right revision, a type nothing in this family uses.
        assertFalse(r17IsRecognised(r17Frame(r17Inner(type = 40, samples = 2) + i16le(listOf(1, 2)))))
        // Stored records need to be asked for.
        val stored = r17Frame(r17Inner(type = 47, samples = 2) + i16le(listOf(1, 2)))
        assertFalse(r17IsRecognised(stored))
        assertTrue(r17IsRecognised(stored, allowStored = true))
    }

    @Test
    fun isLabradorR17FrameRejectsEmptyAndGarbage() {
        assertFalse(r17IsRecognised(ByteArray(0)))
        assertFalse(r17IsRecognised(ByteArray(64) { 0 }))
    }

    // MARK: - Commands

    @Test
    fun commandOpcodesMatchTheRepoProtocolTable() {
        // Checked against the READ-ONLY label table (#893), not the sender enum: Android sends none of
        // these four and they are deliberately absent from `CommandNumber`. `CommandNames` is built from
        // the shared schema, so this pins the same name<->code mapping without asserting sendability.
        assertEquals("SELECT_WRIST", CommandNames.byRaw[Whoop5Ecg.SELECT_WRIST_CMD])
        assertEquals(
            "TOGGLE_LABRADOR_DATA_GENERATION",
            CommandNames.byRaw[Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD],
        )
        assertEquals("TOGGLE_LABRADOR_RAW_SAVE", CommandNames.byRaw[Whoop5Ecg.TOGGLE_SAVE_RAW_ECG_CMD])
        assertEquals(
            "TOGGLE_LABRADOR_FILTERED",
            CommandNames.byRaw[Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD],
        )
        assertEquals(0x7B, Whoop5Ecg.SELECT_WRIST_CMD)
        assertEquals(0x7C, Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD)
        assertEquals(0x7D, Whoop5Ecg.TOGGLE_SAVE_RAW_ECG_CMD)
        assertEquals(0x8B, Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD)
    }

    @Test
    fun commandPayloadIsRevisionThenArg() {
        // LITERAL wire bytes, for the same reason the control-signal pin below spells them out: the old
        // RIGHT(0)/LEFT(1) reading of the client's declaration order was wrong, and a test written
        // through `.raw` would have moved with the enum and stayed green.
        assertEquals(listOf(0x01, 0x01), Whoop5Ecg.selectWristPayload(Whoop5Ecg.WristSelection.RIGHT))
        assertEquals(listOf(0x01, 0x02), Whoop5Ecg.selectWristPayload(Whoop5Ecg.WristSelection.LEFT))
        assertEquals(listOf(0x01, 0x01), Whoop5Ecg.togglePayload(on = true))
        assertEquals(listOf(0x01, 0x00), Whoop5Ecg.togglePayload(on = false))
        // LITERAL wire bytes, not `ControlSignal.X.raw`. Asserting through the symbol is what let the
        // previous mapping stay green through a renumber: the test moved with the enum.
        assertEquals(listOf(0x01, 0x01), Whoop5Ecg.controlPayload(Whoop5Ecg.ControlSignal.STOP))
        assertEquals(listOf(0x01, 0x02), Whoop5Ecg.controlPayload(Whoop5Ecg.ControlSignal.START))
    }

    @Test
    fun commandFramesMatchTheSwiftWireForm() {
        // Inner = [type=35][seq][cmd][revision][arg] = 5 bytes, pad4 → 8. Frame = 8 + 8 + 4 = 20.
        val frame = Whoop5Ecg.selectWristFrame(Whoop5Ecg.WristSelection.LEFT, seq = 9)
        assertEquals(20, frame.size)
        assertEquals(35, frame[8].toInt() and 0xFF)
        assertEquals(0x7B, frame[10].toInt() and 0xFF)
        assertEquals(Whoop5Ecg.COMMAND_REVISION, frame[11].toInt() and 0xFF)
        assertEquals(0x02, frame[12].toInt() and 0xFF)
        assertEquals(listOf(0, 0, 0), (13..15).map { frame[it].toInt() and 0xFF })
        // The builders must agree with the raw framing call the Swift twin is pinned against.
        assertArrayEquals(
            Framing.puffinCommandFrame(cmd = 0x7B, seq = 9, payload = byteArrayOf(0x01, 0x02)),
            frame,
        )
    }

    @Test
    fun everyCommandFrameBuilderMatchesItsOpcodeAndArg() {
        val cases = listOf(
            Whoop5Ecg.toggleRealtimeFilteredEcgFrame(on = true, seq = 9) to (0x8B to 1),
            Whoop5Ecg.toggleSaveRawEcgFrame(on = false, seq = 9) to (0x7D to 0),
            Whoop5Ecg.mainControlEcgDataGenerationFrame(Whoop5Ecg.ControlSignal.START, seq = 9) to (0x7C to 2),
            Whoop5Ecg.mainControlEcgDataGenerationFrame(Whoop5Ecg.ControlSignal.STOP, seq = 9) to (0x7C to 1),
            Whoop5Ecg.selectWristFrame(Whoop5Ecg.WristSelection.RIGHT, seq = 9) to (0x7B to 1),
        )
        for ((frame, expected) in cases) {
            val (cmd, arg) = expected
            assertEquals(cmd, frame[10].toInt() and 0xFF)
            assertEquals(arg, frame[12].toInt() and 0xFF)
            assertEquals(20, frame.size)
        }
    }

    @Test
    fun isLabradorR17FrameIsCrcGated() {
        val frame = r17Frame(r17Inner(samples = 3) + i16le(listOf(1, 2, 3)))
        assertTrue(r17IsRecognised(frame))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertFalse("a bad CRC must not pass recognition", r17IsRecognised(frame))
    }

    @Test
    fun outOfRangeListElementsAreRejectedRatherThanThrowing() {
        // Kotlin's List<Int> can express values Swift's [UInt8] cannot. Those inputs must fail the decode
        // rather than diverge from Swift or throw on a subscript.
        val negativeHeader = header(samples = 2).toMutableList().also { it[0] = -1 }
        assertNull(Whoop5Ecg.decodeHeader(negativeHeader))

        // The same hazard on the R17 path: a negative or oversized element anywhere in the fixed block
        // must fail the decode rather than diverge from Swift or throw on a subscript.
        val negativeR17 = r17Inner(samples = 2).toMutableList().also { it[13] = -1 }
        assertNull(Whoop5Ecg.parseR17(negativeR17 + i16le(listOf(1, 2))))
        val oversizedR17 = r17Inner(samples = 2).toMutableList().also { it[14] = 0x1_0000 }
        assertNull(Whoop5Ecg.parseR17(oversizedR17 + i16le(listOf(1, 2))))

        // A negative leads-off count would make qEnd negative and throw on subList without the guard.
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) + listOf(-5) + List(8) { 0 }
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
    }
}
