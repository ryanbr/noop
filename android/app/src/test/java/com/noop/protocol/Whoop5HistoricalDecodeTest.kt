package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * WHOOP 5.0/MG type-47 "v18" historical decode (Android), against the SAME real captured frames the
 * macOS `Whoop5HistoricalTests` uses — so both platforms are verified to decode byte-for-byte identical
 * data. Offsets are WHOOP5-absolute (record @8), NOT the WHOOP4 V24 layout. Each per-second biometric
 * field is gated to a physical range; this test pins the real decoded values.
 */
class Whoop5HistoricalDecodeTest {

    private fun bytes(s: String): ByteArray =
        s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Real worn WHOOP 5 v18 frame: hr=102, rr=[602,613] ms, |gravity|≈1, skin temp 30.57 °C.
    private val wornV18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    // Real off-wrist v18 frame (hr=0): same thermistor reads ambient (~22.5 °C), not skin.
    private val offWristV18 =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"

    @Test
    fun decodesWhoop5V18CoreAndBiometrics() {
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)
        assertNotNull(p)
        p!!
        assertEquals(18, p["hist_version"])
        assertEquals(1780916150, p["unix"])
        assertEquals(102, p["heart_rate"])
        assertEquals(2, p["rr_count"])
        assertEquals(listOf(602, 613), p["rr_intervals"])

        val gx = p["gravity_x"] as Double
        val gy = p["gravity_y"] as Double
        val gz = p["gravity_z"] as Double
        assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.05)

        // Per-second biometric fields (verified vs the real frame).
        assertEquals(3057, p["skin_temp_raw"]) // 30.57 °C
        // @57 decodes as the FULL little-endian u16 at [57:59], not byte @57 alone (the over-count fix).
        assertEquals(50, p["step_motion_counter"])
        assertEquals(0, p["motion_wear_quality"])
        // @63 also reads as the activity-class enum (#316): this worn-still frame's byte is 0 => still.
        assertEquals(0, p["activity_class"])
        assertTrue((p["dynamic_acceleration"] as Double) in 0.0..8.0)
    }

    /** Mutate one absolute frame byte and re-stamp the CRC32 (over frame[8..len-4]) so it passes the gate. */
    private fun mutateAndReCrc(index: Int, value: Int): ByteArray {
        val f = bytes(wornV18); f[index] = value.toByte()
        val end = f.size - 4
        val crc = Crc.crc32(f.copyOfRange(8, end))
        f[end] = (crc and 0xFF).toByte(); f[end + 1] = ((crc shr 8) and 0xFF).toByte()
        f[end + 2] = ((crc shr 16) and 0xFF).toByte(); f[end + 3] = ((crc shr 24) and 0xFF).toByte()
        return f
    }

    @Test
    fun decodesV18ActivityClassEnum() {
        // @63 is a small validated activity-class enum: 0=still, 1=walk, 2=run, 0xFF=invalid (#316).
        // The four known codes map through; 0xFF and any other value store nothing (null).
        assertEquals(0, decodeHistorical(mutateAndReCrc(63, 0), DeviceFamily.WHOOP5)!!["activity_class"]) // still
        assertEquals(1, decodeHistorical(mutateAndReCrc(63, 1), DeviceFamily.WHOOP5)!!["activity_class"]) // walk
        assertEquals(2, decodeHistorical(mutateAndReCrc(63, 2), DeviceFamily.WHOOP5)!!["activity_class"]) // run
        assertNull(decodeHistorical(mutateAndReCrc(63, 0xFF), DeviceFamily.WHOOP5)!!["activity_class"])   // invalid
        assertNull(decodeHistorical(mutateAndReCrc(63, 7), DeviceFamily.WHOOP5)!!["activity_class"])      // unknown
    }

    @Test
    fun stepCounterIsFullU16NotLowByte() {
        // The over-count bug (#132/#276): @57 must decode as the FULL little-endian u16 at [57:59], so the
        // high byte @58 is honoured. The fixture's low byte @57 is 0x32 (50); setting high byte @58 = 0x01
        // must read 0x0132 (= 306), NOT the low byte 50 alone.
        assertEquals(0x0132, decodeHistorical(mutateAndReCrc(58, 0x01), DeviceFamily.WHOOP5)!!["step_motion_counter"])
    }

    @Test
    fun decodesV18ObservedFields() {
        // Fields read off the same real worn frame, justified by observed behaviour (parity with the
        // Swift Whoop5HistoricalTests.testHistoricalV18ObservedFields).
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertEquals(25443699, p["record_index"])               // @11 per-record counter
        assertEquals(141, p["hr_quality_flags"])                // @36 flag byte (0x8D), NOT a fixed-point HR
        assertEquals(101, p["heart_rate_alt"])                  // @37 duplicate HR (hr@22 = 102)
        assertEquals(170, p["step_cadence"])                    // @59 cadence-like byte (raw)
        assertEquals(1792, p["status_word"])                    // @75 not a deep-sleep marker
        assertEquals(0, p["sleep_state"])                       // @81 worn daytime frame = wake
        assertEquals(25444, p["rr_packed"])
        assertEquals(0, p["cardiac_flags"])
        assertEquals(255, p["cardiac_status"])
        assertEquals(-5.2307, p["unknown_f32_113"] as Double, 0.001)  // @113 float, purpose unknown

        // Newly-mapped adjacent fields (read off the same real worn frame).
        assertEquals(247, p["temp_aux_1_raw"])  // @69 signed i16, °C = raw/10 ≈ 24.7
        assertEquals(265, p["temp_aux_2_raw"])  // @71 signed i16, ≈ 26.5
        assertEquals(3057, p["skin_temp_raw"])  // @73 raw u16, °C = raw/100 ≈ 30.57 (physiological)
        assertEquals(3073, p["status_word_1"])  // @77 raw u16
        assertEquals(3074, p["status_word_2"])  // @79 raw u16
        assertEquals(0, p["wake_quality"])      // @81 bits 2-3
        assertEquals(0, p["onwrist"])           // @81 bits 0-1 (worn daytime, low nibble 0)
        assertEquals(0, p["aux_byte_82"])       // @82 raw byte
    }

    @Test
    fun decodesV18AuxFieldsAcrossDevices() {
        // The aux thermal pair, status words, on-wrist bit, and aux byte read consistently off the
        // other real fixtures. The second-device HR57 frame has the @81 on-wrist bit set (low nibble 1).
        val ack = decodeHistorical(bytes(androidAckCaptureV18), DeviceFamily.WHOOP5)!!
        assertEquals(294, ack["temp_aux_1_raw"])
        assertEquals(310, ack["temp_aux_2_raw"])
        assertEquals(3073, ack["status_word_1"])
        assertEquals(3074, ack["status_word_2"])
        assertEquals(3238, ack["skin_temp_raw"]) // 32.38 °C with the /100 scale

        val dev57 = decodeHistorical(bytes(secondDeviceHR57), DeviceFamily.WHOOP5)!!
        assertEquals(1, dev57["onwrist"])         // @81 low nibble = 1 on this frame
        assertEquals(0, dev57["wake_quality"])
        assertEquals(0, dev57["sleep_state"])
        assertEquals(2962, dev57["skin_temp_raw"]) // 29.62 °C
    }

    @Test
    fun spo2Candidate82SurfacesOnlyInBandValues() {
        // #103: the @82 SpO2 candidate surfaces ONLY the tri-mode in-band values (70–100). The raw byte
        // stays under aux_byte_82 in every mode; sentinels (bit-7: 0x80/0xA0), diagnostic codes (<70
        // nonzero) and the awake 0 must NOT produce a candidate — mirroring gen5.rs's filter(70..=100).
        // Instrumentation only: this key must never be wired into spo2Pct or any score. Twin of the Swift
        // testHistoricalV18Spo2Candidate82TriMode.
        val base = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertEquals(0, base["aux_byte_82"])
        assertEquals(null, base["spo2_candidate_82"])           // awake 0 is not a candidate
        for ((raw, want) in listOf(0x5A to 90, 70 to 70, 100 to 100)) {
            val p = decodeHistorical(mutateAndReCrc(82, raw), DeviceFamily.WHOOP5)!!
            assertEquals(want, p["spo2_candidate_82"])
        }
        for (raw in listOf(0x80, 0xA0, 0x20, 69, 101)) {        // sentinels / diagnostics / out-of-band
            val p = decodeHistorical(mutateAndReCrc(82, raw), DeviceFamily.WHOOP5)!!
            assertEquals(null, p["spo2_candidate_82"])
            assertEquals(raw, p["aux_byte_82"])                 // raw byte stays visible in every mode
        }
    }

    @Test
    fun band81NibblesSplitIndependently() {
        // @81 packs sleep_state (bits 4-5), wake_quality (bits 2-3) and onwrist (bits 0-1). Override the
        // byte on the real fixture and re-stamp the CRC32 (over frame[8..len-4], per Framing) so it passes
        // the gate, then check each sub-field is sliced independently.
        data class Exp(val raw: Int, val sleep: Int, val wakeQ: Int, val onwrist: Int)
        for (e in listOf(
            Exp(0x00, 0, 0, 0),
            Exp(0x39, 3, 2, 1),   // 0b00_11_10_01
            Exp(0x16, 1, 1, 2),   // 0b00_01_01_10
            Exp(0x2B, 2, 2, 3),   // 0b00_10_10_11
        )) {
            val f = bytes(wornV18); f[81] = e.raw.toByte()
            val end = f.size - 4
            val crc = Crc.crc32(f.copyOfRange(8, end))
            f[end] = (crc and 0xFF).toByte(); f[end + 1] = ((crc shr 8) and 0xFF).toByte()
            f[end + 2] = ((crc shr 16) and 0xFF).toByte(); f[end + 3] = ((crc shr 24) and 0xFF).toByte()
            val p = decodeHistorical(f, DeviceFamily.WHOOP5)!!
            assertEquals(e.sleep, p["sleep_state"])
            assertEquals(e.wakeQ, p["wake_quality"])
            assertEquals(e.onwrist, p["onwrist"])
        }
    }

    @Test
    fun sleepStateReadsHighNibbleOnly() {
        // @81 high nibble = band sleep state; low nibble = sub-flags. Override that byte on the real
        // fixture and re-stamp the CRC32 (over frame[8..len-4], per Framing) so it passes the gate.
        for ((raw, expected) in listOf(0x00 to 0, 0x10 to 1, 0x20 to 2, 0x30 to 3, 0x25 to 2)) {
            val f = bytes(wornV18); f[81] = raw.toByte()
            val end = f.size - 4
            val crc = Crc.crc32(f.copyOfRange(8, end))
            f[end] = (crc and 0xFF).toByte(); f[end + 1] = ((crc shr 8) and 0xFF).toByte()
            f[end + 2] = ((crc shr 16) and 0xFF).toByte(); f[end + 3] = ((crc shr 24) and 0xFF).toByte()
            assertEquals(expected, decodeHistorical(f, DeviceFamily.WHOOP5)!!["sleep_state"])
        }
    }

    // #175: the decoded band sleep_state must now survive extractHistoricalStreams as a SleepStateRow (it
    // was decoded but DROPPED before). On the REAL worn daytime fixture the band reads 0 (wake) — the only
    // value we have ever captured — carried VERBATIM (0 is a real wake reading, NOT "absent").
    @Test
    fun sleepStateReachesStreamOnRealFixture() {
        val st = extractHistoricalStreams(listOf(bytes(wornV18)), 1780916150, 1780916150, DeviceFamily.WHOOP5)
        // The whole @81 byte now rides alongside `state`; on this fixture the byte is 0, so both read 0.
        assertEquals(listOf(com.noop.data.SleepStateRow(1780916150L, 0, rawByte = 0)), st.sleepState)
    }

    // The non-zero codes come only from an in-memory byte override (we hold NO real sleeping-night capture),
    // so this proves the PLUMBING carries whatever the band reports. The CRC is re-stamped so the extractor's
    // CRC gate passes; it does NOT assert the code meanings against real data.
    @Test
    fun sleepStateStreamCarriesEachNibble() {
        for ((raw, expected) in listOf(0x10 to 1, 0x20 to 2, 0x30 to 3)) {
            val frame = mutateAndReCrc(81, raw)
            val st = extractHistoricalStreams(listOf(frame), 1780916150, 1780916150, DeviceFamily.WHOOP5)
            // `state` must still be exactly the high nibble of the carried raw byte.
            assertEquals(listOf(com.noop.data.SleepStateRow(1780916150L, expected, rawByte = raw)), st.sleepState)
        }
    }

    @Test
    fun skinTempTracksWristContact() {
        val worn = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        val off = decodeHistorical(bytes(offWristV18), DeviceFamily.WHOOP5)!!
        assertEquals(3057, worn["skin_temp_raw"]) // ~30.6 °C on the wrist
        assertEquals(2247, off["skin_temp_raw"]) // ~22.5 °C off the wrist (ambient), still within guard
    }

    @Test
    fun whoop4FamilyDoesNotMisreadAWhoop5Frame() {
        // Decoding a WHOOP5 frame as WHOOP4 must yield null (different envelope; type@4 != 47 / CRC differs)
        assertNull(decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP4))
    }

    // Real Android WHOOP 5.0 v18 frame from an ACK-enabled hardware offload (a clock-synced strap
    // releasing genuine body frames) — independent ground truth for the same offsets. (#78 fork)
    private val androidAckCaptureV18 =
        "aa01740001003fb12f1280aaae6f01bea0286ae11a004200000000000000000000b0000084414b38dc80b96c3c717d243dd7638f3ee182773ff6007e00000000000000000026013601a60c5004010c020c00000000000000000000000000000000000000000000010100a27c2521000000bff73ec00000002ce4150a"

    @Test
    fun decodesAndroidAckCaptureV18() {
        val p = decodeHistorical(bytes(androidAckCaptureV18), DeviceFamily.WHOOP5)
        assertNotNull(p)
        p!!
        assertEquals(18, p["hist_version"])
        assertEquals(1781047486, p["unix"])
        assertEquals(66, p["heart_rate"])
        assertEquals(3238, p["skin_temp_raw"]) // 32.38 °C on the wrist
        val gx = p["gravity_x"] as Double
        val gy = p["gravity_y"] as Double
        val gz = p["gravity_z"] as Double
        assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.05)
    }

    // A SECOND device (Galaxy S24 Ultra capture, 2026-06-11). Each HR was cross-checked against the
    // SAME device's own live REALTIME_DATA at the identical unix second (57 & 63 bpm matched exactly,
    // 53/53 over the overlap) — ground truth, not self-referential. Pins that v18 GENERALISES.
    private val secondDeviceHR57 =
        "aa01740001003fb12f128093c47c006dbc296a00600039000000000000000000006137020b610000e1e04c063d8fce36bf7b08233f8fea993e38a50000000000000000000019012101920b5002010c020c0100000000000000000000000000000000000000000005010085808080000000a5538ec000000016d0680d"
    private val secondDeviceHR63 =
        "aa01740001003fb12f128034d67c000ece296a0a77003f01fc0300000000000000203a0302e30000ff00f8093c1f8534bcc3a5473f4819243f85a6000000000000000000001b012601e80b5003010c020c00000000000000000000000000000000000000000000050100ced7241c0000006ead8cc00000008775b70c"

    @Test
    fun decodesV18FromASecondDevice() {
        for ((hex, expectHR, expectUnix) in listOf(
            Triple(secondDeviceHR57, 57, 1781120109),
            Triple(secondDeviceHR63, 63, 1781124622),
        )) {
            val p = decodeHistorical(bytes(hex), DeviceFamily.WHOOP5)
            assertNotNull(p); p!!
            assertEquals(18, p["hist_version"])
            assertEquals(expectUnix, p["unix"])
            assertEquals(expectHR, p["heart_rate"]) // == the device's own live HR at this second
            val gx = p["gravity_x"] as Double
            val gy = p["gravity_y"] as Double
            val gz = p["gravity_z"] as Double
            assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.2)
        }
    }

    @Test
    fun decodesV18OpticalRegionFields() {
        // Mirror of Swift testHistoricalV18OpticalRegionFields. The @82-119 "optical/tail" span is ~85%
        // zero padding; only the byte pairs @106/@107 and @108/@109 plus the @113 float carry data, all
        // RAW (no SpO2/respiratory ground truth). Cross-checked on both fixture devices.
        val worn = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertEquals(101, worn["optical_baseline_a"])   // @106
        assertEquals(111, worn["optical_baseline_b"])   // @107
        assertEquals(30, worn["optical_amp_a"])
        assertEquals(30, worn["optical_amp_b"])
        // Off-wrist: BOTH baseline bytes collapse to 0 — the real off-wrist marker (b106 == 0 in exactly
        // the 8 corpus records that also carry HR == 0, b107 == 0 in those same 8) — and both amp bytes
        // read the 128 sentinel.
        val off = decodeHistorical(bytes(offWristV18), DeviceFamily.WHOOP5)!!
        assertEquals(0, off["optical_baseline_a"])
        assertEquals(0, off["optical_baseline_b"])
        assertEquals(128, off["optical_amp_a"])
        assertEquals(128, off["optical_amp_b"])
        // Cross-device: HR=57 decodes fine yet the amp pair is 128/128 — the sentinel marks a bad OPTICAL
        // read, not an absent HR; HR=63 on the same strap carries a valid 36/28 pair.
        val d57 = decodeHistorical(bytes(secondDeviceHR57), DeviceFamily.WHOOP5)!!
        assertEquals(57, d57["heart_rate"])
        assertEquals(128, d57["optical_amp_a"])
        assertEquals(128, d57["optical_amp_b"])
        // …and that same worn frame reads 128 on the @107 BASELINE byte while carrying a valid HR: 128 is
        // not a sentinel there (b106 == 128 in 10 corpus records, b107 == 128 in 103, none off-wrist).
        assertEquals(128, d57["optical_baseline_b"])
        val d63 = decodeHistorical(bytes(secondDeviceHR63), DeviceFamily.WHOOP5)!!
        assertEquals(63, d63["heart_rate"])
        assertEquals(36, d63["optical_amp_a"])
        assertEquals(28, d63["optical_amp_b"])
    }

    @Test
    fun v18Byte36IsAFlagByteNotAFixedPointHR() {
        // Mirror of Swift testHistoricalV18Byte36IsAFlagByteNotAFixedPointHR. @36/@37 was read as one u16
        // `hr_fixed_8_8` with bpm = value/256. Over 18,650 real v18 records that model is false: bit 4 of
        // @36 is NEVER set (0/18,650 — a genuine 8.8 fraction sets it ~50% of the time, and it is the only
        // bit never set), 95.02% of values land in 0x80-0x8F (uniform = 6.25%) over just 40 distinct
        // values, sd 26.5 vs 73.9. @37 equals heart_rate@22 exactly in 99.575% (18,523/18,602), differing
        // only by -6..+2. The "corr 0.989" that justified the old name was circular: the u16 is hr@22 plus
        // a flag byte over 256, residual +0.504 ± 0.189.
        val worn = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertNull(worn["hr_fixed_8_8"])                        // the 8.8 fixed-point reading is retired
        assertEquals(141, worn["hr_quality_flags"])             // 0x8D
        assertEquals(101, worn["heart_rate_alt"])               // hr@22 = 102
        assertEquals(0, (worn["hr_quality_flags"] as Int) and 0x10)      // bit 4 is never set
        assertEquals(0x80, (worn["hr_quality_flags"] as Int) and 0x80)   // bit 7 = valid

        // Bit 7 is a VALIDITY bit: with it CLEAR (n=748 in the corpus) rr_count == 0 in 70.32% of records
        // vs 19.82% with it set, and the @108/@109 sentinel fires in 69.65% vs 1.32%. Both second-device
        // fixtures have it clear — and there @37 is NOT a heart rate (97 and 227 against hr@22 57 and 63),
        // which the retired model would have surfaced as a 227 bpm "high-precision" reading.
        for ((hex, expected) in listOf(secondDeviceHR57 to Triple(57, 11, 97),
                                       secondDeviceHR63 to Triple(63, 2, 227))) {
            val (hr, flags, alt) = expected
            val p = decodeHistorical(bytes(hex), DeviceFamily.WHOOP5)!!
            assertEquals(hr, p["heart_rate"])
            assertEquals(flags, p["hr_quality_flags"])
            assertEquals(0, (p["hr_quality_flags"] as Int) and 0x80)   // bit 7 clear ⇒ invalid
            assertEquals(alt, p["heart_rate_alt"])                     // not a bpm when invalid
        }
    }

    @Test
    fun v18OpticalBaselineIsTwoBytesNotAU16() {
        // Mirror of Swift testHistoricalV18OpticalBaselineIsTwoBytesNotAU16. @106 was read as a u16 LE. It
        // cannot be one: across 18,599 consecutive-second pairs the HIGH byte changed while the LOW byte
        // stayed frozen in 3,514 (18.89%), and the corpus holds ZERO low-byte wrap events — a real u16
        // cannot step its high byte without a carry. The apparent u16 deltas are just 256·Δb107 + Δb106.
        // The two bytes are independent u8 channels (corr +0.73, moving in OPPOSITE directions in 5.8% of
        // pairs), structurally parallel to the @108/@109 pair.
        val m = decodeHistorical(mutateAndReCrc(107, 0xFF), DeviceFamily.WHOOP5)!!
        assertNull(m["optical_baseline_106"])                   // the u16 reading is retired
        // Moving @107 must leave the @106 channel alone — under the u16 model it was worth 256.
        assertEquals(101, m["optical_baseline_a"])
        assertEquals(255, m["optical_baseline_b"])
    }

    @Test
    fun v18OpticalAmpSentinelIsRecordLevel() {
        // Mirror of Swift testHistoricalV18OpticalAmpSentinelIsRecordLevel. The 128 sentinel on @108/@109
        // was noted as invalidating a single CHANNEL. It is RECORD-level: over 18,650 records amp_a == 128
        // in 757 and amp_b == 128 in 757 — the SAME 757, never one without the other. All four real
        // fixtures agree, so the two bytes are never split.
        for (hex in listOf(wornV18, offWristV18, secondDeviceHR57, secondDeviceHR63)) {
            val p = decodeHistorical(bytes(hex), DeviceFamily.WHOOP5)!!
            assertEquals("the 128 sentinel must fire on both amp bytes or neither",
                         p["optical_amp_a"] == 128, p["optical_amp_b"] == 128)
        }
    }

    @Test
    fun v18OpticalFieldsAreNotNamedPhysiologically() {
        // Guard the project rule: the paired optical channel must NOT be surfaced as SpO2/perfusion
        // without on-device ground truth — those keys stay absent on v18 (mirror of the Swift guard).
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertNull(p["spo2_red"])
        assertNull(p["spo2_ir"])
        assertNull(p["resp_rate_raw"])
    }
}
