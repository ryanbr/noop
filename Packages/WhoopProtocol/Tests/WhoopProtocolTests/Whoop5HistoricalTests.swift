import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") HISTORICAL_DATA (type 47) decode, verified against a real captured frame.
///
/// These DSP biometric records are the historical equivalent of REALTIME_DATA. They only arrive once
/// the offload is acknowledged: each HISTORY_END must be echoed back with HISTORICAL_DATA_RESULT(23)
/// to advance the strap's trim cursor — without that handshake the cursor stays frozen and zero
/// type-47 frames are served (see docs/BLE_REVERSE_ENGINEERING.md §5).
///
/// The record carries its layout version in frame[9]. Real WHOOP 5 hardware on the latest firmware
/// emits **version 18**, which is NOT the repo's 4.0 v24 layout shifted by +4 — that firmware
/// revision is not what this device emits, and a naive +4 decodes to garbage. Every offset is read
/// off real frames at its absolute 5.0 position and cross-checked physiologically (rr_count == #valid
/// R-R; 60000/mean(R-R) ≈ heart_rate; |gravity| ≈ 1 g). Offsets are taken from real captures, never
/// invented.
final class Whoop5HistoricalTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// A real type-47 HISTORICAL_DATA v18 frame (worn WHOOP 5, captured 2026-06-08):
    /// unix=1780916150, hr=102, rr=[602,613] ms, |gravity| ≈ 1.0 g.
    private let historicalHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    func testHistoricalV18HeartRateRRAndGravity() {
        let f = parseFrame(bytes(historicalHex), family: .whoop5)

        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)

        // v18 absolute 5.0 offsets: hist_version@9, unix@15, heart_rate@22, rr_count@23, rr@24+
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 18)
        XCTAssertEqual(f.parsed["unix"]?.intValue, 1780916150)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 102)
        XCTAssertEqual(f.parsed["rr_count"]?.intValue, 2)
        XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, [602, 613])

        // Gravity triplet (f32) at 45/49/53 — magnitude ≈ 1 g.
        let gx = f.parsed["gravity_x"]?.doubleValue ?? 0
        let gy = f.parsed["gravity_y"]?.doubleValue ?? 0
        let gz = f.parsed["gravity_z"]?.doubleValue ?? 0
        XCTAssertEqual((gx * gx + gy * gy + gz * gz).squareRoot(), 1.0, accuracy: 0.05)

        // R-R is internally consistent with the heart rate (60000 / mean(R-R) ≈ bpm).
        let meanRR = Double(602 + 613) / 2.0
        XCTAssertEqual(60000.0 / meanRR, 102, accuracy: 8)
    }

    func testHistoricalV18BiometricFields() {
        // The cross-validated per-second fields beyond HR/gravity, each gated to a physical range and
        // verified against this real worn frame. (Optical/perfusion @69/71 still doesn't decode
        // consistently and is left in the raw region.)
        let p = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        // skin temperature: raw u16 register, °C = raw / 100. This very fixture is the proof: worn 3057 /
        // off-wrist 2247 are 30.6 °C skin and 22.5 °C room ambient under /100 (physically right on both
        // ends) but an impossible 23.9 °C "skin" under the /128 once assumed here. Raw kept in the record;
        // consumers divide by 100 (matches Android). The /100 derivation also passes the [5,45] gate.
        XCTAssertEqual(p["skin_temp_raw"]?.intValue, 3057)
        XCTAssertEqual(Double(p["skin_temp_raw"]?.intValue ?? 0) / 100.0, 30.57, accuracy: 0.01)
        // Two auxiliary thermal channels (@69/@71), each value/10 = °C, tracking skin_temp.
        XCTAssertEqual(p["temp_aux_1_raw"]?.intValue, 247)   // 24.7 °C
        XCTAssertEqual(p["temp_aux_2_raw"]?.intValue, 265)   // 26.5 °C
        // dynamic (gravity-removed) acceleration — small for a still wrist, gated to [0, 8] g.
        let dyn = p["dynamic_acceleration"]?.doubleValue ?? -1
        XCTAssertTrue((0.0...8.0).contains(dyn))
        XCTAssertEqual(dyn, 0.0092, accuracy: 0.001)
        // cumulative motion counter (full u16 at [57:59], not byte @57 alone) + wear/contact quality enum.
        XCTAssertEqual(p["step_motion_counter"]?.intValue, 50)
        XCTAssertEqual(p["motion_wear_quality"]?.intValue, 0)
        // @63 also reads as the activity-class enum (#316): this worn-still frame's byte is 0 => still.
        XCTAssertEqual(p["activity_class"]?.intValue, 0)
    }

    /// Flip a single absolute frame byte to a new value (CRC is not re-checked — the field tests read
    /// `.parsed`, which `parseFrame` populates regardless of CRC).
    private func mutating(_ index: Int, to value: UInt8) -> [UInt8] {
        var b = bytes(historicalHex); b[index] = value; return b
    }

    func testHistoricalV18ActivityClassEnum() {
        // @63 is a small validated activity-class enum: 0=still, 1=walk, 2=run, 0xFF=invalid (#316).
        // The four known codes map through; 0xFF and any other value store nothing (nil).
        XCTAssertEqual(parseFrame(mutating(63, to: 0), family: .whoop5).parsed["activity_class"]?.intValue, 0) // still
        XCTAssertEqual(parseFrame(mutating(63, to: 1), family: .whoop5).parsed["activity_class"]?.intValue, 1) // walk
        XCTAssertEqual(parseFrame(mutating(63, to: 2), family: .whoop5).parsed["activity_class"]?.intValue, 2) // run
        XCTAssertNil(parseFrame(mutating(63, to: 0xFF), family: .whoop5).parsed["activity_class"]?.intValue)   // invalid
        XCTAssertNil(parseFrame(mutating(63, to: 7), family: .whoop5).parsed["activity_class"]?.intValue)      // unknown
    }

    func testHistoricalV18StepCounterIsFullU16NotLowByte() {
        // The over-count bug (#132/#276): @57 must decode as the FULL little-endian u16 at [57:59], so the
        // high byte @58 is honoured. The fixture's low byte @57 is 0x32 (50); setting high byte @58 = 0x01
        // must read 0x0132 (= 306), NOT the low byte 50 alone.
        let b = mutating(58, to: 0x01)
        XCTAssertEqual(parseFrame(b, family: .whoop5).parsed["step_motion_counter"]?.intValue, 0x0132)
    }

    func testHistoricalV18ObservedFields() {
        // Fields read off this same real worn frame and justified by their observed behaviour:
        //  @11 record_index — a per-record counter (+1/record, independent of unix; seen on two straps)
        //  @36 hr_quality_flags — a flag byte (bit7 = valid), NOT the low half of a fixed-point HR
        //  @37 heart_rate_alt — a duplicate of heart_rate@22
        //  @59 step_cadence — a cadence-like byte (never 0; lower when moving faster)
        //  @75 status_word — a 16-bit word that is NOT a deep-sleep marker
        //  @81 sleep_state — high nibble = band state (worn daytime frame = wake)
        //  @33/@38/@40 — raw bytes near the HR/R-R fields; @113 — a float of unknown purpose
        let p = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertEqual(p["record_index"]?.intValue, 25443699)
        XCTAssertEqual(p["hr_quality_flags"]?.intValue, 141)    // 0x8D
        XCTAssertEqual(p["heart_rate_alt"]?.intValue, 101)      // ≈ hr@22 (102)
        XCTAssertEqual(p["step_cadence"]?.intValue, 170)
        XCTAssertEqual(p["status_word"]?.intValue, 1792)
        XCTAssertEqual(p["sleep_state"]?.intValue, 0)
        XCTAssertEqual(p["rr_packed"]?.intValue, 25444)
        XCTAssertEqual(p["cardiac_flags"]?.intValue, 0)
        XCTAssertEqual(p["cardiac_status"]?.intValue, 255)
        XCTAssertEqual(p["unknown_f32_113"]?.doubleValue ?? 0, -5.2307, accuracy: 0.001)
    }

    func testHistoricalV18OpticalRegionFields() {
        // The @82–119 "optical/tail" span, reverse-engineered over 18,602 real v18 records (a third strap's
        // overnight R22 stream) and cross-checked here on the two fixture devices. It is ~85% zero padding;
        // only @106/@107 (a byte pair), @108/@109 (a second byte pair) and the @113 float carry data. These
        // are carried RAW — none is named to a physiological metric (no SpO2/respiratory ground truth).
        let worn = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        // @106/@107: two independent u8 baseline channels (worn nonzero; 0 = off-wrist, see below).
        XCTAssertEqual(worn["optical_baseline_a"]?.intValue, 101)
        XCTAssertEqual(worn["optical_baseline_b"]?.intValue, 111)
        // @108/@109: a tightly-coupled pair (here 30/30). Both < 128 ⇒ the optical read is valid.
        XCTAssertEqual(worn["optical_amp_a"]?.intValue, 30)
        XCTAssertEqual(worn["optical_amp_b"]?.intValue, 30)

        // Off-wrist (HR=0): BOTH baseline bytes collapse to 0 — the real off-wrist marker (b106 == 0 in
        // exactly the 8 corpus records that also carry HR == 0, and b107 == 0 in those same 8) — and both
        // amp bytes read the 128 sentinel.
        let off = parseFrame(bytes(historicalOffWristHex), family: .whoop5).parsed
        XCTAssertEqual(off["optical_baseline_a"]?.intValue, 0)
        XCTAssertEqual(off["optical_baseline_b"]?.intValue, 0)
        XCTAssertEqual(off["optical_amp_a"]?.intValue, 128)
        XCTAssertEqual(off["optical_amp_b"]?.intValue, 128)

        // Cross-device: on the SECOND strap, HR=57 decodes fine yet the amp pair is 128/128 — the sentinel
        // marks a bad OPTICAL read, not an absent HR (HR is derived elsewhere); HR=63 carries a valid pair.
        let d2a = parseFrame(bytes(secondDeviceHR57), family: .whoop5).parsed
        XCTAssertEqual(d2a["heart_rate"]?.intValue, 57)
        XCTAssertEqual(d2a["optical_amp_a"]?.intValue, 128)
        XCTAssertEqual(d2a["optical_amp_b"]?.intValue, 128)
        // …and that same worn frame reads 128 on the @107 BASELINE byte while carrying a valid HR: 128 is
        // not a sentinel there (b106 == 128 in 10 corpus records, b107 == 128 in 103, none of them
        // off-wrist), which is why only 0 marks off-wrist on @106/@107.
        XCTAssertEqual(d2a["optical_baseline_b"]?.intValue, 128)
        let d2b = parseFrame(bytes(secondDeviceHR63), family: .whoop5).parsed
        XCTAssertEqual(d2b["heart_rate"]?.intValue, 63)
        XCTAssertEqual(d2b["optical_amp_a"]?.intValue, 36)
        XCTAssertEqual(d2b["optical_amp_b"]?.intValue, 28)
    }

    func testHistoricalV18Byte36IsAFlagByteNotAFixedPointHR() {
        // @36/@37 was read as one u16 `hr_fixed_8_8` with bpm = value/256. Over 18,650 real v18 records
        // that model is false. @36 behaves as a FLAG byte: bit 4 is NEVER set (0/18,650 — a genuine 8.8
        // fraction sets it ~50% of the time) and is the only bit never set; 95.02% of values fall in
        // 0x80–0x8F (uniform would be 6.25%) over just 40 distinct values, sd 26.5 vs 73.9 for a uniform
        // byte. @37 is a DUPLICATE heart rate: it equals heart_rate@22 exactly in 99.575% of records
        // (18,523/18,602), differing only by -6…+2. The "corr 0.989" that justified the old name is
        // circular — the u16 is literally hr@22 plus a flag byte over 256, and the residual
        // (value/256 - hr@22) is +0.504 ± 0.189, i.e. @36/256.
        let worn = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertNil(worn["hr_fixed_8_8"], "the 8.8 fixed-point reading is retired")
        XCTAssertEqual(worn["hr_quality_flags"]?.intValue, 141)          // 0x8D
        XCTAssertEqual(worn["heart_rate_alt"]?.intValue, 101)           // hr@22 = 102
        XCTAssertEqual((worn["hr_quality_flags"]?.intValue ?? 0) & 0x10, 0, "bit 4 is never set")
        XCTAssertEqual((worn["hr_quality_flags"]?.intValue ?? 0) & 0x80, 0x80, "bit 7 = valid")

        // Bit 7 is a VALIDITY bit: with it CLEAR (n=748 in the corpus) rr_count == 0 in 70.32% of records
        // vs 19.82% with it set, and the @108/@109 sentinel fires in 69.65% vs 1.32%. Both second-device
        // fixtures have it clear — and there @37 is NOT a heart rate (97 and 227 against hr@22 57 and 63),
        // which the retired model would have surfaced as a 227 bpm "high-precision" reading.
        for (hex, hr, flags, alt) in [(secondDeviceHR57, 57, 11, 97), (secondDeviceHR63, 63, 2, 227)] {
            let p = parseFrame(bytes(hex), family: .whoop5).parsed
            XCTAssertEqual(p["heart_rate"]?.intValue, hr)
            XCTAssertEqual(p["hr_quality_flags"]?.intValue, flags)
            XCTAssertEqual((p["hr_quality_flags"]?.intValue ?? 0) & 0x80, 0, "bit 7 clear ⇒ invalid")
            XCTAssertEqual(p["heart_rate_alt"]?.intValue, alt, "not a bpm when the validity bit is clear")
        }
    }

    func testHistoricalV18OpticalBaselineIsTwoBytesNotAU16() {
        // @106 was read as a u16 LE. It cannot be one: across 18,599 consecutive-second pairs the HIGH byte
        // changed while the LOW byte stayed frozen in 3,514 pairs (18.89%), and there are ZERO low-byte
        // wrap events in the whole corpus — a real u16 cannot step its high byte without a carry. The
        // apparent u16 deltas are just 256·Δb107 + Δb106 (they cluster at 0, ±1, ±255, ±256, ±257, ±513).
        // @106/@107 are two correlated but independent u8 channels (corr +0.73, moving in OPPOSITE
        // directions in 5.8% of pairs), structurally parallel to the @108/@109 pair.
        var f = bytes(historicalHex)
        f[107] = 0xFF
        let m = parseFrame(f, family: .whoop5).parsed
        XCTAssertNil(m["optical_baseline_106"], "the u16 reading is retired")
        // Moving @107 must leave the @106 channel alone — under the u16 model this byte was worth 256.
        XCTAssertEqual(m["optical_baseline_a"]?.intValue, 101)
        XCTAssertEqual(m["optical_baseline_b"]?.intValue, 255)
    }

    func testHistoricalV18OpticalAmpSentinelIsRecordLevel() {
        // The 128 sentinel on @108/@109 was noted as invalidating a single CHANNEL. It is RECORD-level:
        // over 18,650 records amp_a == 128 in 757 and amp_b == 128 in 757 — the SAME 757 records, never
        // one without the other. All four real fixtures agree, so the two bytes are never split.
        for (name, hex) in [("worn", historicalHex), ("offwrist", historicalOffWristHex),
                            ("device2_hr57", secondDeviceHR57), ("device2_hr63", secondDeviceHR63)] {
            let p = parseFrame(bytes(hex), family: .whoop5).parsed
            XCTAssertEqual(p["optical_amp_a"]?.intValue == 128, p["optical_amp_b"]?.intValue == 128,
                           "\(name): the 128 sentinel must fire on both amp bytes or neither")
        }
    }

    func testHistoricalV18OpticalFieldsAreNotNamedPhysiologically() {
        // Guard the project rule (never invent physiology): the paired optical channel must NOT be surfaced
        // as SpO2 or a named perfusion metric — those keys stay absent on v18 until real ground truth pins
        // them. If a future edit wires @108/@109 into spo2_red/spo2_ir, this fails instead of silently
        // shipping an unvalidated SpO2 reading into the datastore.
        let p = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertNil(p["spo2_red"])
        XCTAssertNil(p["spo2_ir"])
        XCTAssertNil(p["resp_rate_raw"])
    }

    func testHistoricalV18StatusWordSiblings() {
        // @77 / @79 are near-static siblings of status_word@75, distinguished by their low nibble (1, 2).
        // Read off this real worn frame (3073 = 0x0C01, 3074 = 0x0C02).
        let p = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertEqual(p["status_word_1"]?.intValue, 3073)
        XCTAssertEqual(p["status_word_2"]?.intValue, 3074)
        XCTAssertEqual((p["status_word_1"]?.intValue ?? 0) & 0xF, 1)
        XCTAssertEqual((p["status_word_2"]?.intValue ?? 0) & 0xF, 2)
    }

    func testHistoricalV18OnWristAndWakeQualityBits() {
        // @81 packs the band state (b4-5) plus an on-wrist/validity flag (b0-1) and a quality code (b2-3).
        // On the real worn daytime fixture @81 = 0 (all sub-fields 0); override just that byte to exercise
        // each bitfield independently — decode is not CRC-gated, so an in-memory edit is sufficient.
        let base = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertEqual(base["onwrist"]?.intValue, 0)
        XCTAssertEqual(base["wake_quality"]?.intValue, 0)
        var f = bytes(historicalHex)
        // raw 0b00_10_11_01 = 0x2D → sleep_state 2, wake_quality 3, onwrist 1.
        f[81] = 0x2D
        let p = parseFrame(f, family: .whoop5).parsed
        XCTAssertEqual(p["sleep_state"]?.intValue, 2)
        XCTAssertEqual(p["wake_quality"]?.intValue, 3)
        XCTAssertEqual(p["onwrist"]?.intValue, 1)
    }

    func testHistoricalV18AuxByte82() {
        // @82: a raw byte observed nonzero only while asleep. The real worn daytime fixture has it 0;
        // override it to confirm it decodes when present (no CRC gate on decode).
        let base = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertEqual(base["aux_byte_82"]?.intValue, 0)
        var f = bytes(historicalHex)
        f[82] = 0x5A
        XCTAssertEqual(parseFrame(f, family: .whoop5).parsed["aux_byte_82"]?.intValue, 0x5A)
    }

    func testHistoricalV18Spo2Candidate82TriMode() {
        // #103: the @82 SpO2 candidate surfaces ONLY the tri-mode in-band values (70–100). The raw byte
        // stays under aux_byte_82 in every mode; sentinels (bit-7: 0x80/0xA0), diagnostic codes (<70
        // nonzero) and the awake 0 must NOT produce a candidate — mirroring gen5.rs's filter(70..=100).
        // Instrumentation only: this key must never be wired into spo2Pct or any score.
        let base = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        XCTAssertNil(base["spo2_candidate_82"], "awake 0 must not read as a candidate")
        for (raw, want) in [(0x5A, 90), (70, 70), (100, 100)] {   // in-band values pass through
            var f = bytes(historicalHex)
            f[82] = UInt8(raw)
            XCTAssertEqual(parseFrame(f, family: .whoop5).parsed["spo2_candidate_82"]?.intValue, want)
        }
        for raw in [0x80, 0xA0, 0x20, 69, 101] {                  // sentinels / diagnostics / out-of-band
            var f = bytes(historicalHex)
            f[82] = UInt8(raw)
            let p = parseFrame(f, family: .whoop5).parsed
            XCTAssertNil(p["spo2_candidate_82"], "raw 0x\(String(raw, radix: 16)) must not read as a candidate")
            XCTAssertEqual(p["aux_byte_82"]?.intValue, raw, "raw byte must stay visible in every mode")
        }
    }

    func testHistoricalV18SleepStateMapping() {
        // @81's high nibble (bits 4-5) is the band's sleep state; the low nibble is sub-flags. Exercise
        // the mapping by overriding just that byte on the existing real fixture — no extra captures.
        var f = bytes(historicalHex)
        for (raw, expected) in [(0x00, 0), (0x10, 1), (0x20, 2), (0x30, 3), (0x25, 2)] {
            f[81] = UInt8(raw)
            XCTAssertEqual(parseFrame(f, family: .whoop5).parsed["sleep_state"]?.intValue, expected,
                           "raw 0x\(String(raw, radix: 16))")
        }
    }

    // MARK: - #175 band sleep_state STREAM extraction (decode → extractHistoricalStreams row)

    func testHistoricalV18SleepStateReachesStream() {
        // #175: the decoded band sleep_state must now survive extractHistoricalStreams as a
        // SleepStateSample row (it was decoded but DROPPED before). On the REAL worn daytime fixture the
        // band reads 0 (wake) — the only value we have ever captured — and that 0 is carried verbatim
        // (0 is a real wake reading, NOT "absent"), stamped at the record's own unix (1780916150).
        let f = parseFrame(bytes(historicalHex), family: .whoop5)
        let s = extractHistoricalStreams([f], deviceClockRef: 1780916150, wallClockRef: 1780916150)
        // v31 additionally carries the WHOLE @81 byte alongside `state`; on this fixture the byte is 0,
        // so both the interpreted nibble and the raw byte read 0.
        XCTAssertEqual(s.sleepState, [SleepStateSample(ts: 1780916150, state: 0, rawByte: 0)],
                       "the real worn fixture's band wake state (0) must reach the stream")
    }

    /// Set frame byte @index and RE-STAMP the WHOOP5 CRC32 trailer so the mutated frame still passes the
    /// extractor's CRC gate (unlike the parse-only tests, extractHistoricalStreams drops CRC-failed frames,
    /// which is correct). WHOOP5: declaredLength@2 (payload+4 trailer), total = len+8, payload = [8, total-4),
    /// CRC32 stored LE at total-4.
    private func mutatingCRCValid(_ index: Int, to value: UInt8) -> [UInt8] {
        var b = bytes(historicalHex)
        b[index] = value
        let declaredLength = Int(b[2]) | (Int(b[3]) << 8)
        let total = declaredLength + 8
        let payloadEnd = total - 4
        let crc = crc32(b, 8, payloadEnd)
        b[payloadEnd] = UInt8(crc & 0xFF)
        b[payloadEnd + 1] = UInt8((crc >> 8) & 0xFF)
        b[payloadEnd + 2] = UInt8((crc >> 16) & 0xFF)
        b[payloadEnd + 3] = UInt8((crc >> 24) & 0xFF)
        return b
    }

    func testHistoricalV18SleepStateStreamCarriesEachNibble() {
        // The non-zero codes come only from an in-memory byte override (we hold NO real sleeping-night
        // capture), so this proves the PLUMBING carries whatever the band reports — it does NOT assert
        // the code meanings against real data. The CRC is re-stamped so the extractor's CRC gate passes.
        for (raw, expected) in [(0x10, 1), (0x20, 2), (0x30, 3)] {
            let f = parseFrame(mutatingCRCValid(81, to: UInt8(raw)), family: .whoop5)
            XCTAssertEqual(f.crcOK, true, "the re-stamped frame must pass CRC (raw 0x\(String(raw, radix: 16)))")
            let s = extractHistoricalStreams([f], deviceClockRef: 1780916150, wallClockRef: 1780916150)
            // v31 carries the whole byte too; `state` must still be exactly its high nibble.
            XCTAssertEqual(s.sleepState, [SleepStateSample(ts: 1780916150, state: expected, rawByte: raw)],
                           "band code \(expected) must reach the stream (raw 0x\(String(raw, radix: 16)))")
        }
    }

    func testHistoricalV18SkinTempTracksWristContact() {
        // Proof @73 is the real skin-temp sensor: worn it reads skin; off-wrist the same sensor reads a
        // cooler ambient value — both pass the guard, so a valid-but-cooler off-wrist reading is still
        // captured rather than dropped. Asserted on the raw register (worn 3057 > off-wrist 2247; °C =
        // raw/100 → 30.6 °C worn skin / 22.5 °C ambient — both physiological, which is why /100 holds).
        let worn = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        let off = parseFrame(bytes(historicalOffWristHex), family: .whoop5).parsed
        XCTAssertEqual(worn["skin_temp_raw"]?.intValue, 3057)
        XCTAssertEqual(off["skin_temp_raw"]?.intValue, 2247)
        XCTAssertLessThan(off["skin_temp_raw"]?.intValue ?? .max, worn["skin_temp_raw"]?.intValue ?? 0)
        XCTAssertEqual(Double(worn["skin_temp_raw"]?.intValue ?? 0) / 100.0, 30.57, accuracy: 0.01)
        XCTAssertEqual(Double(off["skin_temp_raw"]?.intValue ?? 0) / 100.0, 22.47, accuracy: 0.01)
    }

    func testHeartRateOffsetIsNotTheNaivePlusFour() {
        // Guard the firmware caveat: v18 HR is at offset 22, NOT v24's 21+4=25. If a future change
        // wrongly reuses the 4.0 v24 layout at +4, this fails instead of silently shipping HR=0.
        // collectFields: the annotated fields array is opt-in diagnostics (D#742).
        let f = parseFrame(bytes(historicalHex), family: .whoop5, collectFields: true)
        XCTAssertEqual(f.fields.first { $0.name == "heart_rate" }?.off, 22)
        XCTAssertNotEqual(f.fields.first { $0.name == "heart_rate" }?.off, 25)
    }

    func testHistoricalFeedsStreamExtraction() {
        // The decoded v18 record flows into the datastore path (extractHistoricalStreams keys off
        // unix/heart_rate/rr_intervals/gravity_*), producing real HR, R-R and gravity samples.
        let f = parseFrame(bytes(historicalHex), family: .whoop5)
        let s = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertEqual(s.hr.map { $0.bpm }, [102])
        XCTAssertEqual(s.hr.first?.ts, 1780916150)          // real unix, no wall-clock offset
        XCTAssertEqual(s.rr.map { $0.rrMs }, [602, 613])
        XCTAssertEqual(s.gravity.count, 1)
    }

    /// A real single-R-R v18 frame (same strap): unix=1780916152, hr=101, rr=[595] ms.
    private let historicalOneRRHex =
        "aa01740001003fb12f1280753d8401b89f266a664600650153020000000000000000f8018d656365ff80702f3c7b7039bf71f5fd3e142a003f3200aa000000000000000000f7000901f30b0007010c020c0000000000000000000000000000000000000000000000010066701f1e0000005e77a8c00000001194fc6a"

    func testHistoricalSingleRR() {
        // Breadth: rr_count=1 must yield exactly one interval (not a fixed-width over-read).
        let f = parseFrame(bytes(historicalOneRRHex), family: .whoop5)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 101)
        XCTAssertEqual(f.parsed["rr_count"]?.intValue, 1)
        XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, [595])
    }

    /// A real off-wrist v18 frame (HR=0): the strap still emits a record with no biometric reading.
    private let historicalOffWristHex =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"

    func testHistoricalOffWristEmitsNoHeartRate() {
        // HR=0 is the off-wrist / no-reading sentinel; extractHistoricalStreams must skip it so a
        // 0-bpm sample never lands in the datastore.
        let f = parseFrame(bytes(historicalOffWristHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 0)
        let s = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertTrue(s.hr.isEmpty)
    }

    /// A real type-47 record of a DIFFERENT version (26, 88-byte) — a high-rate waveform buffer the
    /// same WHOOP 5 also emits. We do not map it; the decoder must describe it safely, not crash or
    /// misapply the v18 offsets.
    private let historicalV26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff405fb33c50080101006cb67c17"

    func testHistoricalUnknownVersionFallsBackSafely() {
        let f = parseFrame(bytes(historicalV26Hex), family: .whoop5)
        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 26)
        // No v18 fields are invented for an unknown version.
        XCTAssertNil(f.parsed["heart_rate"])
        XCTAssertNil(f.parsed["rr_intervals"])
        XCTAssertNil(f.parsed["gravity_x"])
    }

    // MARK: Offload handshake (the WHOOP 5 metadata + ack the app drives during a backfill)

    /// Real WHOOP 5 METADATA frames: a HISTORY_END (meta_type 2, trim=112193) and a HISTORY_START.
    private let historyEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"
    private let historyStartHex =
        "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"

    func testWhoop5MetadataClassifiesHistoryEnd() {
        // The +4 metadata decode must expose unix + trim_cursor so classifyHistoricalMeta can drive
        // the ack — without this the WHOOP 5 offload can't advance.
        let f = parseFrame(bytes(historyEndHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "METADATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(classifyHistoricalMeta(f), .end(unix: 1780917124, trim: 112193))
    }

    func testWhoop5MetadataClassifiesHistoryStart() {
        let f = parseFrame(bytes(historyStartHex), family: .whoop5)
        XCTAssertEqual(classifyHistoricalMeta(f), .start)
    }

    func testWhoop5HistoricalAckFrameMatchesHardwareProvenBytes() {
        // end_data = HISTORY_END frame[21..29] (trim 112193 + next 16). The ack must be byte-identical
        // to the Python build_history_ack that walked the cursor on real hardware.
        let endData: [UInt8] = [0x41, 0xb6, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00]
        let ack = whoop5HistoricalAckFrame(endData: endData, seq: 0)
        let hex = ack.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "aa0110000001e0d12300170141b6010010000000667da4fb")
        // And it round-trips as a valid puffin COMMAND carrying cmd 23.
        let parsed = parseFrame(ack, family: .whoop5)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.cmdName?.hasPrefix("HISTORICAL_DATA_RESULT"), true)
    }

    // Real v18 frames from a SECOND device (Galaxy S24 Ultra capture, 2026-06-11) — a different
    // strap/firmware than the 2026-06-08 device the offsets were first read from. The decisive part:
    // each frame's heart rate was cross-checked against THAT SAME device's own live REALTIME_DATA at
    // the identical unix second (57 and 63 bpm matched exactly, 53/53 over the overlap), so these are
    // ground-truth, not self-referential. This pins that the v18 layout GENERALISES, not overfits.
    private let secondDeviceHR57 =
        "aa01740001003fb12f128093c47c006dbc296a00600039000000000000000000006137020b610000e1e04c063d8fce36bf7b08233f8fea993e38a50000000000000000000019012101920b5002010c020c0100000000000000000000000000000000000000000005010085808080000000a5538ec000000016d0680d"
    private let secondDeviceHR63 =
        "aa01740001003fb12f128034d67c000ece296a0a77003f01fc0300000000000000203a0302e30000ff00f8093c1f8534bcc3a5473f4819243f85a6000000000000000000001b012601e80b5003010c020c00000000000000000000000000000000000000000000050100ced7241c0000006ead8cc00000008775b70c"

    func testHistoricalV18GeneralisesToSecondDevice() {
        for (hex, expectHR, expectUnix) in [(secondDeviceHR57, 57, 1781120109), (secondDeviceHR63, 63, 1781124622)] {
            let p = parseFrame(bytes(hex), family: .whoop5).parsed
            XCTAssertEqual(p["hist_version"]?.intValue, 18)
            XCTAssertEqual(p["unix"]?.intValue, expectUnix)
            XCTAssertEqual(p["heart_rate"]?.intValue, expectHR, "HR must match the device's own live HR at this second")
            // Gravity vector reads ~1 g on a worn strap regardless of firmware revision.
            if let gx = p["gravity_x"]?.doubleValue, let gy = p["gravity_y"]?.doubleValue, let gz = p["gravity_z"]?.doubleValue {
                let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
                XCTAssert((0.8...1.2).contains(mag), "|gravity| \(mag) out of range")
            } else {
                XCTFail("gravity did not decode")
            }
        }
    }
}
