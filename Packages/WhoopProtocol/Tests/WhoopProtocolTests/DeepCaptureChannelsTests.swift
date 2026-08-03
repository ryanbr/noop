import XCTest
@testable import WhoopProtocol

/// The v18 fields the decoder produced and `extractHistoricalStreams` used to DISCARD.
///
/// Every expectation below is read off the SAME real worn 5/MG frame `Whoop5HistoricalTests` uses (and
/// that `decoder_oracle.json` pins on both platforms), so nothing here asserts a value the decoder was
/// not already independently proven to produce — these tests are about the STORAGE funnel, which is
/// where the loss happened.
final class DeepCaptureChannelsTests: XCTestCase {

    /// A real type-47 HISTORICAL_DATA v18 frame (worn WHOOP 5, captured 2026-06-08). Same fixture as
    /// `Whoop5HistoricalTests.historicalHex`.
    private let v18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    /// A synthetic WHOOP 4.0 v24 record — same fixture as `HistoricalV24Tests`.
    private let v24Hex =
        "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
        "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
        "200364006400b80bb80b000000000000c25c1a88"

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// The fixture frame, optionally with one byte replaced AND its CRC32 trailer recomputed. The reseal
    /// matters: `extractHistoricalStreams` skips any frame whose CRC fails, so a mutated frame would
    /// otherwise silently test nothing at all.
    private func v18Frame(mutating index: Int? = nil, to value: UInt8 = 0) -> [UInt8] {
        var b = bytes(v18Hex)
        guard let i = index else { return b }
        b[i] = value
        let payloadEnd = b.count - 4
        let c = crc32(b, 8, payloadEnd)
        for k in 0..<4 { b[payloadEnd + k] = UInt8(truncatingIfNeeded: c >> (8 * UInt32(k))) }
        return b
    }

    /// The record's own unix; used as both clock refs so the FIX #72 correction is a no-op.
    private let ts = 1_780_916_150

    private func extract(_ frames: [[UInt8]]) -> Streams {
        extractHistoricalStreams(frames.map { parseFrame($0, family: .whoop5) },
                                 deviceClockRef: ts, wallClockRef: ts)
    }

    // MARK: - The four named channels

    /// `dynamic_acceleration@41` now rides the gravity row for the same second instead of being dropped.
    func testDynamicAccelerationRidesTheGravityRow() throws {
        let g = try XCTUnwrap(extract([v18Frame()]).gravity.first)
        XCTAssertEqual(g.dynAccel ?? .nan, 0.0091596, accuracy: 1e-6)
        // Stored BESIDE the vector, never instead of it — the stager still reads x/y/z.
        XCTAssertEqual(sqrt(g.x * g.x + g.y * g.y + g.z * g.z), 1.0, accuracy: 0.05)
    }

    /// The two auxiliary thermal channels ride the primary skin-temp row.
    func testAuxThermalChannelsRideTheSkinTempRow() throws {
        let s = try XCTUnwrap(extract([v18Frame()]).skinTemp.first)
        XCTAssertEqual(s.raw, 3057)          // primary, unchanged (°C = raw/100 = 30.6)
        XCTAssertEqual(s.aux1Raw, 247)       // @69, °C = raw/10 = 24.7
        XCTAssertEqual(s.aux2Raw, 265)       // @71, °C = raw/10 = 26.5
    }

    /// The WHOLE @81 byte survives, and `state` stays exactly its high nibble.
    func testSleepStateCarriesTheWholeFlagByteAndStateIsUnchanged() throws {
        // 0xE9 = 1110 1001: onwrist(b0-1)=1, wake_quality(b2-3)=2, sleep_state(b4-5)=2, reserved(b6-7)=3.
        // The reserved bits are the point: they read 0 on every real capture and have NO interpretation,
        // so a per-nibble store would make them permanently unrecoverable.
        let s = try XCTUnwrap(extract([v18Frame(mutating: 81, to: 0xE9)]).sleepState.first)
        XCTAssertEqual(s.rawByte, 0xE9)
        XCTAssertEqual(s.state, 2, "state must remain (rawByte >> 4) & 3 — #175 behaviour is bit-identical")
        let raw = try XCTUnwrap(s.rawByte)
        XCTAssertEqual((raw >> 4) & 3, s.state)
        XCTAssertEqual(raw & 3, 1)              // onwrist
        XCTAssertEqual((raw >> 2) & 3, 2)       // wake_quality
        XCTAssertNotEqual(raw & 0xC0, 0, "the fixture must actually exercise the reserved bits")
    }

    /// A zero @81 byte is a REAL reading (worn daytime wake), not an absent one — it must be carried.
    func testZeroFlagByteIsCarriedNotTreatedAsAbsent() throws {
        let s = try XCTUnwrap(extract([v18Frame()]).sleepState.first)
        XCTAssertEqual(s.rawByte, 0)
        XCTAssertEqual(s.state, 0)
    }

    // MARK: - The remaining v18 slots

    /// Every slot the funnel used to drop is banked, verbatim, under the decoder's own name.
    func testEveryRemainingV18SlotIsCollected() throws {
        let a = try XCTUnwrap(extract([v18Frame()]).v18Aux.first)
        XCTAssertEqual(a.ts, ts)
        XCTAssertEqual(a.recordIndex, 25_443_699)     // @11  u32
        XCTAssertEqual(a.rrCount, 2)                  // @23  u8
        XCTAssertEqual(a.cardiacFlags, 0)             // @33  u8
        XCTAssertEqual(a.hrQualityFlags, 141)         // @36  u8 flag byte (0x8D)
        XCTAssertEqual(a.heartRateAlt, 101)           // @37  u8 duplicate HR (hr@22 = 102)
        XCTAssertEqual(a.rrPacked, 25_444)            // @38  u16
        XCTAssertEqual(a.cardiacStatus, 255)          // @40  u8
        XCTAssertEqual(a.stepCadence, 170)            // @59  u8
        XCTAssertEqual(a.statusWord, 1_792)           // @75  u16
        XCTAssertEqual(a.statusWord1, 3_073)          // @77  u16
        XCTAssertEqual(a.statusWord2, 3_074)          // @79  u16
        XCTAssertEqual(a.auxByte82, 0)                // @82  u8 (raw; the gated 70-100 view is derived)
        XCTAssertEqual(a.opticalBaselineA, 101)       // @106 u8
        XCTAssertEqual(a.opticalBaselineB, 111)       // @107 u8
        XCTAssertEqual(a.opticalAmpA, 30)             // @108 u8
        XCTAssertEqual(a.opticalAmpB, 30)             // @109 u8
        // The SAME decimal literal the Kotlin suite asserts. 0xC0A7619D has bit 31 set, so a 32-bit
        // decoded domain reads it as -1_062_772_323 — this is the value, not the blob, that has to match.
        XCTAssertEqual(a.unknownF32Bits, 3_232_194_973)  // @113 raw 32-bit pattern, unsigned domain
        XCTAssertEqual(a.unknownF32At113 ?? .nan, -5.2307, accuracy: 0.001)
    }

    /// EVERY slot's `decoderKey` must exist in a decode of a REAL v18 frame.
    ///
    /// This is the durable guard, and it exists because of a near-miss. Each slot is extracted with an
    /// OPTIONAL dictionary lookup — `p[slot.decoderKey]?.intValue`. If the decoder renames or retires a
    /// key, that lookup returns nil and the slot banks NOTHING: no compile error (the type is `Int?`),
    /// and no visible symptom (absence is a first-class state in the aux format, so an empty slot is
    /// indistinguishable from "the strap did not send it"). The result is permanent, silent data loss in
    /// a capture format whose entire purpose is preserving fields BEFORE the strap trims them on ack.
    ///
    /// That is not hypothetical: #861 retired `hr_fixed_8_8` and `optical_baseline_106` — the two keys
    /// four of these slots used to read — and nothing in this suite would have failed. This test would
    /// have.
    ///
    /// Asserted against the real worn fixture, which carries every v18 field, so it also proves the keys
    /// are spelled the way the decoder actually emits them rather than the way this file believes.
    func testEverySlotDecoderKeyExistsInARealV18Decode() {
        let parsed = parseFrame(v18Frame(), family: .whoop5).parsed
        XCTAssertEqual(parsed["hist_version"]?.intValue, 18, "the guard must run against a v18 decode")
        let missing = V18AuxSlot.allCases.filter { parsed[$0.decoderKey] == nil }
        XCTAssertEqual(missing.map(\.decoderKey), [], """
            \(missing.count) aux slot(s) read a decoder key the v18 decoder does not emit: \
            \(missing.map { "\($0) -> \"\($0.decoderKey)\"" }.joined(separator: ", ")). \
            Those slots bank NOTHING, silently, for every strap-second — no compile error, no runtime \
            error, just a channel that is gone once the strap trims its history. Repoint \
            `V18AuxSlot.decoderKey` (and the matching literal in `extractHistoricalStreams`) at the key \
            the decoder emits today.
            """)
    }

    /// The same guard one level down: a key that exists is not enough, the value has to REACH the sample.
    /// `decoderKey` and the extractor's literal are two separate strings that must agree, so this asserts
    /// the real frame populates every slot rather than just decoding one.
    func testEverySlotIsPopulatedFromARealV18Frame() throws {
        let a = try XCTUnwrap(extract([v18Frame()]).v18Aux.first)
        let values = a.slotValues
        XCTAssertEqual(values.count, V18AuxSlot.allCases.count)
        let unbanked = V18AuxSlot.allCases.filter { values[$0.rawValue] == nil }
        XCTAssertEqual(unbanked.map(\.decoderKey), [],
                       "these slots decoded but never reached V18AuxSample — the extractor's lookup key "
                       + "and V18AuxSlot.decoderKey have drifted apart")
    }

    /// `@36`/`@37` are TWO bytes, not one u16 — the reading #861 retired.
    ///
    /// They were banked as a single u16 `hr_fixed_8_8` slot ("higher-precision HR, bpm = value/256").
    /// #861 disproved that over 18,650 records: bit 4 of `@36` is never set, 95% of its values sit in
    /// 0x80–0x8F, and the famous 0.989 correlation with `heart_rate@22` was circular — the u16 is just
    /// the duplicate HR at `@37` plus a flag byte over 256. Storage now mirrors the wire: two u8 slots.
    func testByte36AndByte37AreTwoIndependentSlots() throws {
        let f = parseFrame(v18Frame(), family: .whoop5)
        let a = try XCTUnwrap(extract([v18Frame()]).v18Aux.first)
        XCTAssertEqual(a.hrQualityFlags, 141)                 // 0x8D — the flag byte
        XCTAssertEqual(a.heartRateAlt, 101)                   // the duplicate HR
        XCTAssertEqual(V18AuxSlot.hrQualityFlags.width, 1)
        XCTAssertEqual(V18AuxSlot.heartRateAlt.width, 1)
        // Bit 7 set = the strap called this second's HR/R-R valid; bit 4 is never set on any real record.
        XCTAssertEqual((a.hrQualityFlags ?? 0) & 0x80, 0x80)
        XCTAssertEqual((a.hrQualityFlags ?? 0) & 0x10, 0)
        // Independence, proved by moving one byte: under the retired u16 model @37 was worth 256, so a
        // change there moved the "bpm". Now it moves exactly one slot and leaves the other alone.
        let m = try XCTUnwrap(extract([v18Frame(mutating: 37, to: 0xFF)]).v18Aux.first)
        XCTAssertEqual(m.heartRateAlt, 255)
        XCTAssertEqual(m.hrQualityFlags, 141, "@36 must not move when @37 does")
        // And @37 is not the measured HR: @22 reads 102 here while @37 reads 101, which is why it is
        // banked as a raw byte rather than promoted to a bpm.
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 102)
        XCTAssertNotEqual(a.heartRateAlt, f.parsed["heart_rate"]?.intValue)
    }

    /// `@106`/`@107` are likewise TWO bytes. #861 showed a u16 there is structurally impossible: across
    /// 18,599 consecutive-second pairs the high byte moved while the low byte stayed frozen 3,514 times,
    /// with zero low-byte wraps in the corpus. Banking them as one u16 fused two independent channels.
    func testOpticalBaselineIsTwoIndependentSlots() throws {
        let a = try XCTUnwrap(extract([v18Frame()]).v18Aux.first)
        XCTAssertEqual(a.opticalBaselineA, 101)               // @106
        XCTAssertEqual(a.opticalBaselineB, 111)               // @107
        XCTAssertEqual(V18AuxSlot.opticalBaselineA.width, 1)
        XCTAssertEqual(V18AuxSlot.opticalBaselineB.width, 1)
        // Moving @107 must leave @106 alone — under the u16 model that byte was worth 256.
        let m = try XCTUnwrap(extract([v18Frame(mutating: 107, to: 0xFF)]).v18Aux.first)
        XCTAssertEqual(m.opticalBaselineB, 255)
        XCTAssertEqual(m.opticalBaselineA, 101, "@106 must not move when @107 does")
    }

    /// The retired keys must not come back by accident: nothing may read `hr_fixed_8_8` or
    /// `optical_baseline_106`, and no slot may re-fuse a byte pair into a 2-byte field.
    func testRetiredU16ReadingsAreNotResurrected() {
        let retired: Set<String> = ["hr_fixed_8_8", "optical_baseline_106"]
        for slot in V18AuxSlot.allCases {
            XCTAssertFalse(retired.contains(slot.decoderKey),
                           "\(slot) reads \(slot.decoderKey), a key #861 retired")
        }
        for slot in [V18AuxSlot.hrQualityFlags, .heartRateAlt, .opticalBaselineA, .opticalBaselineB] {
            XCTAssertEqual(slot.width, 1, "\(slot) is a single wire byte, never half of a u16")
        }
    }

    /// The decoded domain must hold an unsigned 32-bit slot. Swift's `Int` is 64-bit on every supported
    /// target and the Kotlin twin carries `Long` for exactly this reason; a 32-bit domain on either side
    /// silently flips a bit-31 slot negative while the stored bytes stay identical.
    func testDecodedDomainHoldsAFullU32() {
        XCTAssertGreaterThanOrEqual(Int.bitWidth, 64)
        let widest = V18AuxSlot.allCases.map(\.width).max() ?? 0
        XCTAssertEqual(widest, 4)
        let s = V18AuxSample(ts: 0, recordIndex: 0xFFFF_FFFF, unknownF32Bits: 0xC0A7_619D)
        XCTAssertEqual(s.recordIndex, 4_294_967_295)
        XCTAssertEqual(s.unknownF32Bits, 3_232_194_973)
    }

    /// The slot enum and the struct's ordered view cannot drift: the codec indexes one by the other.
    func testSlotValuesOrderMatchesTheSlotEnum() {
        let a = V18AuxSample(ts: 1, recordIndex: 10, rrCount: 11, cardiacFlags: 12, hrQualityFlags: 13,
                             heartRateAlt: 14, rrPacked: 15, cardiacStatus: 16, stepCadence: 17,
                             statusWord: 18, statusWord1: 19, statusWord2: 20, auxByte82: 21,
                             opticalBaselineA: 22, opticalBaselineB: 23, opticalAmpA: 24,
                             opticalAmpB: 25, unknownF32Bits: 26)
        XCTAssertEqual(a.slotValues.count, V18AuxSlot.allCases.count)
        // Slot i must round-trip to position i — this is what makes the persisted bitmap meaningful.
        XCTAssertEqual(a.slotValues, Array(10...26).map { Optional($0) })
        XCTAssertEqual(V18AuxSample(ts: 1, slotValues: a.slotValues), a)
        // Enum raw values must be a dense 0..<n range in declaration order (bitmap bit positions).
        XCTAssertEqual(V18AuxSlot.allCases.map(\.rawValue), Array(0..<V18AuxSlot.allCases.count))
    }

    /// A short slot array (a blob from an older build with fewer slots) leaves the tail nil, never 0.
    func testShortSlotArrayLeavesTheTailAbsent() {
        let a = V18AuxSample(ts: 1, slotValues: [7, 8])
        XCTAssertEqual(a.recordIndex, 7)
        XCTAssertEqual(a.rrCount, 8)
        XCTAssertNil(a.unknownF32Bits)
        XCTAssertNil(a.opticalAmpA)
    }

    // MARK: - What must NOT change

    /// WHOOP 4.0 is untouched: no aux rows, and the new columns stay nil on the streams it does produce.
    func testWhoop4V24RecordAddsNothing() throws {
        let s = extractHistoricalStreams([parseFrame(bytes(v24Hex))],
                                         deviceClockRef: 1_700_000_000, wallClockRef: 1_700_000_000)
        XCTAssertTrue(s.v18Aux.isEmpty, "a 4.0 v24 record must bank no aux row")
        XCTAssertNil(s.gravity.first?.dynAccel)
        XCTAssertNil(s.skinTemp.first?.aux1Raw)
        XCTAssertNil(s.skinTemp.first?.aux2Raw)
        // The 4.0 schema DOES emit rr_count, which is why the aux gate keys on hist_version rather than
        // on which keys happen to be present — a presence test would bank a near-empty row per 4.0 second.
        XCTAssertEqual(parseFrame(bytes(v24Hex)).parsed["rr_count"]?.intValue, 1)
    }

    /// The v18 gate is explicit: only layout 18 banks aux rows.
    func testAuxCollectionIsGatedOnLayoutV18() {
        XCTAssertEqual(parseFrame(v18Frame(), family: .whoop5).parsed["hist_version"]?.intValue, 18)
        // A v26 (optical PPG) record carries no v18 biometric slots at all.
        let v26 = extract([v18Frame(mutating: 9, to: 26)])
        XCTAssertTrue(v26.v18Aux.isEmpty)
    }

    /// The #520 whole-session diagnostic still folds the same field it always did — the new per-second
    /// column is carried BESIDE it, not in place of it.
    func testDynAccelDiagnosticStillFoldsAlongsideTheNewColumn() {
        let s = extract([v18Frame()])
        XCTAssertEqual(s.dynAccel.count, 1)
        XCTAssertEqual(s.gravity.count, 1)
        XCTAssertNotNil(s.gravity.first?.dynAccel)
    }

    /// Nothing already reachable from a banked field is banked a second time.
    ///
    /// The name matters (#979). Most of these ARE stored under their own column, but two are not:
    /// `motion_wear_quality@63` is the same byte as `activity_class` under a second name, and
    /// `spo2_candidate_82` is a gated 70-100 view of `auxByte82`. Neither is persisted in its own
    /// right — both are RECOVERABLE from a byte that is, which is equally good grounds for refusing
    /// to bank them and not the same claim. The old name asserted each "already has a durable home",
    /// which reads as "SpO2 is being stored" and is not true.
    func testNoSlotDuplicatesAFieldAlreadyReachable() {
        let recoverableFromABankedField: Set<String> = [
            "unix", "heart_rate", "rr_intervals", "gravity_x", "gravity_y", "gravity_z",
            "dynamic_acceleration", "skin_temp_raw", "temp_aux_1_raw", "temp_aux_2_raw",
            "step_motion_counter", "activity_class", "motion_wear_quality", "sleep_state",
            "sleep_state_byte", "spo2_candidate_82", "ppg_waveform",
        ]
        for slot in V18AuxSlot.allCases {
            XCTAssertFalse(recoverableFromABankedField.contains(slot.decoderKey),
                           "\(slot.decoderKey) is already reachable from a banked field — banking it twice is waste")
        }
    }
}
