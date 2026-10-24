import XCTest
@testable import WhoopProtocol

/// #891: the flash-banked ECG record — type 47 HISTORICAL_DATA, data revision 16, 1584 bytes.
///
/// Twin of the Kotlin `Whoop5EcgR16Test`. The layout is a protocol fact, so both platforms carry the decode
/// and both pin it; a test only on the side that happens to call it today would not stop the other drifting.
///
/// Fixtures here are SYNTHETIC, built from the layout in `docs/PROTOCOL_ECG.md`, in the same style as the
/// existing R17 tests. They verify the decoder against the documented contract. They are not a hardware
/// measurement and nothing here establishes volts per count, a sample rate, or anything clinical.
final class Whoop5EcgR16Tests: XCTestCase {

    /// A complete, CRC-valid R16 frame.
    ///
    /// `slots` are written as raw three-byte groups from the waveform offset, so a test can plant exact tag
    /// bytes rather than go through the decoder's own arithmetic to build its input.
    private func r16Frame(declaredCount: Int,
                          slots: [(UInt8, UInt8, UInt8)] = [],
                          leadsOffCount: UInt8 = 10,
                          leadsI: [UInt16] = [],
                          leadsQ: [UInt16] = [],
                          liveHR: UInt8 = 0,
                          revision: UInt8 = Whoop5Ecg.r16Revision,
                          type: UInt8 = Whoop5Ecg.storedRecordType,
                          alignment: UInt8 = 0) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: Whoop5Ecg.r16InnerLength)
        inner[0] = type
        inner[1] = revision
        inner[2] = 0x5a                                  // headerSecondary
        put32(&inner, 3, 0x0001_2345)                    // sequence / record index
        put32(&inner, 7, 0x6543_0001)                    // strapSeconds
        put16(&inner, 11, 16_384)                        // subseconds
        inner[13] = 3                                    // quality
        inner[14] = 0x08                                 // flags: presence
        inner[15] = 1                                    // arrhythmia check result
        inner[16] = 2                                    // classifier state (terminal)
        inner[17] = 100                                  // progress (terminal)
        inner[18] = 0x00                                 // unreadable mask
        inner[19] = 64                                   // averageHR
        inner[20] = liveHR
        put16(&inner, 21, 42)                            // variability
        inner[23] = 0                                    // reserved
        put16(&inner, 24, declaredCount)
        for (i, s) in slots.enumerated() {
            let o = Whoop5Ecg.r16SampleStart + i * Whoop5Ecg.r16SampleSlotBytes
            guard o + 2 < Whoop5Ecg.r16LeadsOffCountOffset else { break }
            inner[o] = s.0; inner[o + 1] = s.1; inner[o + 2] = s.2
        }
        inner[Whoop5Ecg.r16LeadsOffCountOffset] = leadsOffCount
        for (i, v) in leadsI.enumerated() where i < Whoop5Ecg.r16LeadsOffSlots {
            put16(&inner, Whoop5Ecg.r16LeadsOffIStart + i * 2, Int(v))
        }
        for (i, v) in leadsQ.enumerated() where i < Whoop5Ecg.r16LeadsOffSlots {
            put16(&inner, Whoop5Ecg.r16LeadsOffQStart + i * 2, Int(v))
        }
        inner[Whoop5Ecg.r16AlignmentOffset] = alignment
        return puffinCommandFrame(cmd: inner[2], seq: inner[1],
                                 payload: Array(inner.dropFirst(3)), type: inner[0])
    }

    private func put16(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8(v & 0xff); b[i + 1] = UInt8((v >> 8) & 0xff)
    }

    private func put32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        for k in 0..<4 { b[i + k] = UInt8((v >> (8 * k)) & 0xff) }
    }

    // MARK: Framing

    func testTheFixtureBuilderProducesTheDocumentedFrameAndInnerLengths() {
        let f = r16Frame(declaredCount: 0)
        XCTAssertEqual(f.count, Whoop5Ecg.r16RecordLength)
        XCTAssertEqual(Whoop5Ecg.r16RecordLength - Whoop5Ecg.r16InnerLength, 12)  // 8 envelope + 4 CRC32
        XCTAssertTrue(verifyFrame(f, family: .whoop5).ok)
        XCTAssertTrue(Whoop5Ecg.isR16Record(f))
        XCTAssertNotNil(Whoop5Ecg.r16FromFrame(f))
    }

    func testACorruptFrameIsRefusedBeforeAnyFieldIsRead() {
        var f = r16Frame(declaredCount: 1, slots: [(0x80, 0x01, 0x02)])
        XCTAssertNotNil(Whoop5Ecg.r16FromFrame(f))
        f[600] ^= 0xff                                   // flip a waveform byte, breaking the CRC32
        XCTAssertNil(Whoop5Ecg.r16FromFrame(f))
    }

    func testOnlyType47Revision16IsAnR16Record() {
        XCTAssertNil(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0, revision: 17)))
        XCTAssertNil(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0, type: 43)))
        XCTAssertFalse(Whoop5Ecg.isR16Record(r16Frame(declaredCount: 0, revision: 17)))
        // An R17 frame must not decode as an R16, and vice versa: the two revisions share a header and are
        // told apart ONLY by inner[1], so a decoder that ignored it would read 240 bytes as 1584.
        XCTAssertNil(Whoop5Ecg.parseR16(inner: [UInt8](repeating: 0, count: 228)))
    }

    func testAShortInnerRecordIsRefusedRatherThanDecodedWithAShrunkSampleBlock() {
        // R17 derives its extent from the declared count; R16 cannot. Every region after the waveform is
        // at a FIXED offset, so decoding a short buffer would read the lead-off arrays from inside the
        // waveform and report them as diagnostics.
        var inner = [UInt8](repeating: 0, count: Whoop5Ecg.r16InnerLength - 1)
        inner[0] = Whoop5Ecg.storedRecordType
        inner[1] = Whoop5Ecg.r16Revision
        XCTAssertNil(Whoop5Ecg.parseR16(inner: inner))
    }

    // MARK: Sample coding

    func testSamplesAreBigEndianEighteenBitTwosComplement() {
        // The documented rule: raw18 = ((b0 & 3) << 16) | (b1 << 8) | b2, then sign-extend at 18 bits.
        // Tag bits 7/6 are flags and bits 2-5 reserved, so a tag of 0xFF must not reach the value.
        // Flat 4-tuples with explicit element types: a nested-tuple literal array here exceeds the Swift
        // type-checker's budget outright (it refuses the file, it does not merely slow down).
        var cases = [(UInt8, UInt8, UInt8, Int32)]()
        cases.append((0x00, 0x00, 0x00, 0))
        cases.append((0x00, 0x00, 0x01, 1))
        cases.append((0x00, 0x01, 0x00, 256))
        cases.append((0x01, 0x00, 0x00, 65_536))
        cases.append((0x01, 0xff, 0xff, 131_071))      // the largest positive value
        cases.append((0x02, 0x00, 0x00, -131_072))     // the sign threshold itself
        cases.append((0x03, 0xff, 0xff, -1))           // all 18 bits set
        cases.append((0xfc, 0x12, 0x34, 0x1234))       // flags + reserved set, value bits clear
        for (b0, b1, b2, expected) in cases {
            let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 1, slots: [(b0, b1, b2)]))
            XCTAssertEqual(got?.samples.first, expected, "slot \(b0) \(b1) \(b2)")
        }
    }

    func testTheCodingRangeIsExactlyEighteenSignedBits() {
        XCTAssertEqual(Whoop5Ecg.r16SampleSignThreshold, 131_072)
        XCTAssertEqual(Whoop5Ecg.r16SampleModulus, 262_144)
        XCTAssertEqual(Whoop5Ecg.r16SampleModulus, Whoop5Ecg.r16SampleSignThreshold * 2)
    }

    func testReadingASlotAsLittleEndianInt16WouldBeADifferentNumber() {
        // Pinned as a NEGATIVE: this is the misdecode that puts a ~65,000-count cliff at every zero
        // crossing, and it is worth a test that the right answer is not the wrong one by coincidence.
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 1, slots: [(0x03, 0xff, 0xfe)]))
        XCTAssertEqual(got?.samples.first, -2)
        let littleEndian = Int16(bitPattern: UInt16(0xff) | (UInt16(0xfe) << 8))
        XCTAssertNotEqual(Int32(littleEndian), got?.samples.first)
    }

    // MARK: Counts and capacity

    func testAFullRecordCarriesFiveHundredSamples() {
        var slots = [(UInt8, UInt8, UInt8)]()
        for i in 0..<500 {
            let hi: UInt8 = UInt8((i >> 16) & 0x03)
            let mid: UInt8 = UInt8((i >> 8) & 0xff)
            let lo: UInt8 = UInt8(i & 0xff)
            slots.append((hi, mid, lo))
        }
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 500, slots: slots))
        XCTAssertEqual(got?.sampleCount, 500)
        XCTAssertEqual(got?.samples.count, 500)
        XCTAssertEqual(got?.samples.first, 0)
        XCTAssertEqual(got?.samples.last, 499)
        XCTAssertEqual(Whoop5Ecg.r16MaxSamples, 500)
    }

    func testAShortAndAnEmptyCountAreBothValid() {
        // The opening records of a real run declare 0 and then 245 before the first full 500.
        for n in [0, 245, 499] {
            let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: n))
            XCTAssertEqual(got?.samples.count, n, "declared \(n)")
            XCTAssertEqual(got?.sampleTags.count, n, "declared \(n)")
        }
    }

    func testADeclaredCountAboveCapacityIsRefused() {
        XCTAssertNil(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 501)))
        XCTAssertNil(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0xffff)))
    }

    func testTheWaveformRegionStopsBeforeTheLeadOffTrailer() {
        // 500 slots of 3 bytes from offset 26 ends exactly where the lead-off count begins. If these two
        // ever disagree a full record would decode its own diagnostics as waveform.
        XCTAssertEqual(Whoop5Ecg.r16SampleStart + Whoop5Ecg.r16MaxSamples * Whoop5Ecg.r16SampleSlotBytes,
                       Whoop5Ecg.r16LeadsOffCountOffset)
    }

    // MARK: Flags

    func testFlagSixAndFlagSevenAndReservedBitsComeFromTheTagByte() {
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 4, slots: [
            (0x00, 0, 0),   // neither flag
            (0x40, 0, 0),   // flag 6 only
            (0x80, 0, 0),   // flag 7 only
            (0x3c, 0, 0),   // reserved bits 2-5 only
        ]))
        XCTAssertEqual(got?.flag6(at: 0), false)
        XCTAssertEqual(got?.flag7(at: 0), false)
        XCTAssertEqual(got?.flag6(at: 1), true)
        XCTAssertEqual(got?.flag7(at: 1), false)
        XCTAssertEqual(got?.flag6(at: 2), false)
        XCTAssertEqual(got?.flag7(at: 2), true)
        XCTAssertEqual(got?.reservedBits(at: 3), 0x0f)
        XCTAssertEqual(got?.reservedBits(at: 0), 0)
        // Out of range reads nil rather than trapping or inventing a value.
        XCTAssertNil(got?.flag6(at: 4))
        XCTAssertNil(got?.flag7(at: -1))
        XCTAssertNil(got?.reservedBits(at: 99))
    }

    func testTheTagByteIsRetainedWholeSoNothingIsDiscarded() {
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 1, slots: [(0xff, 0, 0)]))
        XCTAssertEqual(got?.sampleTags.first, 0xff)
    }

    // MARK: The flag-7 grouping

    func testTheLeadStateGroupingIsFiftyOneThenEightOfFiftyThenFortyNine() throws {
        // The documented 500-raw / 10-slower mapping. The boundary sample keeps the EARLIER entry before
        // the index advances, so entry 0 covers 0...50 — 51 samples, not 50. Ten equal groups of 50 is the
        // wrong answer the doc explicitly tells implementers not to substitute.
        let r16 = try XCTUnwrap(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 500, leadsOffCount: 10)))
        XCTAssertEqual(r16.leadStateGroup(at: 0), 0)
        XCTAssertEqual(r16.leadStateGroup(at: 50), 0)
        XCTAssertEqual(r16.leadStateGroup(at: 51), 1)
        XCTAssertEqual(r16.leadStateGroup(at: 100), 1)
        XCTAssertEqual(r16.leadStateGroup(at: 101), 2)
        XCTAssertEqual(r16.leadStateGroup(at: 450), 8)
        XCTAssertEqual(r16.leadStateGroup(at: 451), 9)
        XCTAssertEqual(r16.leadStateGroup(at: 499), 9)

        // And the group sizes that mapping implies, counted rather than asserted by hand.
        var sizes = [Int](repeating: 0, count: 10)
        for i in 0..<500 {
            let g: Int = try XCTUnwrap(r16.leadStateGroup(at: i))
            sizes[g] += 1
        }
        XCTAssertEqual(sizes[0], 51)
        XCTAssertEqual(sizes[9], 49)
        for g in 1...8 { XCTAssertEqual(sizes[g], 50, "group \(g)") }
        XCTAssertEqual(sizes.reduce(0, +), 500)
    }

    func testTheGroupingIsNotOfferedWhereItIsNotEstablished() {
        // A zero count omits flag-7 insertion, and nonzero counts other than ten are not attested as input
        // to the rule. nil is the honest answer; a divisor computed anyway would be invented.
        for count in [UInt8(0), 1, 9, 11] {
            let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 500, leadsOffCount: count))
            XCTAssertNil(got?.leadStateGroup(at: 0), "count \(count)")
        }
        // Nor for a record that is not a full 500, which is the only raw count the table covers.
        let short = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 245, leadsOffCount: 10))
        XCTAssertNil(short?.leadStateGroup(at: 0))
        XCTAssertNil(short?.leadStateGroup(at: 500))
    }

    // MARK: Lead-off diagnostics

    func testTheLeadOffArraysAreAtFixedOffsetsAndDoNotMoveWithEitherCount() {
        var i = [UInt16]()
        var q = [UInt16]()
        for k in 0..<Whoop5Ecg.r16LeadsOffSlots {
            i.append(UInt16(1000 + k))
            q.append(UInt16(2000 + k))
        }
        // Declared waveform count of ZERO: a `header + count * width` formula would place the arrays at
        // offset 26 and read zeros. They are fixed, so they are still here.
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0, leadsI: i, leadsQ: q))
        XCTAssertEqual(got?.leadsOffIRaw, i)
        XCTAssertEqual(got?.leadsOffQRaw, q)
        XCTAssertEqual(got?.leadsOffIRaw.count, Whoop5Ecg.r16LeadsOffSlots)
        XCTAssertEqual(got?.leadsOffQRaw.count, Whoop5Ecg.r16LeadsOffSlots)

        // And identical on a full record, which is what "fixed" means.
        let full = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 500, leadsI: i, leadsQ: q))
        XCTAssertEqual(full?.leadsOffIRaw, i)
        XCTAssertEqual(full?.leadsOffQRaw, q)
    }

    /// The halfwords are read little-endian, which `docs/PROTOCOL_ECG.md` does not state and which the
    /// waveform slots in the same record contradict. Pinned against the frame's OWN bytes rather than
    /// against the fixture's writer, so the chosen reading is a visible decision and flipping it fails
    /// here: `put16` is little-endian too, so a round-trip through it would pin nothing.
    func testTheLeadOffHalfwordsAreReadLittleEndianByChoice() {
        var i = [UInt16](repeating: 0, count: Whoop5Ecg.r16LeadsOffSlots)
        var q = [UInt16](repeating: 0, count: Whoop5Ecg.r16LeadsOffSlots)
        i[0] = 0x1234
        q[0] = 0xabcd
        let frame = r16Frame(declaredCount: 0, leadsI: i, leadsQ: q)

        // What is actually on the wire, read straight out of the frame.
        let iByte = Whoop5Ecg.rawTypeOffset + Whoop5Ecg.r16LeadsOffIStart
        let qByte = Whoop5Ecg.rawTypeOffset + Whoop5Ecg.r16LeadsOffQStart
        XCTAssertEqual(frame[iByte], 0x34)
        XCTAssertEqual(frame[iByte + 1], 0x12)
        XCTAssertEqual(frame[qByte], 0xcd)
        XCTAssertEqual(frame[qByte + 1], 0xab)

        // Low byte at the lower address, so these and not 0x3412 / 0xcdab.
        let got = Whoop5Ecg.r16FromFrame(frame)
        XCTAssertEqual(got?.leadsOffIRaw[0], 0x1234)
        XCTAssertEqual(got?.leadsOffQRaw[0], 0xabcd)
    }

    func testTheTwoLeadOffChannelsDoNotOverlap() {
        XCTAssertEqual(Whoop5Ecg.r16LeadsOffIStart + Whoop5Ecg.r16LeadsOffSlots * 2,
                       Whoop5Ecg.r16LeadsOffQStart)
        XCTAssertEqual(Whoop5Ecg.r16LeadsOffQStart + Whoop5Ecg.r16LeadsOffSlots * 2,
                       Whoop5Ecg.r16AlignmentOffset)
        XCTAssertEqual(Whoop5Ecg.r16AlignmentOffset + 1, Whoop5Ecg.r16InnerLength)
    }

    func testAnOverCapacityLeadOffCountIsReportedNotClamped() {
        // Clamping would invent a count the strap never sent. The record still decodes — the arrays are at
        // fixed offsets, so a bad count cannot corrupt the waveform — and the anomaly is surfaced.
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 500, leadsOffCount: 12))
        XCTAssertEqual(got?.leadsOffCountRaw, 12)
        XCTAssertEqual(got?.leadsOffCountWithinCapacity, false)
        XCTAssertEqual(got?.samples.count, 500)
        XCTAssertEqual(got?.leadsOffIRaw.count, Whoop5Ecg.r16LeadsOffSlots)

        let ok = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 500, leadsOffCount: 11))
        XCTAssertEqual(ok?.leadsOffCountWithinCapacity, true)
    }

    func testTheAlignmentByteIsCarriedRatherThanAssumed() {
        XCTAssertEqual(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0))?.alignmentByte, 0)
        // Documented as zero; carried verbatim so a caller can see when it is not.
        XCTAssertEqual(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0, alignment: 7))?.alignmentByte, 7)
    }

    // MARK: The shared status header

    func testTheStatusHeaderDecodesIdenticallyToR17() throws {
        // R16 and R17 share their status region byte for byte. The two decoders read it with their own
        // expressions rather than one shared reader, because `parseR17` is the live path; this is what
        // stops them drifting, and it is the check that would have caught the 101st-sample bug a revision
        // earlier if it had existed for the length constants.
        let r16 = try XCTUnwrap(Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 0, liveHR: 71)))

        var inner17 = [UInt8](repeating: 0, count: 228)
        inner17[0] = Whoop5Ecg.rawRecordType
        inner17[1] = Whoop5Ecg.r17Revision
        inner17[2] = 0x5a
        for k in 0..<4 { inner17[3 + k] = UInt8((0x0001_2345 >> (8 * k)) & 0xff) }
        for k in 0..<4 { inner17[7 + k] = UInt8((0x6543_0001 >> (8 * k)) & 0xff) }
        inner17[11] = UInt8(16_384 & 0xff); inner17[12] = UInt8((16_384 >> 8) & 0xff)
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
        let r17 = try XCTUnwrap(Whoop5Ecg.parseR17(inner: inner17))

        XCTAssertEqual(r16.headerSecondary, r17.headerSecondary)
        XCTAssertEqual(r16.sequence, r17.sequence)
        XCTAssertEqual(r16.strapSeconds, r17.strapSeconds)
        XCTAssertEqual(r16.subseconds, r17.subseconds)
        XCTAssertEqual(r16.signalQualityRaw, r17.signalQualityRaw)
        XCTAssertEqual(r16.signalQuality, r17.signalQuality)
        XCTAssertEqual(r16.flags, r17.flags)
        XCTAssertEqual(r16.presence, r17.presence)
        XCTAssertEqual(r16.arrhythmiaCheckResultRaw, r17.arrhythmiaCheckResultRaw)
        XCTAssertEqual(r16.arrhythmiaCheckResult, r17.arrhythmiaCheckResult)
        XCTAssertEqual(r16.classifierState, r17.classifierState)
        XCTAssertEqual(r16.progress, r17.progress)
        XCTAssertEqual(r16.unreadable, r17.unreadable)
        XCTAssertEqual(r16.averageHR, r17.averageHR)
        XCTAssertEqual(r16.liveHR, r17.liveHR)
        XCTAssertEqual(r16.variabilityRaw, r17.variabilityRaw)
        XCTAssertEqual(r16.reserved, r17.reserved)
        XCTAssertEqual(r16.isTerminal, r17.isTerminal)
        XCTAssertEqual(r16.isInvalid, r17.isInvalid)
    }

    func testTheSampleBlockBeginsAtTheSameOffsetAsR17() {
        XCTAssertEqual(Whoop5Ecg.r16SampleStart, Whoop5Ecg.r17SampleStart)
        XCTAssertEqual(Whoop5Ecg.r16SampleStart, Whoop5Ecg.r17FixedLength)
    }

    func testTheUnavailableVariabilitySentinelIsSharedWithR17() {
        var f = r16Frame(declaredCount: 0)
        // inner[21...22] is frame[29...30].
        f[29] = 0xff; f[30] = 0xff
        f = reseal(f)
        XCTAssertNil(Whoop5Ecg.r16FromFrame(f)?.variabilityRaw)
    }

    /// Rebuild a frame's CRCs after a test mutates a payload byte in place.
    private func reseal(_ frame: [UInt8]) -> [UInt8] {
        let inner = Array(frame[Whoop5Ecg.rawTypeOffset..<(frame.count - 4)])
        return puffinCommandFrame(cmd: inner[2], seq: inner[1],
                                 payload: Array(inner.dropFirst(3)), type: inner[0])
    }

    // MARK: What this record is not

    func testNothingHereClaimsARateOrAVoltage() {
        // A guard on the module's own vocabulary. The R16 decode establishes coding and structure; the
        // moment a constant here names volts, millivolts or a sample rate, that is a claim the thread's
        // evidence does not support and it should fail review rather than ship quietly.
        let got = Whoop5Ecg.r16FromFrame(r16Frame(declaredCount: 1, slots: [(0x00, 0x01, 0x00)]))
        XCTAssertEqual(got?.samples.first, 256)          // counts, not microvolts
        XCTAssertEqual(Whoop5Ecg.r16MaxSamples, 500)     // slots per record, not samples per second
    }
}
