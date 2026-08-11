package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden per-tag fixture tests: raw TLV record bytes -> expected decoded event(s). Kotlin twin of the
 * Swift DecoderGoldenTests.swift.
 *
 * PARITY NOTE: every fixture hex string below is byte-for-byte identical to the Swift
 * DecoderGoldenTests fixtures, so the SAME raw record bytes must decode to the SAME values across the
 * Swift and Kotlin ports (that is the whole point of the twin). Most vectors are SYNTHETIC, built from
 * the byte layouts in docs/OURA_PROTOCOL.md s6 — EXCEPT the 0x60 and 0x80 IBI packets, which are two
 * real captured records (a handful of anonymous inter-beat intervals) used to pin the byte-scatter
 * decode against a known-good beat train. The full record is `type len rt(4 LE) payload` with
 * rt = 0x00010002 (counter 2, session 1) throughout, so every assertion pins ringTimestamp == 65538.
 */
class DecoderGoldenTest {
    private val rt: Long = 0x0001_0002   // 65538
    private val eps = 1e-9

    private fun bytes(s: String) = OuraTestHex.bytes(s)

    /** Parse one record from hex and assert the header decoded as expected. */
    private fun record(hex: String): OuraRecord {
        val rec = OuraFraming.parseRecord(bytes(hex))
            ?: throw AssertionError("record failed to parse: $hex")
        assertEquals(rt, rec.ringTimestamp)
        return rec
    }

    // MARK: - 0x80 green IBI quality (high-byte-first 11-bit IBI; quality==1 gate)

    @Test
    fun testGreenIBIQuality0x80RealCapture() {
        // Real 0x80 record from an overnight capture: 7 samples. Six are quality 1 and form a clean
        // ~70 bpm train; the 7th (846 ms) is quality 3 and must be rejected. Validated against open_oura.
        val rec = record("801202000100698c660e652a6a09670f6d2b693e")
        val ibis = OuraDecoders.decodeGreenIBIQuality(rec)
        assertEquals(listOf(844, 822, 810, 849, 831, 875), ibis?.map { it.ibiMs })
    }

    // MARK: - 0x60 IBI + amplitude (byte-scatter 11-bit IBIs; shift from b13 low nibble)

    @Test
    fun testIBIAmplitude0x60RealCapture() {
        // Real 0x60 record from an overnight capture: six IBIs forming a coherent ~60 bpm train under
        // the byte-scatter layout (the old linear-bitstream decode scrambled all but the first).
        // Validated against open_oura parse_api_ibi_and_amplitude_event.
        val rec = record("601202000100807b77757a78e4ddccd4e8d79d33")
        val ibis = OuraDecoders.decodeIBIAmplitude(rec)
        assertEquals(listOf(1028, 987, 958, 938, 976, 967), ibis?.map { it.ibiMs })
        assertEquals(listOf(1824, 1760, 1632, 1696, 1856, 1712), ibis?.map { it.amplitude })
    }

    // MARK: - 0x6E SpO2 IBI (REVERSE byte order x8)

    @Test
    fun testSpO2IBI0x6EReverseOrder() {
        // body[1..5] = 10,20,30,40,50 read 5->1 reversed -> 50,40,30,20,10 then x8.
        val rec = record("6e0a02000100000a141e2832")
        val ibis = OuraDecoders.decodeSpO2IBI(rec)
        assertEquals(
            listOf(
                OuraIBI(ringTimestamp = rt, ibiMs = 400, channel = OuraIbiChannel.SPO2_IBI),
                OuraIBI(ringTimestamp = rt, ibiMs = 320, channel = OuraIbiChannel.SPO2_IBI),
                OuraIBI(ringTimestamp = rt, ibiMs = 240, channel = OuraIbiChannel.SPO2_IBI),
                OuraIBI(ringTimestamp = rt, ibiMs = 160, channel = OuraIbiChannel.SPO2_IBI),
                OuraIBI(ringTimestamp = rt, ibiMs = 80, channel = OuraIbiChannel.SPO2_IBI),
            ),
            ibis,
        )
    }

    // MARK: - 0x5D HRV / RMSSD

    @Test
    fun testHRV0x5D() {
        // (u8 hr, u8 rmssd) pairs — real overnight bytes: 32 84 32 83 -> (50,132),(50,131).
        // hr=50 bpm is sleeping HR (validates the layout; matches the #511 IBI-derived median).
        val rec = record("5d080200010032843283")
        val hrv = OuraDecoders.decodeHRV(rec)
        assertEquals(
            listOf(
                OuraHRV(ringTimestamp = rt, index = 0, hrBpm = 50, rmssdMs = 132, count = 2),
                OuraHRV(ringTimestamp = rt, index = 1, hrBpm = 50, rmssdMs = 131, count = 2),
            ),
            hrv,
        )
    }

    @Test
    fun testHRV0x5DOddLengthIsNull() {
        // A partial trailing pair (odd body length) must decode to null, never a half-sample.
        assertNull(OuraDecoders.decodeHRV(record("5d0702000100328432")))
    }

    // MARK: - 0x5D `00 00` tail padding (#1128)

    @Test
    fun testHRV0x5DDropsTailPadding() {
        // A record that closes early pads its tail with `00 00`. That pair is not a reading, and a
        // stored hr_bpm: 0 is a fabricated value nothing downstream can tell from a measurement. Real
        // shape, from the 2026-08-07 overnight: ... 48/128 47/137 ... 0/0.
        val hrv = OuraDecoders.decodeHRV(record("5d0a02000100328432830000"))
        assertEquals(
            listOf(
                // count is 3, not 2: the dropped pad still counts, or the survivors slide (#1167).
                OuraHRV(ringTimestamp = rt, index = 0, hrBpm = 50, rmssdMs = 132, count = 3),
                OuraHRV(ringTimestamp = rt, index = 1, hrBpm = 50, rmssdMs = 131, count = 3),
            ),
            hrv,
        )
    }

    @Test
    fun testHRV0x5DAllPaddingIsNull() {
        // A body that is ENTIRELY padding carries no bucket at all, so it decodes to null (honest
        // no-data) rather than to an empty list a caller might read as "decoded fine, zero readings".
        assertNull(OuraDecoders.decodeHRV(record("5d06020001000000")))
    }

    @Test
    fun testHRV0x5DZeroPairConsumesItsIndex() {
        // THE ONE THAT MATTERS: a skipped pair must still CONSUME its index. `index` is not a label —
        // OuraStreamMapping derives the bucket's wall-clock from it (bucketTs = ts - index * 300), so
        // renumbering the survivors would slide every later bucket 5 minutes into the past.
        //
        // Tail padding cannot detect that mistake (nothing follows the pad), which is why this plants
        // the zero pair in the MIDDLE: the bucket after it must keep index 2, not collapse to index 1.
        // Only tail padding has been observed in the wild; this guards the shape we have not seen yet.
        val hrv = OuraDecoders.decodeHRV(record("5d0a02000100328400003182"))
        assertEquals(
            listOf(
                OuraHRV(ringTimestamp = rt, index = 0, hrBpm = 50, rmssdMs = 132, count = 3),
                OuraHRV(ringTimestamp = rt, index = 2, hrBpm = 49, rmssdMs = 130, count = 3),
            ),
            hrv,
        )
    }

    @Test
    fun testHRV0x5DLoneZeroByteIsNotTreatedAsPadding() {
        // A genuine bucket with ONE zero byte is not padding and must survive: the rule keys on both
        // bytes being zero, so a real reading with a zero byte stays visible as the anomaly it would be.
        val hrv = OuraDecoders.decodeHRV(record("5d080200010032000083"))
        assertEquals(
            listOf(
                OuraHRV(ringTimestamp = rt, index = 0, hrBpm = 50, rmssdMs = 0, count = 2),
                OuraHRV(ringTimestamp = rt, index = 1, hrBpm = 0, rmssdMs = 131, count = 2),
            ),
            hrv,
        )
    }

    // MARK: - 0x6F SpO2 per-sample (base from high nibble << 7, then u8, 0xFF terminator)

    @Test
    fun testSpO2PerSample0x6F() {
        // byte6 high nibble 1 (base/status, discarded) ; samples 95,96 ; FF terminator (#968).
        val rec = record("6f0802000100105f60ff")
        val s = OuraDecoders.decodeSpO2PerSample(rec)
        // Every sample keeps the RECORD's ringTimestamp and carries its own position, so the consumer can
        // give each one its own second instead of collapsing the record onto one (#1070). Swift twin.
        assertEquals(
            listOf(
                OuraSpO2(ringTimestamp = rt, value = 95, index = 0, count = 2),
                OuraSpO2(ringTimestamp = rt, value = 96, index = 1, count = 2),
            ),
            s,
        )
    }

    @Test
    fun testSpO2PerSample0x6FStampsPositionForEverySample() {
        // A full 13-value record, the real Gen 3 shape: indices 0..12, count 13 on every sample, and the
        // record's own ringTimestamp untouched. Terminator absent.
        // len 0x12 = 4 rt + 1 status + 13 values.
        val body = (0 until 13).joinToString("") { String.format("%02x", 90 + it) }
        val rec = record("6f120200010000" + body)
        val s = OuraDecoders.decodeSpO2PerSample(rec)!!
        assertEquals(13, s.size)
        assertEquals((0 until 13).toList(), s.map { it.index })
        assertEquals(List(13) { 13 }, s.map { it.count })
        assertTrue(s.all { it.ringTimestamp == rt })
    }

    @Test
    fun testSpO2DC0x77StampsPositionForEverySample() {
        // 0x77 shares the multi-sample shape, so it stamps the same way.
        // len 0x0b = 4 rt + 1 header + 3 base + 3 deltas ; hasBase -> base is sample 0, then 3 deltas.
        val rec = record("770b02000100400a0000" + "01ff02")
        val s = OuraDecoders.decodeSpO2DC(rec)!!
        assertEquals(listOf(0, 1, 2, 3), s.map { it.index })
        assertEquals(listOf(4, 4, 4, 4), s.map { it.count })
    }

    // MARK: - 0x7B SpO2 stable (BIG-endian footgun)

    @Test
    fun testSpO2Stable0x7BIsBigEndian() {
        // BE 0x03CA = 970. If decoded LE it would be 0xCA03 = 51715, so this proves the BE path.
        val rec = record("7b060200010003ca")
        val s = OuraDecoders.decodeSpO2Stable(rec)
        assertEquals(OuraSpO2(ringTimestamp = rt, value = 970), s)
    }

    // MARK: - 0x46 temperature (int16 LE / 100)

    @Test
    fun testTemp0x46() {
        // 3650/100 = 36.50 ; 3655/100 = 36.55
        val rec = record("460802000100420e470e")
        val t = OuraDecoders.decodeTemp(rec)!!
        assertEquals(2, t.size)
        assertEquals(rt, t[0].ringTimestamp)
        assertEquals(36.50, t[0].celsius, eps)
        assertEquals(36.55, t[1].celsius, eps)
    }

    // MARK: - 0x42 time sync (int64 LE epoch ms + tz int8 x1800)

    @Test
    fun testTimeSync0x42() {
        // epoch 1719662400000 ms, tz byte 2 -> 3600 s.
        val rec = record("420d0200010000d2dd639001000002")
        val ts = OuraDecoders.decodeTimeSync(rec)
        assertEquals(OuraTimeSync(ringTimestamp = rt, epochMs = 1_719_662_400_000L, tzOffsetSeconds = 3600), ts)
    }

    // MARK: - 0x4E sleep phase (2-bit codes MSB-first; header byte skipped)

    @Test
    fun testSleepPhase0x4E() {
        // header 0x00, phase byte 0x6C = bits 01 10 11 00 = codes 1,2,3,0. Per open_oura's VALIDATED
        // mapping (0=deep, 1=light, 2=rem, 3=awake) -> light, rem, awake, deep. PARITY: byte-identical
        // to the Swift golden (DecoderGoldenTests.testSleepPhase0x4E).
        val rec = record("4e0602000100006c")
        val phases = OuraDecoders.decodeSleepPhase(rec)
        assertEquals(
            listOf(
                OuraSleepPhase(ringTimestamp = rt, index = 0, stage = OuraSleepStage.LIGHT),
                OuraSleepPhase(ringTimestamp = rt, index = 1, stage = OuraSleepStage.REM),
                OuraSleepPhase(ringTimestamp = rt, index = 2, stage = OuraSleepStage.AWAKE),
                OuraSleepPhase(ringTimestamp = rt, index = 3, stage = OuraSleepStage.DEEP),
            ),
            phases,
        )
    }

    @Test
    fun testSleepPhase0x4EWholeFFRecordIsUnwritten() {
        // #1246: two 0xFF code bytes (an erased/unwritten flash page). Flagged unwritten so the assembler
        // drops them as a GAP instead of 8 awake epochs. PARITY twin of the Swift test.
        val rec = record("4e070200010000ffff")
        val phases = OuraDecoders.decodeSleepPhase(rec)
        assertEquals(8, phases?.size)
        assertTrue(phases!!.all { it.unwritten && it.stage == OuraSleepStage.AWAKE })
    }

    @Test
    fun testSleepPhase0x4ELoneFFByteIsGenuineAwake() {
        // #1246 caution: a SINGLE 0xFF code byte is four genuine AWAKE epochs, NOT an erased page — it must
        // stay written (only a run of >=2 all-0xFF code bytes reads as unwritten). PARITY twin of Swift.
        val rec = record("4e060200010000ff")
        val phases = OuraDecoders.decodeSleepPhase(rec)
        assertEquals(4, phases?.size)
        assertTrue(phases!!.none { it.unwritten })
        assertTrue(phases.all { it.stage == OuraSleepStage.AWAKE })
    }

    @Test
    fun testSleepPhase0x4EMixedFFIsWritten() {
        // A record that is NOT entirely 0xFF is genuine data — its 0xFF byte is four REAL awake epochs, so
        // none of the record is flagged unwritten. Guards against a byte-level filter eating genuine wake.
        val rec = record("4e0702000100006cff")
        val phases = OuraDecoders.decodeSleepPhase(rec)
        assertEquals(8, phases?.size)
        assertTrue(phases!!.none { it.unwritten })
        assertTrue(phases.takeLast(4).all { it.stage == OuraSleepStage.AWAKE })
    }

    @Test
    fun testSleepStageRawValuesMatchOpenOura() {
        // Pin the validated open_oura order (0=deep, 1=light, 2=rem, 3=awake) so a regression to the
        // old unverified mapping (0=awake/2=deep/3=REM) breaks loudly. Twin of the Swift enum.
        assertEquals(0, OuraSleepStage.DEEP.raw)
        assertEquals(1, OuraSleepStage.LIGHT.raw)
        assertEquals(2, OuraSleepStage.REM.raw)
        assertEquals(3, OuraSleepStage.AWAKE.raw)
    }

    // MARK: - 0x6B motion period (2-bit MOTION_STATE codes; 2 header bytes skipped)

    @Test
    fun testMotionPeriod0x6B() {
        // 2 header bytes 0x00 0x00, code byte 0x1B = 00 01 10 11 -> noMotion, restless, tossing, active.
        val rec = record("6b070200010000001b")
        val m = OuraDecoders.decodeMotionPeriod(rec)
        assertEquals(
            listOf(
                OuraMotion(ringTimestamp = rt, index = 0, state = OuraMotionState.NO_MOTION),
                OuraMotion(ringTimestamp = rt, index = 1, state = OuraMotionState.RESTLESS),
                OuraMotion(ringTimestamp = rt, index = 2, state = OuraMotionState.TOSSING),
                OuraMotion(ringTimestamp = rt, index = 3, state = OuraMotionState.ACTIVE),
            ),
            m,
        )
    }

    // MARK: - 0x47 motion events (averaged accel vector)

    @Test
    fun testMotionEvents0x47() {
        // open_oura decode_motion vector [0x6f,0x0c,0x1d,0x07,0x0c,0x07]: orientation 0x6f>>5=3,
        // motion_seconds 0x6f&0x1f=15, avg 96/232/56, low 12, high 7.
        val rec = OuraRecord(type = 0x47, ringTimestamp = rt,
            payload = intArrayOf(0x6f, 0x0c, 0x1d, 0x07, 0x0c, 0x07))
        assertEquals(
            OuraMotionEvent(ringTimestamp = rt, orientation = 3, motionSeconds = 15,
                avgX = 96, avgY = 232, avgZ = 56, lowIntensity = 12, highIntensity = 7),
            OuraDecoders.decodeMotionEvents(rec),
        )
    }

    @Test
    fun testMotionEvents0x47DiscriminatesOrientationFromMotionSeconds() {
        // byte0 0xB5 = 1011_0101: orientation 0xB5>>5=5 (NOT &0x03=1), motion_seconds 0x15=21.
        // Negative axes prove ×8 sign; byte4 0x2A → low 42; byte5 0x3F → high 63 (max valid).
        val rec = OuraRecord(type = 0x47, ringTimestamp = rt,
            payload = intArrayOf(0xB5, 0xF4, 0x00, 0x80, 0x2A, 0x3F))
        assertEquals(
            OuraMotionEvent(ringTimestamp = rt, orientation = 5, motionSeconds = 21,
                avgX = -96, avgY = 0, avgZ = -1024, lowIntensity = 42, highIntensity = 63),
            OuraDecoders.decodeMotionEvents(rec),
        )
    }

    @Test
    fun testMotionEvents0x47IntensityValidityBitRejectsRecord() {
        // A set 0x40 bit in an intensity byte means INVALID per open_oura → whole record decodes null.
        assertNull(OuraDecoders.decodeMotionEvents(
            OuraRecord(type = 0x47, ringTimestamp = rt, payload = intArrayOf(0x00, 0, 0, 0, 0x00, 0x47))))
        assertNull(OuraDecoders.decodeMotionEvents(
            OuraRecord(type = 0x47, ringTimestamp = rt, payload = intArrayOf(0x00, 0, 0, 0, 0x40, 0x00))))
    }

    @Test
    fun testMotionEvents0x47OptionalIntensityAndShortBody() {
        // A 4-byte record is valid; intensities null.
        assertEquals(
            OuraMotionEvent(ringTimestamp = rt, orientation = 1, motionSeconds = 0,
                avgX = 80, avgY = 0, avgZ = 0, lowIntensity = null, highIntensity = null),
            OuraDecoders.decodeMotionEvents(
                OuraRecord(type = 0x47, ringTimestamp = rt, payload = intArrayOf(0x20, 0x0a, 0x00, 0x00))),
        )
        // A 3-byte body is too short → null.
        assertNull(OuraDecoders.decodeMotionEvents(
            OuraRecord(type = 0x47, ringTimestamp = rt, payload = intArrayOf(0x6f, 0x0c, 0x1d))))
    }

    // MARK: - 0x85 RTC beacon (unix_s u32 LE)

    @Test
    fun testRtcBeacon0x85() {
        val rec = record("850e0200010040f77f6600000000f601")
        val r = OuraDecoders.decodeRtcBeacon(rec)
        assertEquals(OuraRtcBeacon(ringTimestamp = rt, unixSeconds = 1_719_662_400L), r)
    }

    // MARK: - 0x45 state change

    @Test
    fun testState0x45() {
        val rec = record("45050200010004")
        val s = OuraDecoders.decodeState(rec)
        assertEquals(4, s?.stateCode)     // user_in_rest
        assertNull(s?.text)               // body too short for a trailing string
    }

    // MARK: - 0x43 debug text

    @Test
    fun testDebugText0x43() {
        val rec = record("4306020001004142")
        assertEquals("AB", OuraDecoders.decodeDebugText(rec))
    }

    // MARK: - 0x0D battery (outer response body; percent at [0], voltage at [4..6] LE)

    @Test
    fun testBattery0x0D() {
        // body: 87%, charging 0, voltage 3900 mv at bytes 4..6.
        val body = bytes("570000003c0f0000")
        val b = OuraDecoders.decodeBattery(body)
        assertEquals(OuraBattery(percent = 87, voltageMv = 3900, charging = false), b)
    }

    @Test
    fun testBatteryRejectsImplausiblePercent() {
        // A "percent" > 100 is a misread; decode to null, never a guessed value.
        val body = intArrayOf(200, 0, 0, 0, 0, 0)
        assertNull(OuraDecoders.decodeBattery(body))
    }

    // MARK: - Live HR push (12-bit nibble IBI -> bpm), built from the s5.6 wire layout

    /**
     * The fixture is derived from the OURA_PROTOCOL.md s5.6 wire frame, NOT from the implementation:
     *   full frame = `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f` (len 0x0f = 15)
     * The transport strips the leading `2f 0f 28`, so the decoder receives the 14-byte subBody with the
     * IBI at subBody[5..6]. Here IBI_L=0x01, IBI_H=0x04 -> ibi ((0x04 & 0x0F)<<8)|0x01 = 1025 ->
     * bpm round(60000/1025) = 59. Byte-for-byte identical to the Swift fixture. Per OURA_PROTOCOL.md s5.6.
     */
    @Test
    fun testLiveHRPushNibbleIBI() {
        val fullFrame = bytes("2f0f28020002000001040000000000007f")
        // Self-check the wire layout: type 0x2f, len 0x0f (15) counts the bytes after type+len, i.e. the
        // subop byte plus the subBody (s2.2). So subBody.size must equal len - 1.
        assertEquals(0x2F, fullFrame[0])
        assertEquals(0x0F, fullFrame[1])
        assertEquals(15, fullFrame[1])
        assertEquals(2 + fullFrame[1], fullFrame.size)          // type + len + 15 body bytes = 17
        // Strip `2f 0f 28` (type, len, subop) exactly as the transport does -> the 14-byte subBody.
        assertArrayEquals(intArrayOf(0x2F, 0x0F, 0x28), fullFrame.copyOfRange(0, 3))
        val subBody = fullFrame.copyOfRange(3, fullFrame.size)
        assertEquals(fullFrame[1] - 1, subBody.size)            // 14 == len(15) - subop(1)
        assertEquals(14, subBody.size)
        // The IBI is at subBody index 5 (low) / 6 (high) per the stripped s5.6 layout.
        assertEquals(0x01, subBody[5])
        assertEquals(0x04, subBody[6])

        val hr = OuraDecoders.decodeLiveHRPush(subBody, rt)
        assertEquals(OuraHR(ringTimestamp = rt, bpm = 59, ibiMs = 1025), hr)
    }

    // MARK: - 0x71 green_ibi_and_amp CANDIDATE decode (ringverse @0x503960, upstream #287)

    /**
     * Inverse of the firmware's scrambled packing (ringverse `p_green_ibi_and_amp`): middle-8 bytes
     * at p[4..0] (ds0..ds4), amplitude bytes p[6..10] carry the mantissa in bits [7:1] and the
     * PAIRED IBI's low bit in bit [0] (ds4..ds0 order), bits [2:1] of ds1..ds4 pack into p[12]
     * two bits at a time, ds0's into p[13] bits [7:6] alongside the shift field. Twin of the Swift
     * packGreenIBIAmp test helper.
     */
    private fun packGreenIBIAmp(ibis: IntArray, mants: IntArray, s: Int): IntArray {
        val p = IntArray(14)
        val mids = intArrayOf(4, 3, 2, 1, 0)
        for (i in 0 until 5) p[mids[i]] = (ibis[i] shr 3) and 0xFF
        val amps = intArrayOf(10, 9, 8, 7, 6)
        for (i in 0 until 5) p[amps[i]] = ((mants[4 - i] shl 1) or (ibis[i] and 1)) and 0xFF
        var pack12 = (ibis[1] shr 1) and 3
        pack12 = pack12 or (((ibis[2] shr 1) and 3) shl 2)
        pack12 = pack12 or (((ibis[3] shr 1) and 3) shl 4)
        pack12 = pack12 or (((ibis[4] shr 1) and 3) shl 6)
        p[12] = pack12
        p[13] = (s and 7) or (((ibis[0] shr 1) and 3) shl 6)
        return p
    }

    @Test
    fun testGreenIBIAmpCandidateRoundTrip() {
        // 11-bit IBIs exercising every packed bit field; 7-bit mantissas; s=3 -> shift 4.
        val ibis = intArrayOf(1023, 800, 517, 2046, 901)
        val mants = intArrayOf(1, 64, 100, 127, 33)
        val p = packGreenIBIAmp(ibis, mants, s = 3)
        val decoded = OuraDecoders.decodeGreenIBIAmpCandidate(p, rt)
        assertNotNull(decoded)
        assertEquals(4, decoded!!.shift)
        val samples = decoded.samples
        assertEquals(6, samples.size)
        // First entry is amplitude-only (ibi 0, amp = as[0] = mantissa of p[6] << shift).
        assertEquals(0, samples[0].ibiMs)
        assertEquals(mants[0] shl 4, samples[0].amplitude)
        // The five IBI entries recover the exact packed values; amps pair as[i] per the firmware order.
        assertEquals(ibis.toList(), samples.drop(1).map { it.ibiMs })
        assertEquals(mants.map { it shl 4 }, samples.drop(1).map { it.amplitude })
    }

    @Test
    fun testGreenIBIAmpCandidateGates() {
        // s == 7 means shift 0 (identity amplitudes).
        val p7 = packGreenIBIAmp(intArrayOf(500, 500, 500, 500, 500), intArrayOf(10, 10, 10, 10, 10), s = 7)
        assertEquals(0, OuraDecoders.decodeGreenIBIAmpCandidate(p7, rt)?.shift)
        // Reserved bit [3] of p[13] set -> firmware mismatch -> null, never a guessed decode.
        val bad = p7.copyOf()
        bad[13] = bad[13] or 0x08
        assertNull(OuraDecoders.decodeGreenIBIAmpCandidate(bad, rt))
        // Strict 14-byte gate: any other length is a different firmware layout -> null.
        assertNull(OuraDecoders.decodeGreenIBIAmpCandidate(p7.copyOfRange(0, 13), rt))
        assertNull(OuraDecoders.decodeGreenIBIAmpCandidate(p7 + intArrayOf(0x00), rt))
    }

    // MARK: - 0x4B routes to the SAME validated phase decode as 0x4E/0x5A (parity with Swift dddbe952)

    @Test
    fun testSleepPhase4BDecodesAsHypnogramNotSummary() {
        // 4b 07 <rt:4> <header> <1b = 00 01 10 11 MSB-first = deep,light,rem,awake>.
        val rec = record("4b070200010000" + "1b")
        assertEquals(OuraEventTag.SLEEP_PHASE_B, OuraEventTag.fromRaw(rec.type))
        assertEquals(TrustTier.TIER_A, OuraEventTag.SLEEP_PHASE_B.tier)
        val phases = OuraDecoders.decodeSleepPhase(rec)
        assertEquals(
            listOf(OuraSleepStage.DEEP, OuraSleepStage.LIGHT, OuraSleepStage.REM, OuraSleepStage.AWAKE),
            phases?.map { it.stage },
        )
        // And the driver ingests it as SleepPhaseEvent(s), not a Tier-B summary wrapper.
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        val events = d.ingest(rec)
        assertEquals(4, events.size)
        assertTrue(events.all { it is OuraEvent.SleepPhaseEvent })
    }

    // MARK: - Honest-data invariant: short / malformed records decode to null

    @Test
    fun testShortRecordsDecodeToNil() {
        // A 0x7B record with a 1-byte payload (needs 2 for the u16) -> null, not a guess.
        val shortSpO2 = OuraRecord(type = 0x7B, ringTimestamp = rt, payload = intArrayOf(0x03))
        assertNull(OuraDecoders.decodeSpO2Stable(shortSpO2))
        // A 0x46 temp with an ODD payload length -> null.
        val oddTemp = OuraRecord(type = 0x46, ringTimestamp = rt, payload = intArrayOf(0x01, 0x02, 0x03))
        assertNull(OuraDecoders.decodeTemp(oddTemp))
        // An empty HRV body -> null.
        assertNull(OuraDecoders.decodeHRV(OuraRecord(type = 0x5D, ringTimestamp = rt, payload = intArrayOf())))
    }
}
