import XCTest
@testable import OuraProtocol

/// Golden per-tag fixture tests: raw TLV record bytes -> expected decoded event(s). Most vectors are
/// SYNTHETIC, built from the byte layouts in docs/OURA_PROTOCOL.md s6 — EXCEPT the 0x60 and 0x80 IBI
/// packets, which are two real captured records (a handful of anonymous inter-beat intervals) used to
/// pin the byte-scatter decode against a known-good ~60/70 bpm beat train. The full record is
/// `type len rt(4 LE) payload` with rt = 0x00010002 (counter 2, session 1) throughout, so every
/// assertion pins ringTimestamp == 65538.
final class DecoderGoldenTests: XCTestCase {
    private let rt: UInt32 = 0x0001_0002   // 65538

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// Parse one record from hex and assert the header decoded as expected.
    private func record(_ hex: String) -> OuraRecord {
        guard let rec = OuraFraming.parseRecord(bytes(hex)) else {
            XCTFail("record failed to parse: \(hex)"); return OuraRecord(type: 0, ringTimestamp: 0, payload: [])
        }
        XCTAssertEqual(rec.ringTimestamp, rt)
        return rec
    }

    // MARK: - 0x80 green IBI quality (high-byte-first 11-bit IBI; quality==1 gate)

    func testGreenIBIQuality0x80RealCapture() {
        // Real 0x80 record from an overnight capture: 7 samples. Six are quality 1 and form a clean
        // ~70 bpm train; the 7th (846 ms) is quality 3 and must be rejected. Validated against open_oura.
        let rec = record("801202000100698c660e652a6a09670f6d2b693e")
        let ibis = OuraDecoders.decodeGreenIBIQuality(rec)
        XCTAssertEqual(ibis?.map { $0.ibiMs }, [844, 822, 810, 849, 831, 875])
    }

    // MARK: - 0x60 IBI + amplitude (byte-scatter 11-bit IBIs; shift from b13 low nibble)

    func testIBIAmplitude0x60RealCapture() {
        // Real 0x60 record from an overnight capture: six IBIs forming a coherent ~60 bpm train under
        // the byte-scatter layout (the old linear-bitstream decode scrambled all but the first).
        // Validated against open_oura parse_api_ibi_and_amplitude_event.
        let rec = record("601202000100807b77757a78e4ddccd4e8d79d33")
        let ibis = OuraDecoders.decodeIBIAmplitude(rec)
        XCTAssertEqual(ibis?.map { $0.ibiMs }, [1028, 987, 958, 938, 976, 967])
        XCTAssertEqual(ibis?.map { $0.amplitude }, [1824, 1760, 1632, 1696, 1856, 1712])
    }

    // MARK: - 0x6E SpO2 IBI (REVERSE byte order x8)

    func testSpO2IBI0x6EReverseOrder() {
        // body[1..5] = 10,20,30,40,50 read 5->1 reversed -> 50,40,30,20,10 then x8.
        let rec = record("6e0a02000100000a141e2832")
        let ibis = OuraDecoders.decodeSpO2IBI(rec)
        XCTAssertEqual(ibis, [
            OuraIBI(ringTimestamp: rt, ibiMs: 400, channel: .spo2Ibi),
            OuraIBI(ringTimestamp: rt, ibiMs: 320, channel: .spo2Ibi),
            OuraIBI(ringTimestamp: rt, ibiMs: 240, channel: .spo2Ibi),
            OuraIBI(ringTimestamp: rt, ibiMs: 160, channel: .spo2Ibi),
            OuraIBI(ringTimestamp: rt, ibiMs: 80, channel: .spo2Ibi),
        ])
    }

    // MARK: - 0x5D HRV / RMSSD

    func testHRV0x5D() {
        // (u8 hr, u8 rmssd) pairs — real overnight bytes: 32 84 32 83 -> (50,132),(50,131).
        // hr=50 bpm is sleeping HR (validates the layout; matches the #511 IBI-derived median).
        let rec = record("5d080200010032843283")
        let hrv = OuraDecoders.decodeHRV(rec)
        XCTAssertEqual(hrv, [
            OuraHRV(ringTimestamp: rt, index: 0, hrBpm: 50, rmssdMs: 132, count: 2),
            OuraHRV(ringTimestamp: rt, index: 1, hrBpm: 50, rmssdMs: 131, count: 2),
        ])
    }

    func testHRV0x5DOddLengthIsNil() {
        // A partial trailing pair (odd body length) must decode to nil, never a half-sample.
        XCTAssertNil(OuraDecoders.decodeHRV(record("5d0702000100328432")))
    }

    // MARK: - 0x5D `00 00` tail padding (#1128)

    /// A record that closes early pads its tail with `00 00`. That pair is not a reading, and a stored
    /// `hr_bpm: 0` is a fabricated value nothing downstream can tell from a measurement. Real shape,
    /// from the 2026-08-07 overnight: `... 48/128 47/137 ... 0/0`.
    func testHRV0x5DDropsTailPadding() {
        // (50,132), (50,131), then a 00 00 pad.
        let hrv = OuraDecoders.decodeHRV(record("5d0a02000100328432830000"))
        XCTAssertEqual(hrv, [
            // count is 3, not 2: the dropped pad still counts, or the survivors slide (#1167).
            OuraHRV(ringTimestamp: rt, index: 0, hrBpm: 50, rmssdMs: 132, count: 3),
            OuraHRV(ringTimestamp: rt, index: 1, hrBpm: 50, rmssdMs: 131, count: 3),
        ])
    }

    /// A body that is ENTIRELY padding carries no bucket at all, so it decodes to nil (honest no-data)
    /// rather than to an empty array a caller might treat as "decoded fine, zero readings".
    func testHRV0x5DAllPaddingIsNil() {
        XCTAssertNil(OuraDecoders.decodeHRV(record("5d06020001000000")))
    }

    /// THE ONE THAT MATTERS: a skipped pair must still CONSUME its index. `index` is not a label —
    /// `OuraStreamMapping` derives the bucket's wall-clock from it (`bucketTs = ts - index * 300`), so
    /// renumbering the survivors would slide every later bucket 5 minutes into the past.
    ///
    /// Tail padding cannot detect that mistake (nothing follows the pad), which is why this plants the
    /// zero pair in the MIDDLE: the bucket after it must keep index 2, not collapse to index 1. Only
    /// tail padding has been observed in the wild; this guards the shape we have not seen yet.
    func testHRV0x5DZeroPairConsumesItsIndex() {
        // (50,132), 00 00, (49,130) — the survivor after the pad must stay at index 2.
        let hrv = OuraDecoders.decodeHRV(record("5d0a02000100328400003182"))
        XCTAssertEqual(hrv, [
            OuraHRV(ringTimestamp: rt, index: 0, hrBpm: 50, rmssdMs: 132, count: 3),
            OuraHRV(ringTimestamp: rt, index: 2, hrBpm: 49, rmssdMs: 130, count: 3),
        ])
    }

    /// A genuine bucket whose RMSSD byte happens to be 0 is NOT padding and must survive: the rule keys
    /// on both bytes being zero, so a real reading with one zero byte stays visible as the anomaly it
    /// would be, instead of being swallowed by the padding rule.
    func testHRV0x5DLoneZeroByteIsNotTreatedAsPadding() {
        // (50,0) and (0,131): one zero byte each, neither is the 00 00 signature.
        let hrv = OuraDecoders.decodeHRV(record("5d080200010032000083"))
        XCTAssertEqual(hrv, [
            OuraHRV(ringTimestamp: rt, index: 0, hrBpm: 50, rmssdMs: 0, count: 2),
            OuraHRV(ringTimestamp: rt, index: 1, hrBpm: 0, rmssdMs: 131, count: 2),
        ])
    }

    // MARK: - 0x6F SpO2 per-sample (byte6 high nibble is a base/status field, DISCARDED; samples are
    // direct percentages, #968 — adding the scaled base gave impossible ~223% readings)

    func testSpO2PerSample0x6F() {
        // byte6 high nibble 1 (base/status, discarded) ; samples 95,96 ; FF terminator.
        let rec = record("6f0802000100105f60ff")
        let s = OuraDecoders.decodeSpO2PerSample(rec)
        // Every sample keeps the RECORD's ringTimestamp and carries its own position, so the consumer can
        // give each one its own second instead of collapsing the record onto one (#1070).
        XCTAssertEqual(s, [
            OuraSpO2(ringTimestamp: rt, value: 95, index: 0, count: 2),
            OuraSpO2(ringTimestamp: rt, value: 96, index: 1, count: 2),
        ])
    }

    func testSpO2PerSample0x6FStampsPositionForEverySample() {
        // A full 13-value record, the real Gen 3 shape: indices 0..12, count 13 on every sample, and the
        // record's own ringTimestamp untouched. Terminator absent.
        let body = (0..<13).map { String(format: "%02x", 90 + $0) }.joined()
        let rec = record("6f120200010000" + body)   // len 0x12 = 4 rt + 1 status + 13 values
        let s = OuraDecoders.decodeSpO2PerSample(rec)
        XCTAssertEqual(s?.count, 13)
        XCTAssertEqual(s?.map { $0.index }, Array(0..<13))
        XCTAssertEqual(s?.map { $0.count }, Array(repeating: 13, count: 13))
        XCTAssertTrue(s?.allSatisfy { $0.ringTimestamp == rt } ?? false)
    }

    func testSpO2DC0x77StampsPositionForEverySample() {
        // 0x77 shares the multi-sample shape, so it stamps the same way (it is filtered before the store
        // today, but the two decoders must stay consistent).
        // len 0x0b = 4 rt + 1 header + 3 base + 3 deltas ; hasBase -> base is sample 0, then 3 deltas.
        let rec = record("770b02000100400a0000" + "01ff02")
        let s = OuraDecoders.decodeSpO2DC(rec)
        XCTAssertEqual(s?.map { $0.index }, [0, 1, 2, 3])
        XCTAssertEqual(s?.map { $0.count }, [4, 4, 4, 4])
    }

    // MARK: - 0x7B SpO2 stable (BIG-endian footgun)

    func testSpO2Stable0x7BIsBigEndian() {
        // BE 0x03CA = 970. If decoded LE it would be 0xCA03 = 51715, so this proves the BE path.
        let rec = record("7b060200010003ca")
        let s = OuraDecoders.decodeSpO2Stable(rec)
        XCTAssertEqual(s, OuraSpO2(ringTimestamp: rt, value: 970))
    }

    // MARK: - 0x46 temperature (int16 LE / 100)

    func testTemp0x46() {
        // 3650/100 = 36.50 ; 3655/100 = 36.55
        let rec = record("460802000100420e470e")
        let t = OuraDecoders.decodeTemp(rec)
        XCTAssertEqual(t, [
            OuraTemp(ringTimestamp: rt, celsius: 36.50),
            OuraTemp(ringTimestamp: rt, celsius: 36.55),
        ])
    }

    // MARK: - 0x42 time sync (int64 LE epoch ms + tz int8 x1800)

    func testTimeSync0x42() {
        // epoch 1719662400000 ms, tz byte 2 -> 3600 s.
        let rec = record("420d0200010000d2dd639001000002")
        let ts = OuraDecoders.decodeTimeSync(rec)
        XCTAssertEqual(ts, OuraTimeSync(ringTimestamp: rt, epochMs: 1_719_662_400_000, tzOffsetSeconds: 3600))
    }

    // MARK: - 0x4E sleep phase (2-bit codes MSB-first; header byte skipped)

    func testSleepPhase0x4E() {
        // header 0x00, phase byte 0x6C = bits 01 10 11 00 = codes 1,2,3,0. Per open_oura's VALIDATED
        // mapping (0=deep, 1=light, 2=rem, 3=awake) -> light, rem, awake, deep.
        let rec = record("4e0602000100006c")
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases, [
            OuraSleepPhase(ringTimestamp: rt, index: 0, stage: .light),
            OuraSleepPhase(ringTimestamp: rt, index: 1, stage: .rem),
            OuraSleepPhase(ringTimestamp: rt, index: 2, stage: .awake),
            OuraSleepPhase(ringTimestamp: rt, index: 3, stage: .deep),
        ])
    }

    func testSleepPhase0x4EWholeFFRecordIsUnwritten() {
        // #1246: two code bytes of 0xFF (an erased/unwritten flash page). The 2-bit unpack still reads
        // four awake each, but because the WHOLE record's code bytes are 0xFF the epochs are flagged
        // `unwritten` — the assembler drops them as a GAP instead of manufacturing 8 awake epochs.
        let rec = record("4e070200010000ffff")   // len 07 = rt(4) + payload(00 ff ff): header + two 0xFF bytes
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases?.count, 8)
        XCTAssertEqual(phases?.allSatisfy { $0.unwritten && $0.stage == .awake }, true)
    }

    func testSleepPhase0x4ELoneFFByteIsGenuineAwake() {
        // #1246 caution: a SINGLE 0xFF code byte is four genuine `awake` epochs, NOT an erased page — it
        // must stay written (only a run of >=2 all-0xFF code bytes reads as unwritten).
        let rec = record("4e060200010000ff")   // header + one 0xFF code byte
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases?.count, 4)
        XCTAssertEqual(phases?.contains { $0.unwritten }, false)
        XCTAssertEqual(phases?.allSatisfy { $0.stage == .awake }, true)
    }

    func testSleepPhase0x4EMixedFFIsWritten() {
        // A record that is NOT entirely 0xFF (real codes 0x6C + one 0xFF byte) is genuine data — its 0xFF
        // byte is four REAL awake epochs, so NONE of the record is flagged unwritten. Guards against a
        // byte-level filter eating genuine wake.
        let rec = record("4e0702000100006cff")
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases?.count, 8)
        XCTAssertEqual(phases?.contains { $0.unwritten }, false)
        // The trailing 0xFF byte still decodes to four awake epochs (real wake, kept).
        XCTAssertEqual(phases?.suffix(4).allSatisfy { $0.stage == .awake }, true)
    }

    func testSleepPhase0x4ETrailingFFRunIsUnwritten() {
        // #1284: a PARTLY-written page — real codes then a trailing 0xFF pad. The reporter's `hdr=01`
        // record: `ff ff f3 c0` then nine straight 0xFF (13 code bytes). The whole-record rule missed it;
        // the trailing-run rule flags the 9-byte tail (36 epochs) as unwritten while the leading `ff ff`
        // stays real wake.
        let rec = record("4e120200010000fffff3c0ffffffffffffffffff")
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases?.count, 52)                                  // 13 code bytes * 4
        XCTAssertEqual(phases?.filter { $0.unwritten }.count, 36)          // trailing 9 bytes * 4
        XCTAssertEqual(phases?.prefix(16).allSatisfy { !$0.unwritten }, true)   // leading ff ff f3 c0 kept
        XCTAssertEqual(phases?.suffix(36).allSatisfy { $0.unwritten }, true)    // the pad, dropped as a gap
    }

    func testSleepPhase0x4ETrailingRunFloorIsExclusive() {
        // Exactly `minTrailingUnwritten` trailing 0xFF flags; one fewer is spared as possible real wake.
        // 7 real codes + 6 trailing 0xFF (== floor): the 6-byte tail is unwritten.
        let atFloor = record("4e12020001000055555555555555ffffffffffff")
        XCTAssertEqual(OuraDecoders.decodeSleepPhase(atFloor)?.filter { $0.unwritten }.count,
                       OuraDecoders.minTrailingUnwritten * 4)
        // 8 real codes + 5 trailing 0xFF (floor - 1): nothing flagged.
        let belowFloor = record("4e1202000100005555555555555555ffffffffff")
        XCTAssertEqual(OuraDecoders.decodeSleepPhase(belowFloor)?.contains { $0.unwritten }, false)
    }

    func testSleepPhase0x4ETrailingSingleFFIsGenuineAwake() {
        // #1284/#1246 boundary: a written record ending in a SINGLE trailing 0xFF is four genuine awake epochs,
        // never pad. The trailing floor is clamped to >= 2, so this holds even if `minTrailingUnwritten` is
        // lowered — a lone trailing byte can never be eaten (the case #1246 was careful to protect). Kotlin twin.
        XCTAssertGreaterThanOrEqual(OuraDecoders.minTrailingUnwritten, 2,
                                    "floor < 2 would eat a lone trailing 0xFF (#1246); the decode clamps to 2 as a backstop")
        let rec = record("4e120200010000555555555555555555555555ff")   // 12 real codes + 1 trailing 0xFF
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases?.count, 52)
        XCTAssertEqual(phases?.contains { $0.unwritten }, false)                    // nothing flagged unwritten
        XCTAssertEqual(phases?.suffix(4).allSatisfy { $0.stage == .awake }, true)   // the lone 0xFF stays real wake
    }

    func testSleepPhase0x4ELeadingFFRunIsRealWake() {
        // Trailing-only, by design: a LONG leading/interior 0xFF run (nine here) that does NOT reach the
        // record's end is left as genuine wake — the ring wrote it, and a pre-onset run is dropped by the
        // assembler's onset clip, not here. Guards against eating real wake at the start of a page.
        let rec = record("4e120200010000ffffffffffffffffff55555555")
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases?.count, 52)
        XCTAssertEqual(phases?.contains { $0.unwritten }, false)
    }

    // MARK: - 0x6B motion period (2-bit MOTION_STATE codes; 2 header bytes skipped)

    func testMotionPeriod0x6B() {
        // 2 header bytes 0x00 0x00, code byte 0x1B = 00 01 10 11 -> noMotion, restless, tossing, active.
        let rec = record("6b070200010000001b")
        let m = OuraDecoders.decodeMotionPeriod(rec)
        XCTAssertEqual(m, [
            OuraMotion(ringTimestamp: rt, index: 0, state: .noMotion),
            OuraMotion(ringTimestamp: rt, index: 1, state: .restless),
            OuraMotion(ringTimestamp: rt, index: 2, state: .tossing),
            OuraMotion(ringTimestamp: rt, index: 3, state: .active),
        ])
    }

    // MARK: - 0x47 motion events (averaged accel vector)

    func testMotionEvents0x47() {
        // open_oura decode_motion vector: body [0x6f,0x0c,0x1d,0x07,0x0c,0x07].
        // byte0 0x6f: orientation = 0x6f>>5 = 3, motion_seconds = 0x6f&0x1f = 15.
        // avg x/y/z = 12/29/7 signed ×8 = 96/232/56. low=0x0c&0x3f=12, high=0x07&0x3f=7.
        let rec = OuraRecord(type: OuraEventTag.motion.rawValue, ringTimestamp: rt,
                             payload: [0x6f, 0x0c, 0x1d, 0x07, 0x0c, 0x07])
        XCTAssertEqual(OuraDecoders.decodeMotionEvents(rec),
                       OuraMotionEvent(ringTimestamp: rt, orientation: 3, motionSeconds: 15,
                                       avgX: 96, avgY: 232, avgZ: 56, lowIntensity: 12, highIntensity: 7))
    }

    func testMotionEvents0x47DiscriminatesOrientationFromMotionSeconds() {
        // byte0 0xB5 = 1011_0101: orientation = 0xB5>>5 = 5 (NOT 0xB5&0x03 = 1), motion_seconds = 0x15 = 21.
        // This vector fails the old `& 0x03` orientation bug (would give 1). Negative axes prove ×8 sign.
        // byte4 0x2A → low 42; byte5 0x3F → high 63 (max, still valid).
        let rec = OuraRecord(type: OuraEventTag.motion.rawValue, ringTimestamp: rt,
                             payload: [0xB5, 0xF4, 0x00, 0x80, 0x2A, 0x3F])
        XCTAssertEqual(OuraDecoders.decodeMotionEvents(rec),
                       OuraMotionEvent(ringTimestamp: rt, orientation: 5, motionSeconds: 21,
                                       avgX: -96, avgY: 0, avgZ: -1024, lowIntensity: 42, highIntensity: 63))
    }

    func testMotionEvents0x47IntensityValidityBitRejectsRecord() {
        // A set 0x40 bit in the intensity byte means INVALID per open_oura → the whole record decodes nil.
        XCTAssertNil(OuraDecoders.decodeMotionEvents(   // byte5 0x47 has 0x40 set
            OuraRecord(type: OuraEventTag.motion.rawValue, ringTimestamp: rt, payload: [0x00, 0, 0, 0, 0x00, 0x47])))
        XCTAssertNil(OuraDecoders.decodeMotionEvents(   // byte4 0x40 set
            OuraRecord(type: OuraEventTag.motion.rawValue, ringTimestamp: rt, payload: [0x00, 0, 0, 0, 0x40, 0x00])))
    }

    func testMotionEvents0x47OptionalIntensityAndShortBody() {
        // A 4-byte record is valid (orientation/motion_seconds + 3 axes); intensities are nil.
        let four = OuraDecoders.decodeMotionEvents(
            OuraRecord(type: OuraEventTag.motion.rawValue, ringTimestamp: rt, payload: [0x20, 0x0a, 0x00, 0x00]))
        XCTAssertEqual(four, OuraMotionEvent(ringTimestamp: rt, orientation: 1, motionSeconds: 0,
                                             avgX: 80, avgY: 0, avgZ: 0, lowIntensity: nil, highIntensity: nil))
        // A 3-byte body is too short → nil.
        XCTAssertNil(OuraDecoders.decodeMotionEvents(
            OuraRecord(type: OuraEventTag.motion.rawValue, ringTimestamp: rt, payload: [0x6f, 0x0c, 0x1d])))
    }

    // MARK: - 0x85 RTC beacon (unix_s u32 LE)

    func testRtcBeacon0x85() {
        let rec = record("850e0200010040f77f6600000000f601")
        let r = OuraDecoders.decodeRtcBeacon(rec)
        XCTAssertEqual(r, OuraRtcBeacon(ringTimestamp: rt, unixSeconds: 1_719_662_400))
    }

    // MARK: - 0x45 state change

    func testState0x45() {
        let rec = record("45050200010004")
        let s = OuraDecoders.decodeState(rec)
        XCTAssertEqual(s?.stateCode, 4)     // user_in_rest
        XCTAssertNil(s?.text)               // body too short for a trailing string
    }

    // MARK: - 0x43 debug text

    func testDebugText0x43() {
        let rec = record("4306020001004142")
        XCTAssertEqual(OuraDecoders.decodeDebugText(rec), "AB")
    }

    // MARK: - 0x0D battery (outer response body; percent at [0], voltage at [4..6] LE)

    func testBattery0x0D() {
        // body: 87%, charging 0, voltage 3900 mv at bytes 4..6.
        let body = bytes("570000003c0f0000")
        let b = OuraDecoders.decodeBattery(body)
        XCTAssertEqual(b, OuraBattery(percent: 87, voltageMv: 3900, charging: false))
    }

    func testBatteryRejectsImplausiblePercent() {
        // A "percent" > 100 is a misread; decode to nil, never a guessed value.
        let body: [UInt8] = [200, 0, 0, 0, 0, 0]
        XCTAssertNil(OuraDecoders.decodeBattery(body))
    }

    // MARK: - Live HR push (12-bit nibble IBI -> bpm), built from the s5.6 wire layout

    /// The fixture is derived from the OURA_PROTOCOL.md s5.6 wire frame, NOT from the implementation:
    ///   full frame = `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f` (len 0x0f = 15)
    /// The transport strips the leading `2f 0f 28`, so the decoder receives the 14-byte subBody with the
    /// IBI at subBody[5..6]. Here IBI_L=0x01, IBI_H=0x04 -> ibi ((0x04 & 0x0F)<<8)|0x01 = 1025 ->
    /// bpm round(60000/1025) = 59. Per OURA_PROTOCOL.md s5.6.
    func testLiveHRPushNibbleIBI() {
        let fullFrame = bytes("2f0f28020002000001040000000000007f")
        // Self-check the wire layout: type 0x2f, len 0x0f (15) counts the bytes after type+len, i.e. the
        // subop byte plus the subBody (s2.2). So subBody.count must equal len - 1.
        XCTAssertEqual(fullFrame[0], 0x2F)
        XCTAssertEqual(fullFrame[1], 0x0F)
        XCTAssertEqual(Int(fullFrame[1]), 15)
        XCTAssertEqual(fullFrame.count, 2 + Int(fullFrame[1]))   // type + len + 15 body bytes = 17
        // Strip `2f 0f 28` (type, len, subop) exactly as the transport does -> the 14-byte subBody.
        XCTAssertEqual(Array(fullFrame[0..<3]), [0x2F, 0x0F, 0x28])
        let subBody = Array(fullFrame[3...])
        XCTAssertEqual(subBody.count, Int(fullFrame[1]) - 1)     // 14 == len(15) - subop(1)
        XCTAssertEqual(subBody.count, 14)
        // The IBI is at subBody index 5 (low) / 6 (high) per the stripped s5.6 layout.
        XCTAssertEqual(subBody[5], 0x01)
        XCTAssertEqual(subBody[6], 0x04)

        let hr = OuraDecoders.decodeLiveHRPush(subBody, ringTimestamp: rt)
        XCTAssertEqual(hr, OuraHR(ringTimestamp: rt, bpm: 59, ibiMs: 1025))
    }

    // MARK: - 0x71 green_ibi_and_amp CANDIDATE decode (ringverse @0x503960, upstream #287)

    /// Inverse of the firmware's scrambled packing (ringverse `p_green_ibi_and_amp`): middle-8 bytes
    /// at p[4..0] (ds0..ds4), amplitude bytes p[6..10] carry the mantissa in bits [7:1] and the
    /// PAIRED IBI's low bit in bit [0] (ds4..ds0 order), bits [2:1] of ds1..ds4 pack into p[12]
    /// two bits at a time, ds0's into p[13] bits [7:6] alongside the shift field.
    private func packGreenIBIAmp(ibis: [Int], mants: [Int], s: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 14)
        for (i, mid) in [4, 3, 2, 1, 0].enumerated() { p[mid] = UInt8((ibis[i] >> 3) & 0xFF) }
        for (i, amp) in [10, 9, 8, 7, 6].enumerated() {
            p[amp] = UInt8((mants[4 - i] << 1) | (ibis[i] & 1))
        }
        var pack12 = (ibis[1] >> 1) & 3
        pack12 |= ((ibis[2] >> 1) & 3) << 2
        pack12 |= ((ibis[3] >> 1) & 3) << 4
        pack12 |= ((ibis[4] >> 1) & 3) << 6
        p[12] = UInt8(pack12)
        p[13] = UInt8((s & 7) | (((ibis[0] >> 1) & 3) << 6))
        return p
    }

    func testGreenIBIAmpCandidateRoundTrip() {
        // 11-bit IBIs exercising every packed bit field; 7-bit mantissas; s=3 -> shift 4.
        let ibis = [1023, 800, 517, 2046, 901]
        let mants = [1, 64, 100, 127, 33]
        let p = packGreenIBIAmp(ibis: ibis, mants: mants, s: 3)
        let decoded = OuraDecoders.decodeGreenIBIAmpCandidate(payload: p, ringTimestamp: rt)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.shift, 4)
        let samples = decoded!.samples
        XCTAssertEqual(samples.count, 6)
        // First entry is amplitude-only (ibi 0, amp = as[0] = mantissa of p[6] << shift).
        XCTAssertEqual(samples[0].ibiMs, 0)
        XCTAssertEqual(samples[0].amplitude, mants[0] << 4)
        // The five IBI entries recover the exact packed values; amps pair as[i] per the firmware order.
        XCTAssertEqual(samples.dropFirst().map { $0.ibiMs }, ibis)
        XCTAssertEqual(samples.dropFirst().map { $0.amplitude ?? -1 }, mants.map { $0 << 4 })
    }

    func testGreenIBIAmpCandidateGates() {
        // s == 7 means shift 0 (identity amplitudes).
        let p7 = packGreenIBIAmp(ibis: [500, 500, 500, 500, 500], mants: [10, 10, 10, 10, 10], s: 7)
        XCTAssertEqual(OuraDecoders.decodeGreenIBIAmpCandidate(payload: p7, ringTimestamp: rt)?.shift, 0)
        // Reserved bit [3] of p[13] set -> firmware mismatch -> nil, never a guessed decode.
        var bad = p7
        bad[13] |= 0x08
        XCTAssertNil(OuraDecoders.decodeGreenIBIAmpCandidate(payload: bad, ringTimestamp: rt))
        // Strict 14-byte gate: any other length is a different firmware layout -> nil.
        XCTAssertNil(OuraDecoders.decodeGreenIBIAmpCandidate(payload: Array(p7.dropLast()), ringTimestamp: rt))
        XCTAssertNil(OuraDecoders.decodeGreenIBIAmpCandidate(payload: p7 + [0x00], ringTimestamp: rt))
    }

    // MARK: - Honest-data invariant: short / malformed records decode to nil

    func testShortRecordsDecodeToNil() {
        // A 0x7B record with a 1-byte payload (needs 2 for the u16) -> nil, not a guess.
        let shortSpO2 = OuraRecord(type: 0x7B, ringTimestamp: rt, payload: [0x03])
        XCTAssertNil(OuraDecoders.decodeSpO2Stable(shortSpO2))
        // A 0x46 temp with an ODD payload length -> nil.
        let oddTemp = OuraRecord(type: 0x46, ringTimestamp: rt, payload: [0x01, 0x02, 0x03])
        XCTAssertNil(OuraDecoders.decodeTemp(oddTemp))
        // An empty HRV body -> nil.
        XCTAssertNil(OuraDecoders.decodeHRV(OuraRecord(type: 0x5D, ringTimestamp: rt, payload: [])))
    }
}
