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

    private fun i16le(values: List<Int>): List<Int> =
        values.flatMap { listOf(it and 0xFF, (it shr 8) and 0xFF) }

    private fun u16le(values: List<Int>): List<Int> =
        values.flatMap { listOf(it and 0xFF, (it shr 8) and 0xFF) }

    /**
     * The raw record's leads-off tail: the count byte, then [Whoop5Ecg.LEADS_OFF_SLOT_COUNT] i16 I slots,
     * then the same again for Q. The block is FIXED-SIZE on real hardware (see the Swift
     * `Whoop5EcgRawHardwareTests`), so these fixtures zero-fill the slots the count does not reach instead
     * of packing the arrays to the count.
     */
    private fun leadsOffBlock(i: List<Int>, q: List<Int>): List<Int> {
        require(i.size == q.size && i.size <= Whoop5Ecg.LEADS_OFF_SLOT_COUNT)
        val pad = List(Whoop5Ecg.LEADS_OFF_SLOT_COUNT - i.size) { 0 }
        return listOf(i.size) + u16le(i + pad) + u16le(q + pad)
    }

    private fun puffinFrame(type: Int, payload: List<Int>): ByteArray =
        Framing.puffinCommandFrame(
            cmd = 0x00, seq = 0x01,
            payload = payload.map { it.toByte() }.toByteArray(),
            type = type,
        )

    // MARK: - Filtered packet

    @Test
    fun filteredDecodesEveryFieldInWireOrder() {
        val samples = listOf(0, 1, -1, 32_767, -32_768, 250, -250)
        val payload = header(samples = samples.size) + i16le(samples)
        val packet = Whoop5Ecg.decodeFiltered(payload)
        assertNotNull(packet)
        packet!!

        assertEquals(EcgSignalQuality.MEDIUM, packet.header.signalQuality)
        assertEquals(0x05, packet.header.statusFlags)
        assertTrue(packet.header.heartKeyStarted)
        assertTrue(packet.header.heartKeyIsRunning)
        assertFalse(packet.header.heartKeyIsStoppedAndComplete)
        assertTrue(packet.header.heartKeyLeadsAreOn)
        assertEquals(EcgArrhythmiaCheckResult.NOT_COMPLETE, packet.header.heartKeyArrhythmiaCheckResult)
        assertEquals(EcgArrhythmiaCheckStatus.IN_PROGRESS, packet.header.heartKeyArrhythmiaCheckStatus)
        assertEquals(42, packet.header.heartKeyProgress.percentValue)
        assertEquals(0, packet.header.heartKeyUnreadableReason)
        assertEquals(61, packet.header.heartKeyAverageHR)
        assertEquals(63, packet.header.heartKeyHR)
        assertEquals(812, packet.header.heartKeyHRV)          // u16 LE, not two u8s
        assertEquals(17, packet.header.heartKeyStressScore)
        assertEquals(7, packet.header.numberOfECGSamples)
        assertEquals(samples, packet.filteredECGDataRaw)      // signed, LE
        assertTrue(packet.padding.isEmpty())
    }

    @Test
    fun filteredCarriesTrailingPadding() {
        val payload = header(samples = 2) + i16le(listOf(5, -5)) + listOf(0, 0, 0)
        val packet = Whoop5Ecg.decodeFiltered(payload)
        assertEquals(listOf(5, -5), packet?.filteredECGDataRaw)
        assertEquals(listOf(0, 0, 0), packet?.padding)
    }

    @Test
    fun filteredZeroSamplesIsValid() {
        val packet = Whoop5Ecg.decodeFiltered(header(leadsOn = 0, samples = 0))
        assertNotNull(packet)
        assertEquals(emptyList<Int>(), packet?.filteredECGDataRaw)
        assertEquals(false, packet?.header?.heartKeyLeadsAreOn)
    }

    @Test
    fun filteredRejectsShortHeader() {
        for (count in 0 until Whoop5Ecg.HEADER_LENGTH) {
            assertNull("$count-byte payload must not decode", Whoop5Ecg.decodeFiltered(List(count) { 0 }))
        }
    }

    @Test
    fun filteredRejectsSampleCountLongerThanBuffer() {
        val payload = header(samples = 10) + i16le(listOf(1, 2, 3))
        assertNull(Whoop5Ecg.decodeFiltered(payload))
    }

    @Test
    fun filteredRejectsSampleCountOffByOneByte() {
        val payload = header(samples = 4) + i16le(listOf(1, 2, 3)) + listOf(7)
        assertNull(Whoop5Ecg.decodeFiltered(payload))
    }

    @Test
    fun filteredExtraSamplesBeyondTheCountBecomePadding() {
        val payload = header(samples = 2) + i16le(listOf(9, 9, 9, 9))
        val packet = Whoop5Ecg.decodeFiltered(payload)
        assertEquals(2, packet?.filteredECGDataRaw?.size)
        assertEquals(4, packet?.padding?.size)
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
            val payload = header(arrhythmiaResult = raw, samples = 1) + i16le(listOf(0))
            val packet = Whoop5Ecg.decodeFiltered(payload)
            assertEquals("raw $raw", expectedCase, packet?.header?.heartKeyArrhythmiaCheckResult)
            assertEquals(raw, packet?.header?.heartKeyArrhythmiaCheckResultRaw)
            assertEquals(token, expectedCase.token)
        }
    }

    @Test
    fun unknownArrhythmiaResultIsCarriedRawNotCoerced() {
        val payload = header(arrhythmiaResult = 200, samples = 1) + i16le(listOf(0))
        val packet = Whoop5Ecg.decodeFiltered(payload)
        assertNull(packet?.header?.heartKeyArrhythmiaCheckResult)
        assertEquals(200, packet?.header?.heartKeyArrhythmiaCheckResultRaw)
    }

    @Test
    fun everyArrhythmiaCheckStatusCaseDecodes() {
        val expected = listOf(
            0 to EcgArrhythmiaCheckStatus.NOT_RUNNING,
            1 to EcgArrhythmiaCheckStatus.IN_PROGRESS,
            2 to EcgArrhythmiaCheckStatus.CHECK_COMPLETE,
        )
        assertEquals(EcgArrhythmiaCheckStatus.entries.size, expected.size)
        for ((raw, expectedCase) in expected) {
            val packet = Whoop5Ecg.decodeFiltered(header(arrhythmiaStatus = raw, samples = 0))
            assertEquals(expectedCase, packet?.header?.heartKeyArrhythmiaCheckStatus)
        }
        val bad = Whoop5Ecg.decodeFiltered(header(arrhythmiaStatus = 9, samples = 0))
        assertNull(bad?.header?.heartKeyArrhythmiaCheckStatus)
        assertEquals(9, bad?.header?.heartKeyArrhythmiaCheckStatusRaw)
    }

    @Test
    fun everySignalQualityCaseDecodes() {
        for (quality in EcgSignalQuality.entries) {
            val packet = Whoop5Ecg.decodeFiltered(header(signalQuality = quality.raw, samples = 0))
            assertEquals(quality, packet?.header?.signalQuality)
        }
        val packet = Whoop5Ecg.decodeFiltered(header(signalQuality = 77, samples = 0))
        assertEquals(EcgSignalQuality.UNKNOWN, packet?.header?.signalQuality)
        assertEquals(77, packet?.header?.signalQualityRaw)
    }

    @Test
    fun progressPercentInRangeAndRawOutside() {
        for (value in listOf(0, 1, 50, 99, 100)) {
            val packet = Whoop5Ecg.decodeFiltered(header(progress = value, samples = 0))
            assertEquals(value, packet?.header?.heartKeyProgress?.percentValue)
        }
        // 101..255 is out of percentage range. The source type has a "timed out" case, but its sentinel
        // value is not attested, so the byte is carried raw rather than renamed into an unproven state.
        for (value in listOf(101, 200, 255)) {
            val progress = Whoop5Ecg.decodeFiltered(header(progress = value, samples = 0))?.header?.heartKeyProgress
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
        val payload = header(samples = 4) + rawBlob + leadsOffBlock(leadsOffI, leadsOffQ)

        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 3)
        assertNotNull(packet)
        assertEquals(rawBlob, packet?.rawECGDataRaw)
        assertEquals(2, packet?.numberOfLeadsOffSamples)
        assertEquals(leadsOffI, packet?.leadsOffIRaw)
        assertEquals(leadsOffQ, packet?.leadsOffQRaw)
        assertEquals(emptyList<Int>(), packet?.padding)
        assertEquals(3, packet?.bytesPerSample)              // count ÷ numberOfECGSamples
    }

    /**
     * The SAMPLE region is fixed-size too: numberOfECGSamples says how many of its slots are valid, and
     * the rest is zero-filled capacity that still has to be stepped over to reach the leads-off block.
     * Only the valid bytes are carried; the unused ones are counted. Twin of the Swift
     * rawPartlyFilledSampleRegionIsSteppedOverNotCarried.
     */
    @Test
    fun rawPartlyFilledSampleRegionIsSteppedOverNotCarried() {
        val samples = listOf(1, 2, 3, 4, 5, 6)               // 3 valid samples × 2 bytes
        val unused = List(8) { 0 }                           // 4 more slots the record did not fill
        val payload = header(samples = 3) + samples + unused + leadsOffBlock(listOf(5), listOf(6))

        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2)
        assertEquals(samples, packet?.rawECGDataRaw)
        assertEquals(8, packet?.unusedSampleBytes)
        assertEquals(14, packet?.sampleRegionBytes)
        assertEquals(2, packet?.bytesPerSample)
        assertEquals(1, packet?.numberOfLeadsOffSamples)
        assertEquals(listOf(5), packet?.leadsOffIRaw)
        assertEquals(listOf(6), packet?.leadsOffQRaw)
        assertEquals(emptyList<Int>(), packet?.padding)
    }

    /**
     * The zero-fill is what makes the step-over safe: a non-zero byte between the declared samples and
     * the block means the block is not where this width says it is, so the decode fails closed rather
     * than skipping over bytes that might be data. The stray byte LEADS the unused span so it stays
     * inside that span at every end position the padding budget allows.
     */
    @Test
    fun rawRejectsNonZeroBytesInTheUnusedSampleRegion() {
        val region = listOf(1, 2, 3, 4, 5, 6) + listOf(0x09) + List(7) { 0 }
        val payload = header(samples = 3) + region + leadsOffBlock(listOf(5), listOf(6))
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
        // With the same bytes declared as samples the record is fine — it is the SKIPPING that is gated.
        val full = header(samples = 7) + region + leadsOffBlock(listOf(5), listOf(6))
        assertEquals(region, Whoop5Ecg.decodeRaw(full, bytesPerSample = 2)?.rawECGDataRaw)
    }

    /** A zero count still carries the full fixed block — the slots are simply all unused. */
    @Test
    fun rawWithNoLeadsOffSamples() {
        val payload = header(samples = 2) + listOf(0xAA, 0xBB, 0xCC, 0xDD) + leadsOffBlock(emptyList(), emptyList())
        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2)
        assertEquals(0, packet?.numberOfLeadsOffSamples)
        assertEquals(emptyList<Int>(), packet?.leadsOffIRaw)
        assertEquals(emptyList<Int>(), packet?.leadsOffQRaw)
        assertEquals(listOf(0xAA, 0xBB, 0xCC, 0xDD), packet?.rawECGDataRaw)
        assertEquals(emptyList<Int>(), packet?.padding)
    }

    /**
     * The valid values come off the FRONT of each fixed array, and the unused slots are dropped rather
     * than shifting Q or leaking into the padding — the defect the real capture exposed.
     */
    @Test
    fun rawPartiallyFilledLeadsOffBlockKeepsQAligned() {
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) +
            leadsOffBlock(listOf(11, 12, 13), listOf(21, 22, 23))
        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2)
        assertEquals(3, packet?.numberOfLeadsOffSamples)
        assertEquals(listOf(11, 12, 13), packet?.leadsOffIRaw)
        assertEquals(listOf(21, 22, 23), packet?.leadsOffQRaw)
        assertEquals(emptyList<Int>(), packet?.padding)
    }

    @Test
    fun rawRejectsTruncatedLeadsOffArrays() {
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) + listOf(3) + u16le(listOf(1, 2, 3))
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
    }

    /**
     * The block holds a fixed number of slots, so a count above it cannot describe this layout and must
     * fail closed rather than read past the block.
     */
    @Test
    fun rawRejectsLeadsOffCountAboveTheBlockCapacity() {
        // The blob is exactly full, so the block can only be where the count byte is — this pins the
        // capacity check itself rather than letting the end-of-record search reject the buffer earlier.
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) +
            listOf(Whoop5Ecg.LEADS_OFF_SLOT_COUNT + 1) + List(Whoop5Ecg.LEADS_OFF_SLOT_COUNT * 4) { 0 }
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
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) + leadsOffBlock(emptyList(), emptyList())
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 0))
    }

    @Test
    fun rawSampleWidthCandidatesAreEnumeratedNotGuessed() {
        val payload = header(samples = 4) + List(8) { 0x11 } + leadsOffBlock(listOf(7), listOf(8))
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
        // With a single sample, an all-zero tail long enough to hold the fixed leads-off block leaves
        // every width inside the padding tolerance.
        val payload = header(samples = 1) + List(49) { 0 }
        val candidates = Whoop5Ecg.rawBytesPerSampleCandidates(payload)
        assertEquals("fixture is meant to be ambiguous", listOf(1, 2, 3, 4), candidates)
        assertNull(Whoop5Ecg.decodeRaw(payload))
    }

    // MARK: - Frame level (CRC gating)

    @Test
    fun filteredFrameDecodesThroughAValidPuffinEnvelope() {
        val samples = listOf(10, -10, 300)
        val payload = header(samples = samples.size) + i16le(samples)
        val frame = puffinFrame(0x28, payload)
        val packet = Whoop5Ecg.decodeFilteredFrame(frame)
        assertEquals(samples, packet?.filteredECGDataRaw)
        assertEquals(63, packet?.header?.heartKeyHR)
    }

    @Test
    fun filteredFrameRejectsBadCrc32() {
        val payload = header(samples = 2) + i16le(listOf(1, 2))
        val frame = puffinFrame(0x28, payload)
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertNull("a bad CRC must never reach a field read", Whoop5Ecg.decodeFilteredFrame(frame))
    }

    @Test
    fun filteredFrameRejectsBadHeaderCrc16() {
        val payload = header(samples = 2) + i16le(listOf(1, 2))
        val frame = puffinFrame(0x28, payload)
        frame[6] = (frame[6].toInt() xor 0xFF).toByte()
        assertNull(Whoop5Ecg.decodeFilteredFrame(frame))
    }

    @Test
    fun filteredFrameRejectsCorruptedBodyThatBreaksCrc() {
        val payload = header(samples = 2) + i16le(listOf(1, 2))
        val frame = puffinFrame(0x28, payload)
        frame[12] = (frame[12].toInt() xor 0x01).toByte()
        assertNull(Whoop5Ecg.decodeFilteredFrame(frame))
    }

    @Test
    fun frameRejectsGarbageAndShortInput() {
        assertNull(Whoop5Ecg.decodeFilteredFrame(ByteArray(0)))
        assertNull(Whoop5Ecg.decodeFilteredFrame(byteArrayOf(0xAA.toByte(), 0x01, 0x00)))
        assertNull(Whoop5Ecg.decodeFilteredFrame(ByteArray(64) { 0xFF.toByte() }))
    }

    @Test
    fun rawFrameDecodesThroughAValidPuffinEnvelope() {
        val payload = header(samples = 2) + listOf(1, 2, 3, 4) + leadsOffBlock(listOf(5), listOf(6))
        val frame = puffinFrame(0x2F, payload)
        val packet = Whoop5Ecg.decodeRawFrame(frame, bytesPerSample = 2)
        assertEquals(listOf(1, 2, 3, 4), packet?.rawECGDataRaw)
        assertEquals(listOf(5), packet?.leadsOffIRaw)
        assertEquals(listOf(6), packet?.leadsOffQRaw)
    }

    @Test
    fun rawFrameRejectsBadCrc() {
        val payload = header(samples = 2) + listOf(1, 2, 3, 4) + leadsOffBlock(emptyList(), emptyList())
        val frame = puffinFrame(0x2F, payload)
        frame[frame.size - 2] = (frame[frame.size - 2].toInt() xor 0xFF).toByte()
        assertNull(Whoop5Ecg.decodeRawFrame(frame, bytesPerSample = 2))
    }

    // MARK: - Structural triage

    @Test
    fun plausibleFilteredPayloadAcceptsAWellFormedPacket() {
        assertTrue(Whoop5Ecg.plausibleFilteredPayload(header(samples = 3) + i16le(listOf(1, 2, 3))))
    }

    @Test
    fun plausibleFilteredPayloadRejectsNonBooleanFlagBytes() {
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(started = 7, samples = 3) + i16le(listOf(1, 2, 3))))
    }

    @Test
    fun plausibleFilteredPayloadRejectsOutOfRangeEnums() {
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(signalQuality = 9, samples = 2) + i16le(listOf(1, 2))))
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(arrhythmiaResult = 9, samples = 2) + i16le(listOf(1, 2))))
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(arrhythmiaStatus = 9, samples = 2) + i16le(listOf(1, 2))))
    }

    @Test
    fun plausibleFilteredPayloadRejectsLengthDisagreement() {
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples = 40) + i16le(listOf(1, 2))))
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples = 1) + i16le(listOf(1)) + List(40) { 0 }))
    }

    @Test
    fun plausibleFilteredPayloadRejectsEmptyAndZeroSampleBuffers() {
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(emptyList()))
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples = 0)))
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(List(64) { 0 }))
    }

    // MARK: - Structural triage: sample width

    /**
     * THE DEFECT this widening fixes. The triage hardcoded `n * 2`, so a payload whose samples are 3 bytes
     * wide missed the length agreement, failed the padding budget, and was discarded without a trace —
     * while the probe truthfully reported that no frame passed. A populated raw flash record read off
     * hardware was 1500 bytes against numberOfECGSamples = 500, i.e. 3.
     */
    @Test
    fun triageAcceptsAThreeBytePerSampleBufferAndNamesTheWidth() {
        val payload = header(samples = 4) + List(12) { 0x11 }
        assertEquals(listOf(3), Whoop5Ecg.filteredBytesPerSampleCandidates(payload))
        assertTrue(Whoop5Ecg.plausibleFilteredPayload(payload))
    }

    @Test
    fun triageStillAcceptsTwoBytesPerSampleAndReportsItFirst() {
        val payload = header(samples = 3) + i16le(listOf(1, 2, 3))
        assertEquals(listOf(2), Whoop5Ecg.filteredBytesPerSampleCandidates(payload))
        assertTrue(Whoop5Ecg.plausibleFilteredPayload(payload))
        assertEquals(2, Whoop5Ecg.FILTERED_WIDTH_CANDIDATES.first())
    }

    @Test
    fun triageAcceptsFourBytesPerSample() {
        assertEquals(
            listOf(4),
            Whoop5Ecg.filteredBytesPerSampleCandidates(header(samples = 5) + List(20) { 0x22 }),
        )
    }

    /** An ambiguous buffer REPORTS every width it admits rather than picking one. */
    @Test
    fun triageReportsEveryWidthAnAmbiguousBufferAdmits() {
        assertEquals(
            listOf(3, 4),
            Whoop5Ecg.filteredBytesPerSampleCandidates(header(samples = 2) + List(8) { 0x33 }),
        )
    }

    /** Only the WIDTH assumption moved: every other guard still rejects a length-perfect buffer. */
    @Test
    fun wideningTheWidthDoesNotLoosenAnyOtherGuard() {
        val body = List(12) { 0x11 }
        assertEquals(listOf(3), Whoop5Ecg.filteredBytesPerSampleCandidates(header(samples = 4) + body))
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(header(started = 7, samples = 4) + body).isEmpty())
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(header(running = 2, samples = 4) + body).isEmpty())
        assertTrue(
            Whoop5Ecg.filteredBytesPerSampleCandidates(header(stoppedAndComplete = 9, samples = 4) + body).isEmpty()
        )
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(header(leadsOn = 3, samples = 4) + body).isEmpty())
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(header(signalQuality = 9, samples = 4) + body).isEmpty())
        assertTrue(
            Whoop5Ecg.filteredBytesPerSampleCandidates(header(arrhythmiaResult = 9, samples = 4) + body).isEmpty()
        )
        assertTrue(
            Whoop5Ecg.filteredBytesPerSampleCandidates(header(arrhythmiaStatus = 9, samples = 4) + body).isEmpty()
        )
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(header(samples = 0)).isEmpty())
    }

    @Test
    fun triageStillRejectsBuffersNoWidthExplains() {
        assertTrue(
            Whoop5Ecg.filteredBytesPerSampleCandidates(header(samples = 7) + i16le(listOf(1, 2, 3))).isEmpty()
        )
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(header(samples = 40) + i16le(listOf(1, 2))).isEmpty())
        assertTrue(
            Whoop5Ecg.filteredBytesPerSampleCandidates(
                header(samples = 1) + i16le(listOf(1)) + List(40) { 0 }
            ).isEmpty()
        )
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(emptyList()).isEmpty())
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples = 7) + i16le(listOf(1, 2, 3))))
    }

    /** The offset math runs in Long: an Int overflow wraps NEGATIVE and would slip past the bounds test. */
    @Test
    fun triageWidthMathCannotOverflow() {
        val payload = header(samples = 65_535) + List(8) { 0 }
        assertTrue(
            Whoop5Ecg.filteredBytesPerSampleCandidates(payload, widths = listOf(Int.MAX_VALUE, 2, 3)).isEmpty()
        )
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(payload, widths = listOf(0, -1)).isEmpty())
    }

    @Test
    fun triageWidthsAreReportedThroughACrcGatedFrameToo() {
        val frame = puffinFrame(0x28, header(samples = 4) + List(12) { 0x11 })
        assertEquals(listOf(3), Whoop5Ecg.filteredBytesPerSampleCandidates(frame))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertTrue(Whoop5Ecg.filteredBytesPerSampleCandidates(frame).isEmpty())
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
        assertEquals(listOf(0x01, 0x00), Whoop5Ecg.selectWristPayload(Whoop5Ecg.WristSelection.RIGHT))
        assertEquals(listOf(0x01, 0x01), Whoop5Ecg.selectWristPayload(Whoop5Ecg.WristSelection.LEFT))
        assertEquals(listOf(0x01, 0x01), Whoop5Ecg.togglePayload(on = true))
        assertEquals(listOf(0x01, 0x00), Whoop5Ecg.togglePayload(on = false))
        assertEquals(listOf(0x01, 0x00), Whoop5Ecg.controlPayload(Whoop5Ecg.ControlSignal.STOP))
        assertEquals(listOf(0x01, 0x01), Whoop5Ecg.controlPayload(Whoop5Ecg.ControlSignal.START))
        assertEquals(listOf(0x01, 0x02), Whoop5Ecg.controlPayload(Whoop5Ecg.ControlSignal.RESTART))
    }

    @Test
    fun commandFramesMatchTheSwiftWireForm() {
        // Inner = [type=35][seq][cmd][revision][arg] = 5 bytes, pad4 → 8. Frame = 8 + 8 + 4 = 20.
        val frame = Whoop5Ecg.selectWristFrame(Whoop5Ecg.WristSelection.LEFT, seq = 9)
        assertEquals(20, frame.size)
        assertEquals(35, frame[8].toInt() and 0xFF)
        assertEquals(0x7B, frame[10].toInt() and 0xFF)
        assertEquals(Whoop5Ecg.COMMAND_REVISION, frame[11].toInt() and 0xFF)
        assertEquals(0x01, frame[12].toInt() and 0xFF)
        assertEquals(listOf(0, 0, 0), (13..15).map { frame[it].toInt() and 0xFF })
        // The builders must agree with the raw framing call the Swift twin is pinned against.
        assertArrayEquals(
            Framing.puffinCommandFrame(cmd = 0x7B, seq = 9, payload = byteArrayOf(0x01, 0x01)),
            frame,
        )
    }

    @Test
    fun everyCommandFrameBuilderMatchesItsOpcodeAndArg() {
        val cases = listOf(
            Whoop5Ecg.toggleRealtimeFilteredEcgFrame(on = true, seq = 9) to (0x8B to 1),
            Whoop5Ecg.toggleSaveRawEcgFrame(on = false, seq = 9) to (0x7D to 0),
            Whoop5Ecg.mainControlEcgDataGenerationFrame(Whoop5Ecg.ControlSignal.START, seq = 9) to (0x7C to 1),
            Whoop5Ecg.mainControlEcgDataGenerationFrame(Whoop5Ecg.ControlSignal.STOP, seq = 9) to (0x7C to 0),
            Whoop5Ecg.selectWristFrame(Whoop5Ecg.WristSelection.RIGHT, seq = 9) to (0x7B to 0),
        )
        for ((frame, expected) in cases) {
            val (cmd, arg) = expected
            assertEquals(cmd, frame[10].toInt() and 0xFF)
            assertEquals(arg, frame[12].toInt() and 0xFF)
            assertEquals(20, frame.size)
        }
    }

    @Test
    fun plausibleFilteredFrameIsCrcGated() {
        val payload = header(samples = 3) + i16le(listOf(1, 2, 3))
        val frame = puffinFrame(0x28, payload)
        assertTrue(Whoop5Ecg.plausibleFilteredFrame(frame))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertFalse("a bad CRC must not pass the triage", Whoop5Ecg.plausibleFilteredFrame(frame))
    }

    @Test
    fun outOfRangeListElementsAreRejectedRatherThanThrowing() {
        // Kotlin's List<Int> can express values Swift's [UInt8] cannot. Those inputs must fail the decode
        // rather than diverge from Swift or throw on a subscript.
        val negativeHeader = header(samples = 2).toMutableList().also { it[0] = -1 }
        assertNull(Whoop5Ecg.decodeFiltered(negativeHeader + i16le(listOf(1, 2))))
        assertNull(Whoop5Ecg.decodeHeader(negativeHeader))
        assertFalse(Whoop5Ecg.plausibleFilteredPayload(negativeHeader + i16le(listOf(1, 2))))

        val oversizedHeader = header(samples = 2).toMutableList().also { it[13] = 0x1_0000 }
        assertNull(Whoop5Ecg.decodeFiltered(oversizedHeader + i16le(listOf(1, 2))))

        // A negative leads-off count would make qEnd negative and throw on subList without the guard.
        val payload = header(samples = 2) + listOf(0, 0, 0, 0) + listOf(-5) + List(8) { 0 }
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
    }
}
